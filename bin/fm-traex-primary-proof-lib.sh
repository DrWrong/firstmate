#!/usr/bin/env bash
# TraeX primary ownership proof.
#
# TraeX's default workspace sandbox places Bash tools in a private PID namespace,
# so those tools cannot see the TraeX process that owns Firstmate's fleet lock.
# Native hooks still run as direct TraeX children. This library is the one owner
# of the bridge between those two facts:
#
# - bind-primary records one exact trusted hook/binary/config/tmux boundary;
# - SessionStart establishes a session lineage from the real hook ancestry;
# - PreToolUse refreshes a short-lived proof immediately before a sandboxed tool;
# - lock consumers accept that proof only for the same home, root, session,
#   live attached pane, process incarnation, binding bytes, and existing lock;
# - Stop/SessionEnd/unbind retire authorization without weakening normal harness
#   ancestry or tmux pane identity.
#
# The hook payload and public tmux formats are the only TraeX/tmux state used.
# No TraeX private session database or pane text is read or written.

FM_TRAEX_PRIMARY_PROOF_PROTOCOL=v1
FM_TRAEX_PRIMARY_PROOF_TTL=300

FM_TRAEX_PROOF_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
if ! declare -F fm_traex_sha256 >/dev/null 2>&1; then
  # shellcheck source=bin/fm-traex-lib.sh
  # shellcheck disable=SC1091 # resolved beside this tracked library at runtime
  . "$FM_TRAEX_PROOF_LIB_DIR/fm-traex-lib.sh"
fi

fm_traex_proof_owner_uid() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

fm_traex_proof_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_traex_proof_file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_traex_proof_regular_private() {
  [ -f "$1" ] && [ ! -L "$1" ] \
    && [ "$(fm_traex_proof_owner_uid "$1" 2>/dev/null)" = "$(id -u)" ] \
    && [ "$(fm_traex_proof_file_mode "$1" 2>/dev/null)" = 600 ]
}

fm_traex_proof_regular_owned() {
  [ -f "$1" ] && [ ! -L "$1" ] \
    && [ "$(fm_traex_proof_owner_uid "$1" 2>/dev/null)" = "$(id -u)" ]
}

fm_traex_proof_field() { # <record> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

fm_traex_proof_hex() { # <value> <length>
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq "$2" ]
}

fm_traex_proof_bounded_id() {
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

fm_traex_proof_real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

fm_traex_proof_random_hex() {
  local value
  value=$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  fm_traex_proof_hex "$value" 64 || return 1
  printf '%s\n' "$value"
}

fm_traex_proof_fsync() {
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

fm_traex_proof_atomic_lines() { # <target>, content on stdin
  local target=$1 directory tmp old_umask status=0
  directory=$(dirname -- "$target")
  old_umask=$(umask); umask 077
  tmp=$(mktemp "$directory/.${target##*/}.XXXXXXXX") || { umask "$old_umask"; return 1; }
  if ! cat > "$tmp" \
      || ! chmod 600 "$tmp" \
      || ! fm_traex_proof_fsync "$tmp" \
      || ! mv -f "$tmp" "$target" \
      || ! fm_traex_proof_fsync "$target" \
      || ! fm_traex_proof_fsync "$directory"; then
    status=1
  fi
  rm -f "$tmp" 2>/dev/null || true
  umask "$old_umask"
  return "$status"
}

# Print public structural tmux identity as eight newline-delimited fields:
# socket, server pid, session id, pane id, pane pid, pane tty, pane dead, and
# current command. Requiring a real attached non-control client on this exact
# pane preserves bind-primary's active-client boundary inside hook validation.
fm_traex_proof_tmux_snapshot() { # [target-pane] [attached|spawn-owned] [match-env|capture]
  local line socket server_pid session_id pane_id pane_pid pane_tty pane_dead pane_command
  local client_name client_snapshot client_session client_pane client_control attached=0
  local target=${1:-${TMUX_PANE:-}} client_policy=${2:-attached} env_policy=${3:-match-env}
  [ -n "${TMUX:-}" ] && [ -n "$target" ] || return 1
  case "$client_policy" in attached|spawn-owned) ;; *) return 1 ;; esac
  case "$env_policy" in match-env) [ "${TMUX_PANE:-}" = "$target" ] || return 1 ;; capture) ;; *) return 1 ;; esac
  command -v tmux >/dev/null 2>&1 || return 1
  line=$(tmux display-message -p -t "$target" \
    $'#{socket_path}\t#{pid}\t#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_dead}\t#{pane_current_command}' \
    2>/dev/null) || return 1
  IFS=$'\t' read -r socket server_pid session_id pane_id pane_pid pane_tty pane_dead pane_command <<EOF
