#!/usr/bin/env bash
# Portable public-interface regressions for TraeX primary ownership proof.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091 # test helper is resolved relative to this file at runtime
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

TMP_ROOT=$(fm_test_tmproot fm-traex-primary-proof)
SUPPORTED_SHA=e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581
REAL_SHA256SUM=$(command -v sha256sum 2>/dev/null || true)
REAL_PS=$(command -v ps 2>/dev/null || true)
[ -n "$REAL_SHA256SUM" ] && [ -n "$REAL_PS" ] || { echo 'skip: sha256sum or ps not found'; exit 0; }

make_fixture() { # <name>; prints root|cli|fakebin
  local name=$1 case_dir root cli fakebin hooks_sha dispatcher_sha binary
  case_dir=$TMP_ROOT/$name
  root=$case_dir/firstmate
  cli=$case_dir/cli
  fakebin=$case_dir/fakebin
  mkdir -p "$root/bin" "$root/state" "$root/config" "$root/data" "$root/projects" "$cli" "$fakebin"
  git -C "$root" init -q
  printf '%s\n' 'worker=off' 'primary=on' 'secondmate=off' > "$root/config/traex-adapter"
  cp "$REPO_ROOT/bin/fm-traex-hook-install.sh" "$REPO_ROOT/bin/fm-traex-hook-dispatch.sh" \
    "$REPO_ROOT/bin/fm-traex-lib.sh" "$REPO_ROOT/bin/fm-traex-primary-proof-lib.sh" \
    "$REPO_ROOT/bin/fm-session-lock-lib.sh" "$REPO_ROOT/bin/fm-wake-lib.sh" \
    "$REPO_ROOT/bin/fm-lock.sh" "$REPO_ROOT/bin/fm-harness.sh" \
    "$root/bin/"
  mv "$root/bin/fm-lock.sh" "$root/bin/fm-lock-real.sh"
  cat > "$root/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NATIVE_PID:-}" ]; then
  printf '%s\n' "$FM_TEST_NATIVE_PID" > "$FM_HOME/state/.lock"
  printf '%s\n' "$FM_TEST_NATIVE_PID" >> "$FM_HOME/state/lock-convergence.calls"
  printf 'lock acquired: harness pid %s\n' "$FM_TEST_NATIVE_PID"
  exit 0
fi
exec "$(dirname -- "$0")/fm-lock-real.sh" "$@"
SH
  cat > "$root/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --source startup '*|*' --source clear '*)
    owner=$(sed -n 's/^owner_pid=//p' "$FM_HOME/state/.traex-primary-lineage")
    case "$owner" in ''|*[!0-9]*) exit 1 ;; esac
    printf '%s\n' "$owner" > "$FM_HOME/state/.lock"
    ;;
esac
printf '%s\n' "$*" >> "$FM_HOME/state/sessionstart.sources"
SH
  cat > "$root/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "$root/bin/fm-lock.sh" "$root/bin/fm-lock-real.sh" \
    "$root/bin/fm-sessionstart-run.sh" "$root/bin/fm-turnend-guard.sh"

  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1##*/}" = traex ]; then
  printf '%s  %s\n' "$FM_TEST_TRAEX_SHA" "$1"
  exit 0
fi
exec "$FM_TEST_REAL_SHA256SUM" "$@"
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "${FM_TEST_SANDBOX_PS:-0}" = 1 ]; then
  case "$field" in
    comm=) printf '%s\n' bash ;;
    args=) printf '%s\n' 'bash sandbox-tool' ;;
    ppid=) printf '%s\n' 1 ;;
    *) exec "$FM_TEST_REAL_PS" "${args[@]}" ;;
  esac
  exit 0
fi
if [ -n "${FM_TEST_LIVE_PID:-}" ] && [ "$pid" = "$FM_TEST_LIVE_PID" ]; then
  case "$field" in
    comm=) printf '%s\n' traex ;;
    args=) printf '%s\n' traex ;;
    ppid=) printf '%s\n' 1 ;;
    *) exec "$FM_TEST_REAL_PS" "${args[@]}" ;;
  esac
  exit 0
