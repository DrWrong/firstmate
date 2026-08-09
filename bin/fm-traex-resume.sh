#!/usr/bin/env bash
# Resume one exited TraeX task in its recorded local tmux shell.
# Usage: FM_HOME=<owning-home> fm-traex-resume.sh <task-id>
#
# The command refuses a live/ambiguous/missing endpoint, a non-TraeX task, a
# non-tmux backend, a stale trust receipt, or absent SessionStart identity. It
# never creates a replacement endpoint: missing-window recovery must preserve
# the worktree and be reconciled by Firstmate before a new process is launched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 1 ] || { printf 'usage: FM_HOME=<owning-home> %s <task-id>\n' "${0##*/}" >&2; exit 2; }
[ -n "${FM_HOME:-}" ] || { printf 'error: FM_HOME is required for TraeX resume\n' >&2; exit 1; }
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) printf 'error: invalid task id\n' >&2; exit 2 ;; esac
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
META=$STATE/$ID.meta
[ -f "$META" ] && [ ! -L "$META" ] || { printf 'error: no safe metadata for task %s\n' "$ID" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-traex-lib.sh
. "$SCRIPT_DIR/fm-traex-lib.sh"

meta_value() { fm_meta_get "$META" "$1"; }
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
model_flag() {
  [ -n "$1" ] && [ "$1" != default ] || return 0
  printf -- '--model %s ' "$(shell_quote "$1")"
}
effort_flag() {
  [ -n "$1" ] && [ "$1" != default ] || return 0
  printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$1\"")"
}
session_field() {
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

[ "$(meta_value harness)" = traex ] || { printf 'error: task %s is not a TraeX task\n' "$ID" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = tmux ] || { printf 'error: TraeX resume is supported only on tmux, not %s\n' "$BACKEND" >&2; exit 1; }
TARGET=$(fm_backend_target_of_meta "$META")
case "$(fm_backend_agent_state tmux "$TARGET")" in
  dead) ;;
  alive) printf 'error: TraeX agent is already live for %s\n' "$ID" >&2; exit 1 ;;
  missing) printf 'error: TraeX tmux endpoint is missing for %s; preserving metadata and worktree for recovery\n' "$ID" >&2; exit 1 ;;
  *) printf 'error: TraeX endpoint state is ambiguous for %s; refusing resume\n' "$ID" >&2; exit 1 ;;
esac
KIND=$(meta_value kind)
MODEL=$(meta_value model)
EFFORT=$(meta_value effort)
TRAE_OS_HOME=$(meta_value traex_os_home) || { printf 'error: TraeX task %s has no recorded OS home\n' "$ID" >&2; exit 1; }
TRAE_RUNTIME_HOME=$(meta_value traex_home) || { printf 'error: TraeX task %s has no recorded runtime home\n' "$ID" >&2; exit 1; }
TRAE_CLI_HOME=$(meta_value traex_cli_home) || { printf 'error: TraeX task %s has no recorded CLI home\n' "$ID" >&2; exit 1; }
for recorded_home in "$TRAE_OS_HOME" "$TRAE_RUNTIME_HOME" "$TRAE_CLI_HOME"; do
  case "$recorded_home" in /*) ;; *) printf 'error: TraeX task %s has an unsafe recorded home\n' "$ID" >&2; exit 1 ;; esac
done
HOME=$TRAE_OS_HOME
TRAE_HOME=$TRAE_RUNTIME_HOME
TRAECLI_HOME=$TRAE_CLI_HOME
export HOME TRAE_HOME TRAECLI_HOME
if [ "$KIND" = secondmate ]; then
  ROLE=secondmate
  TASK_HOME=$(meta_value home)
  SESSION_FILE=$TASK_HOME/state/.traex-primary-session
else
  ROLE=worker
  TASK_HOME=
  SESSION_FILE=$STATE/$ID.traex-session
fi
BINARY=$(fm_traex_preflight "$CONFIG" "$ROLE" "$MODEL" "$EFFORT") || exit 1
[ -f "$SESSION_FILE" ] && [ ! -L "$SESSION_FILE" ] || { printf 'error: no safe TraeX session identity for %s\n' "$ID" >&2; exit 1; }
SESSION_ID=$(session_field "$SESSION_FILE" session_id) || { printf 'error: malformed TraeX session identity for %s\n' "$ID" >&2; exit 1; }
case "$SESSION_ID" in ''|*[!A-Za-z0-9._:-]*) printf 'error: unsafe TraeX session id for %s\n' "$ID" >&2; exit 1 ;; esac
SESSION_IDENTITY_BEFORE=$(fm_traex_file_identity "$SESSION_FILE") \
  || { printf 'error: cannot identify the existing TraeX session record for %s\n' "$ID" >&2; exit 1; }
CONFIRM_TRIES=${FM_TRAEX_RESUME_CONFIRM_TRIES:-45}
case "$CONFIRM_TRIES" in ''|*[!0-9]*|0) printf 'error: invalid TraeX resume confirmation attempts\n' >&2; exit 1 ;; esac

COMMAND="env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS HOME=$(shell_quote "$TRAE_OS_HOME") TRAE_HOME=$(shell_quote "$TRAE_RUNTIME_HOME") TRAECLI_HOME=$(shell_quote "$TRAE_CLI_HOME") FM_TRAEX_HARNESS=traex $(shell_quote "$BINARY") resume -y --disable plugins --disable plugin_hooks $(model_flag "$MODEL")$(effort_flag "$EFFORT")$(shell_quote "$SESSION_ID")"
if [ "$KIND" = secondmate ]; then
  COMMAND="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$(shell_quote "$TASK_HOME") FM_SUPERVISION_MODEL=persistent $COMMAND"
fi
fm_backend_source tmux
fm_backend_tmux_send_text_line "$TARGET" "$COMMAND" || { printf 'error: TraeX resume command could not be sent to %s\n' "$TARGET" >&2; exit 1; }

i=0
while [ "$i" -lt "$CONFIRM_TRIES" ]; do
  if [ -f "$SESSION_FILE" ] \
     && [ "$(fm_traex_file_identity "$SESSION_FILE" 2>/dev/null || true)" != "$SESSION_IDENTITY_BEFORE" ] \
     && [ "$(session_field "$SESSION_FILE" source 2>/dev/null || true)" = resume ] \
     && [ "$(session_field "$SESSION_FILE" session_id 2>/dev/null || true)" = "$SESSION_ID" ] \
     && [ "$(fm_backend_agent_state tmux "$TARGET")" = alive ]; then
    printf 'resumed %s session=%s window=%s\n' "$ID" "$SESSION_ID" "$TARGET"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
printf 'error: TraeX resume was not confirmed by SessionStart(source=resume); inspect %s and preserve the task\n' "$TARGET" >&2
exit 1