$line
EOF
  case "$socket" in /*) ;; *) return 1 ;; esac
  case "$server_pid:$pane_pid:$pane_dead" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  [ "$pane_dead" = 0 ] || return 1
  [ "$env_policy" != match-env ] || [ "$pane_id" = "$target" ] || return 1
  case "$session_id" in '$'*|'@'*) ;; *) return 1 ;; esac
  case "$pane_id" in '%'*) ;; *) return 1 ;; esac
  case "$pane_tty" in /dev/*) ;; *) return 1 ;; esac
  while IFS=$'\t' read -r client_name client_control; do
    [ -n "$client_name" ] && [ "$client_control" = 0 ] || continue
    client_snapshot=$(tmux display-message -p -c "$client_name" \
      $'#{session_id}\t#{pane_id}' 2>/dev/null) || continue
    IFS=$'\t' read -r client_session client_pane <<EOF
$client_snapshot
EOF
    [ "$client_session" = "$session_id" ] \
      && [ "$client_pane" = "$pane_id" ] \
      && attached=1
  done < <(tmux list-clients -F $'#{client_name}\t#{client_control_mode}' 2>/dev/null || true)
  [ "$client_policy" = spawn-owned ] || [ "$attached" -eq 1 ] || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$socket" "$server_pid" "$session_id" "$pane_id" "$pane_pid" "$pane_tty" "$pane_dead" "$pane_command"
}

fm_traex_proof_process_start() { # <pid>
  local pid=$1 rest
  if [ -r "/proc/$pid/stat" ]; then
    rest=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null) || return 1
    printf '%s\n' "$rest" | awk '{print $20}'
  else
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  fi
}

fm_traex_proof_process_exe() { # <pid>
  local pid=$1 path comm
  if [ -e "/proc/$pid/exe" ]; then
    path=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
  else
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    case "$comm" in /*) path=$comm ;; *) return 1 ;; esac
  fi
  fm_traex_real_file "$path"
}

# Capture immutable primary binding material. Caller appends these lines to the
# registry record it publishes transactionally with the private token/pointer.
fm_traex_primary_binding_capture() { # <root> <home> <state> [target-pane] [attached|spawn-owned] [gate-file]
  local root=$1 home=$2 state=$3 root_real home_real state_real config gate cli_home runtime_home os_home
  local receipt hooks dispatcher binary receipt_sha hooks_sha dispatcher_sha binary_sha binary_identity proof_sha gate_sha nonce
  local snapshot socket server_pid session_id pane_id pane_pid pane_tty pane_dead pane_command
  local target=${4:-${TMUX_PANE:-}} client_policy=${5:-attached} gate_override=${6:-} env_policy=match-env
  root_real=$(fm_traex_proof_real_dir "$root") || return 1
  home_real=$(fm_traex_proof_real_dir "$home") || return 1
  state_real=$(fm_traex_proof_real_dir "$state") || return 1
  [ "$state_real" = "$home_real/state" ] || return 1
  config=$home_real/config
  gate=${gate_override:-$config/traex-adapter}
  case "$gate" in /*) ;; *) return 1 ;; esac
  fm_traex_proof_regular_owned "$gate" || return 1
  os_home=$(fm_traex_os_home) || return 1
  runtime_home=$(fm_traex_runtime_home) || return 1
  cli_home=$(fm_traex_cli_home) || return 1
  receipt=$(fm_traex_receipt_path) || return 1
  hooks=$(fm_traex_hooks_path) || return 1
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  binary=$(fm_traex_binary) || return 1
  for path in "$receipt" "$hooks" "$dispatcher" "$binary" "$FM_TRAEX_PROOF_LIB_DIR/fm-traex-primary-proof-lib.sh"; do
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  done
  receipt_sha=$(fm_traex_sha256 "$receipt") || return 1
  hooks_sha=$(fm_traex_sha256 "$hooks") || return 1
  dispatcher_sha=$(fm_traex_sha256 "$dispatcher") || return 1
  binary_sha=$(fm_traex_sha256 "$binary") || return 1
  binary_identity=$(fm_traex_file_identity "$binary") || return 1
  proof_sha=$(fm_traex_sha256 "$FM_TRAEX_PROOF_LIB_DIR/fm-traex-primary-proof-lib.sh") || return 1
  gate_sha=$(fm_traex_sha256 "$gate") || return 1
  for path in "$receipt_sha" "$hooks_sha" "$dispatcher_sha" "$binary_sha" "$proof_sha" "$gate_sha"; do
    fm_traex_proof_hex "$path" 64 || return 1
  done
  [ "$binary_sha" = "$FM_TRAEX_SUPPORTED_SHA256" ] || return 1
  [ "$client_policy" != spawn-owned ] || env_policy=capture
  snapshot=$(fm_traex_proof_tmux_snapshot "$target" "$client_policy" "$env_policy") || return 1
  {
    IFS= read -r socket
    IFS= read -r server_pid
    IFS= read -r session_id
    IFS= read -r pane_id
    IFS= read -r pane_pid
    IFS= read -r pane_tty
    IFS= read -r pane_dead
    IFS= read -r pane_command
  } <<EOF
$snapshot
EOF
  [ "$pane_dead" = 0 ] || return 1
  nonce=$(fm_traex_proof_random_hex) || return 1
  printf 'proof_protocol=%s\n' "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL"
  printf 'binding_nonce=%s\n' "$nonce"
  printf 'traex_os_home=%s\n' "$os_home"
  printf 'traex_home=%s\n' "$runtime_home"
  printf 'traex_cli_home=%s\n' "$cli_home"
  printf 'receipt_path=%s\nreceipt_sha256=%s\n' "$receipt" "$receipt_sha"
  printf 'hooks_path=%s\nhooks_sha256=%s\n' "$hooks" "$hooks_sha"
  printf 'dispatcher_path=%s\ndispatcher_sha256=%s\n' "$dispatcher" "$dispatcher_sha"
  printf 'binary_path=%s\nbinary_sha256=%s\nbinary_identity=%s\n' "$binary" "$binary_sha" "$binary_identity"
  printf 'proof_lib_sha256=%s\ngate_path=%s\ngate_sha256=%s\n' "$proof_sha" "$gate" "$gate_sha"
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_session_id=%s\n' "$socket" "$server_pid" "$session_id"
  printf 'tmux_pane=%s\ntmux_pane_pid=%s\ntmux_pane_tty=%s\n' "$pane_id" "$pane_pid" "$pane_tty"
  printf 'tmux_client_policy=%s\n' "$client_policy"
}

fm_traex_primary_binding_record_matches() { # <record> <root> <home> <state> [runtime|binding]
  local record=$1 root=$2 home=$3 state=$4 root_real home_real state_real key value path expected snapshot
  local socket server_pid session_id pane_id pane_pid pane_tty pane_dead pane_command cli_home
  local context=${5:-runtime} client_policy target env_policy=match-env
  fm_traex_proof_regular_private "$record" || return 1
  root_real=$(fm_traex_proof_real_dir "$root") || return 1
  home_real=$(fm_traex_proof_real_dir "$home") || return 1
  state_real=$(fm_traex_proof_real_dir "$state") || return 1
  [ "$(fm_traex_proof_field "$record" proof_protocol)" = "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL" ] || return 1
  value=$(fm_traex_proof_field "$record" binding_nonce) || return 1
  fm_traex_proof_hex "$value" 64 || return 1
  [ "$(fm_traex_proof_field "$record" worktree_real)" = "$root_real" ] || return 1
  [ "$(fm_traex_proof_field "$record" fm_root_real)" = "$root_real" ] || return 1
  [ "$(fm_traex_proof_field "$record" fm_home_real)" = "$home_real" ] || return 1
  [ "$(fm_traex_proof_field "$record" state_real)" = "$state_real" ] || return 1
  [ "$(fm_traex_proof_field "$record" traex_os_home)" = "$(fm_traex_os_home 2>/dev/null)" ] || return 1
  [ "$(fm_traex_proof_field "$record" traex_home)" = "$(fm_traex_runtime_home 2>/dev/null)" ] || return 1
  cli_home=$(fm_traex_cli_home 2>/dev/null) || return 1
  [ "$(fm_traex_proof_field "$record" traex_cli_home)" = "$cli_home" ] || return 1
  for key in receipt hooks dispatcher; do
    path=$(fm_traex_proof_field "$record" "${key}_path") || return 1
    case "$key:$path" in
      receipt:"$cli_home/fm-firstmate-receipt.json"|hooks:"$cli_home/hooks.json"|dispatcher:"$cli_home/fm-firstmate-hook.sh") ;;
      *) return 1 ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    expected=$(fm_traex_proof_field "$record" "${key}_sha256") || return 1
    fm_traex_proof_hex "$expected" 64 || return 1
    [ "$(fm_traex_sha256 "$path" 2>/dev/null)" = "$expected" ] || return 1
  done
  path=$(fm_traex_proof_field "$record" binary_path) || return 1
  [ "$path" = "$(fm_traex_binary 2>/dev/null)" ] || return 1
  expected=$(fm_traex_proof_field "$record" binary_sha256) || return 1
  [ "$expected" = "$FM_TRAEX_SUPPORTED_SHA256" ] || return 1
  [ "$(fm_traex_file_identity "$path" 2>/dev/null)" = "$(fm_traex_proof_field "$record" binary_identity)" ] || return 1
  expected=$(fm_traex_proof_field "$record" proof_lib_sha256) || return 1
  [ "$(fm_traex_sha256 "$FM_TRAEX_PROOF_LIB_DIR/fm-traex-primary-proof-lib.sh" 2>/dev/null)" = "$expected" ] || return 1
  path=$(fm_traex_proof_field "$record" gate_path) || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  fm_traex_proof_regular_owned "$path" || return 1
  [ "$(fm_traex_sha256 "$path" 2>/dev/null)" = "$(fm_traex_proof_field "$record" gate_sha256)" ] || return 1
  client_policy=$(fm_traex_proof_field "$record" tmux_client_policy) || return 1
  target=$(fm_traex_proof_field "$record" tmux_pane) || return 1
  if [ "$context" = binding ] && [ "$client_policy" = spawn-owned ]; then env_policy=capture; fi
  snapshot=$(fm_traex_proof_tmux_snapshot "$target" "$client_policy" "$env_policy") || return 1
  {
    IFS= read -r socket
    IFS= read -r server_pid
    IFS= read -r session_id
    IFS= read -r pane_id
    IFS= read -r pane_pid
    IFS= read -r pane_tty
    IFS= read -r pane_dead
    IFS= read -r pane_command
  } <<EOF
$snapshot
EOF
  [ "$pane_dead" = 0 ] || return 1
  [ "$socket" = "$(fm_traex_proof_field "$record" tmux_socket)" ] || return 1
  [ "$server_pid" = "$(fm_traex_proof_field "$record" tmux_server_pid)" ] || return 1
  [ "$session_id" = "$(fm_traex_proof_field "$record" tmux_session_id)" ] || return 1
  [ "$pane_id" = "$(fm_traex_proof_field "$record" tmux_pane)" ] || return 1
  [ "$pane_pid" = "$(fm_traex_proof_field "$record" tmux_pane_pid)" ] || return 1
  [ "$pane_tty" = "$(fm_traex_proof_field "$record" tmux_pane_tty)" ] || return 1
}

fm_traex_primary_live_pane_matches() { # <record> <root> <home> <state>
  local record=$1 root=$2 home=$3 state=$4 snapshot pane_command target client_policy
  fm_traex_primary_binding_record_matches "$record" "$root" "$home" "$state" || return 1
  target=$(fm_traex_proof_field "$record" tmux_pane) || return 1
  client_policy=$(fm_traex_proof_field "$record" tmux_client_policy) || return 1
  snapshot=$(fm_traex_proof_tmux_snapshot "$target" "$client_policy" match-env) || return 1
  pane_command=$(printf '%s\n' "$snapshot" | sed -n '8p')
  case "$pane_command" in traex|traecli) return 0 ;; *) return 1 ;; esac
}

fm_traex_primary_binding_record_path() { # <state> <root> <home>
  local state=$1 root=$2 home=$3 token_state token cli_home record pointer pointer_value task_id client_policy
  pointer=$root/.fm-traex-hook
  fm_traex_proof_regular_private "$pointer" || return 1
  pointer_value=$(cat "$pointer" 2>/dev/null) || return 1
  case "$pointer_value" in token=*) token=${pointer_value#token=} ;; *) return 1 ;; esac
  case "$token" in ????????-????????-????????-????????) ;; *) return 1 ;; esac
  case "$token" in *[!0-9a-f-]*) return 1 ;; esac
  cli_home=$(fm_traex_cli_home 2>/dev/null) || return 1
  record=$cli_home/fm-firstmate-hooks.d/$token
  fm_traex_proof_regular_private "$record" || return 1
  [ "$(fm_traex_proof_field "$record" token)" = "$token" ] || return 1
  token_state=$(fm_traex_proof_field "$record" token_state_real) || return 1
  case "$token_state" in /*) ;; *) return 1 ;; esac
  fm_traex_proof_regular_private "$token_state" || return 1
  [ "$(cat "$token_state" 2>/dev/null)" = "$token" ] || return 1
  [ "$(fm_traex_proof_field "$record" token_state_real)" = "$token_state" ] || return 1
  [ "$(fm_traex_proof_field "$record" role)" = primary ] || return 1
  task_id=$(fm_traex_proof_field "$record" task_id) || return 1
  fm_traex_proof_bounded_id "$task_id" || return 1
  client_policy=$(fm_traex_proof_field "$record" tmux_client_policy) || return 1
  if [ "$token_state" = "$state/.traex-primary-hook-token" ]; then
    [ "$task_id" = primary ] && [ "$client_policy" = attached ] || return 1
  else
    [ "$client_policy" = spawn-owned ] \
      && [ "${token_state##*/}" = "$task_id.traex-hook-token" ] \
      || return 1
  fi
  fm_traex_primary_live_pane_matches "$record" "$root" "$home" "$state" || return 1
  printf '%s\n' "$record"
}