fi
exec "$FM_TEST_REAL_PS" "${args[@]}"
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    format=${!#}
    case "$format" in *$'\t'*) ;; *) exit 90 ;; esac
    case "$format" in *'\t'*) exit 91 ;; esac
    case " $* " in
      *' -c '*) printf '$9\t%%9\n' ;;
      *) printf '/tmp/fm-proof-tmux\t4242\t$9\t%%9\t777\t/dev/pts/9\t0\t%s\n' "${FM_TEST_TMUX_COMMAND:-traex}" ;;
    esac
    ;;
  list-clients)
    format=${!#}
    case "$format" in *$'\t'*) ;; *) exit 90 ;; esac
    case "$format" in *'\t'*) exit 91 ;; esac
    [ "${FM_TEST_NO_CLIENT:-0}" = 1 ] || printf '/dev/pts/90\t0\n'
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/traex" <<'SH'
#!/usr/bin/env bash
set -u
emit() { # <event> <session> [source]
  local event=$1 session=$2 source=${3:-} payload status=0
  payload=$(jq -cn --arg event "$event" --arg session "$session" --arg source "$source" \
    --arg cwd "$FM_TEST_ROOT" \
    '{hook_event_name:$event,session_id:$session,turn_id:"turn-proof",cwd:$cwd}
     + (if $source == "" then {} else {source:$source} end)
     + (if $event == "PreToolUse" then {tool_name:"Bash",tool_input:{command:"true"}} else {} end)')
  printf '%s' "$payload" | FM_TEST_NATIVE_PID=$$ "$FM_TEST_DISPATCHER" || status=$?
  return "$status"
}
case "${1:-}" in
  --version) printf '%s\n' 'traecli 0.200.19(internal edition)' ;;
  login) printf '%s\n' 'Logged in using Trae' >&2 ;;
  features) printf '%s\n' 'hooks stable true' 'plugin_hooks stable true' ;;
  models) printf '%s\n' '[{"name":"gpt-5.6-luna","real_name":"GPT-5.6-Luna","provider":"trae"}]' ;;
  open)
    emit SessionStart "$2" startup || exit $?
    emit UserPromptSubmit "$2" || exit $?
    emit PreToolUse "$2" || exit $?
    ;;
  guard)
    emit SessionStart "$2" startup || exit $?
    cp "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.guard.lineage"
    cp "$FM_TEST_ROOT/state/.traex-primary-ownership-proof" "$FM_TEST_ROOT/state/.guard.proof"
    chmod 600 "$FM_TEST_ROOT/state/.guard.lineage" "$FM_TEST_ROOT/state/.guard.proof"
    status=0
    emit UserPromptSubmit "$3" >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || exit 71
    cmp -s "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.guard.lineage" || exit 72
    cmp -s "$FM_TEST_ROOT/state/.traex-primary-ownership-proof" "$FM_TEST_ROOT/state/.guard.proof" || exit 73
    mv "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.guard.missing"
    status=0
    emit UserPromptSubmit "$2" >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] && [ ! -e "$FM_TEST_ROOT/state/.traex-primary-lineage" ] || exit 74
    mv "$FM_TEST_ROOT/state/.guard.missing" "$FM_TEST_ROOT/state/.traex-primary-lineage"
    status=0
    FM_TEST_NO_CLIENT=1 emit UserPromptSubmit "$2" >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || exit 75
    cmp -s "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.guard.lineage" || exit 76
    emit UserPromptSubmit "$2" || exit $?
    emit PreToolUse "$2" || exit $?
    : > "$FM_TEST_ROOT/state/prompt-guard.ok"
    ;;
  resume)
    emit SessionStart "$2" resume || exit $?
    emit UserPromptSubmit "$2" || exit $?
    emit PreToolUse "$2" || exit $?
    ;;
  hold)
    emit SessionStart "$2" startup || exit $?
    emit UserPromptSubmit "$2" || exit $?
    emit PreToolUse "$2" || exit $?
    printf '%s\n' "$$" > "$FM_TEST_HOLD_DIR/owner.pid"
    : > "$FM_TEST_HOLD_DIR/ready"
    while [ ! -e "$FM_TEST_HOLD_DIR/release" ]; do sleep 0.05; done
    ;;
  lifecycle)
    emit SessionStart session-before startup || exit $?
    emit UserPromptSubmit session-before || exit $?
    emit Stop session-before || exit $?
    emit PostCompact session-before || exit $?
    cp "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.lineage.before-clear"
    chmod 600 "$FM_TEST_ROOT/state/.lineage.before-clear"
    [ ! -e "$FM_TEST_ROOT/state/.traex-primary-ownership-proof" ] || exit 81
    status=0
    emit UserPromptSubmit session-after >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || exit 82
    status=0
    emit PreToolUse session-after >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || exit 83
    status=0
    emit SessionStart session-before compact >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || exit 84
    cmp -s "$FM_TEST_ROOT/state/.traex-primary-lineage" "$FM_TEST_ROOT/state/.lineage.before-clear" || exit 85
    emit SessionStart session-after clear || exit $?
    emit UserPromptSubmit session-after || exit $?
    emit PreToolUse session-after || exit $?
    : > "$FM_TEST_ROOT/state/lifecycle.ok"
    ;;
  event) emit "$2" "$3" "${4:-}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/sha256sum" "$fakebin/ps" "$fakebin/tmux" "$fakebin/traex"

  printf '%s\n' '{"version":1,"hooks":{}}' > "$cli/hooks.json"
  HOME="$case_dir/home" TRAE_HOME="$case_dir/trae" TRAECLI_HOME="$cli" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$root/bin/fm-traex-hook-install.sh" install >/dev/null || fail "$name: hook install failed"
  hooks_sha=$($REAL_SHA256SUM "$cli/hooks.json" | awk '{print $1}')
  dispatcher_sha=$($REAL_SHA256SUM "$cli/fm-firstmate-hook.sh" | awk '{print $1}')
  binary=$(CDPATH='' cd "$fakebin" && pwd -P)/traex
  jq -n --arg binary "$binary" --arg binary_sha "$SUPPORTED_SHA" \
    --arg hooks_sha "$hooks_sha" --arg dispatcher_sha "$dispatcher_sha" '
      {protocol:"v1",version:"traecli 0.200.19(internal edition)",binary_path:$binary,
       binary_sha256:$binary_sha,hooks_sha256:$hooks_sha,dispatcher_sha256:$dispatcher_sha,
       probe_nonce_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
       events:["SessionStart","UserPromptSubmit","PreToolUse","Stop","SessionEnd"],completed_at:1}' \
    > "$cli/fm-firstmate-receipt.json"
  chmod 600 "$cli/fm-firstmate-receipt.json"
  mkdir -p "$case_dir/home" "$case_dir/trae"
  HOME="$case_dir/home" TRAE_HOME="$case_dir/trae" TRAECLI_HOME="$cli" FM_HOME="$root" \
    TMUX=fake TMUX_PANE=%9 PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$root/bin/fm-traex-hook-install.sh" bind-primary "$root" "$root" >/dev/null \
    || fail "$name: attached primary bind failed"
  printf '%s|%s|%s\n' "$root" "$cli" "$fakebin"
}

