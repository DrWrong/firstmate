#!/usr/bin/env bash
# Opt-in real-tmux matrix for TraeX primary client/pane identity.
set -u

if [ "${FM_TRAEX_PRIMARY_TMUX_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_TRAEX_PRIMARY_TMUX_LIVE_E2E=1 to run the real tmux client/pane matrix'
  exit 0
fi

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
REAL_SCRIPT=$(command -v script 2>/dev/null || true)
[ -x "$REAL_TMUX" ] && [ -x "$REAL_SCRIPT" ] || { echo 'skip: tmux or script is unavailable'; exit 0; }

LAB=$(fm_test_tmproot fm-traex-primary-tmux-live)
SOCKET_A=fm-traex-tmux-a-$$
SOCKET_B=fm-traex-tmux-b-$$
SESSION_A=fm-traex-tmux-a-$$
SESSION_B=fm-traex-tmux-b-$$
PROOF_LIB=$REPO_ROOT/bin/fm-traex-primary-proof-lib.sh
CLIENT_PIDS=()
RUN_SEQ=0

cleanup_live() {
  local pid
  "$REAL_TMUX" -L "$SOCKET_A" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET_B" kill-server >/dev/null 2>&1 || true
  for pid in "${CLIENT_PIDS[@]:-}"; do
    wait "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_live EXIT INT TERM

start_client() { # <socket> <session> <typescript>
  local socket=$1 session=$2 typescript=$3 command
  command=$(printf '%q -L %q attach-session -t %q' "$REAL_TMUX" "$socket" "$session")
  "$REAL_SCRIPT" -q -c "$command" "$typescript" >/dev/null 2>&1 &
  CLIENT_PIDS+=("$!")
}

snapshot() { # <socket> <pane>
  local socket=$1 pane=$2 stem out err rc command status i=0
  RUN_SEQ=$((RUN_SEQ + 1))
  stem=$LAB/snapshot.$RUN_SEQ
  out=$stem.out
  err=$stem.err
  rc=$stem.rc
  rm -f "$out" "$err" "$rc"
  # shellcheck disable=SC2016 # positional expansion belongs to the pane-side bash -c
  printf -v command \
    'bash -c %q _ %q %q > %q 2> %q; printf "%%s\\n" "$?" > %q' \
    '. "$1"; fm_traex_proof_tmux_snapshot "$2" attached match-env' \
    "$PROOF_LIB" "$pane" "$out" "$err" "$rc"
  "$REAL_TMUX" -L "$socket" send-keys -t "$pane" -l "$command" || return 1
  "$REAL_TMUX" -L "$socket" send-keys -t "$pane" Enter || return 1
  while [ "$i" -lt 50 ] && [ ! -s "$rc" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$rc" ] || return 1
  status=$(cat "$rc")
  cat "$out" 2>/dev/null || true
  [ "$status" = 0 ]
}

wait_snapshot() { # <socket> <pane>
  local socket=$1 pane=$2 i=0
  while [ "$i" -lt 100 ]; do
    snapshot "$socket" "$pane" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

expect_snapshot_refusal() { # <description> <socket> <pane>
  local description=$1 socket=$2 pane=$3 status=0
  snapshot "$socket" "$pane" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "$description unexpectedly resolved an attached exact client"
}

"$REAL_TMUX" -L "$SOCKET_A" new-session -d -s "$SESSION_A" -n primary -- bash --noprofile --norc -i \
  || fail 'could not create private tmux server A'
"$REAL_TMUX" -L "$SOCKET_A" split-window -d -t "$SESSION_A:primary" -- bash --noprofile --norc -i \
  || fail 'could not create the mismatched pane on server A'
PANES_A=$("$REAL_TMUX" -L "$SOCKET_A" list-panes -t "$SESSION_A:primary" -F '#{pane_id}')
[ "$(printf '%s\n' "$PANES_A" | grep -c .)" -eq 2 ] || fail 'server A did not create two panes'
PANE_A0=$(printf '%s\n' "$PANES_A" | sed -n '1p')
PANE_A1=$(printf '%s\n' "$PANES_A" | sed -n '2p')
"$REAL_TMUX" -L "$SOCKET_A" select-pane -t "$PANE_A0"
start_client "$SOCKET_A" "$SESSION_A" "$LAB/attached-a.typescript"
wait_snapshot "$SOCKET_A" "$PANE_A0" >/dev/null || fail 'matching active pane did not resolve'
SNAPSHOT_A0=$(snapshot "$SOCKET_A" "$PANE_A0") || fail 'matching snapshot A0 disappeared'
expect_snapshot_refusal 'mismatched inactive pane' "$SOCKET_A" "$PANE_A1"

"$REAL_TMUX" -L "$SOCKET_A" select-pane -t "$PANE_A1" || fail 'could not select the second pane'
wait_snapshot "$SOCKET_A" "$PANE_A1" >/dev/null || fail 'client identity did not follow select-pane'
expect_snapshot_refusal 'previous pane after select-pane' "$SOCKET_A" "$PANE_A0"

"$REAL_TMUX" -L "$SOCKET_B" new-session -d -s "$SESSION_B" -n primary -- bash --noprofile --norc -i \
  || fail 'could not create private tmux server B'
PANE_B0=$("$REAL_TMUX" -L "$SOCKET_B" display-message -p -t "$SESSION_B:primary" '#{pane_id}') \
  || fail 'could not resolve server B pane'
start_client "$SOCKET_B" "$SESSION_B" "$LAB/attached-b.typescript"
wait_snapshot "$SOCKET_B" "$PANE_B0" >/dev/null || fail 'server B matching pane did not resolve'
SNAPSHOT_B0=$(snapshot "$SOCKET_B" "$PANE_B0") || fail 'matching snapshot B0 disappeared'
[ "$(printf '%s\n' "$SNAPSHOT_A0" | sed -n '3p')" = "$(printf '%s\n' "$SNAPSHOT_B0" | sed -n '3p')" ] \
  || fail 'private servers did not create the intended same-shaped session id'
[ "$(printf '%s\n' "$SNAPSHOT_A0" | sed -n '4p')" = "$(printf '%s\n' "$SNAPSHOT_B0" | sed -n '4p')" ] \
  || fail 'private servers did not create the intended same-shaped pane id'
[ "$(printf '%s\n' "$SNAPSHOT_A0" | sed -n '1,2p')" != "$(printf '%s\n' "$SNAPSHOT_B0" | sed -n '1,2p')" ] \
  || fail 'wrong socket/server identity was indistinguishable'

"$REAL_TMUX" -L "$SOCKET_A" detach-client -s "$SESSION_A" || fail 'could not detach server A client'
i=0
while [ "$i" -lt 100 ] && [ -n "$("$REAL_TMUX" -L "$SOCKET_A" list-clients 2>/dev/null || true)" ]; do
  sleep 0.1
  i=$((i + 1))
done
expect_snapshot_refusal 'detached server A' "$SOCKET_A" "$PANE_A1"

pass 'real tmux accepts only the attached exact client pane and rejects inactive, previously active, detached, and same-shaped wrong-server identities'
