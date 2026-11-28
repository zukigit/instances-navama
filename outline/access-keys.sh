#!/bin/bash
# Manages Outline access keys through the local management API. Installed on
# the VM as /usr/local/sbin/outline-access-keys by Terraform (provision.tf) and
# run as root.
#
# Usage:
#   outline-access-keys reset <keys_json_base64>
#       Delete every access key, then create the keys in access_keys (from
#       terraform.tfvars) and print their ss:// links. Cancels pending usage resets.
#   outline-access-keys append
#       Keep the keys as they are, and schedule a usage reset at the currently
#       scheduled shutdown (the "old timer"). Run before the shutdown is moved.
#   outline-access-keys reset-usage
#       Reset every key's data usage to 0 while keeping its ss:// link. Run by
#       the systemd timers that `append` creates.
#
# How reset-usage works: Outline counts usage per key ID and has no "reset
# usage" call, so each key is deleted and created again with the same name,
# password, port, method and data limit. The ss:// link only contains the
# password, host and port, so it stays the same; the new key ID starts at 0.
set -euo pipefail

ACCESS=/opt/outline/access.txt
SCHEDULED_FILE="${SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
STATE_DIR="${STATE_DIR:-/var/lib/outline-access-keys}"
UNIT_PREFIX=outline-usage-reset-
SELF=/usr/local/sbin/outline-access-keys

# Management API on this VM. OUTLINE_API overrides it (for testing).
api_base() {
  if [ -n "${OUTLINE_API:-}" ]; then
    echo "$OUTLINE_API"
    return
  fi
  [ -f "$ACCESS" ] || { echo "access-keys: $ACCESS not found (Outline not installed)" >&2; exit 1; }
  sed -n 's/^apiUrl://p' "$ACCESS" | sed -E 's#^https://[^:/]+#https://127.0.0.1#'
}
BASE=$(api_base)

# api <METHOD> <path> [curl args...]
api() {
  local method=$1 path=$2
  shift 2
  curl -fsSk -X "$method" -H 'Content-Type: application/json' "$@" "$BASE$path"
}

# Outline's containers may still be starting (e.g. right after boot).
wait_for_api() {
  for _ in $(seq 1 60); do
    api GET /server >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "access-keys: Outline API not reachable" >&2
  exit 1
}

ensure_jq() {
  command -v jq >/dev/null && return 0
  echo "access-keys: installing jq"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq >/dev/null ||
    { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq >/dev/null; }
}

gb() { # bytes -> "N GB" (decimal, like Outline Manager)
  if [ -z "$1" ] || [ "$1" = null ]; then echo "no limit"; else echo "$(( $1 / 1000000000 )) GB"; fi
}

# Removes usage-reset timers. With "past", only those whose time has passed.
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

cmd_reset() {
  local keys_json
  keys_json=$(echo "${1:?keys_json_base64 required}" | base64 -d)
  ensure_jq
  wait_for_api
  remove_reset_units all

  local id
  for id in $(api GET /access-keys | jq -r '.accessKeys[].id'); do
    api DELETE "/access-keys/$id" >/dev/null
    echo "access-keys: deleted key $id"
  done

  echo
  echo "===== Outline access keys ====="
  local entry body resp name
  while read -r entry; do
    body=$(jq -c '{name: .key}
      + (if .value.data_limit_gb == null then {}
         else {limit: {bytes: (.value.data_limit_gb * 1000000000 | floor)}} end)' <<<"$entry")
    resp=$(api POST /access-keys -d "$body")
    name=$(jq -r .name <<<"$resp")
    echo "$name ($(gb "$(jq -r '.dataLimit.bytes // empty' <<<"$resp")")): $(jq -r .accessUrl <<<"$resp")"
  done < <(jq -c 'to_entries[]' <<<"$keys_json")
}

cmd_append() {
  remove_reset_units past
  local usec t now
  usec=$(sed -n 's/^USEC=//p' "$SCHEDULED_FILE" 2>/dev/null || true)
  now=$(date +%s)
  if [ -z "$usec" ] || [ $((usec / 1000000)) -le "$now" ]; then
    echo "access-keys: no shutdown scheduled; keys unchanged, no usage reset scheduled"
    return 0
  fi
  t=$((usec / 1000000))

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
  echo "access-keys: keys unchanged; data usage resets to 0 at $(date -d "@$t")"
  echo "access-keys: pending usage resets:"
  systemctl list-timers --all --no-legend "$UNIT_PREFIX*" | sed 's/^/  /'
}

cmd_reset_usage() {
  ensure_jq
  wait_for_api
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
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
    api DELETE "/access-keys/$id" >/dev/null
    resp=""
    for _ in 1 2 3 4 5; do
      resp=$(api POST /access-keys -d "$body") && break
      resp=""
      sleep 2
    done
    if [ -n "$resp" ]; then
      echo "access-keys: usage reset for '$name' (key $id -> $(jq -r .id <<<"$resp"))"
    else
      echo "access-keys: FAILED to recreate '$name' (key $id); see $backup" >&2
      failed=1
    fi
  done < <(jq -c '.accessKeys[]' <<<"$keys")

  if [ "$failed" = 0 ]; then rm -f "$backup"; fi
  return "$failed"
}

case "${1:-}" in
  reset) cmd_reset "${2:-}" ;;
  append) cmd_append ;;
  reset-usage) cmd_reset_usage ;;
  *) echo "usage: $0 reset <keys_json_base64> | append | reset-usage" >&2; exit 2 ;;
esac