run_hook_mode() { # <root> <cli> <fakebin> <fake-traex-args...>
  local root=$1 cli=$2 fakebin=$3
  shift 3
  HOME="${root%/firstmate}/home" TRAE_HOME="${root%/firstmate}/trae" TRAECLI_HOME="$cli" FM_HOME="$root" \
    TMUX=fake TMUX_PANE=%9 PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" FM_TEST_REAL_PS="$REAL_PS" \
    FM_TEST_ROOT="$root" FM_TEST_TRAEX_BINARY="$fakebin/traex" \
    FM_TEST_DISPATCHER="$cli/fm-firstmate-hook.sh" "$fakebin/traex" "$@"
}

run_sandbox() { # <root> <cli> <fakebin> <command...>
  local root=$1 cli=$2 fakebin=$3
  shift 3
  HOME="${FM_TEST_CALLER_OS_HOME:-${root%/firstmate}/home}" \
    TRAE_HOME="${FM_TEST_CALLER_TRAE_HOME:-${root%/firstmate}/trae}" \
    TRAECLI_HOME="${FM_TEST_CALLER_CLI_HOME:-$cli}" FM_HOME="${FM_TEST_CALLER_FM_HOME:-$root}" \
    FM_ROOT_OVERRIDE="${FM_TEST_CALLER_ROOT:-$root}" TMUX=fake \
    TMUX_PANE="${FM_TEST_CALLER_PANE:-%9}" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    FM_TEST_REAL_PS="$REAL_PS" FM_TEST_SANDBOX_PS=1 "$@"
}

make_stale() { # <path>
  if [ "$(uname)" = Darwin ]; then
    touch -t 197001010000 "$1"
  else
    touch -d @0 "$1"
  fi
}

expect_refusal() { # <description> <command...>
  local description=$1 status=0
  shift
  "$@" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "$description unexpectedly accepted ownership"
}

