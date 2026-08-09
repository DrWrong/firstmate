#!/usr/bin/env bash
# Opt-in real-binary TraeX primary ownership lifecycle regression.
#
# The driver copies tracked/untracked source into a disposable FM_HOME, copies
# an explicitly supplied auth file into a separate CLI home without reading it,
# and uses only a unique private tmux server. Native trust remains mandatory.
# Failed and successful labs are preserved under /tmp for inspection.
set -u

mode=${1:-driver}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

capture_ancestry() { # <target>
  local target=$1 pid ppid sid pgid tty elapsed comm exe start_ticks depth
  printf 'depth\tpid\tppid\tsid\tpgid\ttty\telapsed\tcomm\texe\tstart_ticks\n' > "$target"
  pid=$$
  for depth in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    kill -0 "$pid" 2>/dev/null || break
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#^.*/##')
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    exe=${exe##*/}
    start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$depth" "$pid" "$ppid" "$sid" "$pgid" "$tty" "$elapsed" "$comm" "$exe" "$start_ticks" \
      >> "$target"
    case "$ppid" in ''|*[!0-9]*|0|1) break ;; esac
    pid=$ppid
  done
}

capture_hook() {
  local lab payload event now event_dir payload_bytes prompt_bytes prompt_sha tool_keys env_names
  lab=${FM_TRAEX_PROBE_LAB:?}
  payload=$(dd bs=65537 count=1 2>/dev/null || true)
  [ "${#payload}" -le 65536 ] || exit 0
  printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "unknown"')
  now=$(date +%s%N)
  event_dir=$(mktemp -d "$lab/events/${now}.${event}.XXXXXXXX") || exit 0
  chmod 700 "$event_dir"
  payload_bytes=${#payload}
  prompt_bytes=$(printf '%s' "$payload" | jq -r '(.prompt // "") | length')
  prompt_sha=$(printf '%s' "$payload" | jq -r '.prompt // ""' | sha256_stdin)
  tool_keys=$(printf '%s' "$payload" | jq -c '(.tool_input // {}) | if type == "object" then keys | sort else [] end')
  jq -n \
    --arg hook_event_name "$event" \
    --arg cwd "$(printf '%s' "$payload" | jq -r '.cwd // ""')" \
    --arg session_id "$(printf '%s' "$payload" | jq -r '.session_id // ""')" \
    --arg source "$(printf '%s' "$payload" | jq -r '.source // ""')" \
    --arg turn_id "$(printf '%s' "$payload" | jq -r '.turn_id // ""')" \
    --arg tool_name "$(printf '%s' "$payload" | jq -r '.tool_name // ""')" \
    --arg event_type "$(printf '%s' "$payload" | jq -r '.event_type // ""')" \
    --arg trigger "$(printf '%s' "$payload" | jq -r '.trigger // ""')" \
    --arg reason "$(printf '%s' "$payload" | jq -r '.reason // ""')" \
    --arg model "$(printf '%s' "$payload" | jq -r '.model // ""')" \
    --arg permission_mode "$(printf '%s' "$payload" | jq -r '.permission_mode // ""')" \
    --argjson payload_bytes "$payload_bytes" \
    --argjson prompt_bytes "$prompt_bytes" \
    --arg prompt_sha256 "$prompt_sha" \
    --argjson tool_input_keys "$tool_keys" \
    '{hook_event_name:$hook_event_name,cwd:$cwd,session_id:$session_id,source:$source,
      turn_id:$turn_id,tool_name:$tool_name,event_type:$event_type,trigger:$trigger,
      reason:$reason,model:$model,permission_mode:$permission_mode,
      payload_bytes:$payload_bytes,prompt_bytes:$prompt_bytes,
      prompt_sha256:$prompt_sha256,tool_input_keys:$tool_input_keys}' \
    > "$event_dir/payload-safe.json"
  env_names=$(env | sed 's/=.*//' | LC_ALL=C sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -n \
    --arg HOME "${HOME:-}" --arg TRAE_HOME "${TRAE_HOME:-}" \
    --arg TRAECLI_HOME "${TRAECLI_HOME:-}" --arg FM_HOME "${FM_HOME:-}" \
    --arg PWD "$PWD" --arg TMUX "${TMUX:-}" --arg TMUX_PANE "${TMUX_PANE:-}" \
    --arg FM_TRAEX_HARNESS "${FM_TRAEX_HARNESS:-}" \
    --argjson names "$env_names" \
    '{selected:{HOME:$HOME,TRAE_HOME:$TRAE_HOME,TRAECLI_HOME:$TRAECLI_HOME,
      FM_HOME:$FM_HOME,PWD:$PWD,TMUX:$TMUX,TMUX_PANE:$TMUX_PANE,
      FM_TRAEX_HARNESS:$FM_TRAEX_HARNESS},names:$names}' \
    > "$event_dir/environment-safe.json"
  capture_ancestry "$event_dir/ancestry.tsv"
  exit 0
}

