#!/bin/bash
# Sets the VM's scheduled shutdown. Run by Terraform (provision.tf) over SSH.
#
# Usage: shutdown-timer.sh <reset|append> <hours>
#   reset  <hours>: shut down <hours> from now
#   append <hours>: shut down <hours> after the currently scheduled shutdown
#                   (from now if nothing is scheduled)
#   <hours> = 0   : cancel any scheduled shutdown
set -euo pipefail

MODE="${1:?mode (reset|append) required}"
HOURS="${2:?hours required}"
SCHEDULED_FILE="${SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}"

if [ "$HOURS" -eq 0 ]; then
  sudo shutdown -c 2>/dev/null || true
  echo "No shutdown scheduled (run_hours = 0)"
  exit 0
fi

MINUTES=$((HOURS * 60))
NOW=$(date +%s)

if [ "$MODE" = "append" ]; then
  # systemd stores the pending shutdown time as USEC=<microseconds since epoch>.
  USEC=$(sudo sed -n 's/^USEC=//p' "$SCHEDULED_FILE" 2>/dev/null || true)
  if [ -n "$USEC" ]; then
    REMAINING=$(((USEC / 1000000 - NOW) / 60))
    if [ "$REMAINING" -gt 0 ]; then
      echo "Currently scheduled: $(date -d "@$((USEC / 1000000))") (${REMAINING} min left)"
      MINUTES=$((REMAINING + MINUTES))
    fi
  else
    echo "No shutdown scheduled yet; counting ${HOURS}h from now."
  fi
fi

# A new shutdown command replaces the pending one.
sudo shutdown -h "+${MINUTES}" "run_hours limit reached (${MODE} ${HOURS}h)"
echo "Shutdown (${MODE} ${HOURS}h) scheduled for $(date -d "@$((NOW + MINUTES * 60))")"