test_valid_missing_stale_forged_and_scope_refusals() {
  local rec root cli fakebin state proof saved issued out other
  rec=$(make_fixture scope) || fail "scope fixture failed"
  IFS='|' read -r root cli fakebin <<EOF
$rec
EOF
  state=$root/state
  run_hook_mode "$root" "$cli" "$fakebin" guard session-one other-session \
    || fail "native hook could not establish guarded proof"
  [ -e "$state/prompt-guard.ok" ] || fail "UserPrompt guard sequence did not complete"
  out=$(run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh") \
    || fail "no-ancestor tool rejected a valid native-hook proof: $out"
  assert_contains "$out" 'lock acquired: harness pid' "valid proof did not preserve lock ownership"
  [ "$(run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-harness.sh")" = traex ] \
    || fail "valid proof did not identify the sandboxed primary as TraeX"

  proof=$state/.traex-primary-ownership-proof
  saved=$state/.proof.saved
  cp "$proof" "$saved"
  chmod 600 "$saved"
  mv "$proof" "$state/.proof.missing"
  expect_refusal "missing proof" run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  mv "$state/.proof.missing" "$proof"

  make_stale "$proof"
  expect_refusal "stale proof" run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  cp "$saved" "$proof"
  chmod 600 "$proof"

  sed 's/^session_id=.*/session_id=forged-session/' "$saved" > "$proof"
  chmod 600 "$proof"
  expect_refusal "forged proof" run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  cp "$saved" "$proof"
  chmod 600 "$proof"

  sed 's/^session_id=.*/session_id=other-session/' "$state/.traex-primary-session" > "$state/.session.wrong"
  chmod 600 "$state/.session.wrong"
  mv "$state/.session.wrong" "$state/.traex-primary-session"
  expect_refusal "cross-session proof" run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  printf 'session_id=session-one\nsource=startup\n' > "$state/.traex-primary-session"
  chmod 600 "$state/.traex-primary-session"

  FM_TEST_CALLER_PANE=%8 expect_refusal "mismatched pane" \
    run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  FM_TEST_NO_CLIENT=1 expect_refusal "detached client" \
    run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  FM_TEST_TMUX_COMMAND=bash expect_refusal "dead owner pane" \
    run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"

  other=${root%/firstmate}/other-home
  mkdir -p "$other/state" "$other/config"
  for artifact in .traex-primary-hook-token .traex-primary-ownership-proof \
      .traex-primary-lineage .traex-primary-session .lock; do
    cp "$state/$artifact" "$other/state/$artifact"
    chmod 600 "$other/state/$artifact"
  done
  FM_TEST_CALLER_FM_HOME="$other" expect_refusal "cross-home copied proof" \
    run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  issued=$(sed -n 's/^issued_at=//p' "$proof")
  case "$issued" in ''|*[!0-9]*) fail "proof did not record a bounded issuance time" ;; esac
  pass "TraeX primary proof accepts the no-ancestor tool and rejects missing, stale, forged, cross-session, cross-home, detached, mismatched, and dead-owner cases"
}

test_competing_resume_clear_and_compact() {
  local rec root cli fakebin state hold owner status lock_after old_lock resumed_owner rec2 root2 cli2 fakebin2 hold_pid i
  rec=$(make_fixture competing) || fail "competing fixture failed"
  IFS='|' read -r root cli fakebin <<EOF
$rec
EOF
  state=$root/state
  hold=${root%/firstmate}/hold
  mkdir -p "$hold"
  HOME="${root%/firstmate}/home" TRAE_HOME="${root%/firstmate}/trae" TRAECLI_HOME="$cli" FM_HOME="$root" \
    TMUX=fake TMUX_PANE=%9 PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" FM_TEST_REAL_PS="$REAL_PS" \
    FM_TEST_ROOT="$root" FM_TEST_TRAEX_BINARY="$fakebin/traex" \
    FM_TEST_DISPATCHER="$cli/fm-firstmate-hook.sh" FM_TEST_HOLD_DIR="$hold" \
    "$fakebin/traex" hold session-live &
  hold_pid=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$hold/ready" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$hold/ready" ] || fail "live primary fixture did not become ready"
  owner=$(cat "$hold/owner.pid")
  status=0
  FM_TEST_LIVE_PID="$owner" run_hook_mode "$root" "$cli" "$fakebin" resume session-live \
    >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a competing live primary acquired the existing home"
  lock_after=$(cat "$state/.lock")
  [ "$lock_after" = "$owner" ] || fail "competing primary moved the live owner's lock"
  : > "$hold/release"
  wait "$hold_pid" || fail "held primary exited unexpectedly"

  old_lock=$(cat "$state/.lock")
  run_hook_mode "$root" "$cli" "$fakebin" resume session-live \
    || fail "correct-session resume after owner death was refused"
  resumed_owner=$(sed -n 's/^owner_pid=//p' "$state/.traex-primary-lineage")
  [ "$resumed_owner" != "$old_lock" ] || fail "resume retained the exited owner pid"
  [ "$(cat "$state/.lock")" = "$resumed_owner" ] \
    || fail "resume lineage owner and fleet lock did not converge"
  [ "$(sed -n 's/^source=//p' "$state/.traex-primary-lineage")" = resume ] \
    || fail "resume lineage source was not retained"
  status=0
  run_hook_mode "$root" "$cli" "$fakebin" resume wrong-session >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "wrong-session resume replaced the established lineage"
  [ "$(sed -n 's/^session_id=//p' "$state/.traex-primary-lineage")" = session-live ] \
    || fail "wrong-session resume changed the lineage"
  [ "$(cat "$state/.lock")" = "$resumed_owner" ] \
    || fail "wrong-session resume changed the converged lock owner"

  rec2=$(make_fixture lifecycle) || fail "lifecycle fixture failed"
  IFS='|' read -r root2 cli2 fakebin2 <<EOF