blocking_hook() {
  local lab payload event
  lab=${FM_TRAEX_PROBE_LAB:?}
  payload=$(dd bs=65537 count=1 2>/dev/null || true)
  [ "${#payload}" -le 65536 ] || exit 0
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)
  if [ "$event" = PreToolUse ] && [ -f "$lab/block-pretool" ]; then
    printf '%s\n' FIRSTMATE_PROBE_PRETOOL_BLOCKED >&2
    exit 2
  fi
  exit 0
}

capture_tool() { # <evidence-dir> <root>
  local evidence=$1 root=$2 status=0
  mkdir -p "$(dirname -- "$evidence")" || exit 1
  chmod 700 "$(dirname -- "$evidence")" || exit 1
  mkdir -m 700 "$evidence" || exit 1
  capture_ancestry "$evidence/ancestry.tsv"
  env | sed 's/=.*//' | LC_ALL=C sort -u > "$evidence/environment-names.txt"
  jq -n --arg home "${HOME:-}" --arg trae_home "${TRAE_HOME:-}" \
    --arg traecli_home "${TRAECLI_HOME:-}" --arg fm_home "${FM_HOME:-}" \
    --arg tmux_pane "${TMUX_PANE:-}" \
    '{HOME:$home,TRAE_HOME:$trae_home,TRAECLI_HOME:$traecli_home,
      FM_HOME:$fm_home,TMUX_PANE:$tmux_pane}' > "$evidence/environment-safe.json"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$root/bin/fm-harness.sh" \
    > "$evidence/harness.out" 2> "$evidence/harness.err" || status=$?
  printf '%s\n' "$status" > "$evidence/harness.rc"
  status=0
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" bash -c \
    '. "$1/bin/fm-session-lock-lib.sh"; fm_session_owner_pid "$1/state"' _ "$root" \
    > "$evidence/proof-owner.out" 2> "$evidence/proof-owner.err" || status=$?
  printf '%s\n' "$status" > "$evidence/proof-owner.rc"
  status=0
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$root/bin/fm-session-start.sh" \
    > "$evidence/session-start.out" 2> "$evidence/session-start.err" || status=$?
  printf '%s\n' "$status" > "$evidence/session-start.rc"
  printf '%s\n' FIRSTMATE_TRAEX_PRIMARY_TOOL_PROBE_COMPLETE
}

case "$mode" in
  hook) capture_hook ;;
  block) blocking_hook ;;
  tool)
    [ "$#" -eq 3 ] || exit 2
    capture_tool "$2" "$3"
    exit 0
    ;;
esac

