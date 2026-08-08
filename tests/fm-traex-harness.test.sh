#!/usr/bin/env bash
# Portable detection, launch-rendering, gate, and backend-scope regression for
# the tmux-only TraeX adapter. Real lifecycle semantics live in the opt-in live
# suite; this file drives public scripts with isolated fakes and no credentials.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
INSTALL="$ROOT/bin/fm-traex-hook-install.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-traex-harness)
SUPPORTED_SHA=e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581
REAL_SHA256SUM=$(command -v sha256sum 2>/dev/null || true)
[ -n "$REAL_SHA256SUM" ] || { echo 'skip: sha256sum not found'; exit 0; }

test_exact_detection_and_session_lock_names() {
  local dir bin out fakebin
  dir="$TMP_ROOT/detection"
  mkdir -p "$dir"
  for bin in traex traecli; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
      -u FM_TRAEX_HARNESS "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" = traex ] || fail "exact process ancestor $bin resolved '$out', expected traex"
  done
  for bin in traex-helper nottraex traecli-helper; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
      -u FM_TRAEX_HARNESS "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != traex ] || fail "inexact process ancestor $bin was misdetected as TraeX"
  done
  out=$(FM_TRAEX_HARNESS=traex CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "existing higher-precedence Claude marker changed: $out"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT FM_TRAEX_HARNESS=traex "$HARNESS")
  [ "$out" = traex ] || fail "exact TraeX launch marker was not detected"

  fakebin=$(fm_fakebin "$dir/lock")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'comm='*) printf '%s\n' "${FM_TEST_PROCESS_PATH:-/usr/local/bin/${FM_TEST_PROCESS_NAME:-traex}}" ;;
  *'args='*) printf '%s\n' "${FM_TEST_PROCESS_PATH:-${FM_TEST_PROCESS_NAME:-traex}}" ;;
  *'ppid='*) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  PATH="$fakebin:$PATH" bash -c \
    '. "$1/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 42' _ "$ROOT" \
    || fail "session lock rejected an exact traex holder"
  if PATH="$fakebin:$PATH" FM_TEST_PROCESS_NAME=traex-helper bash -c \
      '. "$1/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 42' _ "$ROOT"; then
    fail "session lock accepted a traex-helper lookalike"
  fi
  if PATH="$fakebin:$PATH" FM_TEST_PROCESS_PATH=/tmp/traex/helper bash -c \
      '. "$1/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 42' _ "$ROOT"; then
    fail "session lock accepted TraeX from a directory component"
  fi
  pass "TraeX detection and session-lock recognition use only the exact marker/process identities"
}

make_spawn_fixture() {
  local case_dir=$1 home proj wt fakebin cli_home hooks_sha dispatcher_sha binary
  home=$case_dir/home
  proj=$case_dir/project
  wt=$case_dir/wt
  fakebin=$case_dir/fakebin
  cli_home=$case_dir/cli
  mkdir -p "$home/data/traex-task" "$home/data/raw-traex" "$home/data/raw-wrapper-1" \
    "$home/data/raw-wrapper-2" "$home/data/raw-wrapper-3" "$home/data/raw-wrapper-4" \
    "$home/data/raw-wrapper-safe" "$home/data/missing-profile" "$home/os-home" "$home/trae-runtime" \
    "$home/projects" "$home/state" "$home/config" "$fakebin" "$cli_home"
  printf 'brief\n' > "$home/data/traex-task/brief.md"
  printf 'brief\n' > "$home/data/raw-traex/brief.md"
  printf 'brief\n' > "$home/data/raw-wrapper-1/brief.md"
  printf 'brief\n' > "$home/data/raw-wrapper-2/brief.md"
  printf 'brief\n' > "$home/data/raw-wrapper-3/brief.md"
  printf 'brief\n' > "$home/data/raw-wrapper-4/brief.md"
  printf 'brief\n' > "$home/data/raw-wrapper-safe/brief.md"
  printf 'brief\n' > "$home/data/missing-profile/brief.md"
  mkdir -p "$home/data/traex-scout"
  printf 'scout brief\n' > "$home/data/traex-scout/brief.md"
  printf '%s\n' 'worker=on' 'primary=off' 'secondmate=off' > "$home/config/traex-adapter"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" fm/traex-task

  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1##*/}" = traex ]; then
  [ "${FM_TEST_CLASSIFY_NO_BINARY_HASH:-0}" != 1 ] || exit 77
  printf '%s  %s\n' "$FM_TEST_TRAEX_SHA" "$1"
  exit 0
fi
exec "$FM_TEST_REAL_SHA256SUM" "$@"
SH
  cat > "$fakebin/traex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'traecli 0.200.19(internal edition)' ;;
  login) printf '%s\n' 'Logged in using Trae' >&2 ;;
  features) printf '%s\n' 'hooks stable true' 'plugin_hooks stable true' ;;
  models) printf '%s\n' '[{"name":"GPT-5.6-Luna","provider":"trae"}]' ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_TEST_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sha256sum" "$fakebin/traex" "$fakebin/tmux" "$fakebin/treehouse"
  : > "$cli_home/hooks.json"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$cli_home/hooks.json"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" "$INSTALL" install >/dev/null \
    || fail "spawn fixture hook install failed"
  hooks_sha=$($REAL_SHA256SUM "$cli_home/hooks.json" | awk '{print $1}')
  dispatcher_sha=$($REAL_SHA256SUM "$cli_home/fm-firstmate-hook.sh" | awk '{print $1}')
  binary=$(cd "$fakebin" && pwd -P)/traex
  jq -n --arg binary "$binary" --arg binary_sha "$SUPPORTED_SHA" \
    --arg hooks_sha "$hooks_sha" --arg dispatcher_sha "$dispatcher_sha" '
      {protocol:"v1",version:"traecli 0.200.19(internal edition)",binary_path:$binary,
       binary_sha256:$binary_sha,hooks_sha256:$hooks_sha,dispatcher_sha256:$dispatcher_sha,
       probe_nonce_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       events:["SessionStart","UserPromptSubmit","Stop","SessionEnd"],completed_at:1}' \
    > "$cli_home/fm-firstmate-receipt.json"
  chmod 600 "$cli_home/fm-firstmate-receipt.json"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$cli_home"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <cli-home> [spawn args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 cli_home=$5
  shift 5
  HOME="$home/os-home" TRAE_HOME="$home/trae-runtime" TRAECLI_HOME="$cli_home" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_TEST_TMUX_LOG="$home/tmux.log" FM_TEST_PANE_PATH="$wt" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