fm_traex_proof_mac() { # <nonce> <binding-sha> <session> <owner-pid> <owner-start> <event> <issued> <expires>
  printf 'protocol=%s\nbinding_sha256=%s\nsession_id=%s\nowner_pid=%s\nowner_start=%s\nevent=%s\nissued_at=%s\nexpires_at=%s\nnonce=%s\n' \
    "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$1" \
    | fm_traex_sha256 /dev/stdin
}

fm_traex_lineage_mac() { # <nonce> <binding-sha> <session> <owner-pid> <owner-start> <source> <updated>
  printf 'protocol=%s\nbinding_sha256=%s\nsession_id=%s\nowner_pid=%s\nowner_start=%s\nsource=%s\nupdated_at=%s\nnonce=%s\n' \
    "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL" "$2" "$3" "$4" "$5" "$6" "$7" "$1" \
    | fm_traex_sha256 /dev/stdin
}

fm_traex_lineage_valid() { # <lineage> <record> <binding-sha>
  local lineage=$1 record=$2 binding_sha=$3 nonce session owner_pid owner_start source updated mac
  fm_traex_proof_regular_private "$lineage" || return 1
  [ "$(fm_traex_proof_field "$lineage" protocol)" = "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL" ] || return 1
  [ "$(fm_traex_proof_field "$lineage" binding_sha256)" = "$binding_sha" ] || return 1
  nonce=$(fm_traex_proof_field "$record" binding_nonce) || return 1
  session=$(fm_traex_proof_field "$lineage" session_id) || return 1
  owner_pid=$(fm_traex_proof_field "$lineage" owner_pid) || return 1
  owner_start=$(fm_traex_proof_field "$lineage" owner_start) || return 1
  source=$(fm_traex_proof_field "$lineage" source) || return 1
  updated=$(fm_traex_proof_field "$lineage" updated_at) || return 1
  mac=$(fm_traex_proof_field "$lineage" mac) || return 1
  fm_traex_proof_bounded_id "$session" || return 1
  case "$owner_pid:$updated" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ -n "$owner_start" ] || return 1
  case "$source" in startup|resume|clear) ;; *) return 1 ;; esac
  [ "$mac" = "$(fm_traex_lineage_mac "$nonce" "$binding_sha" "$session" "$owner_pid" "$owner_start" "$source" "$updated")" ]
}

