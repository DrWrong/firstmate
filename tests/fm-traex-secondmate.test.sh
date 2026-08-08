#!/usr/bin/env bash
# Portable local-tmux secondmate and exact-session resume coverage for TraeX.
# Remote placement is asserted to refuse before any remote readiness or Herdr
# lifecycle path can run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
RESUME="$ROOT/bin/fm-traex-resume.sh"
INSTALL="$ROOT/bin/fm-traex-hook-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-traex-secondmate)
SUPPORTED_SHA=e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581
REAL_SHA256SUM=$(command -v sha256sum 2>/dev/null || true)
[ -n "$REAL_SHA256SUM" ] || { echo 'skip: sha256sum not found'; exit 0; }

make_fixture() {
  local case_dir=$1 parent sub fakebin cli_home binary hooks_sha dispatcher_sha
  parent=$case_dir/parent
  sub=$case_dir/secondmate
  fakebin=$case_dir/fakebin
  cli_home=$case_dir/cli
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects" \
    "$parent/os-home" "$parent/trae-runtime" \
    "$sub/data" "$sub/state" "$sub/config" "$sub/projects" "$fakebin" "$cli_home"
  printf '%s\n' 'primary=on' 'secondmate=on' 'worker=off' > "$parent/config/traex-adapter"
  printf '%s\n' traex > "$parent/config/secondmate-harness"
  printf '%s\n' traex-sm > "$sub/.fm-secondmate-home"
  printf '# Firstmate fixture\n' > "$sub/AGENTS.md"
  printf 'local TraeX secondmate charter\n' > "$sub/data/charter.md"
  ln -s "$ROOT/bin" "$sub/bin"
  touch "$parent/state/.last-watcher-beat"
  printf '%s\n' traex > "$case_dir/mode"
  : > "$case_dir/tmux.log"

  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1##*/}" = traex ]; then
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
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_current_command}'*) cat "$FM_TEST_TMUX_MODE" ;;
      *'#{pane_current_path}'*) printf '%s\n' "$FM_TEST_SECONDMATE_HOME" ;;
      *'#{pane_pid}'*) printf '%s\n' 999999 ;;
      *'#S'*) printf '%s\n' firstmate ;;
      *) printf '%s\n' '@99' ;;
    esac
    ;;
  list-windows)
    if [ -e "$FM_TEST_TMUX_WINDOW_STATE" ]; then
      case "$*" in
        *'#{window_name}'*) printf '%s\n' fm-traex-sm ;;
        *) printf '%s\n' 'firstmate:fm-traex-sm' ;;
      esac
    fi
    ;;
  new-window)
    : > "$FM_TEST_TMUX_WINDOW_STATE"
    printf '%s\n' '@99'
    ;;
  send-keys)
    case "$*" in
      *' resume -y '*)
        printf '%s\n' traex > "$FM_TEST_TMUX_MODE"
        if [ "${FM_TEST_SKIP_RESUME_CALLBACK:-0}" != 1 ]; then
          printf 'session_id=%s\nsource=resume\n' "$FM_TEST_SESSION_ID" \
            > "$FM_TEST_SECONDMATE_HOME/state/.traex-primary-session"
        fi
        ;;
    esac
    ;;
  has-session|new-session|set-window-option|kill-window) ;;
esac
exit 0
SH
  chmod +x "$fakebin/sha256sum" "$fakebin/traex" "$fakebin/tmux"

  printf '%s\n' '{"version":1,"hooks":{}}' > "$cli_home/hooks.json"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" "$INSTALL" install >/dev/null \
    || fail "secondmate fixture hook install failed"
  hooks_sha=$($REAL_SHA256SUM "$cli_home/hooks.json" | awk '{print $1}')
  dispatcher_sha=$($REAL_SHA256SUM "$cli_home/fm-firstmate-hook.sh" | awk '{print $1}')
  binary=$(cd "$fakebin" && pwd -P)/traex
  jq -n --arg binary "$binary" --arg binary_sha "$SUPPORTED_SHA" \
    --arg hooks_sha "$hooks_sha" --arg dispatcher_sha "$dispatcher_sha" '
      {protocol:"v1",version:"traecli 0.200.19(internal edition)",binary_path:$binary,
       binary_sha256:$binary_sha,hooks_sha256:$hooks_sha,dispatcher_sha256:$dispatcher_sha,
       probe_nonce_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
       events:["SessionStart","UserPromptSubmit","Stop","SessionEnd"],completed_at:1}' \
    > "$cli_home/fm-firstmate-receipt.json"
  chmod 600 "$cli_home/fm-firstmate-receipt.json"
  printf '%s|%s|%s|%s\n' "$parent" "$sub" "$fakebin" "$cli_home"
}

