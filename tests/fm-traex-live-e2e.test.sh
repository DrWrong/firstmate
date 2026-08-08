#!/usr/bin/env bash
# Opt-in drift guard for Firstmate's trusted TraeX lifecycle adapter.
#
# This test spends real model turns. It creates unique disposable HOME,
# FM_HOME, TRAE_HOME, and TRAECLI_HOME directories plus a private tmux server.
# It never addresses the ambient tmux socket, never uses the current Firstmate
# home, never edits TraeX's trust store, and never passes a hook-trust bypass.
# Native trust is accepted only after the private pane displays the exact
# review choice. Failed evidence is preserved; successful evidence is removed.
set -u

if [ "${FM_TRAEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TRAEX_LIVE_E2E=1 to run the real TraeX adapter regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
TRAE_CANDIDATE=$(command -v traex 2>/dev/null || true)
MODEL=${FM_TRAEX_LIVE_MODEL:-GPT-5.6-Luna}
AUTH_SOURCE=${FM_TRAEX_LIVE_AUTH_SOURCE:-${TRAECLI_HOME:-$HOME/.trae/cli}/auth.json}
LAB=
SOCKET="fm-traex-live-$$"
SESSION="traex-live-$$"
SUCCEEDED=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

exit_private_window() {  # <target> <window-name>
  local target=$1 window_name=$2 attempt=0
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l '/exit' || return 1
  while [ "$attempt" -lt 3 ]; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
    sleep 2
    if ! "$REAL_TMUX" -L "$SOCKET" list-windows -t "$SESSION" -F '#W' 2>/dev/null \
        | grep -Fxq "$window_name"; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$LAB" ]; then
    if [ "$SUCCEEDED" -eq 1 ]; then
      rm -rf -- "$LAB"
    else
      printf '# failed TraeX evidence preserved at %s\n' "$LAB" >&2
    fi
  fi
}
trap cleanup EXIT INT TERM

[ -x "$REAL_TMUX" ] || fail "tmux is required"
[ -x "$TRAE_CANDIDATE" ] || fail "a real traex executable is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$AUTH_SOURCE" ] && [ ! -L "$AUTH_SOURCE" ] || fail "set FM_TRAEX_LIVE_AUTH_SOURCE to an owned regular TraeX auth.json"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-traex-live.XXXXXXXX") || fail "could not create isolated lab"
HOME_DIR=$LAB/home
TRAE_HOME_DIR=$LAB/trae
CLI_HOME=$LAB/cli
FM_HOME_DIR=$LAB/fm-home
PROJECT=$LAB/project
STATE=$FM_HOME_DIR/state
CONFIG=$FM_HOME_DIR/config
mkdir -m 700 "$HOME_DIR" "$TRAE_HOME_DIR" "$CLI_HOME" "$FM_HOME_DIR" "$STATE" \
  "$CONFIG" "$FM_HOME_DIR/data" "$FM_HOME_DIR/projects" "$PROJECT" || fail "could not create isolated homes"

