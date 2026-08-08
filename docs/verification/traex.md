# TraeX adapter verification

Audience: maintainer verification.

This record supports the feature-gated TraeX adapter described in [`configuration.md`](../configuration.md#traex-adapter). It is version-scoped evidence, not a broader compatibility claim. The current supported set is ordinary workers, scouts, the Firstmate primary, and a local tmux secondmate. Remote secondmates and the Herdr, zellij, Orca, and cmux backends remain excluded.

## Binary and isolated lab

The complete live lifecycle pass ran on 2026-08-08 against the real installed executable resolved from `/data00/home/chengyuhang/.local/bin/traex`:

```text
version: traecli 0.200.19(internal edition)
sha256: e7e194f1a748ecb899f955028f3611048e2760de51f135ef2b49dbaa71331581
authenticated model: GPT-5.6-Luna
```

The lab used disposable root `/tmp/fm-traex-probe.20260808-1330-a6`, a private TraeX CLI home, a separate disposable runtime home, and a dedicated tmux socket/session containing one control window plus exact target windows. It neither read nor wrote the active Firstmate operational home and never addressed an existing tmux session. Exact target cleanup left the control window alive.

The probe script was created as one untracked file with `apply_patch`; paths and nonces entered through positional parameters or environment variables. It passed `bash -n` and ShellCheck before execution and was removed with `apply_patch` afterward. This is the required shape for future live refreshes: do not rebuild a multilayer probe inside one shell command.

## Trust: construction failures are not hook semantics

The failed evidence directory `/tmp/fm-traex-hook-check.OtGliR` is intentionally preserved. That earlier attempt contained an outer-shell quoting/construction failure. Its absent callback output is therefore not evidence that a correctly installed hook was rejected, undiscovered, or untrusted.

The later correctly structured isolated lab established the separate semantic result. With four valid user hook entries present, TraeX displayed:

```text
Hooks need review
4 hooks are new or changed.
Continue without trusting (hooks won't run)
```

At that point the hook had been discovered but did not execute automatically. Only after accepting the entries through TraeX's own native review UI did callbacks run. No probe used `--dangerously-bypass-hook-trust`, and no probe edited the private trust store. Maintainers must preserve this distinction: shell quoting failure establishes nothing about trust; the valid UI observation proves discovery without auto-execution before native approval.

## Lifecycle and blocking

The accepted-hook run recorded two `SessionStart`, five `UserPromptSubmit`, five `Stop`, and two `SessionEnd` callbacks. The native source vocabulary included `startup` and `resume`. The resumed process carried the same session id as the original process.

The Stop counterfactual returned exit status 2 with bounded feedback. TraeX kept the same turn id, called the hook first with `stop_hook_active=false`, delivered the feedback to the model, then called it with `stop_hook_active=true`. It started no resume process. This proves direct blocking for the primary turn-end guard and the required one-continuation bound.

`SessionStart` stdout was visible in model context: the model returned the nonce supplied only by hook stdout. `/exit` emitted `SessionEnd` and returned to the shell. Foreign-session callbacks were also present in the user-level stream, proving that event name alone is insufficient and motivating the adapter's cwd, opaque pointer, private record, uid, task, generation, root, home, and receipt checks.

## Login-status channel counterfactual

Two initially failed adapter-level labs are preserved at `/tmp/fm-traex-live.vfeOMHOo` and `/tmp/fm-traex-live.SqejwzHq`. Both used these exact relationships, with the lab basename varying:

```text
HOME=/tmp/fm-traex-live.<id>/home
TRAE_HOME=/tmp/fm-traex-live.<id>/trae
TRAECLI_HOME=/tmp/fm-traex-live.<id>/cli
auth source=/tmp/fm-traex-probe.20260808-1330-a6/cli/auth.json
auth sha256=8cbfeb939de61094ad87948130ac68dfb316ec2ba8b1857888f273f9da2b9d99
```

The adapter reported `TraeX is not logged in`, while a later terminal read appeared successful. A focused isolated counterfactual on 2026-08-08 separated output channel, root selection, and process timing. Every row launched a new real `traex login status` process with ambient API-key variables removed. The exact `TRAECLI_HOME` was ready immediately before directory trust, at the directory-trust prompt, at the hook-trust prompt, while the TUI was live, and on the first read after clean exit. Every exact-root process returned 0 with empty stdout and the exact line `Logged in using Trae` on stderr. A sibling `TRAECLI_HOME` with no copied `auth.json` returned 1 and `Not logged in`. The auth hash stayed unchanged.

The original adapter checked only stdout, and its fake CLI printed the success line there, so this deterministic output-channel mismatch looked like a timing race. It was neither credential propagation delay nor a stale process snapshot. `fm_traex_login_ready` now requires both exit status 0 and one exact success line from combined output; portable negatives cover exit-zero `Not logged in` and nonzero ready-looking stderr. No readiness wait was added because the real binary was ready on attempt zero at every phase.

After that correction, the complete opt-in live suite passed in fresh disposable homes and a new private tmux server: native hook review, all four receipt callbacks, bound-worker semantic busy/idle, durable `Stop` and `SessionEnd`, exact-session resume with `SessionStart(source=resume)`, unregister, and exact managed-hook removal.

## TUI, input, and process semantics

The real TUI rendered `GPT-5.6-Luna low`; separate model-qualified runs rendered `low`, `medium`, `high`, `xhigh`, and `max` exactly. The authenticated `traex models --json` result proves that exact model remains account-visible, while the narrower live-verified model/effort matrix is pinned in `bin/fm-traex-lib.sh`. Catalog visibility alone does not open another model, and worker/scout/local-secondmate launch refuses an omitted model or effort.

The composer was captured with ANSI intact and added to `tests/fm-composer-ghost.test.sh`. Escape interrupted a running shell tool, TraeX restored composer content, and `C-u` cleared it. This is why `fm-send` performs both actions and records the semantic interrupt only after delivery. Safe submission continues to use the shared structural composer and acknowledgement owner; visible placeholder text is not treated as state.

The foreground process identities observed by tmux were exact `traex` / `traecli`. Portable tests include lookalike negatives so substring names cannot become recovery authority. Launch and resume rendering also pin the exact absolute `HOME`, `TRAE_HOME`, and authenticated `TRAECLI_HOME` that passed preflight, closing the tmux-daemon environment counterfactual exposed by the login investigation. `traex resume -y ... <session-id>` opened the recorded session and delivered `SessionStart(source=resume)`.

## Adapter-level gates

Portable tests exercise the public scripts and real backend interfaces rather than private shell helpers alone:

```sh
tests/fm-traex-hook.test.sh
tests/fm-traex-harness.test.sh
tests/fm-traex-secondmate.test.sh
tests/fm-secondmate-lifecycle-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-supervision-instructions.test.sh
```

Together they cover merge-preserving hook installation, malformed input refusal, exact task scope, semantic busy/idle, durable append and deduplication, matching failure status 2, unbound no-op, primary session-start output, primary Stop blocking, binary/config/dispatcher snapshot drift, structural binary identity without hot-path rehashing, model and effort gates, launch flags with no trust bypass, pre-endpoint refusal, local secondmate binding, exact-session resume, parent/child marker separation, generic local-secondmate handoff/reply/recovery/teardown, and refusal of the TraeX remote route before SSH or remote readiness. The generic lifecycle test owns harness-independent secondmate mechanics; the TraeX-specific test owns its gate, binding, launch, and resume differences.

The opt-in live suite is `FM_TRAEX_LIVE_E2E=1 tests/fm-traex-live-e2e.test.sh`. It refuses the active Firstmate home and ambient tmux server, creates unique disposable homes and a private tmux socket, and preserves failed evidence. Run it after any TraeX upgrade; the supported version/hash gate must not be changed from help or stub evidence alone.

No Herdr lifecycle command was driven during this verification. The excluded backends were reviewed only through portable refusal tests and unchanged adapter surfaces.
