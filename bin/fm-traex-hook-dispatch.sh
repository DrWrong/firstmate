#!/usr/bin/env bash
# Firstmate TraeX hook dispatcher.
#
# The installed copy is one user-level hook shared by every TraeX session. It
# is inert unless the payload cwd contains a Firstmate-created
# .fm-traex-hook pointer whose opaque token resolves to a private registry
# record beside this script. Unbound sessions are silent exit 0. Once a record
# matches, every validation or persistence failure exits 2 with bounded stderr
# so TraeX keeps the failure visible instead of silently ending the turn.
set -u

PROTOCOL=v1
SUPPORTED_VERSION='traecli 0.200.19(internal edition)'
SUPPORTED_BINARY_SHA256='e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581'
MAX_PAYLOAD=65536

fail_matching() {
  printf 'Firstmate TraeX lifecycle persistence failed (%s); keep this turn active and retry after supervision is repaired.\n' "$1" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

owner_uid() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

regular_owned() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(owner_uid "$1" 2>/dev/null)" = "$(id -u)" ]
}

field() {  # <record> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

token_valid() {
  case "$1" in ????????-????????-????????-????????) ;; *) return 1 ;; esac
  case "$1" in *[!0-9a-f-]*) return 1 ;; esac
}

bounded_id() {
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

receipt_valid() {  # <cli-home>
  local cli_home=$1 receipt hooks self binary binary_sha hooks_sha self_sha
  receipt=$cli_home/fm-firstmate-receipt.json
  hooks=$cli_home/hooks.json
  self=$cli_home/fm-firstmate-hook.sh
  regular_owned "$receipt" && regular_owned "$hooks" && regular_owned "$self" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg protocol "$PROTOCOL" --arg version "$SUPPORTED_VERSION" --arg sha "$SUPPORTED_BINARY_SHA256" '
    type == "object" and .protocol == $protocol and .version == $version
    and .binary_sha256 == $sha and (.binary_path | strings | startswith("/"))
    and (.hooks_sha256 | strings | test("^[0-9a-f]{64}$"))
    and (.dispatcher_sha256 | strings | test("^[0-9a-f]{64}$"))
    and .events == ["SessionStart","UserPromptSubmit","Stop","SessionEnd"]
  ' "$receipt" >/dev/null 2>&1 || return 1
  binary=$(jq -r '.binary_path' "$receipt")
  regular_owned "$binary" && [ -x "$binary" ] || return 1
  binary_sha=$(sha256_file "$binary") || return 1
  hooks_sha=$(sha256_file "$hooks") || return 1
  self_sha=$(sha256_file "$self") || return 1
  [ "$binary_sha" = "$SUPPORTED_BINARY_SHA256" ] \
    && [ "$binary_sha" = "$(jq -r '.binary_sha256' "$receipt")" ] \
    && [ "$hooks_sha" = "$(jq -r '.hooks_sha256' "$receipt")" ] \
    && [ "$self_sha" = "$(jq -r '.dispatcher_sha256' "$receipt")" ]
}

probe_material_valid() {  # <record> <cli-home>
  local record=$1 cli_home=$2 binary hooks self
  binary=$(field "$record" binary_path) || return 1
  hooks=$cli_home/hooks.json
  self=$cli_home/fm-firstmate-hook.sh
  regular_owned "$binary" && regular_owned "$hooks" && regular_owned "$self" || return 1
  [ "$(sha256_file "$binary")" = "$(field "$record" binary_sha256)" ] \
    && [ "$(sha256_file "$hooks")" = "$(field "$record" hooks_sha256)" ] \
    && [ "$(sha256_file "$self")" = "$(field "$record" dispatcher_sha256)" ]
}

meta_value() {  # <meta> <key>
  field "$1" "$2"
}

worker_binding_valid() {  # <record>
  local record=$1 meta meta_wt meta_real current_gen state_token
  meta=$STATE_REAL/$TASK_ID.meta
  regular_owned "$meta" || return 1
  [ "$(meta_value "$meta" harness)" = traex ] || return 1
  [ "$(meta_value "$meta" busy_gen)" = "$BUSY_GEN" ] || return 1
  meta_wt=$(meta_value "$meta" worktree) || return 1
  meta_real=$(real_dir "$meta_wt") || return 1
  [ "$meta_real" = "$WORKTREE_REAL" ] || return 1
  current_gen=$(cat "$STATE_REAL/$TASK_ID.busy-gen" 2>/dev/null) || return 1
  [ "$current_gen" = "$BUSY_GEN" ] || return 1
  state_token=$(field "$record" token_state_real) || return 1
  regular_owned "$state_token" || return 1
  [ "$(cat "$state_token" 2>/dev/null)" = "$TOKEN" ]
}

primary_binding_valid() {  # <record>
  local record=$1 state_token
  state_token=$(field "$record" token_state_real) || return 1
  regular_owned "$state_token" || return 1
  [ "$(cat "$state_token" 2>/dev/null)" = "$TOKEN" ] \
    && [ -x "$FM_ROOT_REAL/bin/fm-sessionstart-run.sh" ] \
    && [ -x "$FM_ROOT_REAL/bin/fm-turnend-guard.sh" ]
}

lock_acquire() {  # <lock-dir>
  local lock=$1 tries=0 now mtime age
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || return 1
    if [ "$tries" -eq 40 ]; then
      now=$(date +%s)
      mtime=$(file_mtime "$lock" 2>/dev/null || printf '%s' "$now")
      age=$((now - mtime))
      [ "$age" -lt 10 ] || rmdir "$lock" 2>/dev/null || true
    fi
    sleep 0.05
  done
}

fsync_file() {
  sync -f "$1" 2>/dev/null && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
    return $?
  fi
  sync 2>/dev/null
}

append_completion() {  # <event> <session-id> <turn-id>
  local event=$1 session_id=$2 turn_id=$3 lock signal key session_hash turn_hash seq old_umask
  bounded_id "$session_id" && bounded_id "$turn_id" || return 1
  key=$(printf '%s' "$BUSY_GEN|$session_id|$turn_id|$event" | sha256_stdin) || return 1
  session_hash=$(printf '%s' "$session_id" | sha256_stdin) || return 1
  turn_hash=$(printf '%s' "$turn_id" | sha256_stdin) || return 1
  key=${key:0:32}
  session_hash=${session_hash:0:16}
  turn_hash=${turn_hash:0:16}
  signal=$STATE_REAL/$TASK_ID.turn-ended
  lock=$STATE_REAL/$TASK_ID.traex-callback.lock
  [ ! -e "$signal" ] || regular_owned "$signal" || return 1
  [ ! -e "$lock" ] || [ -d "$lock" ] || return 1
  lock_acquire "$lock" || return 1
  if [ -f "$signal" ] && grep -Fq " key=$key " "$signal" 2>/dev/null; then
    rmdir "$lock" 2>/dev/null || true
    return 0
  fi
  seq=1
  if [ -f "$signal" ]; then
    seq=$(( $(wc -l < "$signal" 2>/dev/null || printf '0') + 1 ))
  fi
  old_umask=$(umask)
  umask 077
  if ! printf 'v1 gen=%s key=%s session=%s turn=%s event=%s seq=%s ts=%s\n' \
      "$BUSY_GEN" "$key" "$session_hash" "$turn_hash" "$event" "$seq" "$(date +%s)" >> "$signal" \
      || ! fsync_file "$signal"; then
    umask "$old_umask"
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
  umask "$old_umask"
  rmdir "$lock" 2>/dev/null || true
}

write_worker_session() {  # <session-id> <source>
  local session_id=$1 source=$2 target tmp old_umask status
  bounded_id "$session_id" || return 1
  case "$source" in startup|resume|clear|compact|new|reload|fork) ;; *) source=unknown ;; esac
  target=$STATE_REAL/$TASK_ID.traex-session
  [ ! -e "$target" ] || regular_owned "$target" || return 1
  tmp=$target.tmp.$$
  old_umask=$(umask); umask 077
  printf 'session_id=%s\nsource=%s\n' "$session_id" "$source" > "$tmp" \
    && mv -f "$tmp" "$target" && fsync_file "$target"
  status=$?
  umask "$old_umask"
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