test_spawn_launch_and_closed_axes() {
  local rec home proj wt fakebin cli_home out status launch id raw_id raw_command safe_rec
  local safe_home safe_proj safe_wt safe_fakebin safe_cli_home
  local -a raw_commands
  rec=$(make_spawn_fixture "$TMP_ROOT/spawn") || fail "spawn fixture failed"
  IFS='|' read -r home proj wt fakebin cli_home <<EOF
$rec
EOF
  : > "$home/tmux.log"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
    traex-task "$proj" traex --model GPT-5.6-Luna --effort high --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "TraeX tmux spawn should succeed: $out"
  assert_contains "$out" 'spawned traex-task harness=traex' "TraeX spawn did not report success"
  launch=$(grep 'FM_TRAEX_HARNESS=traex' "$home/tmux.log" | tail -1)
  assert_contains "$launch" 'FM_TRAEX_HARNESS=traex' "launch omitted exact harness marker"
  assert_contains "$launch" "'$fakebin/traex' -y" "launch did not pin the preflighted canonical binary"
  assert_contains "$launch" "HOME='$home/os-home'" "launch did not pin the preflighted HOME"
  assert_contains "$launch" "TRAE_HOME='$home/trae-runtime'" "launch did not pin the preflighted TRAE_HOME"
  assert_contains "$launch" "TRAECLI_HOME='$cli_home'" "launch did not pin the authenticated TRAECLI_HOME"
  assert_contains "$launch" '--disable plugins --disable plugin_hooks' "launch did not disable plugin hook mutation"
  assert_contains "$launch" "--model 'GPT-5.6-Luna'" "launch lost the authenticated model"
  assert_contains "$launch" "model_reasoning_effort=\"high\"" "launch lost the live-verified effort"
  assert_not_contains "$launch" '--dangerously-bypass-hook-trust' "launch bypassed native TraeX hook trust"
  assert_present "$home/state/traex-task.traex-receipt" "spawn did not persist drift-check receipt snapshot"
  assert_present "$home/state/traex-task.traex-hook-token" "spawn did not register a task-scoped hook token"
  assert_grep "traex_os_home=$home/os-home" "$home/state/traex-task.meta" "meta lost the authenticated OS home"
  assert_grep "traex_home=$home/trae-runtime" "$home/state/traex-task.meta" "meta lost the Trae runtime home"
  assert_grep "traex_cli_home=$cli_home" "$home/state/traex-task.meta" "meta lost the authenticated CLI home"

  : > "$home/tmux.log"
  if out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
      raw-traex "$proj" "$fakebin/traex --dangerously-bypass-hook-trust" \
      --mode no-mistakes --yolo off); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "raw TraeX launch unexpectedly bypassed the canonical template"
  assert_contains "$out" 'TraeX raw launch commands are forbidden' \
    "raw TraeX refusal did not identify the canonical-launch boundary"
  assert_not_contains "$(cat "$home/tmux.log")" 'new-window' \
    "raw TraeX refusal created an endpoint"

  raw_commands=(
    "env FOO=1 '$fakebin/traex' --dangerously-bypass-hook-trust"
    "command '$fakebin/traex' --dangerously-bypass-hook-trust"
    "bash -lc 'env FOO=1 command \"$fakebin/traex\" --dangerously-bypass-hook-trust'"
    "env bash -c 'command traex --dangerously-bypass-hook-trust'"
  )
  for id in "${!raw_commands[@]}"; do
    raw_id=raw-wrapper-$((id + 1))
    raw_command=${raw_commands[$id]}
    if out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
        "$raw_id" "$proj" "$raw_command" --mode no-mistakes --yolo off); then
      status=0
    else
      status=$?
    fi
    [ "$status" -ne 0 ] || fail "wrapped raw TraeX launch unexpectedly bypassed the canonical template: $raw_command"
    assert_contains "$out" 'TraeX raw launch commands are forbidden' \
      "wrapped raw TraeX refusal did not identify the canonical-launch boundary"
  done
  assert_not_contains "$(cat "$home/tmux.log")" 'new-window' \
    "wrapped raw TraeX refusal created an endpoint"

  safe_rec=$(make_spawn_fixture "$TMP_ROOT/wrapper-safe") || fail "safe wrapper fixture failed"
  IFS='|' read -r safe_home safe_proj safe_wt safe_fakebin safe_cli_home <<EOF
