#!/usr/bin/env bash
# Install, verify, probe, bind, and remove Firstmate's trusted TraeX hook.
#
# Usage:
#   fm-traex-hook-install.sh install
#   fm-traex-hook-install.sh probe --model GPT-5.6-Luna
#   fm-traex-hook-install.sh verify
#   fm-traex-hook-install.sh bind-primary [<firstmate-root> [<firstmate-home>]]
#   fm-traex-hook-install.sh unbind-primary [<firstmate-root> [<firstmate-home>]]
#   fm-traex-hook-install.sh remove
#
# Internal task lifecycle commands (called by fm-spawn/fm-teardown):
#   ... register <worker|primary> <task-id> <worktree> <state> <fm-root> <fm-home> <busy-gen|-> <token-state>
#   ... unregister <worktree> <token-state>
#
# `install` merge-preserves every non-Firstmate hook and invalidates the receipt
# when managed bytes change. It never edits TraeX's private trust store.
# `probe` deliberately omits --dangerously-bypass-hook-trust: the native TraeX
# review must already have accepted the exact installed hooks. Only observed
# SessionStart/UserPromptSubmit/Stop/SessionEnd callbacks generate a receipt.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-traex-lib.sh
. "$SCRIPT_DIR/fm-traex-lib.sh"

usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

owner_uid() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

regular_owned() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(owner_uid "$1" 2>/dev/null)" = "$(id -u)" ]
}

directory_owned() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(owner_uid "$1" 2>/dev/null)" = "$(id -u)" ]
}

real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

field() {
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

token_valid() {
  case "$1" in ????????-????????-????????-????????) ;; *) return 1 ;; esac
  case "$1" in *[!0-9a-f-]*) return 1 ;; esac
}

token_new() {
  local hex
  hex=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#hex}" -eq 32 ] || return 1
  printf '%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:8}" "${hex:16:8}" "${hex:24:8}"
}

FM_TRAEX_PROBE_RECORD=
FM_TRAEX_PROBE_TOKEN_STATE=
FM_TRAEX_PROBE_POINTER=

probe_binding_cleanup() {
  local status=0
  if [ -n "$FM_TRAEX_PROBE_RECORD" ]; then
    rm -f -- "$FM_TRAEX_PROBE_RECORD" && FM_TRAEX_PROBE_RECORD= || status=1
  fi
  if [ -n "$FM_TRAEX_PROBE_TOKEN_STATE" ]; then
    rm -f -- "$FM_TRAEX_PROBE_TOKEN_STATE" && FM_TRAEX_PROBE_TOKEN_STATE= || status=1
  fi
  if [ -n "$FM_TRAEX_PROBE_POINTER" ]; then
    rm -f -- "$FM_TRAEX_PROBE_POINTER" && FM_TRAEX_PROBE_POINTER= || status=1
  fi
  return "$status"
}

probe_exit_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  probe_binding_cleanup || true
  exit "$status"
}

atomic_write() {  # <target> <source> <mode>
  local target=$1 source=$2 mode=$3 tmp
  tmp=$(mktemp "$(dirname -- "$target")/.${target##*/}.XXXXXXXX") || return 1
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cp "$source" "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

render_dispatcher() {  # <source> <target>
  local source=$1 target=$2 line version_seen=0 sha_seen=0
  : > "$target" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'SUPPORTED_VERSION=__FM_TRAEX_SUPPORTED_VERSION__')
        [ "$version_seen" -eq 0 ] || return 1
        printf 'SUPPORTED_VERSION=%s\n' "$(shell_quote "$FM_TRAEX_SUPPORTED_VERSION")" >> "$target" || return 1
        version_seen=1
        ;;
      'SUPPORTED_BINARY_SHA256=__FM_TRAEX_SUPPORTED_SHA256__')
        [ "$sha_seen" -eq 0 ] || return 1
        printf 'SUPPORTED_BINARY_SHA256=%s\n' "$(shell_quote "$FM_TRAEX_SUPPORTED_SHA256")" >> "$target" || return 1
        sha_seen=1
        ;;
      *)
        printf '%s\n' "$line" >> "$target" || return 1
        ;;
    esac
  done < "$source"
  [ "$version_seen" -eq 1 ] && [ "$sha_seen" -eq 1 ]
}