write_primary_session() {  # <session-id> <source>
  local session_id=$1 source=$2 target tmp old_umask status
  bounded_id "$session_id" || return 1
  case "$source" in startup|resume|clear|compact|new|reload|fork) ;; *) source=unknown ;; esac
  target=$STATE_REAL/.traex-primary-session
  [ ! -e "$target" ] || regular_owned "$target" || return 1
  tmp=$target.tmp.$$
  old_umask=$(umask); umask 077
  printf 'session_id=%s\nsource=%s\n' "$session_id" "$source" > "$tmp" \
    && mv -f "$tmp" "$target" && fsync_file "$target"
  status=$?
  umask "$old_umask"
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

payload=$(dd bs=$((MAX_PAYLOAD + 1)) count=1 2>/dev/null || true)
[ "${#payload}" -le "$MAX_PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
EVENT=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)
case "$EVENT" in SessionStart|UserPromptSubmit|Stop|SessionEnd) ;; *) exit 0 ;; esac
CWD=$(printf '%s' "$payload" | jq -r '.cwd | strings | select(length > 0)' 2>/dev/null) || exit 0
WORKTREE_PAYLOAD_REAL=$(real_dir "$CWD") || exit 0
POINTER=$WORKTREE_PAYLOAD_REAL/.fm-traex-hook
regular_owned "$POINTER" || exit 0
[ "$(wc -l < "$POINTER" 2>/dev/null | tr -d ' ')" = 1 ] || exit 0
pointer_line=$(cat "$POINTER" 2>/dev/null) || exit 0
case "$pointer_line" in token=*) TOKEN=${pointer_line#token=} ;; *) exit 0 ;; esac
token_valid "$TOKEN" || exit 0

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
REGISTRY=$SELF_DIR/fm-firstmate-hooks.d
if ! { [ -d "$REGISTRY" ] && [ ! -L "$REGISTRY" ] \
  && [ "$(owner_uid "$REGISTRY" 2>/dev/null)" = "$(id -u)" ]; }; then
  fail_matching registry
fi
RECORD=$REGISTRY/$TOKEN
regular_owned "$RECORD" || fail_matching binding
[ "$(field "$RECORD" protocol 2>/dev/null)" = "$PROTOCOL" ] || fail_matching protocol
[ "$(field "$RECORD" token 2>/dev/null)" = "$TOKEN" ] || fail_matching token
[ "$(field "$RECORD" uid 2>/dev/null)" = "$(id -u)" ] || fail_matching uid
ROLE=$(field "$RECORD" role 2>/dev/null) || fail_matching role
case "$ROLE" in worker|primary|probe) ;; *) fail_matching role ;; esac
TASK_ID=$(field "$RECORD" task_id 2>/dev/null) || fail_matching task
case "$TASK_ID" in ''|*[!A-Za-z0-9._-]*) fail_matching task ;; esac
WORKTREE_REAL=$(field "$RECORD" worktree_real 2>/dev/null) || fail_matching worktree
[ "$WORKTREE_REAL" = "$WORKTREE_PAYLOAD_REAL" ] || fail_matching cwd
STATE_REAL=$(field "$RECORD" state_real 2>/dev/null) || fail_matching state
FM_ROOT_REAL=$(field "$RECORD" fm_root_real 2>/dev/null) || fail_matching root
FM_HOME_REAL=$(field "$RECORD" fm_home_real 2>/dev/null) || fail_matching home
[ "$(real_dir "$STATE_REAL" 2>/dev/null)" = "$STATE_REAL" ] || fail_matching state
[ "$(real_dir "$FM_ROOT_REAL" 2>/dev/null)" = "$FM_ROOT_REAL" ] || fail_matching root
[ "$(real_dir "$FM_HOME_REAL" 2>/dev/null)" = "$FM_HOME_REAL" ] || fail_matching home
BUSY_GEN=$(field "$RECORD" busy_gen 2>/dev/null || true)

