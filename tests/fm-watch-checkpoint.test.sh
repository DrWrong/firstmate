#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_late_checkpoint_surfaces_terminal_after_blind_stop_once() {
  local home out err status drained second_out second_err
  home=$(make_home terminal-catchup)
  out="$home/out.txt"
  err="$home/err.txt"

  fm_git_init_commit "$home"
  mkdir -p "$home/bin"
  : > "$home/AGENTS.md"
  : > "$home/state/demo.meta"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "foreground checkpoint must exit before terminal completion"

  status=0
  printf '%s\n' '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$ROOT/bin/fm-turnend-guard.sh" >"$out" 2>"$err" \
    || status=$?
  expect_code 2 "$status" "initial blind primary stop must force one continuation"

  printf 'done: synthetic terminal completion\n' > "$home/state/demo.status"
  : > "$home/state/demo.turn-ended"

  status=0
  printf '%s\n' '{"stop_hook_active":true}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$ROOT/bin/fm-turnend-guard.sh" >"$out" 2>"$err" \
    || status=$?
  expect_code 2 "$status" "bounded Codex continuation must not end before terminal catch-up"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "late checkpoint terminal catch-up"
  assert_contains "$(cat "$out")" "signal:" "late checkpoint did not surface the terminal completion"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "terminal status was not durably queued"
  assert_contains "$drained" $'\tsignal\tdemo.turn-ended\t' "terminal turn-end marker was not durably queued"

  second_out="$home/second.out"
  second_err="$home/second.err"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$second_out" 2>"$second_err" || status=$?
  expect_code 124 "$status" "terminal catch-up replay checkpoint"
  assert_not_contains "$(cat "$second_out")" "signal:" "terminal completion surfaced more than once"
  [ ! -s "$home/state/.wake-queue" ] || fail "terminal completion was queued more than once"
  pass "late checkpoint surfaces a terminal event exactly once after the bounded Codex blind-stop continuation"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_late_checkpoint_surfaces_terminal_after_blind_stop_once