fm_traex_current_primary_process() { # <record>; prints pid then start identity
  local record=$1 pid comm base exe expected start args script matched=0
  expected=$(fm_traex_proof_field "$record" binary_path) || return 1
  # Walk for the exact receipted TraeX executable rather than asking the generic
  # harness matcher. That prevents an unrelated outer Codex/Claude process from
  # satisfying a hook whose real TraeX parent is missing.
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    base=$(basename -- "$comm")
    case "$base" in
      traex|traecli)
        exe=$(fm_traex_proof_process_exe "$pid" 2>/dev/null || true)
        [ "$exe" != "$expected" ] || { matched=1; break; }
        ;;
      bash|sh)
        # Portable regression fixtures use an exact script at the pinned binary
        # path. The production pin is native, so this cannot widen that identity.
        # shellcheck disable=SC2086 # deliberate argv tokenization for a fixture path without whitespace
        set -- $args
        script=${2:-}
        [ "$script" != "$expected" ] || { matched=1; break; }
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$matched" -eq 1 ] || return 1
  start=$(fm_traex_proof_process_start "$pid") || return 1
  [ -n "$start" ] || return 1
  printf '%s\n%s\n' "$pid" "$start"
}

fm_traex_primary_proof_write() { # <state> <record> <binding-sha> <session> <owner-pid> <owner-start> <event>
  local state=$1 record=$2 binding_sha=$3 session=$4 owner_pid=$5 owner_start=$6 event=$7 issued expires nonce mac proof
  issued=$(date +%s) || return 1
  case "$issued" in ''|*[!0-9]*) return 1 ;; esac
  expires=$((issued + FM_TRAEX_PRIMARY_PROOF_TTL))
  nonce=$(fm_traex_proof_field "$record" binding_nonce) || return 1
  mac=$(fm_traex_proof_mac "$nonce" "$binding_sha" "$session" "$owner_pid" "$owner_start" "$event" "$issued" "$expires") || return 1
  proof=$state/.traex-primary-ownership-proof
  fm_traex_proof_atomic_lines "$proof" <<EOF
