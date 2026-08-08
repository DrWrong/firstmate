#!/usr/bin/env bash
# Portable lifecycle regression for Firstmate's TraeX global hook adapter.
# The fake CLI reproduces only the public TraeX commands the adapter consumes;
# lifecycle behavior is exercised through the installed dispatcher and the
# public installer/preflight interfaces, never by sourcing private functions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-traex-hook-install.sh"
PREFLIGHT="$ROOT/bin/fm-traex-preflight.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-traex-hook)
SUPPORTED_SHA=e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581
REAL_SHA256SUM=$(command -v sha256sum 2>/dev/null || true)
[ -n "$REAL_SHA256SUM" ] || { echo 'skip: sha256sum not found'; exit 0; }

make_fake_cli() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
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
set -u
case "${1:-}" in
  --version)
    printf '%s\n' "${FM_TEST_TRAEX_VERSION:-traecli 0.200.19(internal edition)}"
    exit 0
    ;;
  login)
    [ "${2:-}" = status ] || exit 2
    case "${FM_TEST_LOGIN_MODE:-ready}" in
      ready) printf '%s\n' 'Logged in using Trae' >&2; exit 0 ;;
      not-ready) printf '%s\n' 'Not logged in' >&2; exit 0 ;;
      error) printf '%s\n' 'Logged in using Trae' >&2; exit 1 ;;
    esac
    exit 2
    ;;
  features)
    [ "${2:-}" = list ] || exit 2
    printf '%s\n' 'hooks stable true' 'plugin_hooks stable true'
    exit 0
    ;;
  models)
    [ "${2:-}" = --json ] || exit 2
    printf '%s\n' '[{"name":"GPT-5.6-Luna","provider":"trae"},{"name":"Catalog-Only","provider":"trae"}]'
    exit 0
    ;;
  exec)
    if [ -n "${FM_TEST_TRAEX_EXEC_BLOCK_DIR:-}" ]; then
      printf '%s\n' "$PWD" > "$FM_TEST_TRAEX_EXEC_BLOCK_DIR/project"
      while [ ! -e "$FM_TEST_TRAEX_EXEC_BLOCK_DIR/release" ]; do
        sleep 0.05
      done
      exit 91
    fi
    command=$(jq -r '.hooks.SessionStart[-1].hooks[0].command' "$TRAECLI_HOME/hooks.json")
    session=sess-probe-1
    turn=turn-probe-1
    for event in SessionStart UserPromptSubmit Stop SessionEnd; do
      source=null
      [ "$event" != SessionStart ] || source='"startup"'
      payload=$(jq -cn --arg event "$event" --arg session "$session" --arg turn "$turn" \
        --arg cwd "$PWD" --argjson source "$source" \
        '{hook_event_name:$event,session_id:$session,turn_id:$turn,cwd:$cwd,source:$source}')
      printf '%s' "$payload" | bash -c "$command" || exit $?
    done
    printf '%s\n' FIRSTMATE_TRAEX_PROBE
    exit 0
    ;;
esac
exit 2
SH
  chmod +x "$fakebin/sha256sum" "$fakebin/traex"
  printf '%s\n' "$fakebin"
}

setup_adapter() {  # <name>
  local name=$1 case_dir cli_home fakebin
  case_dir="$TMP_ROOT/$name"
  cli_home="$case_dir/cli"
  fakebin=$(make_fake_cli "$case_dir")
  mkdir -p "$cli_home"
  chmod 750 "$cli_home"
  printf '%s\n' '{"version":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"printf user-hook","timeout":7}]}]}}' \
    > "$cli_home/hooks.json"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$INSTALL" install >/dev/null || fail "$name: hook install failed"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$INSTALL" probe --model GPT-5.6-Luna >/dev/null \
    || fail "$name: trusted lifecycle probe failed"
  printf '%s|%s|%s\n' "$case_dir" "$cli_home" "$fakebin"
}

run_adapter() {  # <cli-home> <fakebin> <command...>
  local cli_home=$1 fakebin=$2
  shift 2
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$@"
}