[ "$mode" = driver ] || exit 2
if [ "$#" -eq 0 ]; then
  if [ "${FM_TRAEX_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
    printf '%s\n' 'skip: set FM_TRAEX_PRIMARY_LIVE_E2E=1 and FM_TRAEX_LIVE_AUTH_SOURCE=<auth.json> to run the real TraeX primary lifecycle regression'
    exit 0
  fi
  ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 2
  AUTH_SOURCE=${FM_TRAEX_LIVE_AUTH_SOURCE:-}
  BINARY=${FM_TRAEX_LIVE_BINARY:-$(command -v traex 2>/dev/null || true)}
  MODEL=${FM_TRAEX_LIVE_MODEL:-GPT-5.6-Luna}
else
  [ "$#" -ge 4 ] || { printf 'usage: %s driver <root> <auth.json> <traex> [model]\n' "$0" >&2; exit 2; }
  ROOT=$2
  AUTH_SOURCE=$3
  BINARY=$4
  MODEL=${5:-GPT-5.6-Luna}
fi
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
REAL_SCRIPT=$(command -v script 2>/dev/null || true)
[ -d "$ROOT" ] || exit 2
[ -f "$AUTH_SOURCE" ] && [ ! -L "$AUTH_SOURCE" ] || exit 2
[ -x "$BINARY" ] && [ ! -L "$BINARY" ] || exit 2
[ -x "$REAL_TMUX" ] && [ -x "$REAL_SCRIPT" ] || exit 2
command -v jq >/dev/null 2>&1 || exit 2
command -v shellcheck >/dev/null 2>&1 || exit 2

LAB=$(mktemp -d /tmp/fm-traex-primary-proof-live.XXXXXXXX) || exit 1
HOME_DIR=$LAB/home
TRAE_HOME_DIR=$LAB/trae
CLI_HOME=$LAB/cli
LAB_ROOT=$LAB/firstmate
EVENTS=$LAB/events
TOOL_EVIDENCE=$LAB_ROOT/tool-evidence
SOCKET=fm-traex-proof-live-$$
SESSION=fm-traex-proof-live-$$
TARGET=$SESSION:primary
HOOK_COPY=$CLI_HOME/primary-proof-live-hook.sh
PROBE_COPY=$LAB_ROOT/.traex-primary-live-probe.sh
ATTACHED_PID=
ATTACHED_FIFO=$LAB/attached.stdin
ATTACHED_FIFO_OPEN=0
SUCCEEDED=0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$ATTACHED_PID" ]; then
    wait "$ATTACHED_PID" >/dev/null 2>&1 || true
  fi
  if [ "$ATTACHED_FIFO_OPEN" -eq 1 ]; then
    exec 9>&-
  fi
  printf 'evidence=%s succeeded=%s\n' "$LAB" "$SUCCEEDED" >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  printf 'not ok - %s; evidence=%s\n' "$1" "$LAB" >&2
  exit 1
}

capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -2000 2>/dev/null || true; }
capture_visible() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true; }

