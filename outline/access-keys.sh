#!/bin/bash
# Manages Outline access keys through the local management API. Installed on
# the VM as /usr/local/sbin/outline-access-keys by Terraform (provision.tf) and
# run as root. See MODES.md for when each command runs.
#
# Usage:
#   outline-access-keys sync <keys_json_base64>
#       Make the server's keys match access_keys (terraform.tfvars), by name:
#       existing keys keep their ss:// link and usage and get the new limit,
#       new names get new keys, other keys are deleted. Prints every link.
#   outline-access-keys reset-usage
#       Reset every key's data usage to 0, keeping its ss:// link.
#   outline-access-keys schedule-reset <epoch>
#       Run reset-usage at <epoch> (a systemd timer that survives reboots).
#   outline-access-keys cancel-resets
#       Remove all pending reset-usage timers.
#   outline-access-keys restore
#       Create again any key from the last reset-usage backup that is missing
#       (same password and port, so the same link). For a failed reset; every
#       reset-usage also does this first.
#
# Only one command runs at a time (a lock), so a usage reset at boot, a missed
# reset timer and Terraform's sync can't change the same keys at once.
#
# How reset-usage works: Outline counts usage per key ID and has no "reset
# usage" call, so each key is deleted and created again with the same name,
# password, port, method and data limit. The ss:// link only contains the
# password, host and port, so it stays the same; the new key ID starts at 0.
set -euo pipefail

ACCESS=/opt/outline/access.txt
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
STATE_DIR="${STATE_DIR:-/var/lib/outline-access-keys}"
LOCK_FILE="${LOCK_FILE:-/run/outline-access-keys.lock}"
UNIT_PREFIX=outline-usage-reset-
SELF=/usr/local/sbin/outline-access-keys
BASE=""

# Management API on this VM. OUTLINE_API overrides it (for testing).
init_api() {
  if [ -n "${OUTLINE_API:-}" ]; then
    BASE=$OUTLINE_API
  else
    [ -f "$ACCESS" ] || { echo "access-keys: $ACCESS not found (Outline not installed)" >&2; exit 1; }
    BASE=$(sed -n 's/^apiUrl://p' "$ACCESS" | sed -E 's#^https://[^:/]+#https://127.0.0.1#')
  fi
  ensure_jq
  # Outline's containers may still be starting (e.g. right after boot).
  for _ in $(seq 1 60); do
    api GET /server >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "access-keys: Outline API not reachable" >&2
  exit 1
}

# api <METHOD> <path> [curl args...]
api() {
  local method=$1 path=$2
  shift 2
  curl -fsSk -X "$method" -H 'Content-Type: application/json' "$@" "$BASE$path"
}

ensure_jq() {
  command -v jq >/dev/null && return 0
  echo "access-keys: installing jq"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq >/dev/null ||
    { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq >/dev/null; }
}

gb() { # bytes -> "N GB" (decimal, like Outline Manager)
  if [ -z "$1" ] || [ "$1" = null ]; then echo "no limit"; else echo "$(($1 / 1000000000)) GB"; fi
}

# Newest backup left by a failed reset-usage, if any.
latest_backup() { ls -1t "$STATE_DIR"/before-reset-*.json 2>/dev/null | head -n1 || true; }

# create_key <json body> -> prints the created key's JSON. Retries briefly.
create_key() {
  local resp
  for _ in 1 2 3 4 5; do
    resp=$(api POST /access-keys -d "$1") && { echo "$resp"; return 0; }
    sleep 2
  done
  return 1
}