$rec2
EOF
  run_hook_mode "$root2" "$cli2" "$fakebin2" lifecycle \
    || fail "same-incarnation clear activation sequence was refused"
  [ -e "$root2/state/lifecycle.ok" ] || fail "clear lifecycle negative matrix did not complete"
  [ "$(sed -n 's/^session_id=//p' "$root2/state/.traex-primary-lineage")" = session-after ] \
    || fail "clear did not advance the exact session lineage"
  [ "$(sed -n 's/^source=//p' "$root2/state/.traex-primary-lineage")" = clear ] \
    || fail "clear lineage source was not retained"
  assert_grep '--source clear' "$root2/state/sessionstart.sources" "clear did not route through SessionStart"
  assert_grep '--source compact' "$root2/state/sessionstart.sources" \
    "real PostCompact route did not request context re-emission"
  [ "$(grep -c -- '--source compact' "$root2/state/sessionstart.sources")" = 1 ] \
    || fail "compact context re-emission was not owned by one PostCompact event"
  run_sandbox "$root2" "$cli2" "$fakebin2" "$root2/bin/fm-lock.sh" >/dev/null \
    || fail "post-clear sandbox proof did not own the exact lock"
  pass "TraeX primary lineage guards prompts, converges exact resume ownership, and models clear activation without inventing SessionStart(compact)"
}

test_spawn_owned_secondmate_token_authority() {
  local rec root cli fakebin state token record external rewritten out
  rec=$(make_fixture spawn-owned) || fail "spawn-owned fixture failed"
  IFS='|' read -r root cli fakebin <<EOF
$rec
EOF
  state=$root/state
  token=$(cat "$state/.traex-primary-hook-token")
  record=$cli/fm-firstmate-hooks.d/$token
  external=${root%/firstmate}/parent-state/spawned-primary.traex-hook-token
  mkdir -p "${external%/*}"
  mv "$state/.traex-primary-hook-token" "$external"
  rewritten=$record.rewritten
  awk -v token_state="$external" '
    /^task_id=/ { print "task_id=spawned-primary"; next }
    /^token_state_real=/ { print "token_state_real=" token_state; next }
    /^tmux_client_policy=/ { print "tmux_client_policy=spawn-owned"; next }
    { print }
  ' "$record" > "$rewritten"
  chmod 600 "$external" "$rewritten"
  mv "$rewritten" "$record"

  run_hook_mode "$root" "$cli" "$fakebin" open session-spawn-owned \
    || fail "spawn-owned native hook could not establish proof"
  out=$(run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh") \
    || fail "spawn-owned no-ancestor tool rejected its parent-held token authority: $out"
  assert_contains "$out" 'lock acquired: harness pid' \
    "spawn-owned proof did not preserve lock ownership"
  [ "$(run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-harness.sh")" = traex ] \
    || fail "spawn-owned proof did not identify the sandboxed secondmate primary as TraeX"
  mv "$external" "$external.missing"
  expect_refusal "missing parent-held spawn token" \
    run_sandbox "$root" "$cli" "$fakebin" "$root/bin/fm-lock.sh"
  mv "$external.missing" "$external"
  pass "TraeX spawn-owned secondmate proof resolves its exact parent-held teardown token and fails closed when it disappears"
}

test_valid_missing_stale_forged_and_scope_refusals
test_competing_resume_clear_and_compact
test_spawn_owned_secondmate_token_authority