wait_text() { # <text> [attempts]
  local expected=$1 attempts=${2:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

send_line() { # <text>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$1" || return 1
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
}

wait_shell() {
  local i=0 command
  while [ "$i" -lt 120 ]; do
    command=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
    [ "$command" = bash ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_command() { # <command> [attempts]
  local expected=$1 attempts=${2:-120} i=0 command
  while [ "$i" -lt "$attempts" ]; do
    command=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
    [ "$command" = "$expected" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_input_ready() { # [attempts]
  local attempts=${1:-120} i=0 visible
  while [ "$i" -lt "$attempts" ]; do
    visible=$(capture_visible)
    if printf '%s\n' "$visible" | grep -Fq '❯' \
        && ! printf '%s\n' "$visible" | grep -Eq 'Running [0-9]+ .*hooks|esc to interrupt'; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

clear_pane_history() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-l || return 1
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" clear-history -t "$TARGET"
}

start_attached_client() {
  local attach_command target_snapshot expected_session expected_pane client snapshot active_session active_pane control i=0
  attach_command=$(printf '%q -L %q attach-session -t %q' "$REAL_TMUX" "$SOCKET" "$SESSION")
  if [ "$ATTACHED_FIFO_OPEN" -eq 0 ]; then
    mkfifo "$ATTACHED_FIFO" || return 1
    exec 9<>"$ATTACHED_FIFO"
    ATTACHED_FIFO_OPEN=1
  fi
  "$REAL_SCRIPT" -q -c "$attach_command" "$LAB/attached.typescript" <&9 >/dev/null 2>&1 &
  ATTACHED_PID=$!
  target_snapshot=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" \
    $'#{session_id}\t#{pane_id}') || return 1
  IFS=$'\t' read -r expected_session expected_pane <<EOF
$target_snapshot
EOF
  while [ "$i" -lt 100 ]; do
    while IFS=$'\t' read -r client control; do
      [ -n "$client" ] && [ "$control" = 0 ] || continue
      snapshot=$("$REAL_TMUX" -L "$SOCKET" display-message -p -c "$client" \
        $'#{session_id}\t#{pane_id}' 2>/dev/null) || continue
      IFS=$'\t' read -r active_session active_pane <<EOF
$snapshot
EOF
      [ "$active_session" = "$expected_session" ] && [ "$active_pane" = "$expected_pane" ] && return 0
    done < <("$REAL_TMUX" -L "$SOCKET" list-clients -F \
      $'#{client_name}\t#{client_control_mode}' 2>/dev/null || true)
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

event_exists() { # <event> [source]
  local wanted=$1 source=${2:-} file
  for file in "$EVENTS"/*/payload-safe.json; do
    [ -f "$file" ] || continue
    jq -e --arg event "$wanted" --arg source "$source" \
      '.hook_event_name == $event and ($source == "" or .source == $source)' "$file" >/dev/null 2>&1 \
      && return 0
  done
  return 1
}

event_count() { # <event>
  local wanted=$1 file count=0
  for file in "$EVENTS"/*/payload-safe.json; do
    [ -f "$file" ] || continue
    if jq -e --arg event "$wanted" '.hook_event_name == $event' "$file" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

wait_event_count_gt() { # <event> <prior-count> [attempts]
  local event=$1 prior=$2 attempts=${3:-240} i=0 current
  while [ "$i" -lt "$attempts" ]; do
    current=$(event_count "$event")
    [ "$current" -gt "$prior" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_event() { # <event> [source] [attempts]
  local event=$1 source=${2:-} attempts=${3:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    event_exists "$event" "$source" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

fresh_event_file() { # <event> <source-or-empty> <after-nanoseconds>
  local wanted=$1 source=$2 after=$3 file directory stamp
  while IFS= read -r file; do
    directory=${file%/payload-safe.json}
    stamp=${directory##*/}
    stamp=${stamp%%.*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -gt "$after" ] || continue
    jq -e --arg event "$wanted" --arg source "$source" --arg cwd "$LAB_ROOT" \
      '.hook_event_name == $event and .cwd == $cwd
       and ($source == "" or .source == $source)' "$file" >/dev/null 2>&1 || continue
    printf '%s\n' "$file"
    return 0
  done < <(find "$EVENTS" -mindepth 2 -maxdepth 2 -name payload-safe.json -print 2>/dev/null | LC_ALL=C sort)
  return 1
}

wait_fresh_event_file() { # <event> <source-or-empty> <after-nanoseconds> [attempts]
  local event=$1 source=$2 after=$3 attempts=${4:-120} i=0 file
  while [ "$i" -lt "$attempts" ]; do
    file=$(fresh_event_file "$event" "$source" "$after" 2>/dev/null || true)
    if [ -n "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

run_tool_turn() { # <evidence-dir>
  local evidence=$1 probe_q evidence_q root_q prior_stop i=0
  printf -v probe_q '%q' "$PROBE_COPY"
  printf -v evidence_q '%q' "$evidence"
  printf -v root_q '%q' "$LAB_ROOT"
  prior_stop=$(event_count Stop)
  send_line "Use the Bash tool exactly once with this complete command: bash $probe_q tool $evidence_q $root_q" \
    || return 1
  while [ "$i" -lt 240 ] && [ ! -s "$evidence/session-start.rc" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -s "$evidence/session-start.rc" ] || return 1
  wait_event_count_gt Stop "$prior_stop" 120 || return 1
  wait_input_ready 120
}

mkdir -m 700 "$HOME_DIR" "$TRAE_HOME_DIR" "$CLI_HOME" "$LAB_ROOT" "$EVENTS" || fail 'could not create isolated homes'
cp "$AUTH_SOURCE" "$CLI_HOME/auth.json" || fail 'could not copy isolated auth source'
chmod 600 "$CLI_HOME/auth.json"
git -C "$ROOT" ls-files --cached --others --exclude-standard -z > "$LAB/files.list" || fail 'could not enumerate source'
tar -C "$ROOT" --null -T "$LAB/files.list" -cf - | tar -C "$LAB_ROOT" -xf - || fail 'could not copy source into lab'
mkdir -m 700 "$LAB_ROOT/state" "$LAB_ROOT/config" "$LAB_ROOT/data" "$LAB_ROOT/projects"
git -C "$LAB_ROOT" init -q -b main || fail 'could not initialize lab repository'
git -C "$LAB_ROOT" add . || fail 'could not stage lab repository'
git -C "$LAB_ROOT" -c user.name=fm-probe -c user.email=fm-probe@example.invalid commit -q -m baseline \
  || fail 'could not commit lab repository'
printf 'worker=off\nprimary=on\nsecondmate=off\n' > "$LAB_ROOT/config/traex-adapter"
cp "$0" "$HOOK_COPY" || fail 'could not copy capture hook'
cp "$0" "$PROBE_COPY" || fail 'could not copy sandbox probe entry point'
chmod 700 "$HOOK_COPY" "$PROBE_COPY"

export HOME=$HOME_DIR TRAE_HOME=$TRAE_HOME_DIR TRAECLI_HOME=$CLI_HOME FM_HOME=$LAB_ROOT
unset TMUX TMUX_PANE FM_TRAEX_HARNESS CLAUDECODE PI_CODING_AGENT GROK_AGENT NO_MISTAKES_GATE

capture_command=$(printf 'env FM_TRAEX_PROBE_LAB=%q bash %q hook' "$LAB" "$HOOK_COPY")
block_command=$(printf 'env FM_TRAEX_PROBE_LAB=%q bash %q block' "$LAB" "$HOOK_COPY")
jq -n --arg capture "$capture_command" --arg block "$block_command" '
  {version:1,hooks:{}}
  | reduce ["SessionStart","UserPromptSubmit","PreToolUse","Stop","SessionEnd","PreCompact","PostCompact"][] as $event
      (. ; .hooks[$event]=[{hooks:[{type:"command",command:$capture,timeout:30}]}])
  | .hooks.PreToolUse += [{hooks:[{type:"command",command:$block,timeout:30}]}]
' > "$CLI_HOME/hooks.json" || fail 'could not render isolated hooks'
chmod 600 "$CLI_HOME/hooks.json"

"$LAB_ROOT/bin/fm-traex-hook-install.sh" install > "$LAB/install.out" 2> "$LAB/install.err" \
  || fail 'hook installation failed'
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n primary -c "$LAB_ROOT" -- \
  env HOME="$HOME" TRAE_HOME="$TRAE_HOME" TRAECLI_HOME="$TRAECLI_HOME" FM_HOME="$FM_HOME" bash --noprofile --norc -i \
  || fail 'private tmux server failed'
"$REAL_TMUX" -L "$SOCKET" set-option -g remain-on-exit on
start_attached_client || fail 'foreground PTY client did not attach to the exact primary pane'
"$REAL_TMUX" -L "$SOCKET" list-clients -F \
  $'#{client_name}\t#{client_session}\t#{session_id}\t#{pane_id}\t#{client_control_mode}' \
  > "$LAB/attached.clients.tsv"

printf -v launch_q 'env HOME=%q TRAE_HOME=%q TRAECLI_HOME=%q FM_HOME=%q %q -y --disable plugins --disable plugin_hooks' \
  "$HOME" "$TRAE_HOME" "$TRAECLI_HOME" "$FM_HOME" "$BINARY"
send_line "$launch_q" || fail 'could not launch native trust review'
directory_trusted=0
i=0
while [ "$i" -lt 150 ]; do
  capture > "$LAB/trust.txt"
  if grep -Fq 'Do you trust the contents of this directory?' "$LAB/trust.txt"; then
    if [ "$directory_trusted" -eq 0 ]; then
      grep -Eq '❯[[:space:]]+1\. Yes, continue' "$LAB/trust.txt" || fail 'directory trust choice moved'
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
      directory_trusted=1
      sleep 1
    fi
  elif grep -Fq 'Hooks need review' "$LAB/trust.txt"; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
grep -Fq 'Hooks need review' "$LAB/trust.txt" || fail 'native hook review was not shown'
grep -Eq '❯[[:space:]]+2\. Trust all and continue' "$LAB/trust.txt" || fail 'native hook trust choice moved'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_text 'TRAE CLI Next' 150 || fail 'TraeX did not continue after explicit native hook trust'
capture > "$LAB/trust-accepted.txt"
send_line /exit || fail 'could not exit native trust session'
wait_shell || fail 'trust session did not return to the bound shell pane'

"$LAB_ROOT/bin/fm-traex-hook-install.sh" probe --model "$MODEL" > "$LAB/receipt-probe.out" 2> "$LAB/receipt-probe.err" \
  || fail 'real lifecycle receipt probe failed'
"$LAB_ROOT/bin/fm-traex-hook-install.sh" verify > "$LAB/receipt-verify.out" 2> "$LAB/receipt-verify.err" \
  || fail 'real lifecycle receipt verification failed'

printf -v bind_q '%q bind-primary %q %q' "$LAB_ROOT/bin/fm-traex-hook-install.sh" "$LAB_ROOT" "$LAB_ROOT"
send_line "$bind_q; printf '__ATTACHED_BIND_RC=%s\\n' \"\$?\"" || fail 'could not request attached bind'
wait_text '__ATTACHED_BIND_RC=0' 60 || fail 'attached matching pane did not bind'
capture > "$LAB/bind-attached.txt"

"$REAL_TMUX" -L "$SOCKET" detach-client -s "$SESSION" || fail 'could not detach isolated proof client'
wait "$ATTACHED_PID" >/dev/null 2>&1 || true
ATTACHED_PID=
[ -z "$("$REAL_TMUX" -L "$SOCKET" list-clients 2>/dev/null || true)" ] || fail 'private session still had a client'
send_line "$bind_q; printf '__DETACHED_BIND_RC=%s\\n' \"\$?\"" || fail 'could not request detached negative control'
wait_text '__DETACHED_BIND_RC=1' 60 || fail 'detached/no-client bind did not refuse'
capture > "$LAB/bind-detached.txt"
start_attached_client || fail 'could not reattach exact foreground client'
send_line "$bind_q; printf '__REATTACHED_BIND_RC=%s\\n' \"\$?\"" || fail 'could not request reattached bind'
wait_text '__REATTACHED_BIND_RC=0' 60 || fail 'reattached matching pane did not validate existing binding'
capture > "$LAB/bind-reattached.txt"

printf -v primary_q 'env HOME=%q TRAE_HOME=%q TRAECLI_HOME=%q FM_HOME=%q %q --permission-mode default --disable plugins --disable plugin_hooks -m %q -c %q' \
  "$HOME" "$TRAE_HOME" "$TRAECLI_HOME" "$FM_HOME" "$BINARY" "$MODEL" 'model_reasoning_effort="low"'
clear_pane_history || fail 'could not clear stale trust-session pane history'
send_line "$primary_q" || fail 'could not launch default-permission primary'
wait_command traex 150 || fail 'default-permission primary process did not become current'
wait_text 'GPT-5.6-Luna low' 150 || fail 'default-permission primary TUI did not become ready'
nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
run_tool_turn "$TOOL_EVIDENCE/startup" || fail 'startup tool probe did not complete'
capture > "$LAB/primary-startup.txt"
[ "$(cat "$TOOL_EVIDENCE/startup/harness.rc")" = 0 ] && [ "$(cat "$TOOL_EVIDENCE/startup/harness.out")" = traex ] \
  || fail 'sandbox proof did not identify TraeX'
[ "$(cat "$TOOL_EVIDENCE/startup/proof-owner.rc")" = 0 ] || fail 'sandbox proof did not resolve an owner'
[ "$(cat "$TOOL_EVIDENCE/startup/session-start.rc")" = 0 ] || fail 'sandboxed session start refused ownership'
grep -Fq 'lock acquired: harness pid' "$TOOL_EVIDENCE/startup/session-start.out" \
  || fail 'sandboxed session start did not preserve lock ownership'
grep -Fq 'primary harness: traex' "$TOOL_EVIDENCE/startup/session-start.out" \
  || fail 'sandboxed session start did not route TraeX supervision'
grep -Eq $'^[0-9]+$' "$TOOL_EVIDENCE/startup/proof-owner.out" || fail 'proof owner was not a host pid'
[ "$(cat "$TOOL_EVIDENCE/startup/proof-owner.out")" = "$(cat "$LAB_ROOT/state/.lock")" ] \
  || fail 'proof owner did not equal the existing lock'
! awk -F '\t' 'NR > 1 && ($8 == "traex" || $8 == "traecli") {found=1} END {exit !found}' \
  "$TOOL_EVIDENCE/startup/ancestry.tsv" || fail 'sandbox tool unexpectedly saw a TraeX ancestor'
jq -e --arg home "$HOME" --arg trae "$TRAE_HOME" --arg cli "$TRAECLI_HOME" --arg fm "$FM_HOME" \
  '.HOME == $home and .TRAE_HOME == $trae and .TRAECLI_HOME == $cli and .FM_HOME == $fm and (.TMUX_PANE | startswith("%"))' \
  "$TOOL_EVIDENCE/startup/environment-safe.json" >/dev/null || fail 'sandbox environment roots drifted'
event_exists SessionStart startup || fail 'native startup SessionStart was absent'
event_exists PreToolUse || fail 'native PreToolUse was absent'
for ancestry in "$EVENTS"/*.SessionStart.*/ancestry.tsv "$EVENTS"/*.PreToolUse.*/ancestry.tsv; do
  [ -f "$ancestry" ] || continue
  awk -F '\t' 'NR > 1 && ($8 == "traex" || $8 == "traecli") {found=1} END {exit !found}' "$ancestry" \
    || fail 'native hook did not retain the real TraeX parentage'
done

: > "$LAB/block-pretool"
blocked_target=$LAB_ROOT/pretool-must-not-exist
send_line "Use the Bash tool to run: touch $blocked_target . Then report the exact hook error." \
  || fail 'could not request blocking probe'
wait_text FIRSTMATE_PROBE_PRETOOL_BLOCKED 180 || fail 'PreToolUse exit 2 did not visibly block'
capture > "$LAB/pretool-block.txt"
[ ! -e "$blocked_target" ] || fail 'blocked PreToolUse still executed the tool'
rm -f "$LAB/block-pretool"
run_tool_turn "$TOOL_EVIDENCE/after-block" || fail 'post-block proof recovery failed'
[ "$(cat "$TOOL_EVIDENCE/after-block/harness.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/after-block/proof-owner.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/after-block/session-start.rc")" = 0 ] \
  || fail 'post-block tool did not retain all primary proof guarantees'

send_line /compact || fail 'could not request compact'
if ! wait_event PostCompact '' 75; then
  prior_stop=$(event_count Stop)
  send_line "Write about 1200 words of varied technical prose and end exactly FIRSTMATE_COMPACT_SEED_$nonce." \
    || fail 'could not seed compaction'
  wait_event_count_gt Stop "$prior_stop" 300 || fail 'compaction seed turn did not complete'
  send_line /compact || fail 'could not retry compact after seed'
  wait_event PostCompact '' 120 || fail 'real compact emitted no PostCompact event'
fi
event_exists PreCompact || fail 'real compact emitted no PreCompact event'
wait_input_ready 120 || fail 'PostCompact context re-emission did not return the composer to idle'
capture > "$LAB/compact.txt"

session_before_clear=$(sed -n 's/^session_id=//p' "$LAB_ROOT/state/.traex-primary-session")
clear_pane_history || fail 'could not clear stale pane history before clear'
clear_cursor=$(date +%s%N)
send_line /clear || fail 'could not request clear'
wait_text 'Context 100% left' 120 || fail 'real clear did not restore an input-ready TUI'
clear_activation_started=$(date +%s)
prior_stop=$(event_count Stop)
send_line "Reply exactly FIRSTMATE_CLEAR_ACTIVATED_$nonce without using any tool." \
  || fail 'could not submit the first post-clear activation prompt'
clear_start_file=$(wait_fresh_event_file SessionStart clear "$clear_cursor" 120) \
  || fail 'first post-clear prompt emitted no fresh SessionStart(source=clear)'
clear_prompt_file=$(wait_fresh_event_file UserPromptSubmit '' "$clear_cursor" 120) \
  || fail 'first post-clear prompt emitted no fresh UserPromptSubmit'
wait_event_count_gt Stop "$prior_stop" 180 || fail 'first post-clear activation turn did not complete'
wait_input_ready 120 || fail 'first post-clear activation turn did not return to idle'
clear_start_dir=${clear_start_file%/payload-safe.json}
clear_prompt_dir=${clear_prompt_file%/payload-safe.json}
clear_start_stamp=${clear_start_dir##*/}
clear_start_stamp=${clear_start_stamp%%.*}
clear_prompt_stamp=${clear_prompt_dir##*/}
clear_prompt_stamp=${clear_prompt_stamp%%.*}
[ "$clear_start_stamp" -lt "$clear_prompt_stamp" ] \
  || fail 'post-clear SessionStart did not precede UserPromptSubmit'
session_after_clear=$(jq -r '.session_id' "$clear_start_file")
case "$session_after_clear" in ''|*[!A-Za-z0-9._:-]*) fail 'clear did not publish a safe session id' ;; esac
[ "$session_after_clear" != "$session_before_clear" ] || fail 'real clear did not publish a new bound session id'
[ "$(jq -r '.session_id' "$clear_prompt_file")" = "$session_after_clear" ] \
  || fail 'post-clear SessionStart and UserPromptSubmit used different sessions'
[ "$(sed -n 's/^session_id=//p' "$LAB_ROOT/state/.traex-primary-session")" = "$session_after_clear" ] \
  || fail 'managed clear session record did not match native hook order evidence'
clear_activation_finished=$(date +%s)
printf 'prompt_started_at=%s\nfinished_at=%s\nelapsed_seconds=%s\nsession_start_event_ns=%s\nuser_prompt_event_ns=%s\n' \
  "$clear_activation_started" "$clear_activation_finished" \
  "$((clear_activation_finished - clear_activation_started))" "$clear_start_stamp" "$clear_prompt_stamp" \
  > "$LAB/clear-readiness.txt"
run_tool_turn "$TOOL_EVIDENCE/after-clear" || fail 'post-clear proof failed'
[ "$(cat "$TOOL_EVIDENCE/after-clear/harness.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/after-clear/proof-owner.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/after-clear/session-start.rc")" = 0 ] \
  || fail 'post-clear tool did not retain all primary proof guarantees'
capture > "$LAB/clear.txt"

send_line /exit || fail 'could not exit primary'
wait_shell || fail 'primary exit did not return to the same shell pane'
wait_event SessionEnd '' 60 || fail 'primary exit emitted no SessionEnd'
[ ! -e "$LAB_ROOT/state/.traex-primary-ownership-proof" ] || fail 'exit did not retire the bounded proof'

printf -v resume_q 'env HOME=%q TRAE_HOME=%q TRAECLI_HOME=%q FM_HOME=%q %q resume --permission-mode default --disable plugins --disable plugin_hooks -m %q -c %q %q' \
  "$HOME" "$TRAE_HOME" "$TRAECLI_HOME" "$FM_HOME" "$BINARY" "$MODEL" 'model_reasoning_effort="low"' "$session_after_clear"
clear_pane_history || fail 'could not clear stale primary pane history before resume'
send_line "$resume_q" || fail 'could not launch exact-session resume'
wait_command traex 150 || fail 'resumed TraeX process did not become current'
wait_text 'GPT-5.6-Luna low' 150 || fail 'resumed TraeX TUI did not become ready'
run_tool_turn "$TOOL_EVIDENCE/resume" || fail 'resumed no-ancestor proof failed'
[ "$(cat "$TOOL_EVIDENCE/resume/harness.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/resume/proof-owner.rc")" = 0 ] \
  && [ "$(cat "$TOOL_EVIDENCE/resume/session-start.rc")" = 0 ] \
  || fail 'resumed tool did not retain all primary proof guarantees'
wait_event SessionStart resume 60 || fail 'resume emitted no SessionStart(source=resume)'
capture > "$LAB/resume.txt"
send_line /exit || fail 'could not exit resumed primary'
wait_shell || fail 'resumed primary did not return to the same shell pane'
[ ! -e "$LAB_ROOT/state/.traex-primary-ownership-proof" ] || fail 'resumed exit did not retire proof'

printf -v unbind_q '%q unbind-primary %q %q' "$LAB_ROOT/bin/fm-traex-hook-install.sh" "$LAB_ROOT" "$LAB_ROOT"
send_line "$unbind_q; printf '__UNBIND_RC=%s\\n' \"\$?\"" || fail 'could not request primary unbind'
wait_text '__UNBIND_RC=0' 60 || fail 'primary unbind failed'
"$LAB_ROOT/bin/fm-traex-hook-install.sh" remove > "$LAB/remove.out" 2> "$LAB/remove.err" \
  || fail 'managed hook removal failed'

jq -s 'sort_by(.hook_event_name) | group_by(.hook_event_name)
  | map({event:.[0].hook_event_name,count:length,sources:(map(.source)|unique),
         sessions:(map(.session_id)|unique),permissions:(map(.permission_mode)|unique)})' \
  "$EVENTS"/*/payload-safe.json > "$LAB/event-summary.json" || fail 'could not summarize events'
printf 'session_after_clear=%s\n' "$session_after_clear" > "$LAB/session-summary.txt"
SUCCEEDED=1
printf '%s\n' "$LAB"
