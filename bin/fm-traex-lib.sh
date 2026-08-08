#!/usr/bin/env bash
# Shared TraeX adapter facts and fail-closed preflight.
#
# This file is the single owner of the supported binary identity, explicit
# role gates, receipt validation, authenticated catalog check, and accepted
# Firstmate effort vocabulary for TraeX. It is sourced by fm-spawn and the
# TraeX maintenance/control commands; sourcing it has no side effects.

FM_TRAEX_ADAPTER_PROTOCOL=v1
FM_TRAEX_SUPPORTED_VERSION='traecli 0.200.19(internal edition)'
FM_TRAEX_SUPPORTED_SHA256='e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581'
FM_TRAEX_SUPPORTED_MODEL='GPT-5.6-Luna'

fm_traex_sha256() {  # <regular-file>
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Cheap structural identity for the already SHA-256-verified binary. Device,
# inode, size, mtime, and ctime detect replacement and in-place rewrites (ctime
# cannot be restored by an unprivileged owner), so the busy classifier need not
# hash a roughly 300 MB executable on every watcher fold.
fm_traex_file_identity() {  # <regular-file>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%z:%m:%c' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%s:%Y:%Z:%y:%z' "$1" 2>/dev/null
  fi
}

fm_traex_real_file() {  # <path>
  local path=$1 real dir
  [ -f "$path" ] || return 1
  if command -v realpath >/dev/null 2>&1; then
    real=$(realpath "$path" 2>/dev/null) || return 1
  elif real=$(readlink -f "$path" 2>/dev/null); then
    :
  else
    [ ! -L "$path" ] || return 1
    dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
    real=$dir/$(basename -- "$path")
  fi
  [ -f "$real" ] && [ ! -L "$real" ] || return 1
  printf '%s\n' "$real"
}

fm_traex_binary() {
  local candidate
  candidate=$(command -v traex 2>/dev/null || true)
  [ -n "$candidate" ] || {
    printf 'error: TraeX adapter requires an executable traex on PATH\n' >&2
    return 1
  }
  fm_traex_real_file "$candidate" || {
    printf 'error: TraeX binary must resolve to a regular non-symlink file: %s\n' "$candidate" >&2
    return 1
  }
}

fm_traex_os_home() {
  local home=${HOME:-}
  case "$home" in /*) ;; *) printf 'error: TraeX adapter requires an absolute HOME\n' >&2; return 1 ;; esac
  printf '%s\n' "$home"
}

fm_traex_runtime_home() {
  local home
  if [ -n "${TRAE_HOME:-}" ]; then
    home=$TRAE_HOME
  else
    home=$(fm_traex_os_home) || return 1
    home=$home/.trae
  fi
  case "$home" in /*) ;; *) printf 'error: TRAE_HOME must be absolute: %s\n' "$home" >&2; return 1 ;; esac
  printf '%s\n' "$home"
}

fm_traex_cli_home() {
  local home
  if [ -n "${TRAECLI_HOME:-}" ]; then
    home=$TRAECLI_HOME
  elif [ -n "${HOME:-}" ]; then
    home=$HOME/.trae/cli
  else
    printf 'error: cannot resolve TRAECLI_HOME because HOME is unset\n' >&2
    return 1
  fi
  case "$home" in /*) ;; *) printf 'error: TRAECLI_HOME must be absolute: %s\n' "$home" >&2; return 1 ;; esac
  printf '%s\n' "$home"
}

fm_traex_hooks_path() {
  local home
  home=$(fm_traex_cli_home) || return 1
  printf '%s/hooks.json\n' "$home"
}

fm_traex_dispatcher_path() {
  local home
  home=$(fm_traex_cli_home) || return 1
  printf '%s/fm-firstmate-hook.sh\n' "$home"
}

fm_traex_registry_dir() {
  local home
  home=$(fm_traex_cli_home) || return 1
  printf '%s/fm-firstmate-hooks.d\n' "$home"
}

fm_traex_receipt_path() {
  local home
  home=$(fm_traex_cli_home) || return 1
  printf '%s/fm-firstmate-receipt.json\n' "$home"
}

fm_traex_snapshot_path() {  # <state-dir> <task-id>
  printf '%s/%s.traex-receipt\n' "$1" "$2"
}

fm_traex_snapshot_field() {  # <snapshot> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

# Record the exact locally verifiable receipt material for one task. The busy
# classifier checks this cheap snapshot on every fold, so config/dispatcher/
# binary drift turns an old idle record into unknown immediately.
fm_traex_snapshot_write() {  # <state-dir> <task-id>
  local state=$1 id=$2 target tmp receipt hooks dispatcher binary verified_binary old_umask status
  local os_home runtime_home cli_home receipt_sha hooks_sha dispatcher_sha binary_sha binary_identity identity_after
  os_home=$(fm_traex_os_home) || return 1
  runtime_home=$(fm_traex_runtime_home) || return 1
  cli_home=$(fm_traex_cli_home) || return 1
  receipt=$(fm_traex_receipt_path) || return 1
  hooks=$(fm_traex_hooks_path) || return 1
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  binary=$(fm_traex_binary) || return 1
  binary_identity=$(fm_traex_file_identity "$binary") || return 1
  # Re-verify at snapshot time rather than assuming the earlier spawn preflight
  # is still current. This closes the preflight-to-binding race without making
  # the later busy-state hot path hash the large binary.
  verified_binary=$(fm_traex_receipt_verify) || return 1
  [ "$verified_binary" = "$binary" ] || return 1
  receipt_sha=$(fm_traex_sha256 "$receipt") || return 1
  hooks_sha=$(fm_traex_sha256 "$hooks") || return 1
  dispatcher_sha=$(fm_traex_sha256 "$dispatcher") || return 1
  binary_sha=$FM_TRAEX_SUPPORTED_SHA256
  identity_after=$(fm_traex_file_identity "$binary") || return 1
  [ "$identity_after" = "$binary_identity" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ "$hooks_sha" = "$(jq -r '.hooks_sha256' "$receipt" 2>/dev/null)" ] || return 1
  [ "$dispatcher_sha" = "$(jq -r '.dispatcher_sha256' "$receipt" 2>/dev/null)" ] || return 1
  [ "$receipt_sha" = "$(fm_traex_sha256 "$receipt" 2>/dev/null)" ] || return 1
  for status in "$receipt_sha" "$hooks_sha" "$dispatcher_sha" "$binary_sha"; do
    case "$status" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#status}" -eq 64 ] || return 1
  done
  target=$(fm_traex_snapshot_path "$state" "$id")
  tmp=$target.tmp.$$
  old_umask=$(umask); umask 077
  {
    printf 'protocol=%s\n' "$FM_TRAEX_ADAPTER_PROTOCOL"
    printf 'traex_os_home=%s\n' "$os_home"
    printf 'traex_home=%s\n' "$runtime_home"
    printf 'traex_cli_home=%s\n' "$cli_home"
    printf 'receipt=%s\n' "$receipt"
    printf 'receipt_sha256=%s\n' "$receipt_sha"
    printf 'hooks=%s\n' "$hooks"
    printf 'hooks_sha256=%s\n' "$hooks_sha"
    printf 'dispatcher=%s\n' "$dispatcher"
    printf 'dispatcher_sha256=%s\n' "$dispatcher_sha"
    printf 'binary=%s\n' "$binary"
    printf 'binary_sha256=%s\n' "$binary_sha"
    printf 'binary_identity=%s\n' "$binary_identity"
  } > "$tmp" && mv -f "$tmp" "$target"
  status=$?
  umask "$old_umask"
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

fm_traex_snapshot_valid() {  # <state-dir> <task-id>
  local snapshot meta path expected key identity os_home runtime_home cli_home
  snapshot=$(fm_traex_snapshot_path "$1" "$2")
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
  meta=$1/$2.meta
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_traex_snapshot_field "$snapshot" protocol 2>/dev/null)" = "$FM_TRAEX_ADAPTER_PROTOCOL" ] || return 1
  os_home=$(fm_traex_snapshot_field "$snapshot" traex_os_home) || return 1
  runtime_home=$(fm_traex_snapshot_field "$snapshot" traex_home) || return 1
  cli_home=$(fm_traex_snapshot_field "$snapshot" traex_cli_home) || return 1
  case "$os_home" in /*) ;; *) return 1 ;; esac
  case "$runtime_home" in /*) ;; *) return 1 ;; esac
  case "$cli_home" in /*) ;; *) return 1 ;; esac
  [ "$os_home" = "$(fm_traex_snapshot_field "$meta" traex_os_home 2>/dev/null)" ] || return 1
  [ "$runtime_home" = "$(fm_traex_snapshot_field "$meta" traex_home 2>/dev/null)" ] || return 1
  [ "$cli_home" = "$(fm_traex_snapshot_field "$meta" traex_cli_home 2>/dev/null)" ] || return 1
  for key in receipt hooks dispatcher binary; do
    path=$(fm_traex_snapshot_field "$snapshot" "$key") || return 1
    case "$path" in /*) ;; *) return 1 ;; esac
    case "$key" in
      receipt) [ "$path" = "$cli_home/fm-firstmate-receipt.json" ] || return 1 ;;
      hooks) [ "$path" = "$cli_home/hooks.json" ] || return 1 ;;
      dispatcher) [ "$path" = "$cli_home/fm-firstmate-hook.sh" ] || return 1 ;;
      binary) ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    expected=$(fm_traex_snapshot_field "$snapshot" "${key}_sha256") || return 1
    case "$expected" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#expected}" -eq 64 ] || return 1
    if [ "$key" = binary ]; then
      [ "$expected" = "$FM_TRAEX_SUPPORTED_SHA256" ] || return 1
      identity=$(fm_traex_snapshot_field "$snapshot" binary_identity) || return 1
      [ -n "$identity" ] && [ "$(fm_traex_file_identity "$path" 2>/dev/null)" = "$identity" ] || return 1
    else
      [ "$(fm_traex_sha256 "$path" 2>/dev/null)" = "$expected" ] || return 1
    fi
  done
}

# config/traex-adapter is deliberately role-separated. Every key defaults off;
# only one exact `key=on` opens it. Unknown keys, duplicate keys, unsafe files,
# and malformed values are errors rather than implicit disablement so an
# operator can distinguish a typo from a deliberate closed gate.
fm_traex_gate_enabled() {  # <config-dir> <worker|primary|secondmate>
  local config=$1 wanted=$2 file line key value wanted_on=0
  local seen_worker=0 seen_primary=0 seen_secondmate=0
  case "$wanted" in worker|primary|secondmate) ;; *) return 2 ;; esac
  file=$config/traex-adapter
  [ -f "$file" ] && [ ! -L "$file" ] || {
    printf 'error: TraeX %s gate is closed; create %s with %s=on after native hook trust and receipt verification\n' "$wanted" "$file" "$wanted" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in '# '*) continue ;; '#'*) continue ;; esac
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) printf 'error: malformed TraeX adapter gate line in %s: %s\n' "$file" "$line" >&2; return 1 ;; esac
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$key" in
      worker) [ "$seen_worker" -eq 0 ] || { printf 'error: duplicate TraeX gate key worker in %s\n' "$file" >&2; return 1; }; seen_worker=1 ;;
      primary) [ "$seen_primary" -eq 0 ] || { printf 'error: duplicate TraeX gate key primary in %s\n' "$file" >&2; return 1; }; seen_primary=1 ;;
      secondmate) [ "$seen_secondmate" -eq 0 ] || { printf 'error: duplicate TraeX gate key secondmate in %s\n' "$file" >&2; return 1; }; seen_secondmate=1 ;;
      *) printf 'error: unknown TraeX adapter gate key %s in %s\n' "$key" "$file" >&2; return 1 ;;
    esac
    case "$value" in on|off) ;; *) printf 'error: TraeX adapter gate %s must be on or off in %s\n' "$key" "$file" >&2; return 1 ;; esac
    if [ "$key" = "$wanted" ] && [ "$value" = on ]; then
      wanted_on=1
    fi
  done < "$file"
  if [ "$wanted_on" = 1 ]; then
    return 0
  fi
  printf 'error: TraeX %s gate is closed in %s\n' "$wanted" "$file" >&2
  return 1
}

fm_traex_receipt_verify() {  # prints resolved binary on success
  local receipt hooks dispatcher binary version binary_sha hooks_sha dispatcher_sha
  command -v jq >/dev/null 2>&1 || { printf 'error: TraeX adapter requires jq\n' >&2; return 1; }
  receipt=$(fm_traex_receipt_path) || return 1
  hooks=$(fm_traex_hooks_path) || return 1
  dispatcher=$(fm_traex_dispatcher_path) || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
    printf 'error: TraeX trust receipt is missing at %s; run bin/fm-traex-hook-install.sh install, review hooks in TraeX, then run its probe command\n' "$receipt" >&2
    return 1
  }
  [ -f "$hooks" ] && [ ! -L "$hooks" ] || { printf 'error: TraeX hooks config is missing or unsafe: %s\n' "$hooks" >&2; return 1; }
  [ -x "$dispatcher" ] && [ -f "$dispatcher" ] && [ ! -L "$dispatcher" ] || { printf 'error: TraeX Firstmate dispatcher is missing or unsafe: %s\n' "$dispatcher" >&2; return 1; }
  jq -e --arg protocol "$FM_TRAEX_ADAPTER_PROTOCOL" --arg version "$FM_TRAEX_SUPPORTED_VERSION" --arg sha "$FM_TRAEX_SUPPORTED_SHA256" '
    type == "object"
    and .protocol == $protocol
    and .version == $version
    and .binary_sha256 == $sha
    and (.binary_path | type == "string" and startswith("/"))
    and (.hooks_sha256 | strings | test("^[0-9a-f]{64}$"))
    and (.dispatcher_sha256 | strings | test("^[0-9a-f]{64}$"))
    and (.probe_nonce_sha256 | strings | test("^[0-9a-f]{64}$"))
    and .events == ["SessionStart","UserPromptSubmit","Stop","SessionEnd"]
    and (.completed_at | type == "number")
  ' "$receipt" >/dev/null 2>&1 || { printf 'error: TraeX trust receipt is malformed or unsupported: %s\n' "$receipt" >&2; return 1; }
  binary=$(fm_traex_binary) || return 1
  [ "$binary" = "$(jq -r '.binary_path' "$receipt")" ] || { printf 'error: TraeX binary path drifted since trust receipt; re-install, review, and probe\n' >&2; return 1; }
  binary_sha=$(fm_traex_sha256 "$binary") || { printf 'error: cannot hash TraeX binary\n' >&2; return 1; }
  [ "$binary_sha" = "$FM_TRAEX_SUPPORTED_SHA256" ] || { printf 'error: TraeX binary hash is not live-verified for this adapter: %s\n' "$binary_sha" >&2; return 1; }
  [ "$binary_sha" = "$(jq -r '.binary_sha256' "$receipt")" ] || { printf 'error: TraeX binary hash drifted since trust receipt; re-install, review, and probe\n' >&2; return 1; }
  version=$("$binary" --version 2>/dev/null || true)
  [ "$version" = "$FM_TRAEX_SUPPORTED_VERSION" ] || { printf 'error: TraeX version is not supported: %s\n' "${version:-unreadable}" >&2; return 1; }
  hooks_sha=$(fm_traex_sha256 "$hooks") || { printf 'error: cannot hash TraeX hooks config\n' >&2; return 1; }
  [ "$hooks_sha" = "$(jq -r '.hooks_sha256' "$receipt")" ] || { printf 'error: TraeX hooks config changed after trust; review hooks natively and rerun the receipt probe\n' >&2; return 1; }
  dispatcher_sha=$(fm_traex_sha256 "$dispatcher") || { printf 'error: cannot hash TraeX dispatcher\n' >&2; return 1; }
  [ "$dispatcher_sha" = "$(jq -r '.dispatcher_sha256' "$receipt")" ] || { printf 'error: TraeX dispatcher changed after trust; reinstall and rerun the receipt probe\n' >&2; return 1; }
  if ! fm_traex_login_ready "$binary"; then
    printf 'error: TraeX is not logged in; run traex login before dispatch\n' >&2
    return 1
  fi
  if ! "$binary" features list 2>/dev/null | awk '$1 == "hooks" && $2 == "stable" && $3 == "true" { ok=1 } END { exit !ok }'; then
    printf 'error: TraeX hooks feature is not stable and enabled on the installed binary\n' >&2
    return 1
  fi
  printf '%s\n' "$binary"
}

fm_traex_model_supported() {  # <binary> <model>
  local catalog
  [ -n "$2" ] && [ "$2" != default ] || {
    printf 'error: TraeX worker and secondmate launches require an explicit live-verified model\n' >&2
    return 1
  }
  [ "$2" = "$FM_TRAEX_SUPPORTED_MODEL" ] || {
    printf 'error: TraeX model/effort behavior is not live-verified for this adapter: %s\n' "$2" >&2
    return 1
  }
  catalog=$("$1" models --json 2>/dev/null) || {
    printf 'error: TraeX model catalog is unavailable; refusing to guess model support\n' >&2
    return 1
  }
  printf '%s' "$catalog" | jq -e --arg model "$2" 'type == "array" and any(.[]; .name == $model)' >/dev/null 2>&1 || {
    printf 'error: model is not present in the authenticated TraeX catalog: %s\n' "$2" >&2
    return 1
  }
}

fm_traex_effort_supported() {  # <model> <effort>
  [ "$1" = "$FM_TRAEX_SUPPORTED_MODEL" ] || {
    printf 'error: TraeX effort matrix is not live-verified for model: %s\n' "${1:-default}" >&2
    return 1
  }
  case "${2:-}" in low|medium|high|xhigh|max) return 0 ;; esac
  printf 'error: TraeX launches require an explicit live-verified effort (low, medium, high, xhigh, or max): %s\n' "${2:-default}" >&2
  return 1
}

# Real traecli 0.200.19 writes both its temporary-home advisory and the
# successful `Logged in using Trae` status line to stderr. Require exit 0 and
# one exact status line from the combined output; checking stdout alone makes a
# valid copied auth root look logged out, while substring matching could accept
# an unrelated warning.
fm_traex_login_ready() {  # <binary>
  local output status
  if output=$("$1" login status 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -Fxq 'Logged in using Trae'
}

fm_traex_preflight() {  # <config-dir> <worker|primary|secondmate> [model] [effort]
  local config=$1 role=$2 model=${3:-} effort=${4:-} binary
  fm_traex_gate_enabled "$config" "$role" || return 1
  if [ "$role" = secondmate ]; then
    fm_traex_gate_enabled "$config" primary || return 1
  fi
  binary=$(fm_traex_receipt_verify) || return 1
  # A primary binding only wires the already-running process's lifecycle
  # hooks, so its model/effort are outside this command's launch authority.
  # Every process Firstmate itself launches (worker/scout/local secondmate)
  # must name one exact live-verified model/effort pair.
  if [ "$role" != primary ] || [ -n "$model$effort" ]; then
    fm_traex_model_supported "$binary" "$model" || return 1
    fm_traex_effort_supported "$model" "$effort" || return 1
  fi
  printf '%s\n' "$binary"
}
