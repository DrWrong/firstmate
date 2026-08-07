#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity changes preserve
# Codex's bounded foreground-checkpoint supervision path.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
STOP_PROJECT="$LAB/stop-project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
STOP_TRANSCRIPT="$LAB/codex-stop.jsonl"
CODEX_VERSION=$(codex --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

git clone -q "$ROOT" "$STOP_PROJECT"
cat > "$STOP_PROJECT/.codex/repeated-stop-e2e.sh" <<'SH'
#!/usr/bin/env bash
set -u
root=$(pwd -P)
payload=$(cat)
printf '%s\n' "$payload" >> "$root/.codex/stop-payloads.jsonl"
count=$(wc -l < "$root/.codex/stop-payloads.jsonl" | tr -d '[:space:]')
if [ "$count" -lt 3 ]; then
  printf 'CODEX_REPEAT_STOP_%s: reply with exactly CONTINUATION%s and stop again without tools\n' "$count" "$count" >&2
  exit 2
fi
exit 0
SH
chmod +x "$STOP_PROJECT/.codex/repeated-stop-e2e.sh"
cat > "$STOP_PROJECT/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc 'exec \"$(pwd -P)/.codex/repeated-stop-e2e.sh\"'",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
JSON

(
  cd "$STOP_PROJECT" || exit 1
  codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    'Reply with exactly INITIAL and stop. Follow any Stop hook feedback literally.'
) > "$STOP_TRANSCRIPT" 2>&1 || fail "Codex repeated Stop-hook turn failed: $(tail -20 "$STOP_TRANSCRIPT")"

[ "$(wc -l < "$STOP_PROJECT/.codex/stop-payloads.jsonl" | tr -d '[:space:]')" = 3 ] \
  || fail "Codex did not honor exactly two consecutive Stop blocks: $(cat "$STOP_PROJECT/.codex/stop-payloads.jsonl" 2>/dev/null)"
jq -se 'length == 3 and .[0].stop_hook_active == false and .[1].stop_hook_active == true and .[2].stop_hook_active == true' \
  "$STOP_PROJECT/.codex/stop-payloads.jsonl" >/dev/null \
  || fail "Codex Stop payloads did not preserve false -> true -> true continuation history"

printf 'ok - %s live E2E preserved the foreground checkpoint and honored two consecutive Stop blocks\n' "$CODEX_VERSION"
