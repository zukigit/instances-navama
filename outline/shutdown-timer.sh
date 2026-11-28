#!/bin/bash
# Sets the run_hours period on a running VM: its end (the scheduled shutdown)
# and, when access keys are managed, the data usage resets. Run by Terraform
# (provision.tf) over SSH. See MODES.md.
#
# Usage: shutdown-timer.sh <reset|append> <hours> <manage_keys> <plan_timestamp>
#   reset  <hours>: new period now: usage 0 now, ends <hours> from now
#   append <hours>: extend the current period: ends <hours> after its current
#                   end; usage resets to 0 at that current end
#   <hours> = 0   : no end (cancels the shutdown); reset still resets usage now,
#                   append still resets usage at the current end
#   manage_keys   : "true" when access_keys is set
#   plan_timestamp: when this terraform plan was made (RFC 3339)
#
# The period end is saved in END_FILE; the boot script reads it, so a reboot
# keeps the period instead of starting a new one.
set -euo pipefail

MODE="${1:?mode (reset|append) required}"
HOURS="${2:?hours required}"
MANAGE="${3:-false}"
PLAN_TS="${4:-}"
END_FILE="${END_FILE:-/var/lib/outline-period/end}"
BOOT_STATE="${BOOT_STATE:-/run/outline-period/boot}"
SCHEDULED_FILE="${SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}"
KEYS="${KEYS:-/usr/local/sbin/outline-access-keys}"
BTIME="${BTIME:-$(awk '/^btime/ {print $2}' /proc/stat)}"
NOW=$(date +%s)

keys() { sudo "$KEYS" "$@"; }
fmt() { date -d "@$1"; }

# Current period end, if it is still ahead.
OLD_END=$(sudo cat "$END_FILE" 2>/dev/null || true)
if [ -z "$OLD_END" ] || [ "$OLD_END" -le "$NOW" ]; then
  # No saved end (e.g. set up before this existed): use systemd's pending shutdown.
  USEC=$(sudo sed -n 's/^USEC=//p' "$SCHEDULED_FILE" 2>/dev/null || true)
  OLD_END=""
  if [ -n "$USEC" ] && [ $((USEC / 1000000)) -gt "$NOW" ]; then OLD_END=$((USEC / 1000000)); fi
fi

# Was the VM started by this apply (booted after the plan), and did that boot
# start a new period? Then the boot already did what reset does (usage 0, new
# end), so neither reset again nor append on top of it.
if [ "$HOURS" -gt 0 ] && [ -n "$PLAN_TS" ] && [ "$BTIME" -ge "$(date -d "$PLAN_TS" +%s)" ]; then
  for _ in $(seq 1 30); do # the boot script may still be running
    [ -f "$BOOT_STATE" ] && break
    sleep 2
  done
  if [ "$(cat "$BOOT_STATE" 2>/dev/null)" = new ]; then
    echo "VM started by this apply and its boot started a new period; using it."
    MODE=boot
  fi
fi

if [ "$MODE" = reset ] && [ -x "$KEYS" ]; then
  keys cancel-resets
  if [ "$MANAGE" = true ]; then keys reset-usage; fi
fi
if [ "$MODE" = append ] && [ -n "$OLD_END" ]; then
  echo "Current period ends $(fmt "$OLD_END") ($(((OLD_END - NOW) / 60)) min left)"
  if [ "$MANAGE" = true ]; then keys schedule-reset "$OLD_END"; fi
fi

if [ "$HOURS" -eq 0 ]; then
  sudo shutdown -c 2>/dev/null || true
  sudo rm -f "$END_FILE"
  echo "No shutdown scheduled (run_hours = 0)"
  exit 0
fi

if [ "$MODE" = append ] && [ -n "$OLD_END" ]; then
  END=$((OLD_END + HOURS * 3600))
else
  [ "$MODE" = append ] && echo "No period running; counting ${HOURS}h from now."
  END=$((NOW + HOURS * 3600))
fi

sudo mkdir -p "$(dirname "$END_FILE")"
echo "$END" | sudo tee "$END_FILE" >/dev/null
# A new shutdown command replaces the pending one (rounded up to the minute).
sudo shutdown -h "+$(((END - NOW + 59) / 60))" "run_hours period ended (${MODE} ${HOURS}h)"
echo "Period (${MODE} ${HOURS}h) ends $(fmt "$END")"
