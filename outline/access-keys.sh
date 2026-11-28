#!/bin/bash
# Manages Outline access keys through the local management API. Installed on
# the VM as /usr/local/sbin/outline-access-keys by Terraform (provision.tf) and
# run as root.
#
# Usage:
#   outline-access-keys reset <keys_json_base64>
#       Sync the keys with access_keys (from terraform.tfvars) by name: existing
#       keys keep their ss:// link and get usage 0 and the new limit, missing
#       ones are created, others deleted. Prints all ss:// links. Cancels
#       pending usage resets.
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

# create_key <json body> -> prints the created key's JSON. Retries briefly.
create_key() {
  local resp
  for _ in 1 2 3 4 5; do
    resp=$(api POST /access-keys -d "$1") && { echo "$resp"; return 0; }
    sleep 2
  done
  return 1
}

# Syncs the server's keys with access_keys, by name:
#   name in access_keys, key exists -> recreated with the same password and port
#                                      (same ss:// link), new limit, usage 0
#   name in access_keys, no key     -> created (new ss:// link)
#   key not in access_keys          -> deleted
cmd_reset() {
  local keys_json
  keys_json=$(echo "${1:?keys_json_base64 required}" | base64 -d)
  ensure_jq
  wait_for_api
  remove_reset_units all

  local current
  current=$(api GET /access-keys)
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local backup="$STATE_DIR/before-reset-$(date +%s).json"
  (umask 077 && echo "$current" >"$backup")

  local key id name
  # Keys not in access_keys (and duplicate names) are deleted.
  while read -r key; do
    id=$(jq -r .id <<<"$key")
    name=$(jq -r .name <<<"$key")
    api DELETE "/access-keys/$id" >/dev/null
    echo "access-keys: deleted '$name' (key $id: not in access_keys, or a duplicate name)"
  done < <(jq -c --argjson want "$keys_json" '
    .accessKeys | group_by(.name)
    | map(if (.[0].name | in($want)) then .[1:] else . end) | add // [] | .[]' <<<"$current")

  echo
  echo "===== Outline access keys ====="
  local entry limit old body resp status failed=0
  while read -r entry; do
    name=$(jq -r .key <<<"$entry")
    limit=$(jq -c 'if .value.data_limit_gb == null then null
      else {bytes: (.value.data_limit_gb * 1000000000 | floor)} end' <<<"$entry")
    old=$(jq -c --arg n "$name" '[.accessKeys[] | select(.name == $n)][0] // empty' <<<"$current")
    if [ -n "$old" ]; then
      # Same password and port = same ss:// link; the new key ID starts at 0.
      body=$(jq -c --argjson l "$limit" '{name, password, port, method}
        + (if $l == null then {} else {limit: $l} end)' <<<"$old")
      api DELETE "/access-keys/$(jq -r .id <<<"$old")" >/dev/null
      status="same link, usage reset to 0"
    else
      body=$(jq -c -n --arg n "$name" --argjson l "$limit" '{name: $n}
        + (if $l == null then {} else {limit: $l} end)')
      status="NEW link"
    fi
    if resp=$(create_key "$body"); then
      echo "$name ($(gb "$(jq -r '.dataLimit.bytes // empty' <<<"$resp")"), $status): $(jq -r .accessUrl <<<"$resp")"
    else
      echo "access-keys: FAILED to create '$name'; see $backup on the VM" >&2
      failed=1
    fi
  done < <(jq -c 'to_entries[]' <<<"$keys_json")

  if [ "$failed" = 0 ]; then rm -f "$backup"; fi
  return "$failed"
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
    if resp=$(create_key "$body"); then
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