managed_command() {
  local dispatcher
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  printf 'bash %s\n' "$(shell_quote "$dispatcher")"
}

validate_hooks_json() {  # <file>
  jq -e '
    . as $root
    | type == "object"
    and ((.version // 1) == 1)
    and ((.hooks // {}) | type == "object")
    and (["SessionStart","UserPromptSubmit","Stop","SessionEnd"]
      | all(.[]; . as $event
        | (($root.hooks[$event] // []) | type == "array")
        and all(($root.hooks[$event] // [])[];
          type == "object" and (.hooks | type == "array"))))
  ' "$1" >/dev/null 2>&1
}

install_hook() {
  local cli_home hooks dispatcher receipt source command work existing candidate source_tmp mode changed=0
  command -v jq >/dev/null 2>&1 || { printf 'fm-traex-hook-install: refused: jq is required.\n' >&2; return 1; }
  cli_home=$(fm_traex_cli_home) || return 1
  hooks=$(fm_traex_hooks_path) || return 1
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  receipt=$(fm_traex_receipt_path) || return 1
  source=$SCRIPT_DIR/fm-traex-hook-dispatch.sh
  [ -f "$source" ] && [ ! -L "$source" ] || { printf 'fm-traex-hook-install: refused: tracked dispatcher is missing.\n' >&2; return 1; }
  if [ -e "$cli_home" ] || [ -L "$cli_home" ]; then
    [ -d "$cli_home" ] && [ ! -L "$cli_home" ] || { printf 'fm-traex-hook-install: refused: TRAECLI_HOME is unsafe: %s\n' "$cli_home" >&2; return 1; }
  else
    mkdir -p "$cli_home" || return 1
    chmod 700 "$cli_home" || return 1
  fi
  if [ -e "$dispatcher" ] || [ -L "$dispatcher" ]; then
    regular_owned "$dispatcher" || { printf 'fm-traex-hook-install: refused: dispatcher path is not an owned regular file: %s\n' "$dispatcher" >&2; return 1; }
    head -n 2 "$dispatcher" | grep -Fq 'Firstmate TraeX hook dispatcher.' || { printf 'fm-traex-hook-install: refused: dispatcher path has non-Firstmate content: %s\n' "$dispatcher" >&2; return 1; }
  fi
  work=$(mktemp -d "$cli_home/.fm-traex-install.XXXXXXXX") || return 1
  existing=$work/hooks.before
  candidate=$work/hooks.after
  source_tmp=$work/dispatcher
  if [ -e "$hooks" ] || [ -L "$hooks" ]; then
    regular_owned "$hooks" || { printf 'fm-traex-hook-install: refused: hooks.json is not an owned regular file.\n' >&2; rm -rf "$work"; return 1; }
    cp "$hooks" "$existing" || { rm -rf "$work"; return 1; }
    mode=$(file_mode "$hooks" 2>/dev/null || printf '600')
  else
    printf '{"version":1,"hooks":{}}\n' > "$existing"
    mode=600
  fi
  validate_hooks_json "$existing" || { printf 'fm-traex-hook-install: refused: malformed or unsupported hooks.json; no bytes changed.\n' >&2; rm -rf "$work"; return 1; }
  command=$(managed_command) || { rm -rf "$work"; return 1; }
  if ! jq -e --arg command "$command" '
      [.. | objects | .command? | select(type == "string" and contains("fm-firstmate-hook.sh") and . != $command)] | length == 0
    ' "$existing" >/dev/null 2>&1; then
    printf 'fm-traex-hook-install: refused: conflicting Firstmate-looking command exists in hooks.json.\n' >&2
    rm -rf "$work"
    return 1
  fi
  jq --arg command "$command" '
    .version = (.version // 1)
    | .hooks = (.hooks // {})
    | {hooks:[{type:"command",command:$command,timeout:180}]} as $managed
    | reduce ["SessionStart","UserPromptSubmit","Stop","SessionEnd"][] as $event
        (. ; .hooks[$event] = (((.hooks[$event] // [])
          | map(.hooks |= map(select((type != "object") or (.command? != $command))))
          | map(select((.hooks | length) > 0))) + [$managed]))
  ' "$existing" > "$candidate" || { rm -rf "$work"; return 1; }
  validate_hooks_json "$candidate" || { rm -rf "$work"; return 1; }
  render_dispatcher "$source" "$source_tmp" || { rm -rf "$work"; return 1; }
  chmod 700 "$source_tmp"
  if [ ! -f "$dispatcher" ] || ! cmp -s "$source_tmp" "$dispatcher"; then
    atomic_write "$dispatcher" "$source_tmp" 700 || { rm -rf "$work"; return 1; }
    changed=1
  fi
  if [ ! -f "$hooks" ] || ! cmp -s "$candidate" "$hooks"; then
    atomic_write "$hooks" "$candidate" "$mode" || { rm -rf "$work"; return 1; }
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    rm -f "$receipt"
    printf 'installed: TraeX hook bytes changed; native review and probe are required before dispatch\n'
  else
    printf 'installed: TraeX hook bytes already current\n'
  fi
  rm -rf "$work"
}

supported_material() {  # prints: binary|binary-sha|hooks-sha|dispatcher-sha
  local binary version cli_home hooks dispatcher binary_sha hooks_sha dispatcher_sha
  binary=$(fm_traex_binary) || return 1
  version=$("$binary" --version 2>/dev/null || true)
  [ "$version" = "$FM_TRAEX_SUPPORTED_VERSION" ] || { printf 'error: unsupported TraeX version: %s\n' "${version:-unreadable}" >&2; return 1; }
  binary_sha=$(fm_traex_sha256 "$binary") || return 1
  [ "$binary_sha" = "$FM_TRAEX_SUPPORTED_SHA256" ] || { printf 'error: unsupported TraeX binary hash: %s\n' "$binary_sha" >&2; return 1; }
  cli_home=$(fm_traex_cli_home) || return 1
  hooks=$cli_home/hooks.json
  dispatcher=$cli_home/fm-firstmate-hook.sh
  regular_owned "$hooks" && regular_owned "$dispatcher" && [ -x "$dispatcher" ] || { printf 'error: install the Firstmate TraeX hook before probing\n' >&2; return 1; }
  validate_hooks_json "$hooks" || { printf 'error: installed hooks.json is malformed\n' >&2; return 1; }
  hooks_sha=$(fm_traex_sha256 "$hooks") || return 1
  dispatcher_sha=$(fm_traex_sha256 "$dispatcher") || return 1
  fm_traex_login_ready "$binary" || { printf 'error: TraeX is not logged in\n' >&2; return 1; }
  "$binary" features list 2>/dev/null | awk '$1 == "hooks" && $2 == "stable" && $3 == "true" { ok=1 } END { exit !ok }' \
    || { printf 'error: TraeX hooks feature is not stable and enabled\n' >&2; return 1; }
  printf '%s|%s|%s|%s\n' "$binary" "$binary_sha" "$hooks_sha" "$dispatcher_sha"
}

register_binding() {  # <role> <task> <worktree> <state> <root> <home> <gen|-> <token-state>
  local role=$1 task=$2 worktree=$3 state=$4 root=$5 home=$6 gen=$7 token_state=$8
  local cli_home registry worktree_real state_real root_real home_real token_state_dir token_state_name
  local token record pointer tmp token_tmp pointer_tmp old_umask exclude token_published=0 pointer_published=0 record_published=0
  case "$role" in worker|primary) ;; *) printf 'error: invalid TraeX binding role\n' >&2; return 1 ;; esac
  case "$task" in ''|*[!A-Za-z0-9._-]*) printf 'error: invalid TraeX binding task id\n' >&2; return 1 ;; esac
  worktree_real=$(real_dir "$worktree") || return 1
  state_real=$(real_dir "$state") || return 1
  root_real=$(real_dir "$root") || return 1
  home_real=$(real_dir "$home") || return 1
  case "$token_state" in /*) ;; *) printf 'error: TraeX token state must be absolute\n' >&2; return 1 ;; esac
  token_state_dir=$(real_dir "$(dirname -- "$token_state")") || return 1
  token_state_name=${token_state##*/}
  if [ "$role" = worker ]; then
    [ "$token_state_dir" = "$state_real" ] && [ "$token_state_name" = "$task.traex-hook-token" ] \
      || { printf 'error: TraeX worker token state must use its owning state directory and task id\n' >&2; return 1; }
    case "$gen" in ''|-|*[!A-Za-z0-9._-]*) printf 'error: invalid TraeX busy generation\n' >&2; return 1 ;; esac
  else
    case "$token_state_name" in
      .traex-primary-hook-token|"$task.traex-hook-token") ;;
      *) printf 'error: invalid TraeX primary token-state name\n' >&2; return 1 ;;
    esac
    gen=-
  fi
  fm_traex_receipt_verify >/dev/null || return 1
  cli_home=$(fm_traex_cli_home) || return 1
  exclude=$(git -C "$worktree_real" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || true)
  if [ -n "$exclude" ]; then
    case "$exclude" in /*) ;; *) printf 'error: cannot resolve an absolute git exclude path for %s\n' "$worktree_real" >&2; return 1 ;; esac
    mkdir -p "$(dirname -- "$exclude")" || return 1
    grep -Fqx '.fm-traex-hook' "$exclude" 2>/dev/null || printf '.fm-traex-hook\n' >> "$exclude" || return 1
  fi
  registry=$cli_home/fm-firstmate-hooks.d
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    [ -d "$registry" ] && [ ! -L "$registry" ] && [ "$(owner_uid "$registry")" = "$(id -u)" ] \
      || { printf 'error: unsafe TraeX registry: %s\n' "$registry" >&2; return 1; }
  else
    mkdir -m 700 "$registry" || return 1
  fi
  chmod 700 "$registry"
  pointer=$worktree_real/.fm-traex-hook
  token=
  if [ -e "$token_state" ] || [ -L "$token_state" ]; then
    regular_owned "$token_state" || { printf 'error: unsafe TraeX token state: %s\n' "$token_state" >&2; return 1; }
    token=$(cat "$token_state" 2>/dev/null || true)
    token_valid "$token" || { printf 'error: malformed TraeX token state: %s\n' "$token_state" >&2; return 1; }
  else
    token=$(token_new) || return 1
  fi
  record=$registry/$token
  if [ -e "$record" ] || [ -L "$record" ]; then
    regular_owned "$record" || { printf 'error: unsafe TraeX registry record: %s\n' "$record" >&2; return 1; }
    [ "$(field "$record" task_id 2>/dev/null)" = "$task" ] || { printf 'error: TraeX token is already bound to another task\n' >&2; return 1; }
  fi
  if [ -e "$pointer" ] || [ -L "$pointer" ]; then
    regular_owned "$pointer" || { printf 'error: unsafe TraeX worktree pointer: %s\n' "$pointer" >&2; return 1; }
    [ "$(cat "$pointer" 2>/dev/null)" = "token=$token" ] || { printf 'error: TraeX worktree pointer conflicts with this task\n' >&2; return 1; }
  fi
  if [ -e "$token_state" ] || [ -L "$token_state" ]; then
    [ "$(field "$record" protocol 2>/dev/null)" = "$FM_TRAEX_ADAPTER_PROTOCOL" ] \
      && [ "$(field "$record" token 2>/dev/null)" = "$token" ] \
      && [ "$(field "$record" role 2>/dev/null)" = "$role" ] \
      && [ "$(field "$record" task_id 2>/dev/null)" = "$task" ] \
      && [ "$(field "$record" busy_gen 2>/dev/null)" = "$gen" ] \
      && [ "$(field "$record" worktree_real 2>/dev/null)" = "$worktree_real" ] \
      && [ "$(field "$record" state_real 2>/dev/null)" = "$state_real" ] \
      && [ "$(field "$record" fm_root_real 2>/dev/null)" = "$root_real" ] \
      && [ "$(field "$record" fm_home_real 2>/dev/null)" = "$home_real" ] \
      && [ "$(field "$record" uid 2>/dev/null)" = "$(id -u)" ] \
      && [ "$(field "$record" adapter_version 2>/dev/null)" = "$FM_TRAEX_SUPPORTED_VERSION" ] \
      && [ "$(field "$record" token_state_real 2>/dev/null)" = "$token_state" ] \
      || { printf 'error: existing TraeX binding does not match the requested registration\n' >&2; return 1; }
    if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
      old_umask=$(umask); umask 077
      pointer_tmp=$(mktemp "$worktree_real/.fm-traex-pointer.XXXXXXXX") || { umask "$old_umask"; return 1; }
      if ! printf 'token=%s\n' "$token" > "$pointer_tmp" || ! chmod 600 "$pointer_tmp"; then
        rm -f "$pointer_tmp"
        umask "$old_umask"
        return 1
      fi
      if ! ln "$pointer_tmp" "$pointer"; then
        if ! regular_owned "$pointer" || [ "$(cat "$pointer" 2>/dev/null)" != "token=$token" ]; then
          rm -f "$pointer_tmp"
          umask "$old_umask"
          printf 'error: cannot atomically restore the TraeX worktree pointer\n' >&2
          return 1
        fi
      fi
      rm -f "$pointer_tmp"
      umask "$old_umask"
    fi
    return 0
  fi
  old_umask=$(umask); umask 077
  tmp=$(mktemp "$registry/.fm-record.XXXXXXXX") || { umask "$old_umask"; return 1; }
  token_tmp=$token_state.tmp.$$
  pointer_tmp=$pointer.tmp.$$
  {
    printf 'protocol=%s\n' "$FM_TRAEX_ADAPTER_PROTOCOL"
    printf 'token=%s\n' "$token"
    printf 'role=%s\n' "$role"
    printf 'task_id=%s\n' "$task"
    printf 'busy_gen=%s\n' "$gen"
    printf 'worktree_real=%s\n' "$worktree_real"
    printf 'state_real=%s\n' "$state_real"
    printf 'fm_root_real=%s\n' "$root_real"
    printf 'fm_home_real=%s\n' "$home_real"
    printf 'uid=%s\n' "$(id -u)"
    printf 'adapter_version=%s\n' "$FM_TRAEX_SUPPORTED_VERSION"
    printf 'token_state_real=%s\n' "$token_state"
  } > "$tmp" || { rm -f "$tmp"; umask "$old_umask"; return 1; }
  if ! chmod 600 "$tmp" \
      || ! printf '%s\n' "$token" > "$token_tmp" \
      || ! chmod 600 "$token_tmp" \
      || ! printf 'token=%s\n' "$token" > "$pointer_tmp" \
      || ! chmod 600 "$pointer_tmp"; then
    rm -f "$tmp" "$token_tmp" "$pointer_tmp"
    umask "$old_umask"
    return 1
  fi
  if [ -e "$token_state" ] || [ -L "$token_state" ] \
      || [ -e "$pointer" ] || [ -L "$pointer" ] \
      || [ -e "$record" ] || [ -L "$record" ]; then
    rm -f "$tmp" "$token_tmp" "$pointer_tmp"
    umask "$old_umask"
    return 1
  fi
  if ln "$token_tmp" "$token_state"; then token_published=1; fi
  if [ "$token_published" -eq 1 ] && ln "$pointer_tmp" "$pointer"; then pointer_published=1; fi
  if [ "$pointer_published" -eq 1 ] && ln "$tmp" "$record"; then record_published=1; fi
  if [ "$record_published" -ne 1 ]; then
    [ "$pointer_published" -eq 0 ] || rm -f "$pointer"
    [ "$token_published" -eq 0 ] || rm -f "$token_state"
    rm -f "$tmp" "$token_tmp" "$pointer_tmp"
    umask "$old_umask"
    return 1
  fi
  rm -f "$tmp" "$token_tmp" "$pointer_tmp"
  umask "$old_umask"
}

require_current_tmux() {
  local pane
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
    || { printf 'error: TraeX primary binding requires the current process to run inside tmux\n' >&2; return 1; }
  command -v tmux >/dev/null 2>&1 \
    || { printf 'error: TraeX primary binding requires tmux\n' >&2; return 1; }
  pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) \
    || { printf 'error: cannot verify the current tmux pane for TraeX primary binding\n' >&2; return 1; }
  [ "$pane" = "$TMUX_PANE" ] \
    || { printf 'error: TraeX primary binding tmux pane identity does not match the current process\n' >&2; return 1; }
}

unregister_binding() {  # <worktree> <token-state>
  local worktree=$1 token_state=$2 worktree_real token registry record pointer record_wt
  [ -e "$token_state" ] || [ -L "$token_state" ] || return 0
  regular_owned "$token_state" || { printf 'error: unsafe TraeX token state: %s\n' "$token_state" >&2; return 1; }
  token=$(cat "$token_state" 2>/dev/null || true)
  token_valid "$token" || { printf 'error: malformed TraeX token state: %s\n' "$token_state" >&2; return 1; }
  registry=$(fm_traex_registry_dir) || return 1
  record=$registry/$token
  regular_owned "$record" || { printf 'error: TraeX registry record is missing or unsafe: %s\n' "$record" >&2; return 1; }
  worktree_real=$(real_dir "$worktree" 2>/dev/null || true)
  record_wt=$(field "$record" worktree_real 2>/dev/null) || return 1
  if [ -n "$worktree_real" ] && [ "$worktree_real" != "$record_wt" ]; then
    printf 'error: TraeX registry worktree does not match teardown target\n' >&2
    return 1
  fi
  pointer=$record_wt/.fm-traex-hook
  if [ -e "$pointer" ] || [ -L "$pointer" ]; then
    regular_owned "$pointer" && [ "$(cat "$pointer" 2>/dev/null)" = "token=$token" ] \
      || { printf 'error: refusing to remove mismatched TraeX pointer: %s\n' "$pointer" >&2; return 1; }
    rm -f "$pointer" || return 1
  fi
  rm -f "$record" "$token_state"
}

probe_hook() {  # <model>
  local model=$1 material binary binary_sha hooks_sha dispatcher_sha cli_home registry lab project state proof nonce token record token_state rc receipt hooks dispatcher nonce_sha tmp
  [ -n "$model" ] || { printf 'error: probe requires --model GPT-5.6-Luna\n' >&2; return 2; }
  material=$(supported_material) || return 1
  IFS='|' read -r binary binary_sha hooks_sha dispatcher_sha <<EOF
$material
EOF
  fm_traex_model_supported "$binary" "$model" || return 1
  cli_home=$(fm_traex_cli_home) || return 1
  registry=$cli_home/fm-firstmate-hooks.d
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    directory_owned "$registry" || { printf 'error: unsafe TraeX registry: %s\n' "$registry" >&2; return 1; }
  else
    mkdir -m 700 "$registry" || return 1
  fi
  chmod 700 "$registry"
  lab=$(mktemp -d /tmp/fm-traex-receipt.XXXXXXXX) || return 1
  project=$lab/project
  state=$lab/state
  mkdir -m 700 "$project" "$state"
  git -C "$project" init -q -b main
  printf '# Firstmate TraeX trust receipt probe\n' > "$project/README.md"
  git -C "$project" -c user.name=fm-probe -c user.email=fm-probe@example.invalid add README.md
  git -C "$project" -c user.name=fm-probe -c user.email=fm-probe@example.invalid commit -q -m init
  proof=$project/.fm-traex-proof
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  token=$(token_new) || return 1
  token_state=$state/probe-token
  record=$registry/$token
  FM_TRAEX_PROBE_RECORD=$record
  FM_TRAEX_PROBE_TOKEN_STATE=$token_state
  FM_TRAEX_PROBE_POINTER=$project/.fm-traex-hook
  trap probe_exit_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  {
    printf 'protocol=%s\n' "$FM_TRAEX_ADAPTER_PROTOCOL"
    printf 'token=%s\n' "$token"
    printf 'role=probe\n'
    printf 'task_id=receipt-probe\n'
    printf 'busy_gen=-\n'
    printf 'worktree_real=%s\n' "$(real_dir "$project")"
    printf 'state_real=%s\n' "$(real_dir "$state")"
    printf 'fm_root_real=%s\n' "$(real_dir "$FM_ROOT")"
    printf 'fm_home_real=%s\n' "$(real_dir "$FM_ROOT")"
    printf 'uid=%s\n' "$(id -u)"
    printf 'adapter_version=%s\n' "$FM_TRAEX_SUPPORTED_VERSION"
    printf 'token_state_real=%s\n' "$token_state"
    printf 'proof_real=%s\n' "$proof"
    printf 'nonce=%s\n' "$nonce"
    printf 'binary_path=%s\n' "$binary"
    printf 'binary_sha256=%s\n' "$binary_sha"
    printf 'hooks_sha256=%s\n' "$hooks_sha"
    printf 'dispatcher_sha256=%s\n' "$dispatcher_sha"
  } > "$record"
  chmod 600 "$record"
  printf '%s\n' "$token" > "$token_state"
  printf 'token=%s\n' "$token" > "$project/.fm-traex-hook"
  chmod 600 "$token_state" "$project/.fm-traex-hook"
  printf 'probe: TraeX will run without hook-trust bypass; if native review appears, review and trust the installed Firstmate entries, then rerun this command.\n' >&2
  if (CDPATH='' cd "$project" && TRAECLI_HOME="$cli_home" "$binary" exec -y --disable plugins --disable plugin_hooks -m "$model" "Reply exactly FIRSTMATE_TRAEX_PROBE_$nonce and do not use tools.") > "$lab/traex.out" 2> "$lab/traex.err"; then
    rc=0
  else
    rc=$?
  fi
  if ! probe_binding_cleanup; then
    printf 'error: TraeX receipt probe binding cleanup failed; evidence preserved at %s\n' "$lab" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'error: TraeX receipt probe exited %s; evidence preserved at %s\n' "$rc" "$lab" >&2
    return 1
  fi
  for event in SessionStart UserPromptSubmit Stop SessionEnd; do
    if ! grep -Fq "nonce=$nonce event=$event " "$proof" 2>/dev/null; then
      printf 'error: trusted TraeX hook did not deliver %s; evidence preserved at %s (native trust may still be pending)\n' "$event" "$lab" >&2
      return 1
    fi
  done
  receipt=$(fm_traex_receipt_path) || return 1
  hooks=$(fm_traex_hooks_path) || return 1
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  [ "$hooks_sha" = "$(fm_traex_sha256 "$hooks")" ] && [ "$dispatcher_sha" = "$(fm_traex_sha256 "$dispatcher")" ] \
    || { printf 'error: TraeX hook material changed during probe; evidence preserved at %s\n' "$lab" >&2; return 1; }
  if command -v sha256sum >/dev/null 2>&1; then
    nonce_sha=$(printf '%s' "$nonce" | sha256sum | awk '{print $1}') || return 1
  elif command -v shasum >/dev/null 2>&1; then
    nonce_sha=$(printf '%s' "$nonce" | shasum -a 256 | awk '{print $1}') || return 1
  else
    return 1
  fi
  tmp=$receipt.tmp.$$
  if ! jq -n --arg protocol "$FM_TRAEX_ADAPTER_PROTOCOL" --arg binary_path "$binary" \
    --arg binary_sha256 "$binary_sha" --arg version "$FM_TRAEX_SUPPORTED_VERSION" \
    --arg hooks_sha256 "$hooks_sha" --arg dispatcher_sha256 "$dispatcher_sha" \
    --arg probe_nonce_sha256 "$nonce_sha" --argjson completed_at "$(date +%s)" '
      {protocol:$protocol,binary_path:$binary_path,binary_sha256:$binary_sha256,version:$version,
       hooks_sha256:$hooks_sha256,dispatcher_sha256:$dispatcher_sha256,
       probe_nonce_sha256:$probe_nonce_sha256,
       events:["SessionStart","UserPromptSubmit","Stop","SessionEnd"],completed_at:$completed_at}
    ' > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$receipt"; then
    rm -f "$tmp"
    return 1
  fi
  rm -rf "$lab"
  trap - EXIT INT TERM
  printf 'verified: native TraeX trust delivered all required lifecycle events; receipt=%s\n' "$receipt"
}

remove_hook() {
  local cli_home hooks dispatcher receipt registry command work candidate mode
  cli_home=$(fm_traex_cli_home) || return 1
  hooks=$cli_home/hooks.json
  dispatcher=$cli_home/fm-firstmate-hook.sh
  receipt=$cli_home/fm-firstmate-receipt.json
  registry=$cli_home/fm-firstmate-hooks.d
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    directory_owned "$registry" || {
      printf 'fm-traex-hook-install: refused: registry path is unsafe: %s\n' "$registry" >&2
      return 1
    }
  fi
  if [ -d "$registry" ] && [ -n "$(find "$registry" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    printf 'fm-traex-hook-install: refused: active TraeX registry bindings remain in %s\n' "$registry" >&2
    return 1
  fi
  regular_owned "$hooks" || { printf 'fm-traex-hook-install: refused: hooks.json is missing or unsafe.\n' >&2; return 1; }
  validate_hooks_json "$hooks" || return 1
  mode=$(file_mode "$hooks" 2>/dev/null || printf '600')
  command=$(managed_command) || return 1
  work=$(mktemp -d "$cli_home/.fm-traex-remove.XXXXXXXX") || return 1
  candidate=$work/hooks.after
  jq --arg command "$command" '
    reduce ["SessionStart","UserPromptSubmit","Stop","SessionEnd"][] as $event
        (. ; if .hooks[$event] then
          .hooks[$event] |= (map(.hooks |= map(select((type != "object") or (.command? != $command))))
            | map(select((.hooks | length) > 0)))
        else . end)
  ' "$hooks" > "$candidate" || { rm -rf "$work"; return 1; }
  if [ -e "$dispatcher" ] || [ -L "$dispatcher" ]; then
    if ! regular_owned "$dispatcher" \
       || ! head -n 2 "$dispatcher" | grep -Fq 'Firstmate TraeX hook dispatcher.'; then
      printf 'fm-traex-hook-install: refused: dispatcher ownership/content mismatch.\n' >&2
      rm -rf "$work"
      return 1
    fi
  fi
  atomic_write "$hooks" "$candidate" "$mode" || { rm -rf "$work"; return 1; }
  rm -f "$dispatcher" "$receipt"
  rmdir "$registry" 2>/dev/null || true
  rm -rf "$work"
  printf 'removed: exact Firstmate TraeX hook entries and owned files; user hooks preserved\n'
}

action=${1:-}
case "$action" in
  install)
    [ "$#" -eq 1 ] || usage
    install_hook
    ;;
  verify)
    [ "$#" -eq 1 ] || usage
    fm_traex_receipt_verify
    ;;
  probe)
    [ "$#" -eq 3 ] && [ "$2" = --model ] || usage
    probe_hook "$3"
    ;;
  register)
    [ "$#" -eq 9 ] || usage
    register_binding "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
    ;;
  unregister)
    [ "$#" -eq 3 ] || usage
    unregister_binding "$2" "$3"
    ;;
  bind-primary|unbind-primary)
    [ "$#" -le 3 ] || usage
    root=${2:-$FM_ROOT}
    home=${3:-${FM_HOME:-$root}}
    root=$(real_dir "$root") || exit 1
    home=$(real_dir "$home") || exit 1
    state=$home/state
    config=$home/config
    state=$(real_dir "$state") || { printf 'error: primary state directory is missing: %s\n' "$state" >&2; exit 1; }
    if [ "$action" = bind-primary ]; then
      require_current_tmux || exit 1
      fm_traex_preflight "$config" primary >/dev/null || exit 1
      register_binding primary primary "$root" "$state" "$root" "$home" - "$state/.traex-primary-hook-token"
      printf 'bound: TraeX primary hook for %s\n' "$home"
    else
      unregister_binding "$root" "$state/.traex-primary-hook-token"
      printf 'unbound: TraeX primary hook for %s\n' "$home"
    fi
    ;;
  remove)
    [ "$#" -eq 1 ] || usage
    remove_hook
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac
