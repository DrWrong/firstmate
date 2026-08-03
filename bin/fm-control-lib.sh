#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables and nothing else. It has no side
# effects, runs no backend command, and reads no state, so it can be sourced
# by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, and which command exits the agent. These are
#      the empirically verified facts previously carried only in the
#      harness-adapters skill's per-adapter tables; that skill now points here
#      so one executable owner holds them.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) return 0 ;;
  esac
  return 1
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|kimi) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|grok|kimi) printf '1' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi) printf '/exit' ;;
    codex|pi|pi-signed) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter and Ctrl+C; Orca's terminal API exposes only an interrupt
# and an Enter, so it cannot deliver Escape at all
# (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_auth_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-} token
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) token=$(cat "$state/$id.grok-turnend-token" 2>/dev/null || true) ;;
    kimi) token=$(cat "$state/$id.kimi-turnend-token" 2>/dev/null || true) ;;
    *) return 0 ;;
  esac
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
  esac
}

# Remove every per-task wiring artifact <harness> owns for <id>. Used by a
# relaunch before the new incarnation is armed, and by teardown. Removal is
# best-effort and idempotent: an absent artifact is already in the wanted
# state, so this never fails a caller that is otherwise succeeding.
fm_control_clear_harness_wiring() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-} path
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f "$path" 2>/dev/null || true
  done <<EOF
$(fm_control_harness_turnend_auth_path "$harness" "$state" "$id")
$(fm_control_harness_wiring_paths "$harness" "$wt" "$state" "$id")
EOF
  return 0
}