run_env() {  # <parent> <sub> <fakebin> <cli-home> <command...>
  local parent=$1 sub=$2 fakebin=$3 cli_home=$4
  shift 4
  HOME="${FM_TEST_AMBIENT_HOME:-$parent/os-home}" \
    TRAE_HOME="${FM_TEST_AMBIENT_TRAE_HOME:-$parent/trae-runtime}" \
    FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" FM_DATA_OVERRIDE="$parent/data" \
    FM_PROJECTS_OVERRIDE="$parent/projects" FM_CONFIG_OVERRIDE="$parent/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 TMUX='fake,1,0' \
    TRAECLI_HOME="${FM_TEST_AMBIENT_CLI_HOME:-$cli_home}" FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" \
    FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" FM_TEST_TMUX_LOG="${parent%/parent}/tmux.log" \
    FM_TEST_TMUX_MODE="${parent%/parent}/mode" FM_TEST_SECONDMATE_HOME="$sub" \
    FM_TEST_TMUX_WINDOW_STATE="${parent%/parent}/window" \
    FM_TEST_SESSION_ID=session-sm-1 PATH="$fakebin:$PATH" "$@"
}

test_local_secondmate_launch_and_resume() {
  local rec parent sub fakebin cli_home out status meta launch record token
  rec=$(make_fixture "$TMP_ROOT/local") || fail "local secondmate fixture failed"
  IFS='|' read -r parent sub fakebin cli_home <<EOF
$rec
EOF
  out=$(run_env "$parent" "$sub" "$fakebin" "$cli_home" "$SPAWN" traex-sm "$sub" traex \
    --secondmate --model GPT-5.6-Luna --effort high 2>&1)
  status=$?
  expect_code 0 "$status" "local TraeX secondmate spawn failed: $out"
  meta="$parent/state/traex-sm.meta"
  assert_grep 'kind=secondmate' "$meta" "secondmate kind was not recorded"
  assert_grep 'harness=traex' "$meta" "TraeX harness was not recorded"
  assert_grep "home=$sub" "$meta" "secondmate home was not recorded"
  assert_grep "traex_os_home=$parent/os-home" "$meta" "secondmate meta lost the authenticated OS home"
  assert_grep "traex_home=$parent/trae-runtime" "$meta" "secondmate meta lost the Trae runtime home"
  assert_grep "traex_cli_home=$cli_home" "$meta" "secondmate meta lost the authenticated CLI home"
  launch=$(grep 'FM_TRAEX_HARNESS=traex' "${parent%/parent}/tmux.log" | tail -1)
  assert_contains "$launch" "FM_HOME='$sub'" "secondmate launch did not select its isolated home"
  assert_contains "$launch" "HOME='$parent/os-home'" "secondmate launch did not retain the authenticated OS home"
  assert_contains "$launch" "TRAE_HOME='$parent/trae-runtime'" "secondmate launch did not retain the authenticated Trae runtime home"
  assert_contains "$launch" "TRAECLI_HOME='$cli_home'" "secondmate launch did not retain the authenticated CLI home"
  assert_contains "$launch" 'FM_SUPERVISION_MODEL=persistent' "TraeX secondmate did not use persistent supervision"
  assert_not_contains "$launch" 'turn-ended' "secondmate launch incorrectly referenced a parent turn marker"
  assert_present "$sub/.fm-traex-hook" "local secondmate primary pointer was not registered"
  assert_present "$parent/state/traex-sm.traex-hook-token" "parent did not retain binding teardown authority"
  token=$(cat "$parent/state/traex-sm.traex-hook-token")
  record="$cli_home/fm-firstmate-hooks.d/$token"
  assert_grep 'role=primary' "$record" "secondmate hook binding is not a primary binding"
  assert_grep "state_real=$sub/state" "$record" "secondmate hook binding points at parent state"
  assert_grep "fm_root_real=$sub" "$record" "secondmate hook binding points at parent code root"

  printf 'session_id=session-sm-1\nsource=startup\n' > "$sub/state/.traex-primary-session"
  printf '%s\n' zsh > "${parent%/parent}/mode"
  mkdir -p "${parent%/parent}/wrong-home" "${parent%/parent}/wrong-trae" "${parent%/parent}/wrong-cli"
  out=$(FM_TEST_AMBIENT_HOME="${parent%/parent}/wrong-home" \
    FM_TEST_AMBIENT_TRAE_HOME="${parent%/parent}/wrong-trae" \
    FM_TEST_AMBIENT_CLI_HOME="${parent%/parent}/wrong-cli" \
    run_env "$parent" "$sub" "$fakebin" "$cli_home" "$RESUME" traex-sm 2>&1)
  status=$?
  expect_code 0 "$status" "exact-session secondmate resume failed: $out"
  assert_contains "$out" 'resumed traex-sm session=session-sm-1' "resume did not confirm the recorded session"
  launch=$(grep ' resume -y ' "${parent%/parent}/tmux.log" | tail -1)
  assert_contains "$launch" "'session-sm-1'" "resume did not pin the recorded session id"
  assert_contains "$launch" "HOME='$parent/os-home'" "resume adopted the ambient OS home instead of recorded identity"
  assert_contains "$launch" "TRAE_HOME='$parent/trae-runtime'" "resume adopted the ambient Trae home instead of recorded identity"
  assert_contains "$launch" "TRAECLI_HOME='$cli_home'" "resume adopted the ambient CLI home instead of recorded identity"
  assert_not_contains "$launch" '--dangerously-bypass-hook-trust' "resume bypassed native hook trust"

  printf '%s\n' zsh > "${parent%/parent}/mode"
  if out=$(FM_TEST_SKIP_RESUME_CALLBACK=1 FM_TRAEX_RESUME_CONFIRM_TRIES=1 \
      run_env "$parent" "$sub" "$fakebin" "$cli_home" "$RESUME" traex-sm 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "resume accepted stale SessionStart evidence"
  assert_contains "$out" 'was not confirmed by SessionStart(source=resume)' \
    "stale resume refusal did not identify the missing fresh callback"

  out=$(FM_TEARDOWN_GUARD_DONE=1 \
    FM_TEST_AMBIENT_HOME="${parent%/parent}/wrong-home" \
    FM_TEST_AMBIENT_TRAE_HOME="${parent%/parent}/wrong-trae" \
    FM_TEST_AMBIENT_CLI_HOME="${parent%/parent}/wrong-cli" \
    run_env "$parent" "$sub" "$fakebin" "$cli_home" \
      "$ROOT/bin/fm-teardown.sh" traex-sm --force 2>&1)
  status=$?
  expect_code 0 "$status" "TraeX teardown under changed ambient roots failed: $out"
  assert_absent "$record" "teardown left the binding in the recorded TraeX registry"
  assert_absent "$parent/state/traex-sm.traex-hook-token" "teardown left parent binding authority"
  assert_absent "$sub" "teardown did not remove the local secondmate home"
  pass "TraeX local secondmate launch, fresh resume, and recorded-root teardown stay exact"
}

test_remote_route_refuses_before_remote_lifecycle() {
  local rec parent sub fakebin cli_home out status marker
  rec=$(make_fixture "$TMP_ROOT/remote") || fail "remote refusal fixture failed"
  IFS='|' read -r parent sub fakebin cli_home <<EOF
$rec
EOF
  mkdir -p "$parent/data"
  printf '%s\n' \
    '- traex-remote - excluded route (host: remote-host; root: /remote/firstmate; home: /remote/home; scope: excluded; projects: none; added 2026-08-08)' \
    > "$parent/data/secondmates.md"
  marker="${parent%/parent}/remote-called"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf called > "$FM_TEST_REMOTE_MARKER"
exit 99
SH
  chmod +x "$fakebin/ssh"
  if out=$(FM_TEST_REMOTE_MARKER="$marker" run_env "$parent" "$sub" "$fakebin" "$cli_home" \
      "$SPAWN" traex-remote traex --secondmate 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "remote TraeX secondmate route unexpectedly launched"
  assert_contains "$out" 'remote secondmate with harness=traex is excluded' "remote refusal did not name the excluded axis"
  assert_absent "$marker" "remote refusal reached SSH/readiness lifecycle"
  pass "TraeX remote secondmate refuses before remote readiness or Herdr lifecycle"
}

test_local_secondmate_launch_and_resume
test_remote_route_refuses_before_remote_lifecycle
