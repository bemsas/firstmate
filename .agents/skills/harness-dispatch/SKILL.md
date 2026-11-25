---
name: harness-dispatch
description: Load before selecting a worker profile or runtime and before every spawn.
user-invocable: false
metadata:
  internal: true
---

# Harness and runtime dispatch

- Load `harness-adapters` before every spawn or recovery and before trust handling, skill invocation, interrupt, exit, resume, or adapter verification.
- The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `omp`, and `agy`, plus `muse`, `gemini`, `rovo`, `devin`, `commandcode` (Command Code), `polytoken`, `cortex`, `kiro`, and `hermes` for crewmates and scouts only; never dispatch on an unverified adapter.
- If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back only to a verified adapter rather than launching it.
- Only the captain chooses or changes a worker account pin or declared account list (`config/claude-account`, `config/pi-account`, `config/claude-accounts`), so on a pin refusal report the needed login and never edit or remove the file to unblock a spawn.

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
Before creating a task branch, verify that its isolated worktree starts at the project's resolved base-branch tip and stop before mutation if it does not.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
Load `quota-array-dispatch` before choosing among a matched profile array or a Claude spawn's declared accounts; that skill is the single owner of the TOON-first spendPriority selection procedure.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn`, or pass your reason to override as `--dispatch-override <reason>`, because `fm-spawn` refuses other flags without it; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
`harness-adapters` owns the generic effort fallback and its precedence.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `fm-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../../../docs/configuration.md) "Runtime backend").
A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently retry on another backend.