protocol=$FM_TRAEX_PRIMARY_PROOF_PROTOCOL
binding_sha256=$binding_sha
session_id=$session
owner_pid=$owner_pid
owner_start=$owner_start
event=$event
issued_at=$issued
expires_at=$expires
mac=$mac
EOF
}

fm_traex_primary_lineage_write() { # <state> <record> <binding-sha> <session> <owner-pid> <owner-start> <source>
  local state=$1 record=$2 binding_sha=$3 session=$4 owner_pid=$5 owner_start=$6 source=$7 updated nonce mac lineage
  updated=$(date +%s) || return 1
  nonce=$(fm_traex_proof_field "$record" binding_nonce) || return 1
  mac=$(fm_traex_lineage_mac "$nonce" "$binding_sha" "$session" "$owner_pid" "$owner_start" "$source" "$updated") || return 1
  lineage=$state/.traex-primary-lineage
  fm_traex_proof_atomic_lines "$lineage" <<EOF
protocol=$FM_TRAEX_PRIMARY_PROOF_PROTOCOL
binding_sha256=$binding_sha
session_id=$session
owner_pid=$owner_pid
owner_start=$owner_start
source=$source
updated_at=$updated
mac=$mac
EOF
}

fm_traex_primary_session_transition_valid() { # <record> <session-id> <source>
  local record=$1 session=$2 source=$3 state root home binding_sha process owner_pid owner_start
  local lineage old_session old_pid old_start lock_pid has_lineage=0
  fm_traex_proof_bounded_id "$session" || return 1
  case "$source" in startup|resume|clear) ;; *) return 1 ;; esac
  state=$(fm_traex_proof_field "$record" state_real) || return 1
  root=$(fm_traex_proof_field "$record" fm_root_real) || return 1
  home=$(fm_traex_proof_field "$record" fm_home_real) || return 1
  fm_traex_primary_live_pane_matches "$record" "$root" "$home" "$state" || return 1
  process=$(fm_traex_current_primary_process "$record") || return 1
  owner_pid=${process%%$'\n'*}
  owner_start=${process#*$'\n'}
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  lineage=$state/.traex-primary-lineage
  if [ -e "$lineage" ] || [ -L "$lineage" ]; then
    fm_traex_lineage_valid "$lineage" "$record" "$binding_sha" || return 1
    has_lineage=1
    old_session=$(fm_traex_proof_field "$lineage" session_id) || return 1
    old_pid=$(fm_traex_proof_field "$lineage" owner_pid) || return 1
    old_start=$(fm_traex_proof_field "$lineage" owner_start) || return 1
    case "$source" in
      startup)
        [ "$session" = "$old_session" ] && [ "$owner_pid" = "$old_pid" ] && [ "$owner_start" = "$old_start" ] || return 1
        ;;
      resume)
        [ "$session" = "$old_session" ] || return 1
        ;;
      clear)
        [ "$session" != "$old_session" ] \
          && [ "$owner_pid" = "$old_pid" ] && [ "$owner_start" = "$old_start" ] \
          || return 1
        ;;
    esac
  else
    [ "$source" = startup ] || return 1
  fi

  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*)
      [ "$source" = startup ] && [ "$has_lineage" -eq 0 ] || return 1
      ;;
    *)
      [ "$lock_pid" = "$owner_pid" ] && return 0
      if declare -F fm_harness_pid_alive >/dev/null 2>&1 \
          && fm_harness_pid_alive "$lock_pid"; then
        return 1
      fi
      case "$source" in
        startup) [ "$has_lineage" -eq 0 ] || return 1 ;;
        resume) [ "$has_lineage" -eq 1 ] && [ "$lock_pid" = "$old_pid" ] || return 1 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