$safe_rec
EOF
  out=$(run_spawn "$safe_home" "$safe_proj" "$safe_wt" "$safe_fakebin" "$safe_cli_home" \
    raw-wrapper-safe "$safe_proj" 'env FOO=1 custom-agent --flag' --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "non-TraeX raw wrapper was rejected: $out"

  printf '%s\n' 'worker=off' 'primary=off' 'secondmate=off' > "$home/config/traex-adapter"
  : > "$home/tmux.log"
  id=closed-task
  if out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
      "$id" "$proj" traex --mode no-mistakes --yolo off); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "closed TraeX worker gate accepted a spawn"
  assert_contains "$out" 'worker gate is closed' "closed TraeX gate failure was not actionable"
  if grep -Fq 'new-window' "$home/tmux.log"; then
    fail "closed gate created an endpoint"
  fi

  printf '%s\n' 'worker=on' 'primary=off' 'secondmate=off' > "$home/config/traex-adapter"
  : > "$home/tmux.log"
  if out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
      other-backend "$proj" traex --backend zellij --mode no-mistakes --yolo off); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "TraeX unexpectedly opened on zellij"
  assert_contains "$out" "tmux is the only supported backend" "non-tmux refusal did not name the verified boundary"
  if grep -Fq 'new-window' "$home/tmux.log"; then
    fail "non-tmux TraeX refusal created an endpoint"
  fi

  out=$(TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_CLASSIFY_NO_BINARY_HASH=1 \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" bash -c \
    '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux firstmate:fm-traex-task traex traex-task "$2"' \
    _ "$ROOT" "$home/state")
  [ "$out" = 'busy fm-spawn' ] \
    || fail "valid TraeX snapshot did not trust its semantic state without rehashing the binary: $out"
  printf '\n' >> "$cli_home/hooks.json"
  out=$(TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" bash -c \
    '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux firstmate:fm-traex-task traex traex-task "$2"' \
    _ "$ROOT" "$home/state")
  [ "$out" = 'unknown traex-unverified' ] \
    || fail "post-spawn hook drift did not fail semantic state closed: $out"
  pass "TraeX spawn pins trusted launch flags and fails before endpoint creation for closed gates/backends"
}

test_scout_and_explicit_profile_gate() {
  local rec home proj wt fakebin cli_home out status launch
  rec=$(make_spawn_fixture "$TMP_ROOT/scout") || fail "scout fixture failed"
  IFS='|' read -r home proj wt fakebin cli_home <<EOF
$rec
EOF
  : > "$home/tmux.log"
  if out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
      missing-profile "$proj" traex --mode no-mistakes --yolo off); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "TraeX launch without an explicit model/effort unexpectedly succeeded"
  assert_contains "$out" 'require an explicit live-verified model' "missing-model refusal was not actionable"
  assert_not_contains "$(cat "$home/tmux.log")" 'new-window' "missing-model refusal created an endpoint"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$cli_home" \
    traex-scout "$proj" traex --scout --model GPT-5.6-Luna --effort medium)
  status=$?
  expect_code 0 "$status" "TraeX scout spawn failed: $out"
  assert_grep 'kind=scout' "$home/state/traex-scout.meta" "TraeX scout kind was not recorded"
  assert_grep 'harness=traex' "$home/state/traex-scout.meta" "TraeX scout harness was not recorded"
  launch=$(grep 'FM_TRAEX_HARNESS=traex' "$home/tmux.log" | tail -1)
  assert_contains "$launch" "--model 'GPT-5.6-Luna'" "TraeX scout lost its model"
  assert_contains "$launch" 'model_reasoning_effort="medium"' "TraeX scout lost its effort"
  touch "$fakebin/traex"
  out=$(TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_CLASSIFY_NO_BINARY_HASH=1 FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" bash -c \
    '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux firstmate:fm-traex-scout traex traex-scout "$2"' \
    _ "$ROOT" "$home/state")
  [ "$out" = 'unknown traex-unverified' ] \
    || fail "post-spawn binary identity drift did not fail semantic state closed: $out"
  pass "TraeX scout uses the worker adapter and launches only with an explicit verified profile"
}

test_exact_detection_and_session_lock_names
test_spawn_launch_and_closed_axes
test_scout_and_explicit_profile_gate
