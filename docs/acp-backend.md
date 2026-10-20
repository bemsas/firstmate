# ACP runtime backend (pilot)

`--backend acp` runs a scout under `bin/fm-acp-harness.py`, Firstmate's own client for the Agent Client Protocol (ACP), instead of in a terminal pane.
It is a pilot: off by default, scouts only, ACP v1 only, one agent (OpenCode), and Python standard library only.
No existing backend or task changes when it is unused.

## Setup

The pilot needs `python3`, `treehouse`, and `opencode` on `PATH`.
`bin/fm-spawn.sh <id> <project> --scout --harness opencode --model <free-model> --backend acp` selects it for that one task.
It is never chosen by `config/backend`, `FM_BACKEND`, or runtime auto-detection, and a ship, secondmate, or `fm-spawn.sh --relaunch` spawn on it is refused.
`--model` is required, and the harness stops a run whose agent reports a cost above `FM_ACP_MAX_COST` (default `0`).

## What it does

- The worktree is leased with `treehouse get --lease`, so slot ownership and teardown work as for any other backend.
- The agent is a child process in its own process group, started with `opencode acp`; the harness owns its stdin and stdout.
- The rendered launch brief is the first `session/prompt`; a steer from `fm-send.sh` is a later prompt, queued while a turn runs.
- Every `stopReason` touches `state/<id>.turn-ended` and every turn start writes a `working` line to `state/<id>.status`, the files the watcher already reads.
- A permission request is answered automatically only when it stays inside the task worktree, the task's `data/<id>/` directory, its status file, its steering inbox, or `/tmp/fm-<id>`.
- Everything else is queued behind a keyed `needs-decision` status line; `bin/fm-acp-harness.py answer <id> <n> allow|reject` closes it.
- `cancel` sends `session/cancel` and answers pending requests `cancelled`.
- A turn that ends with a last status line of `done` and `data/<id>/report.md` present closes stdin, waits five seconds, then terminates the whole process group, so nothing outlives the scout.
- A killed run restarts with `resume` and loads the saved session through `session/load`; an agent without `loadSession` gets a fresh session and the brief again.
- `fm-control.sh relaunch` uses that recovery path in the recorded worktree, optionally delivering a progress note, and refuses harness, model, or effort changes.
- `fm-crew-state.sh` reads the harness's process-bound state directly, including pending permissions and completion after the process exits.

## Files

`state/<id>.acp.json` is the state file, `state/<id>.events.jsonl` is the frame log, and `state/<id>.acp/` holds the command queue, queued permissions, and logs.
`bin/fm-acp-harness.py tail <id> -f` is the readable view, and `fm-peek.sh` shows the same.
The frame log shortens long strings and stores the agent's command list as a count.
The script header owns the full command surface and `tests/fm-acp-harness.test.sh` pins the behavior.

## Limits

- No Claude, Codex, or Kimi adapter has been exercised, and a paid lane is outside the pilot.
- Ship spawning remains disabled; the harness's preparatory ship exit gate is owned by its script header and reuses `bin/fm-dod-lib.sh` for delivery acceptance.
- The watcher has not run against a live fleet that includes an ACP task.
- The harness steers OpenCode's permission prompts through the `OPENCODE_PERMISSION` environment variable, which worked in the 2026-10-20 pilot runs but is not listed in OpenCode's public permission documentation, so a future release could ignore it.
- Remote (ssh) agents and ACP v2 are not supported.