payload() {  # <event> <cwd> [session] [turn] [source]
  jq -cn --arg event "$1" --arg cwd "$2" --arg session "${3:-sess-1}" \
    --arg turn "${4:-turn-1}" --arg source "${5:-}" \
    '{hook_event_name:$event,cwd:$cwd,session_id:$session,turn_id:$turn}
     + (if $source == "" then {} else {source:$source} end)'
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_install_merge_probe_and_preflight() {
  local rec case_dir cli_home fakebin config out hooks_mode hooks_sha external managed_command count event new_cli
  rec=$(setup_adapter install) || fail "install setup failed"
  IFS='|' read -r case_dir cli_home fakebin <<EOF
$rec
EOF
  jq -e '.hooks.Stop[0].hooks[0].command == "printf user-hook"' "$cli_home/hooks.json" >/dev/null \
    || fail "installer did not preserve the existing user hook"
  for event in SessionStart UserPromptSubmit Stop SessionEnd; do
    jq -e --arg event "$event" \
      'any(.hooks[$event][]; any(.hooks[]; .command | contains("fm-firstmate-hook.sh")))' \
      "$cli_home/hooks.json" >/dev/null || fail "installer omitted managed $event hook"
  done
  assert_present "$cli_home/fm-firstmate-receipt.json" "trusted probe did not create a receipt"
  [ "$(file_mode "$cli_home")" = 750 ] || fail "install changed the existing TRAECLI_HOME mode"
  new_cli="$case_dir/new-cli"
  TRAECLI_HOME="$new_cli" PATH="$fakebin:$PATH" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$INSTALL" install >/dev/null || fail "install could not create a private TRAECLI_HOME"
  [ "$(file_mode "$new_cli")" = 700 ] || fail "new TRAECLI_HOME was not created with mode 0700"

  managed_command=$(jq -r '[.. | objects | .command? | select(type == "string" and contains("fm-firstmate-hook.sh"))][0]' \
    "$cli_home/hooks.json")
  jq --arg command "$managed_command" '
    .hooks.Stop |= map(
      if any(.hooks[]; .command? == $command) then
        .hooks = ((.hooks | map(if .command? == $command then .timeout = 7 else . end))
          + [{type:"command",command:"printf preserved-sibling",timeout:9}])
      else . end)
  ' "$cli_home/hooks.json" > "$case_dir/hooks.modified"
  mv "$case_dir/hooks.modified" "$cli_home/hooks.json"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" install >/dev/null \
    || fail "reinstall over a modified managed entry failed"
  for event in SessionStart UserPromptSubmit Stop SessionEnd; do
    count=$(jq --arg event "$event" --arg command "$managed_command" \
      '[.hooks[$event][] | .hooks[] | select(.command? == $command)] | length' \
      "$cli_home/hooks.json")
    [ "$count" = 1 ] || fail "reinstall left $count managed $event commands"
    jq -e --arg event "$event" --arg command "$managed_command" \
      'any(.hooks[$event][]; .hooks == [{type:"command",command:$command,timeout:180}])' \
      "$cli_home/hooks.json" >/dev/null || fail "reinstall did not canonicalize $event"
  done
  jq -e 'any(.hooks.Stop[]; any(.hooks[]; .command? == "printf preserved-sibling"))' \
    "$cli_home/hooks.json" >/dev/null || fail "reinstall discarded a user hook sharing the modified entry"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" probe --model GPT-5.6-Luna >/dev/null \
    || fail "reinstall lifecycle probe failed"

  config="$case_dir/config"
  mkdir -p "$config"
  printf '%s\n' 'worker=on' 'primary=on' 'secondmate=on' > "$config/traex-adapter"
  out=$(run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker GPT-5.6-Luna xhigh) \
    || fail "valid worker preflight failed"
  [ "$out" = "$fakebin/traex" ] || fail "preflight printed '$out', expected canonical fake binary"
  if FM_TEST_LOGIN_MODE=not-ready run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" \
      "$config" worker GPT-5.6-Luna low >/dev/null 2>&1; then
    fail "exit-zero login status without the exact ready line opened preflight"
  fi
  if FM_TEST_LOGIN_MODE=error run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" \
      "$config" worker GPT-5.6-Luna low >/dev/null 2>&1; then
    fail "nonzero login status with ready-looking stderr opened preflight"
  fi
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker not-a-model low >/dev/null 2>&1; then
    fail "preflight accepted a model absent from TraeX's authenticated catalog"
  fi
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker Catalog-Only low >/dev/null 2>&1; then
    fail "preflight accepted a catalog-visible model without live model/effort evidence"
  fi
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker GPT-5.6-Luna ultra >/dev/null 2>&1; then
    fail "preflight accepted an unverified effort value"
  fi
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker default low >/dev/null 2>&1; then
    fail "preflight accepted a worker launch without an explicit model"
  fi
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker GPT-5.6-Luna default >/dev/null 2>&1; then
    fail "preflight accepted a worker launch without an explicit effort"
  fi
  run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" primary >/dev/null \
    || fail "receipt-only primary binding incorrectly required launch model/effort"
  printf '%s\n' 'worker=on' 'primary=off' 'secondmate=on' > "$config/traex-adapter"
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" secondmate GPT-5.6-Luna low >/dev/null 2>&1; then
    fail "secondmate preflight opened without the required primary gate"
  fi
  printf '%s\n' 'worker=on' 'primary=on' 'secondmate=off' > "$config/traex-adapter"
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" secondmate GPT-5.6-Luna low >/dev/null 2>&1; then
    fail "secondmate preflight opened while its own role gate was closed"
  fi
  printf '%s\n' 'worker=off' 'primary=on' 'secondmate=on' > "$config/traex-adapter"
  if run_adapter "$cli_home" "$fakebin" "$PREFLIGHT" "$config" worker GPT-5.6-Luna low >/dev/null 2>&1; then
    fail "closed worker gate did not fail closed"
  fi
  hooks_mode=$(file_mode "$cli_home/hooks.json")
  run_adapter "$cli_home" "$fakebin" "$INSTALL" remove >/dev/null \
    || fail "exact managed-hook removal failed"
  [ "$(file_mode "$cli_home/hooks.json")" = "$hooks_mode" ] \
    || fail "managed-hook removal changed the user's hooks.json mode"
  jq -e '.hooks.Stop[0].hooks[0].command == "printf user-hook"' "$cli_home/hooks.json" >/dev/null \
    || fail "managed-hook removal changed the existing user hook"
  if jq -e '[.. | strings | select(contains("fm-firstmate-hook.sh"))] | length > 0' \
      "$cli_home/hooks.json" >/dev/null; then
    fail "managed-hook removal left a Firstmate command"
  fi
  assert_absent "$cli_home/fm-firstmate-hook.sh" "managed-hook removal left the dispatcher"
  assert_absent "$cli_home/fm-firstmate-receipt.json" "managed-hook removal left the receipt"
  external="$case_dir/external-registry"
  mkdir "$external"
  ln -s "$external" "$cli_home/fm-firstmate-hooks.d"
  hooks_sha=$($REAL_SHA256SUM "$cli_home/hooks.json" | awk '{print $1}')
  if run_adapter "$cli_home" "$fakebin" "$INSTALL" remove >/dev/null 2>&1; then
    fail "managed-hook removal accepted a symlinked private registry"
  fi
  [ "$($REAL_SHA256SUM "$cli_home/hooks.json" | awk '{print $1}')" = "$hooks_sha" ] \
    || fail "unsafe-registry refusal changed hooks.json"
  [ -z "$(find "$external" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "unsafe-registry refusal wrote through the symlink"
  pass "TraeX installer merge-preserves user hooks and receipt/model/effort/role preflight fails closed"
}

test_interrupted_probe_cleans_binding_and_preserves_evidence() {
  local rec case_dir cli_home fakebin block pid status project lab token record tries=0
  rec=$(setup_adapter interrupted-probe) || fail "interrupted probe setup failed"
  IFS='|' read -r case_dir cli_home fakebin <<EOF
$rec
EOF
  block="$case_dir/block"
  mkdir -p "$block"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_EXEC_BLOCK_DIR="$block" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$INSTALL" probe --model GPT-5.6-Luna > "$case_dir/probe.out" 2> "$case_dir/probe.err" &
  pid=$!
  while [ ! -s "$block/project" ] && [ "$tries" -lt 200 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$block/project" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "blocking probe did not publish its project"; }
  project=$(cat "$block/project")
  lab=${project%/project}
  token=$(sed -n 's/^token=//p' "$project/.fm-traex-hook")
  record="$cli_home/fm-firstmate-hooks.d/$token"
  assert_present "$record" "probe did not publish its registry binding before execution"
  assert_present "$lab/state/probe-token" "probe did not publish its token state before execution"
  kill -TERM "$pid" || fail "could not interrupt the blocking probe"
  touch "$block/release"
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "interrupted probe exited successfully"
  assert_absent "$record" "interrupted probe left its registry binding"
  assert_absent "$lab/state/probe-token" "interrupted probe left its token state"
  assert_absent "$project/.fm-traex-hook" "interrupted probe left its worktree pointer"
  assert_present "$lab/traex.err" "interrupted probe discarded its diagnostic evidence"
  case "$lab" in /tmp/fm-traex-receipt.*) ;; *) fail "probe evidence path escaped its disposable namespace" ;; esac
  rm -rf "$lab"
  pass "Interrupted TraeX probe removes active binding and preserves evidence"
}

test_library_owned_binary_pin_renders_dispatcher() {
  local case_dir cli_home fakebin adapter_bin alternate_version alternate_sha state wt root home gen token_state dispatcher
  case_dir="$TMP_ROOT/pin-owner"
  cli_home="$case_dir/cli"
  adapter_bin="$case_dir/adapter/bin"
  fakebin=$(make_fake_cli "$case_dir")
  alternate_version='traecli 0.200.19(test-owner)'
  alternate_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$cli_home" "$adapter_bin"
  cp "$ROOT/bin/fm-traex-lib.sh" "$adapter_bin/fm-traex-lib.sh"
  cp "$ROOT/bin/fm-traex-hook-install.sh" "$adapter_bin/fm-traex-hook-install.sh"
  cp "$ROOT/bin/fm-traex-hook-dispatch.sh" "$adapter_bin/fm-traex-hook-dispatch.sh"
  sed -e "s|^FM_TRAEX_SUPPORTED_VERSION=.*|FM_TRAEX_SUPPORTED_VERSION='$alternate_version'|" \
    -e "s|^FM_TRAEX_SUPPORTED_SHA256=.*|FM_TRAEX_SUPPORTED_SHA256='$alternate_sha'|" \
    "$adapter_bin/fm-traex-lib.sh" > "$case_dir/fm-traex-lib.sh"
  mv "$case_dir/fm-traex-lib.sh" "$adapter_bin/fm-traex-lib.sh"
  chmod +x "$adapter_bin/fm-traex-hook-install.sh" "$adapter_bin/fm-traex-hook-dispatch.sh"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$cli_home/hooks.json"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_VERSION="$alternate_version" \
    FM_TEST_TRAEX_SHA="$alternate_sha" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$adapter_bin/fm-traex-hook-install.sh" install >/dev/null \
    || fail "library-owned binary pin did not render the installed dispatcher"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_VERSION="$alternate_version" \
    FM_TEST_TRAEX_SHA="$alternate_sha" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$adapter_bin/fm-traex-hook-install.sh" probe --model GPT-5.6-Luna >/dev/null \
    || fail "rendered dispatcher did not complete the native lifecycle probe"

  state="$case_dir/state"
  wt="$case_dir/worktree"
  root="$case_dir/root"
  home="$case_dir/home"
  gen=pin-owner-gen
  token_state="$state/pin-owner.traex-hook-token"
  mkdir -p "$state" "$wt" "$root" "$home"
  git -C "$wt" init -q
  printf '%s\n' "$gen" > "$state/pin-owner.busy-gen"
  printf '%s\n' 'harness=traex' "busy_gen=$gen" "worktree=$wt" > "$state/pin-owner.meta"
  TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_VERSION="$alternate_version" \
    FM_TEST_TRAEX_SHA="$alternate_sha" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    "$adapter_bin/fm-traex-hook-install.sh" register worker pin-owner "$wt" "$state" \
      "$root" "$home" "$gen" "$token_state" >/dev/null \
    || fail "library-owned binary pin could not register a worker binding"
  dispatcher="$cli_home/fm-firstmate-hook.sh"
  payload SessionStart "$wt" owner-session turn-unused startup \
    | TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" FM_TEST_TRAEX_VERSION="$alternate_version" \
      FM_TEST_TRAEX_SHA="$alternate_sha" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" "$dispatcher" \
    || fail "installed dispatcher retained a competing binary identity pin"
  [ "$(sed -n 's/^session_id=//p' "$state/pin-owner.traex-session")" = owner-session ] \
    || fail "rendered dispatcher did not accept its library-owned binary identity"
  pass "TraeX installed dispatcher consumes the library-owned binary identity"
}

test_worker_scope_busy_completion_and_failure_visibility() {
  local rec case_dir cli_home fakebin state wt root home gen token token_state dispatcher out status lines badgit key complete_count
  rec=$(setup_adapter worker) || fail "worker setup failed"
  IFS='|' read -r case_dir cli_home fakebin <<EOF
$rec
EOF
  state="$case_dir/state"
  wt="$case_dir/worktree"
  root="$case_dir/root"
  home="$case_dir/home"
  mkdir -p "$state" "$wt" "$root/bin" "$home"
  cp "$BUSY_EVENT" "$root/bin/fm-busy-event.sh"
  cp "$ROOT/bin/fm-busy-lib.sh" "$root/bin/fm-busy-lib.sh"
  cp "$ROOT/bin/fm-traex-lib.sh" "$root/bin/fm-traex-lib.sh"
  chmod +x "$root/bin/fm-busy-event.sh"
  git -C "$wt" init -q
  gen=$($BUSY_EVENT arm "$state" task-a)
  printf '%s\n' \
    'window=fm:task-a' 'endpoint_task_id=task-a' "worktree=$wt" "project=$wt" \
    'harness=traex' 'kind=ship' "busy_gen=$gen" > "$state/task-a.meta"
  token_state="$state/task-a.traex-hook-token"
  badgit="$case_dir/badgit"
  mkdir -p "$badgit"
  cat > "$badgit/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' relative/info/exclude
SH
  chmod +x "$badgit/git"
  if TRAECLI_HOME="$cli_home" PATH="$badgit:$fakebin:$PATH" \
      FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
      "$INSTALL" register worker task-a "$wt" "$state" "$root" "$home" "$gen" "$token_state" \
      >/dev/null 2>&1; then
    fail "binding registration accepted an unresolved git exclude path"
  fi
  assert_absent "$token_state" "failed exclude preparation published token state"
  assert_absent "$wt/.fm-traex-hook" "failed exclude preparation published a worktree pointer"
  [ -z "$(find "$cli_home/fm-firstmate-hooks.d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
    || fail "failed exclude preparation published a registry record"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" register worker task-a "$wt" "$state" "$root" "$home" "$gen" "$token_state" \
    || fail "worker binding registration failed"
  dispatcher="$cli_home/fm-firstmate-hook.sh"
  token=$(cat "$token_state")

  rm -f "$wt/.fm-traex-hook"
  if out=$(payload Stop "$wt" | run_adapter "$cli_home" "$fakebin" "$dispatcher" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" = 2 ] || fail "active binding with a missing pointer returned $status, expected 2"
  assert_contains "$out" 'lifecycle persistence failed (pointer)' \
    "missing active pointer did not fail closed at the pointer boundary"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" register worker task-a "$wt" "$state" "$root" "$home" "$gen" "$token_state" \
    || fail "idempotent registration did not restore a missing pointer"
  [ -f "$wt/.fm-traex-hook" ] && [ ! -L "$wt/.fm-traex-hook" ] \
    || fail "idempotent registration did not restore an owned regular pointer"
  [ "$(cat "$wt/.fm-traex-hook")" = "token=$token" ] \
    || fail "idempotent registration restored the wrong pointer payload"

  rm -f "$wt/.fm-traex-hook"
  ln -s "$token_state" "$wt/.fm-traex-hook"
  if out=$(payload Stop "$wt" | run_adapter "$cli_home" "$fakebin" "$dispatcher" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" = 2 ] || fail "active binding with a symlinked pointer returned $status, expected 2"
  assert_contains "$out" 'lifecycle persistence failed (pointer)' \
    "symlinked active pointer did not fail closed at the pointer boundary"
  if run_adapter "$cli_home" "$fakebin" "$INSTALL" register worker task-a "$wt" "$state" "$root" "$home" "$gen" "$token_state" \
      >/dev/null 2>&1; then
    fail "idempotent registration accepted a symlinked pointer"
  fi
  rm -f "$wt/.fm-traex-hook"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" register worker task-a "$wt" "$state" "$root" "$home" "$gen" "$token_state" \
    || fail "idempotent registration did not republish the pointer after safe repair"

  payload UserPromptSubmit "$wt" | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "UserPromptSubmit callback failed"
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" bash -c '. "$1"; fm_busy_record_read "$2" task-a' \
    _ "$ROOT/bin/fm-busy-lib.sh" "$state")
  [ "$out" = 'busy traex-hook user-prompt-submit 2' ] \
    || fail "UserPromptSubmit did not write semantic busy: $out"

  payload Stop "$wt" | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "Stop callback failed"
  payload Stop "$wt" | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "duplicate Stop callback failed"
  lines=$(wc -l < "$state/task-a.turn-ended" | tr -d ' ')
  [ "$lines" = 1 ] || fail "duplicate Stop was not idempotent (lines=$lines)"
  payload SessionEnd "$wt" sess-1 turn-exit | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "SessionEnd callback failed"
  lines=$(wc -l < "$state/task-a.turn-ended" | tr -d ' ')
  [ "$lines" = 2 ] || fail "distinct SessionEnd completion did not append durably"
  assert_grep 'event=SessionEnd' "$state/task-a.turn-ended" "SessionEnd completion evidence missing"

  payload UserPromptSubmit "$wt" sess-partial turn-partial | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "could not arm semantic busy for partial-completion recovery"
  key=$(printf '%s' "$gen|sess-partial|turn-partial|Stop" | "$REAL_SHA256SUM" | awk '{print substr($1,1,32)}')
  printf 'v1 gen=%s key=%s ' "$gen" "$key" >> "$state/task-a.turn-ended"
  payload Stop "$wt" sess-partial turn-partial | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "retry did not replace partial completion evidence durably"
  complete_count=$(awk -v gen_field="gen=$gen" -v key_field="key=$key" '
    $1 == "v1" && $2 == gen_field && $3 == key_field &&
      $4 ~ /^session=[0-9a-f]+$/ && length($4) == 24 &&
      $5 ~ /^turn=[0-9a-f]+$/ && length($5) == 21 &&
      $6 == "event=Stop" && $7 ~ /^seq=[0-9]+$/ &&
      $8 ~ /^ts=[0-9]+$/ && NF == 8 { count++ }
    END { print count + 0 }
  ' "$state/task-a.turn-ended")
  [ "$complete_count" = 1 ] \
    || fail "partial completion key was treated as a durable complete record"

  mkdir -p "$case_dir/unbound"
  payload Stop "$case_dir/unbound" | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "unbound TraeX session was not a silent no-op"

  mkdir -p "$case_dir/cross"
  cp "$wt/.fm-traex-hook" "$case_dir/cross/.fm-traex-hook"
  if out=$(payload Stop "$case_dir/cross" | run_adapter "$cli_home" "$fakebin" "$dispatcher" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" = 2 ] || fail "known-token cross-worktree callback returned $status, expected 2"
  assert_contains "$out" 'lifecycle persistence failed (cwd)' "matching callback failure was not bounded and visible"
  assert_not_contains "$out" 'sess-1' "matching failure leaked payload/session content"

  rm -f "$state/task-a.turn-ended"
  mkdir "$state/task-a.turn-ended"
  payload UserPromptSubmit "$wt" sess-2 turn-2 | run_adapter "$cli_home" "$fakebin" "$dispatcher" \
    || fail "could not restore semantic busy before completion failure"
  if out=$(payload Stop "$wt" sess-2 turn-2 | run_adapter "$cli_home" "$fakebin" "$dispatcher" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" = 2 ] || fail "matching persistence failure returned $status, expected 2"
  assert_contains "$out" 'completion-write' "matching persistence failure did not identify its bounded stage"
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
    FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" bash -c '. "$1"; fm_busy_record_read "$2" task-a' \
    _ "$ROOT/bin/fm-busy-lib.sh" "$state")
  case "$out" in
    'busy traex-hook user-prompt-submit '*) ;;
    *) fail "completion failure published idle before durable completion: $out" ;;
  esac
  rmdir "$state/task-a.turn-ended" || fail "could not clear completion-failure fixture"
  run_adapter "$cli_home" "$fakebin" "$INSTALL" unregister "$wt" "$token_state" \
    || fail "worker binding unregister failed"
  assert_absent "$wt/.fm-traex-hook" "unregister left the worktree pointer"
  assert_absent "$token_state" "unregister left parent token state"
  assert_absent "$cli_home/fm-firstmate-hooks.d/$token" "unregister left the private registry record"
  jq -e '.hooks.Stop[0].hooks[0].command == "printf user-hook"' "$cli_home/hooks.json" >/dev/null \
    || fail "task unregister changed a user hook"
  pass "TraeX worker callbacks are cwd/gen scoped, semantic, durable, idempotent, and fail visibly"
}

test_primary_session_start_and_stop_guard() {
  local rec case_dir cli_home fakebin state primary token_state dispatcher out status
  rec=$(setup_adapter primary) || fail "primary setup failed"
  IFS='|' read -r case_dir cli_home fakebin <<EOF
$rec
EOF
  primary="$case_dir/primary"
  state="$primary/state"
  mkdir -p "$primary/bin" "$primary/config" "$state"
  git -C "$primary" init -q
  printf '%s\n' 'worker=off' 'primary=on' 'secondmate=off' > "$primary/config/traex-adapter"
  cat > "$primary/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'SESSION_START_CONTEXT\n'
printf '%s\n' "$*" > "$FM_HOME/state/sessionstart.args"
SH
  cat > "$primary/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(dd bs=65537 count=1 2>/dev/null || true)
printf '%s' "$payload" > "$FM_HOME/state/guard.payload"
printf 'continue supervised work\n' >&2
exit 2
SH
  chmod +x "$primary/bin/fm-sessionstart-run.sh" "$primary/bin/fm-turnend-guard.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_id}'*) printf '%s\n' '%9' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  token_state="$state/.traex-primary-hook-token"
  if out=$(env -u TMUX -u TMUX_PANE TRAECLI_HOME="$cli_home" PATH="$fakebin:$PATH" \
      FM_TEST_TRAEX_SHA="$SUPPORTED_SHA" FM_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
      "$INSTALL" bind-primary "$primary" "$primary" 2>&1); then
    fail "primary binding succeeded outside tmux"
  fi
  assert_contains "$out" 'requires the current process to run inside tmux' \
    "plain-terminal primary refusal did not identify the tmux boundary"
  assert_absent "$token_state" "plain-terminal primary refusal published a token"
  TMUX=fake TMUX_PANE=%9 run_adapter "$cli_home" "$fakebin" \
    "$INSTALL" bind-primary "$primary" "$primary" >/dev/null \
    || fail "tmux primary binding failed"
  dispatcher="$cli_home/fm-firstmate-hook.sh"

  out=$(payload SessionStart "$primary" primary-session turn-unused resume \
    | run_adapter "$cli_home" "$fakebin" "$dispatcher") || fail "primary SessionStart routing failed"
  [ "$out" = SESSION_START_CONTEXT ] || fail "SessionStart stdout did not reach the caller/model context"
  [ "$(cat "$state/sessionstart.args")" = '--source resume' ] \
    || fail "SessionStart source was not routed exactly: $(cat "$state/sessionstart.args")"
  [ "$(sed -n 's/^session_id=//p' "$state/.traex-primary-session")" = primary-session ] \
    || fail "primary session identity was not persisted"

  if out=$(payload Stop "$primary" primary-session primary-turn \
      | run_adapter "$cli_home" "$fakebin" "$dispatcher" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" = 2 ] || fail "primary Stop guard returned $status, expected TraeX continuation status 2"
  assert_contains "$out" 'continue supervised work' "primary Stop guard feedback was not preserved"
  jq -e '.hook_event_name == "Stop" and .session_id == "primary-session"' "$state/guard.payload" >/dev/null \
    || fail "primary Stop payload was not delivered intact to the guard"
  pass "TraeX primary SessionStart stdout and Stop exit-2 supervision route through authoritative owners"
}

test_install_merge_probe_and_preflight
test_interrupted_probe_cleans_binding_and_preserves_evidence
test_library_owned_binary_pin_renders_dispatcher
test_worker_scope_busy_completion_and_failure_visibility
test_primary_session_start_and_stop_guard