if [ "$ROLE" = probe ]; then
  probe_material_valid "$RECORD" "$SELF_DIR" || fail_matching probe-material
  PROOF=$(field "$RECORD" proof_real 2>/dev/null) || fail_matching proof
  NONCE=$(field "$RECORD" nonce 2>/dev/null) || fail_matching nonce
  case "$NONCE" in ''|*[!0-9a-f]*) fail_matching nonce ;; esac
  case "$PROOF" in "$WORKTREE_REAL"/*) ;; *) fail_matching proof ;; esac
  [ ! -e "$PROOF" ] || regular_owned "$PROOF" || fail_matching proof
  session_id=$(printf '%s' "$payload" | jq -r '.session_id | strings | select(length > 0)' 2>/dev/null) || fail_matching session
  source=$(printf '%s' "$payload" | jq -r '.source // ""' 2>/dev/null)
  if ! printf 'v1 nonce=%s event=%s session=%s source=%s\n' \
      "$NONCE" "$EVENT" "$session_id" "$source" >> "$PROOF" \
      || ! fsync_file "$PROOF"; then
    fail_matching proof-write
  fi
  exit 0
fi

receipt_valid "$SELF_DIR" || fail_matching receipt
if [ "$ROLE" = primary ]; then
  primary_binding_valid "$RECORD" || fail_matching binding
  case "$EVENT" in
    SessionStart)
      source=$(printf '%s' "$payload" | jq -r '.source // "startup"' 2>/dev/null)
      session_id=$(printf '%s' "$payload" | jq -r '.session_id | strings | select(length > 0)' 2>/dev/null) || fail_matching session
      write_primary_session "$session_id" "$source" || fail_matching session-write
      FM_ROOT_OVERRIDE="$FM_ROOT_REAL" FM_HOME="$FM_HOME_REAL" \
        "$FM_ROOT_REAL/bin/fm-sessionstart-run.sh" --source "$source"
      exit 0
      ;;
    Stop)
      printf '%s' "$payload" | FM_ROOT_OVERRIDE="$FM_ROOT_REAL" FM_HOME="$FM_HOME_REAL" \
        "$FM_ROOT_REAL/bin/fm-turnend-guard.sh"
      exit $?
      ;;
    *) exit 0 ;;
  esac
fi

worker_binding_valid "$RECORD" || fail_matching binding
case "$EVENT" in
  SessionStart)
    session_id=$(printf '%s' "$payload" | jq -r '.session_id | strings | select(length > 0)' 2>/dev/null) || fail_matching session
    source=$(printf '%s' "$payload" | jq -r '.source // "unknown"' 2>/dev/null)
    write_worker_session "$session_id" "$source" || fail_matching session-write
    ;;
  UserPromptSubmit)
    "$FM_ROOT_REAL/bin/fm-busy-event.sh" apply "$STATE_REAL" "$TASK_ID" busy \
      --gen "$BUSY_GEN" --source traex-hook --event user-prompt-submit \
      >/dev/null 2>&1 || fail_matching busy-write
    ;;
  Stop|SessionEnd)
    if [ "$EVENT" = Stop ]; then
      event_slug=stop
    else
      event_slug=session-end
    fi
    "$FM_ROOT_REAL/bin/fm-busy-event.sh" apply "$STATE_REAL" "$TASK_ID" idle \
      --gen "$BUSY_GEN" --source traex-hook --event "$event_slug" \
      >/dev/null 2>&1 || fail_matching idle-write
    session_id=$(printf '%s' "$payload" | jq -r '.session_id | strings | select(length > 0)' 2>/dev/null) || fail_matching session
    turn_id=$(printf '%s' "$payload" | jq -r '.turn_id | strings | select(length > 0)' 2>/dev/null) || fail_matching turn
    append_completion "$EVENT" "$session_id" "$turn_id" || fail_matching completion-write
    ;;
esac
exit 0