ACTIVE_FM_HOME=${FM_HOME:-$ROOT}
ACTIVE_FM_HOME=$(cd "$ACTIVE_FM_HOME" 2>/dev/null && pwd -P) || fail "could not resolve the active Firstmate home"
LAB_REAL=$(cd "$LAB" && pwd -P) || fail "could not resolve the isolated lab"
[ "$ACTIVE_FM_HOME" != "$LAB_REAL" ] || fail "isolated lab resolved to the active Firstmate home"
case "$LAB_REAL" in
  "$ACTIVE_FM_HOME"/*) fail "isolated lab is nested under the active Firstmate home" ;;
esac

cp "$AUTH_SOURCE" "$CLI_HOME/auth.json" || fail "could not copy TraeX auth into the isolated CLI home"
chmod 600 "$CLI_HOME/auth.json"
git -C "$PROJECT" init -q -b main || fail "could not initialize isolated project"
git -C "$PROJECT" config user.name fm-traex-live
git -C "$PROJECT" config user.email fm-traex-live@example.invalid
printf '# isolated TraeX live adapter lab\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m init || fail "could not commit isolated project"

export HOME=$HOME_DIR
export TRAE_HOME=$TRAE_HOME_DIR
export TRAECLI_HOME=$CLI_HOME
export FM_HOME=$FM_HOME_DIR
unset TMUX TMUX_PANE NO_MISTAKES_GATE

# shellcheck source=bin/fm-traex-lib.sh
. "$ROOT/bin/fm-traex-lib.sh"
BINARY=$(fm_traex_binary) || fail "TraeX binary did not resolve through the adapter"
[ "$BINARY" = "$(fm_traex_real_file "$TRAE_CANDIDATE")" ] || fail "adapter resolved a different TraeX binary"
[ "$("$BINARY" --version 2>/dev/null)" = "$FM_TRAEX_SUPPORTED_VERSION" ] || fail "installed TraeX version is outside the verified gate"
[ "$(fm_traex_sha256 "$BINARY")" = "$FM_TRAEX_SUPPORTED_SHA256" ] || fail "installed TraeX hash is outside the verified gate"

"$ROOT/bin/fm-traex-hook-install.sh" install > "$LAB/install.out" 2> "$LAB/install.err" \
  || fail "Firstmate hook installation failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$PROJECT" \
  || fail "could not create the private tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n trust -c "$PROJECT" -- \
  env HOME="$HOME" TRAE_HOME="$TRAE_HOME" TRAECLI_HOME="$TRAECLI_HOME" FM_HOME="$FM_HOME" \
    "$BINARY" -y --disable plugins --disable plugin_hooks \
  || fail "could not open the isolated native hook review"

TRUST_TARGET=$SESSION:trust
TRUST_CAPTURE=$LAB/trust-review.txt
DIRECTORY_TRUST_ACCEPTED=0
i=0
while [ "$i" -lt 90 ]; do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TRUST_TARGET" -S -120 > "$TRUST_CAPTURE" 2>/dev/null || true
  if grep -Fq 'Do you trust the contents of this directory?' "$TRUST_CAPTURE"; then
    cp "$TRUST_CAPTURE" "$LAB/directory-trust.txt"
    if [ "$DIRECTORY_TRUST_ACCEPTED" -eq 0 ]; then
      grep -Eq '❯[[:space:]]+1\. Yes, continue' "$TRUST_CAPTURE" \
        || fail "native directory-trust selection moved; refusing to guess"
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TRUST_TARGET" Enter
      DIRECTORY_TRUST_ACCEPTED=1
      sleep 1
    fi
  elif grep -Fq 'Hooks need review' "$TRUST_CAPTURE"; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
grep -Fq 'Hooks need review' "$TRUST_CAPTURE" || fail "TraeX did not discover the isolated hooks for native review"
grep -Fq 'Trust all and continue' "$TRUST_CAPTURE" || fail "TraeX native review did not offer the expected explicit trust choice"
grep -Eq '❯[[:space:]]+2\. Trust all and continue' "$TRUST_CAPTURE" \
  || fail "native review selection moved; refusing to guess or bypass hook trust"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TRUST_TARGET" Enter

i=0
while [ "$i" -lt 90 ]; do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TRUST_TARGET" -S -160 > "$LAB/trust-accepted.txt" 2>/dev/null || true
  grep -Fq 'TRAE CLI Next' "$LAB/trust-accepted.txt" && break
  sleep 1
  i=$((i + 1))
done
grep -Fq 'TRAE CLI Next' "$LAB/trust-accepted.txt" || fail "TraeX did not continue after native hook trust"
exit_private_window "$TRUST_TARGET" trust || fail "trusted TraeX review window did not exit cleanly"
pass "TraeX discovered the hook and required explicit native trust"

"$ROOT/bin/fm-traex-hook-install.sh" probe --model "$MODEL" > "$LAB/probe.out" 2> "$LAB/probe.err" \
  || fail "trusted real-binary lifecycle receipt probe failed"
"$ROOT/bin/fm-traex-hook-install.sh" verify > "$LAB/verify.out" 2> "$LAB/verify.err" \
  || fail "fresh lifecycle receipt did not verify"
pass "real TraeX delivered the four required trusted lifecycle callbacks"

printf 'worker=on\nprimary=off\nsecondmate=off\n' > "$CONFIG/traex-adapter"
"$ROOT/bin/fm-traex-preflight.sh" "$CONFIG" worker "$MODEL" low > "$LAB/preflight.out" 2> "$LAB/preflight.err" \
  || fail "real TraeX worker preflight did not open after the receipt"

GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) || fail "could not arm isolated semantic busy state"
cat > "$STATE/live.meta" <<EOF
window=$SESSION:worker
worktree=$PROJECT
project=traex-live
harness=traex
model=$MODEL
effort=low
kind=crew
busy_gen=$GEN
EOF
fm_traex_snapshot_write "$STATE" live || fail "could not snapshot the real receipt"
"$ROOT/bin/fm-traex-hook-install.sh" register worker live "$PROJECT" "$STATE" "$ROOT" "$FM_HOME_DIR" "$GEN" "$STATE/live.traex-hook-token" \
  || fail "could not register the isolated worker binding"

LIVE_NONCE=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
if (CDPATH='' cd "$PROJECT" && FM_TRAEX_HARNESS=traex "$BINARY" exec -y \
    --disable plugins --disable plugin_hooks -m "$MODEL" \
    -c 'model_reasoning_effort="low"' \
    "Reply exactly FIRSTMATE_TRAEX_LIVE_$LIVE_NONCE and do not use tools.") \
    > "$LAB/worker.out" 2> "$LAB/worker.err"; then
  :
else
  fail "real bound TraeX worker turn failed"
fi
grep -Fq "FIRSTMATE_TRAEX_LIVE_$LIVE_NONCE" "$LAB/worker.out" \
  || fail "real bound TraeX worker did not complete its model turn"
grep -Eq '^v1 .* state=idle source=traex-hook event=session-end ' "$STATE/live.busy-state" \
  || fail "real worker lifecycle did not settle semantic state through SessionEnd"
grep -Fq ' event=Stop ' "$STATE/live.turn-ended" \
  || fail "real worker Stop did not append a durable completion"
grep -Fq ' event=SessionEnd ' "$STATE/live.turn-ended" \
  || fail "real worker SessionEnd did not append a durable completion"
pass "real bound worker produced semantic busy/idle and durable turn-end delivery"

SESSION_ID=$(sed -n 's/^session_id=//p' "$STATE/live.traex-session")
case "$SESSION_ID" in ''|*[!A-Za-z0-9._:-]*) fail "real worker did not persist a safe session id" ;; esac
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n resume -c "$PROJECT" -- \
  env HOME="$HOME" TRAE_HOME="$TRAE_HOME" TRAECLI_HOME="$TRAECLI_HOME" FM_HOME="$FM_HOME" \
    FM_TRAEX_HARNESS=traex "$BINARY" resume -y --disable plugins --disable plugin_hooks \
    -m "$MODEL" -c 'model_reasoning_effort="low"' "$SESSION_ID" \
    "Reply exactly FIRSTMATE_TRAEX_RESUMED_$LIVE_NONCE and do not use tools." \
  || fail "could not launch the exact-session resume in private tmux"

RESUME_TARGET=$SESSION:resume
i=0
while [ "$i" -lt 150 ]; do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$RESUME_TARGET" -S -240 > "$LAB/resume.txt" 2>/dev/null || true
  grep -Fq "FIRSTMATE_TRAEX_RESUMED_$LIVE_NONCE" "$LAB/resume.txt" \
    && grep -Fq 'source=resume' "$STATE/live.traex-session" && break
  sleep 1
  i=$((i + 1))
done
grep -Fq "FIRSTMATE_TRAEX_RESUMED_$LIVE_NONCE" "$LAB/resume.txt" || fail "real TraeX resume did not complete"
grep -Fq 'source=resume' "$STATE/live.traex-session" || fail "resume was not confirmed by native SessionStart source"
exit_private_window "$RESUME_TARGET" resume || fail "resumed TraeX window did not exit cleanly"
pass "real TraeX resumed the exact recorded session with native confirmation"

"$ROOT/bin/fm-traex-hook-install.sh" unregister "$PROJECT" "$STATE/live.traex-hook-token" \
  || fail "isolated worker binding did not unregister"
"$ROOT/bin/fm-traex-hook-install.sh" remove > "$LAB/remove.out" 2> "$LAB/remove.err" \
  || fail "exact Firstmate hook removal failed"

SUCCEEDED=1
pass "TraeX live adapter regression passed in disposable homes and a private tmux server"
