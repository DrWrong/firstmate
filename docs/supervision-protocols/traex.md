Mode: TraeX foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_TRAEX_WATCH_CHECKPOINT:-180}"`.
4. If it prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle the wake, then start the next checkpoint.
5. If it prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to TraeX, then start the next checkpoint.
6. Never use shell `&` or an untracked detached process for Firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as TraeX's normal supervision command.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

TraeX 0.200.19 has no live-verified background-task completion surface that can reawaken the model reliably. The bounded foreground checkpoint returns control regularly. Its native, trusted Stop hook is the backstop: if a turn tries to end while work needs supervision and no watcher is healthy, `bin/fm-turnend-guard.sh` exits 2 with a repair instruction and TraeX continues the same turn once, bounded by `stop_hook_active`.