# Removes reset-usage timers: all of them, or with "past" only elapsed ones.
remove_reset_units() {
  local which=$1 now changed=0 unit t
  now=$(date +%s)
  for unit in "$UNIT_DIR/$UNIT_PREFIX"*.timer; do
    [ -e "$unit" ] || continue
    t=$(basename "$unit" .timer)
    t=${t#"$UNIT_PREFIX"}
    if [ "$which" = all ] || [ "$t" -le "$now" ]; then
      systemctl disable --now "$(basename "$unit")" >/dev/null 2>&1 || true
      rm -f "$unit" "$UNIT_DIR/$UNIT_PREFIX$t.service"
      [ "$which" = all ] && echo "access-keys: cancelled usage reset at $(date -d "@$t")"
      changed=1
    fi
  done
  if [ "$changed" = 1 ]; then systemctl daemon-reload; fi
}

cmd_sync() {
  local keys_json
  keys_json=$(echo "${1:?keys_json_base64 required}" | base64 -d)
  init_api

  local current key id name
  current=$(api GET /access-keys)
  # Keys not in access_keys (and duplicate names) are deleted.
  while read -r key; do
    id=$(jq -r .id <<<"$key")
    name=$(jq -r .name <<<"$key")
    if api DELETE "/access-keys/$id" >/dev/null; then
      echo "access-keys: deleted '$name' (key $id: not in access_keys, or a duplicate name)"
    fi
  done < <(jq -c --argjson want "$keys_json" '
    .accessKeys | group_by(.name)
    | map(if (.[0].name | in($want)) then .[1:] else . end) | add // [] | .[]' <<<"$current")

  echo
  echo "===== Outline access keys ====="
  local entry limit old prev resp failed=0 backups=()
  mapfile -t backups < <(ls -1t "$STATE_DIR"/before-reset-*.json 2>/dev/null || true)
  while read -r entry; do
    name=$(jq -r .key <<<"$entry")
    limit=$(jq -c 'if .value.data_limit_gb == null then null
      else {bytes: (.value.data_limit_gb * 1000000000 | floor)} end' <<<"$entry")
    old=$(jq -c --arg n "$name" '[.accessKeys[] | select(.name == $n)][0] // empty' <<<"$current")
    if [ -n "$old" ]; then
      # Existing key: only the limit changes; link and usage stay.
      id=$(jq -r .id <<<"$old")
      if [ "$limit" = null ]; then
        api DELETE "/access-keys/$id/data-limit" >/dev/null 2>&1 || true
      else
        api PUT "/access-keys/$id/data-limit" -d "{\"limit\":$limit}" >/dev/null
      fi
      echo "$name ($(gb "$(jq -r '.bytes // empty' <<<"$limit")")): $(jq -r .accessUrl <<<"$old")"
      continue
    fi
    # Missing, but lost in a failed usage reset: create it again with its old
    # password and port, so the link stays the same.
    prev=""
    if [ "${#backups[@]}" -gt 0 ]; then # newest backup first
      prev=$(jq -c -s --arg n "$name" '[.[].accessKeys[] | select(.name == $n)][0] // empty' "${backups[@]}")
    fi
    if [ -n "$prev" ] && resp=$(create_key "$(jq -c --argjson l "$limit" '{name, password, port, method}
      + (if $l == null then {} else {limit: $l} end)' <<<"$prev")"); then
      echo "$name ($(gb "$(jq -r '.dataLimit.bytes // empty' <<<"$resp")"), restored, same link): $(jq -r .accessUrl <<<"$resp")"
    elif [ -z "$prev" ] && resp=$(create_key "$(jq -c -n --arg n "$name" --argjson l "$limit" \
      '{name: $n} + (if $l == null then {} else {limit: $l} end)')"); then
      echo "$name ($(gb "$(jq -r '.dataLimit.bytes // empty' <<<"$resp")"), NEW link): $(jq -r .accessUrl <<<"$resp")"
    else
      echo "access-keys: FAILED to create '$name'" >&2
      failed=1
    fi
  done < <(jq -c 'to_entries[]' <<<"$keys_json")
  # The keys now match access_keys, so old backups must not bring back keys
  # that were removed on purpose.
  if [ "$failed" = 0 ]; then rm -f "$STATE_DIR"/before-reset-*.json; fi
  return "$failed"
}

cmd_reset_usage() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # First bring back keys an earlier failed reset left missing (same links).
  if [ -n "$(latest_backup)" ]; then cmd_restore || true; fi
  # A new period at boot and a missed reset timer can both fire right after a
  # boot; one reset is enough (and one disconnect).
  local last
  last=$(cat "$STATE_DIR/last-reset" 2>/dev/null || echo 0)
  if [ $(($(date +%s) - last)) -lt 300 ]; then
    echo "access-keys: usage was reset less than 5 minutes ago; skipping"
    return 0
  fi
  init_api
  # Backup in case a key cannot be created again (contains the key passwords).
  local backup keys
  backup="$STATE_DIR/before-reset-$(date +%s).json"
  keys=$(api GET /access-keys)
  (umask 077 && echo "$keys" >"$backup")

  local key id name body resp failed=0
  while read -r key; do
    id=$(jq -r .id <<<"$key")
    name=$(jq -r .name <<<"$key")
    body=$(jq -c '{name, password, port, method}
      + (if .dataLimit == null then {} else {limit: .dataLimit} end)' <<<"$key")
    if ! api DELETE "/access-keys/$id" >/dev/null; then
      echo "access-keys: skipped '$name' (key $id is already gone)"
      continue
    fi
    if resp=$(create_key "$body"); then
      echo "access-keys: usage reset to 0 for '$name' (key $id -> $(jq -r .id <<<"$resp"), same link)"
      continue
    fi
    echo "access-keys: FAILED to recreate '$name' (key $id); retrying from the backup" >&2
    # Bring it back from the backup (same link, new ID so usage 0 too), then
    # carry on with the other keys. If that fails, stop: at most one key missing.
    local restored=false
    for _ in 1 2 3; do
      sleep "${RESTORE_WAIT:-10}"
      if cmd_restore keep; then restored=true; break; fi
    done
    if [ "$restored" = false ]; then
      echo "access-keys: '$name' still missing; other keys left as they are. Run 'sudo outline-access-keys restore' later (the next sync also restores it)." >&2
      failed=1
      break
    fi
  done < <(jq -c '.accessKeys[]' <<<"$keys")

  if [ "$failed" = 0 ]; then rm -f "$backup"; fi
  date +%s >"$STATE_DIR/last-reset"
  return "$failed"
}

# restore [keep]: with "keep", the backup is not deleted afterwards.
cmd_restore() {
  local backup
  backup=$(latest_backup)
  if [ -z "$backup" ]; then
    echo "access-keys: no backup found in $STATE_DIR (nothing to restore)"
    return 0
  fi
  init_api
  local current key name body resp failed=0
  current=$(api GET /access-keys)
  echo "access-keys: restoring missing keys from $backup"
  while read -r key; do
    name=$(jq -r .name <<<"$key")
    body=$(jq -c '{name, password, port, method}
      + (if .dataLimit == null then {} else {limit: .dataLimit} end)' <<<"$key")
    if resp=$(create_key "$body"); then
      echo "access-keys: restored '$name' (key $(jq -r .id <<<"$resp"), same link)"
    else
      echo "access-keys: FAILED to restore '$name'" >&2
      failed=1
    fi
  done < <(jq -c --argjson cur "$current" '
    ($cur.accessKeys | map(.password)) as $have
    | .accessKeys[] | select(.password as $p | $have | index($p) | not)' "$backup")
  if [ "$failed" = 0 ] && [ "${1:-}" != keep ]; then rm -f "$backup"; fi
  return "$failed"
}

cmd_schedule_reset() {
  local t=${1:?epoch required}
  [[ $t =~ ^[0-9]{9,11}$ ]] || { echo "access-keys: bad time '$t' (want epoch seconds)" >&2; exit 2; }
  remove_reset_units past
  cat >"$UNIT_DIR/$UNIT_PREFIX$t.service" <<EOF
[Unit]
Description=Reset Outline access key data usage (run_hours period ended)

[Service]
Type=oneshot
ExecStart=$SELF reset-usage
EOF
  cat >"$UNIT_DIR/$UNIT_PREFIX$t.timer" <<EOF
[Unit]
Description=Reset Outline access key data usage at $(date -u -d "@$t")

[Timer]
OnCalendar=$(date -u -d "@$t" '+%Y-%m-%d %H:%M:%S') UTC
AccuracySec=1s
# Run at the next boot if the VM was off at that time.
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT_PREFIX$t.timer" >/dev/null 2>&1
  echo "access-keys: data usage resets to 0 at $(date -d "@$t")"
}

# sync prints the links, so let the boot script finish first: it may still be
# telling Outline a new IP (it waits for Outline's containers). Done before
# taking the lock, because the boot script's own usage reset needs it.
# Waits up to 10 minutes.
if [ "${1:-}" = sync ]; then
  for _ in $(seq 1 120); do
    state=$(systemctl show -p ActiveState --value google-startup-scripts.service 2>/dev/null || true)
    [ "$state" = activating ] || break
    [ -n "${waited:-}" ] || { echo "access-keys: waiting for the boot script to finish"; waited=1; }
    sleep 5
  done
fi

# One command at a time (waits up to 10 minutes for another to finish).
exec 9>"$LOCK_FILE"
flock -w 600 9 || { echo "access-keys: another key operation is still running" >&2; exit 1; }

case "${1:-}" in
  sync) cmd_sync "${2:-}" ;;
  reset-usage) cmd_reset_usage ;;
  schedule-reset) cmd_schedule_reset "${2:-}" ;;
  cancel-resets) remove_reset_units all ;;
  restore) cmd_restore ;;
  *)
    echo "usage: $0 sync <keys_json_base64> | reset-usage | schedule-reset <epoch> | cancel-resets | restore" >&2
    exit 2
    ;;
esac