fm_traex_primary_proof_publish_session() { # <record> <session-id> <source>
  local record=$1 session=$2 source=$3 state binding_sha process owner_pid owner_start
  fm_traex_primary_session_transition_valid "$record" "$session" "$source" || return 1
  state=$(fm_traex_proof_field "$record" state_real) || return 1
  process=$(fm_traex_current_primary_process "$record") || return 1
  owner_pid=${process%%$'\n'*}
  owner_start=${process#*$'\n'}
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  fm_traex_primary_lineage_write "$state" "$record" "$binding_sha" "$session" "$owner_pid" "$owner_start" "$source" \
    || return 1
  fm_traex_primary_proof_write "$state" "$record" "$binding_sha" "$session" "$owner_pid" "$owner_start" SessionStart
}

fm_traex_primary_lineage_guard() { # <record> <session-id>
  local record=$1 session=$2 state root home binding_sha process owner_pid owner_start lineage lock_pid session_file
  fm_traex_proof_bounded_id "$session" || return 1
  state=$(fm_traex_proof_field "$record" state_real) || return 1
  root=$(fm_traex_proof_field "$record" fm_root_real) || return 1
  home=$(fm_traex_proof_field "$record" fm_home_real) || return 1
  fm_traex_primary_live_pane_matches "$record" "$root" "$home" "$state" || return 1
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  lineage=$state/.traex-primary-lineage
  fm_traex_lineage_valid "$lineage" "$record" "$binding_sha" || return 1
  [ "$(fm_traex_proof_field "$lineage" session_id)" = "$session" ] || return 1
  process=$(fm_traex_current_primary_process "$record") || return 1
  owner_pid=${process%%$'\n'*}
  owner_start=${process#*$'\n'}
  [ "$(fm_traex_proof_field "$lineage" owner_pid)" = "$owner_pid" ] || return 1
  [ "$(fm_traex_proof_field "$lineage" owner_start)" = "$owner_start" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$owner_pid" ] || return 1
  session_file=$state/.traex-primary-session
  fm_traex_proof_regular_private "$session_file" || return 1
  [ "$(fm_traex_proof_field "$session_file" session_id)" = "$session" ] || return 1
}

fm_traex_primary_proof_publish_pretool() { # <record> <session-id>
  local record=$1 session=$2 state binding_sha process owner_pid owner_start
  fm_traex_primary_lineage_guard "$record" "$session" || return 1
  state=$(fm_traex_proof_field "$record" state_real) || return 1
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  process=$(fm_traex_current_primary_process "$record") || return 1
  owner_pid=${process%%$'\n'*}
  owner_start=${process#*$'\n'}
  fm_traex_primary_proof_write "$state" "$record" "$binding_sha" "$session" "$owner_pid" "$owner_start" PreToolUse
}

fm_traex_primary_proof_retire() { # <record> <session-id>
  local record=$1 session=$2 state proof binding_sha process owner_pid owner_start
  state=$(fm_traex_proof_field "$record" state_real) || return 1
  proof=$state/.traex-primary-ownership-proof
  [ -e "$proof" ] || [ -L "$proof" ] || return 0
  fm_traex_proof_regular_private "$proof" || return 1
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  [ "$(fm_traex_proof_field "$proof" binding_sha256)" = "$binding_sha" ] || return 1
  [ "$(fm_traex_proof_field "$proof" session_id)" = "$session" ] || return 1
  process=$(fm_traex_current_primary_process "$record") || return 1
  owner_pid=${process%%$'\n'*}
  owner_start=${process#*$'\n'}
  [ "$(fm_traex_proof_field "$proof" owner_pid)" = "$owner_pid" ] || return 1
  [ "$(fm_traex_proof_field "$proof" owner_start)" = "$owner_start" ] || return 1
  rm -f "$proof"
}

# Validate a PreToolUse proof from a sandboxed tool and print the host TraeX pid
# only when it already equals this home's fleet lock. This function never grants
# authority to create or replace a lock; SessionStart's real hook ancestry must
# have acquired it first.
fm_traex_primary_proof_owner_pid() { # <state>
  local state=$1 root home state_real record binding_sha proof lineage session_file session owner_pid owner_start event issued expires mac nonce now mtime lock_pid
  state_real=$(fm_traex_proof_real_dir "$state") || return 1
  root=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$FM_TRAEX_PROOF_LIB_DIR/.." 2>/dev/null && pwd -P)}
  root=$(fm_traex_proof_real_dir "$root") || return 1
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}
  home=$(fm_traex_proof_real_dir "$home") || return 1
  [ "$state_real" = "$home/state" ] || return 1
  record=$(fm_traex_primary_binding_record_path "$state_real" "$root" "$home") || return 1
  fm_traex_primary_live_pane_matches "$record" "$root" "$home" "$state_real" || return 1
  binding_sha=$(fm_traex_sha256 "$record") || return 1
  proof=$state_real/.traex-primary-ownership-proof
  lineage=$state_real/.traex-primary-lineage
  fm_traex_proof_regular_private "$proof" || return 1
  fm_traex_lineage_valid "$lineage" "$record" "$binding_sha" || return 1
  [ "$(fm_traex_proof_field "$proof" protocol)" = "$FM_TRAEX_PRIMARY_PROOF_PROTOCOL" ] || return 1
  [ "$(fm_traex_proof_field "$proof" binding_sha256)" = "$binding_sha" ] || return 1
  session=$(fm_traex_proof_field "$proof" session_id) || return 1
  owner_pid=$(fm_traex_proof_field "$proof" owner_pid) || return 1
  owner_start=$(fm_traex_proof_field "$proof" owner_start) || return 1
  event=$(fm_traex_proof_field "$proof" event) || return 1
  issued=$(fm_traex_proof_field "$proof" issued_at) || return 1
  expires=$(fm_traex_proof_field "$proof" expires_at) || return 1
  mac=$(fm_traex_proof_field "$proof" mac) || return 1
  fm_traex_proof_bounded_id "$session" || return 1
  [ "$event" = PreToolUse ] || return 1
  case "$owner_pid:$issued:$expires" in *[!0-9:]*|:*|*::*|*:) return 1 ;; esac
  [ -n "$owner_start" ] || return 1
  now=$(date +%s) || return 1
  [ "$issued" -le "$((now + 5))" ] && [ "$now" -le "$expires" ] || return 1
  [ "$expires" -gt "$issued" ] && [ "$((expires - issued))" -le "$FM_TRAEX_PRIMARY_PROOF_TTL" ] || return 1
  mtime=$(fm_traex_proof_file_mtime "$proof") || return 1
  [ "$mtime" -ge "$((issued - 5))" ] && [ "$mtime" -le "$((now + 5))" ] || return 1
  nonce=$(fm_traex_proof_field "$record" binding_nonce) || return 1
  [ "$mac" = "$(fm_traex_proof_mac "$nonce" "$binding_sha" "$session" "$owner_pid" "$owner_start" "$event" "$issued" "$expires")" ] || return 1
  [ "$(fm_traex_proof_field "$lineage" session_id)" = "$session" ] || return 1
  [ "$(fm_traex_proof_field "$lineage" owner_pid)" = "$owner_pid" ] || return 1
  [ "$(fm_traex_proof_field "$lineage" owner_start)" = "$owner_start" ] || return 1
  session_file=$state_real/.traex-primary-session
  fm_traex_proof_regular_private "$session_file" || return 1
  [ "$(fm_traex_proof_field "$session_file" session_id)" = "$session" ] || return 1
  lock_pid=$(cat "$state_real/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$owner_pid" ] || return 1
  printf '%s\n' "$owner_pid"
}

fm_traex_primary_proof_retire_binding() { # <state>
  local state=$1 path
  for path in .traex-primary-ownership-proof .traex-primary-lineage .traex-primary-session; do
    if [ -e "$state/$path" ] || [ -L "$state/$path" ]; then
      fm_traex_proof_regular_private "$state/$path" || return 1
    fi
  done
  rm -f "$state/.traex-primary-ownership-proof" "$state/.traex-primary-lineage" "$state/.traex-primary-session"
}
