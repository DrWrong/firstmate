#!/usr/bin/env bash
# Public fail-closed TraeX adapter preflight.
# Usage: fm-traex-preflight.sh <config-dir> <worker|primary|secondmate> [model] [effort]
# Success prints the canonical supported binary path; failure creates no endpoint.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-traex-lib.sh
. "$SCRIPT_DIR/fm-traex-lib.sh"

[ "$#" -ge 2 ] && [ "$#" -le 4 ] || {
  printf 'usage: %s <config-dir> <worker|primary|secondmate> [model] [effort]\n' "${0##*/}" >&2
  exit 2
}
fm_traex_preflight "$1" "$2" "${3:-}" "${4:-}"
