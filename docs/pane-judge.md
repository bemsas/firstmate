# Tier-2 pane judge

`bin/fm-pane-judge.py` is a gated, read-only, advisory classifier for fleet worker lanes.
It asks a small cached model what an ambiguous lane is doing and records the answer as a verdict row.
It never acts: it sends no text, keystrokes, interrupts, restarts, merges, or cleanups to any lane, and a label such as `needs-restart` is only a recommendation for a separately approved consumer.
The script header owns the command surface and flags; this page owns the behavior and the data contracts.

## Which lanes it reads

Homes come only from declared fleet metadata: the main home named by `--main-home` plus every secondmate home in the `--registry` file (`data/secondmates.md`).
Only the local desktop and the `akamai_vm` host are authorized; any other registered host is ignored, and a remote host is read over `ssh -o BatchMode=yes` by piping the script into a remote `python3 - collect-local`, which writes nothing on that host.
Within a home, only `state/<id>.meta` records of kind `ship` or `scout` are lanes; secondmates, remote-secondmate records, and every other kind are skipped.
Any home, task id, project, worktree, branch, repo, or base branch matching `veni` (any case) is excluded from the metadata alone, before any pane, process, or repository read.
A pane is read only when the multiplexer reports that pane's working directory inside the task's recorded worktree, so a reused or human pane is never sampled.

## Snapshot contract (`fm-pane-judge.snapshot.v1`)

Each lane becomes one JSON object; every field may be `null`, and `null` always means unknown, never failure.

| Field | Source |
| --- | --- |
| `host`, `home`, `home_path`, `task`, `kind`, `mode`, `harness`, `branch`, `base_branch` | the task metadata and the declared home |
| `agent` `{status, focused, seq, seq_source}` | Herdr `agent get`; `seq` is `completion_seq` when Herdr reports it, else `state_change_seq` |
| `busy` `{state, event, source, ts}` | the semantic busy record `state/<id>.busy-state` |
| `process` `{shell_pid, shell_only, harness_alive, foreground, build_procs, build_cpu_ticks, build_cpu_active}` | Herdr `pane process-info` plus a one-second `/proc` CPU sample of test and build descendants, excluding the harness itself |
| `pane_tail`, `pane_sha` | the last 80 lines of Herdr `pane read --source recent-unwrapped` |
| `git` `{head, dirty_files, upstream, unpushed_commits, commits_ahead_of_base, base_ref, last_commit_ts}` | read-only git in the worktree with optional locks off |
| `pr_url`, `last_event`, `status_tail` | `pr=` metadata, else the newest pull or merge request URL in the status log, and its last event |
| `report_exists`, `brief_dod` | `data/<id>/report.md` and the brief's Definition of done section |
| `tool_ring` | the last 10 events of `state/<id>.tool-ring.jsonl`, any fields, when present |
| `silence_seconds` | the caller's value, else the judge's own pane-change tracking and the newest tool-ring `ts` |

Secrets, tokens, passwords, credentials in URLs, private keys, and JWT-shaped strings are redacted at collection and again before any request or log line.
Callers may add fields; the judge ignores unknown fields and tolerates missing ones.

## Tier-1 gate

The model sees a lane only in one of two ambiguity classes, and every other lane settles without a call.

- `idle-unmet-dod`: the hook or Herdr reports the turn idle or done, nothing reports it working, and the definition of done is provably unmet.
- `silent-working`: the lane reports working, its pane has not changed for more than 300 seconds, and the CPU sample proves no test or build descendant ran.

A lane with active build CPU always settles, so a running build is never classified.
A declared `needs-decision`, `blocked`, `paused`, or `failed` event settles the lane unless the busy hook proves later activity (busy after the declaration, or idle more than 600 seconds after it).
Unmet requires positive evidence: dirty files or unpushed commits; for a pull-request mode, no recorded pull request with no work pushed or none committed; for `local-only`, nothing committed; for a scout, no report.
Unknown facts settle as unknown and are never read as unmet or stalled.
An unchanged lane (same gate, `seq`, pane hash, and DoD facts) is not judged twice.

## Model call

The primary model is `anthropic/claude-haiku-5.5` with thinking disabled, and `openai/gpt-5-nano` at minimal reasoning is the single fallback, both through OpenRouter with the key read only from `~/.config/fleet-judge/env`.
A model is used only when the live OpenRouter catalog lists it with structured outputs at no more than $0.20 per million input and $1.00 per million output tokens; provider routing carries the same price ceilings.
The request is a byte-stable system rubric marked for prompt caching, followed by a suffix of at most 4,200 characters holding the gate, task, DoD text and facts, agent, busy, process, status tail, tool ring, and the newest pane lines that fit.
The reply must be strict JSON `{"label", "confidence", "evidence"}` with one of the six labels below; anything else is a failed call.

## Labels and post-model filters

The six labels match the step-5 actuator vocabulary: `working`, `finished`, `needs-nudge`, `stalled:loop`, `stalled:blocked`, and `needs-restart`.
The model's answer passes three filters in order, and the result is the emitted `label`:

1. Process override: active build CPU forces `working`, and a bare shell (`shell_only`) turns `working`, `needs-nudge`, or `stalled:loop` into `needs-restart`, because nothing can be typed into a shell with no agent.
2. Contradiction filter: `finished` with an unmet DoD or a working agent, `needs-restart` without a proven bare shell, and `working` for an idle turn with unmet DoD all emit `unknown`.
3. Confidence hysteresis: a label needs confidence 0.75 or more; the lane's previous label is held down to 0.60; anything else emits `unknown`.

## Budget

All judge processes on a home share one lock and ledger under `state/pane-judge/`.
Before each call the judge atomically reserves a worst-case cost from the request size and the price ceilings, and refuses when the lane already used 40 calls that UTC day or when committed spend plus the reservation would reach $0.50.
After the call the reservation is replaced by OpenRouter's reported cost; a call with no reported cost keeps its full reservation.
An unreadable ledger, a missing credential, or an unverified model catalog refuses the call.

## Verdict contract (`fm-pane-judge.verdict.v1`)

Each judged or refused lane appends one JSON line; `--out` defaults to `state/pane-judge-shadow.jsonl` in the running home.

| Field | Meaning |
| --- | --- |
| `schema` | `fm-pane-judge.verdict.v1` |
| `ts`, `at` | epoch seconds and UTC ISO time of the verdict |
| `task`, `host`, `home`, `home_path`, `lane` | lane identity; `home` is the registry mate id or `main`, and `lane` is `<host>:<home>:<task>` |
| `kind`, `mode` | task kind and delivery mode |
| `seq`, `seq_source` | the turn the verdict is about, from `completion_seq` or `herdr_state_change_seq` |
| `gate` | `idle-unmet-dod` or `silent-working` |
| `label`, `confidence` | the emitted label after filters, or `unknown` |
| `model_label`, `model_confidence`, `evidence` | the model's raw answer and its redacted evidence, at most 160 characters |
| `filters` | applied filters, for example `contradiction:finished-vs-unmet-dod` or `hysteresis:held` |
| `skip` | why no answer was obtained, for example `daily-spend-cap`, or `null` |
| `shadow`, `advisory` | always `true` in this version |
| `model`, `cost_usd`, `cost_source`, `usage` | the serving model, cost charged to the ledger (`reported` or `reservation`), and token usage including cached tokens |
| `input_sha`, `facts` | the suffix hash and the deterministic facts the filters used |

A consumer must ignore any row whose `shadow` is `true` and any `label` of `unknown`.
This version writes shadow rows only and has no live publication mode.

## Shadow audit and outcome labels

`shadow` runs collection and judging every `--interval` seconds for `--duration` seconds.
It writes `manifest-start.json` only after its preflight proves the credential, a usable model catalog entry, and a working collector on every requested host, then appends one line per cycle to `cycles.jsonl` and finishes with `manifest-end.json`.
Ground truth is a separate JSONL of human or mate labels, schema `fm-pane-judge.outcome.v1` with `lane` (or `host`, `home`, `task`), `ts`, one of the six labels, a non-empty `labeler`, and an optional `note`.
`summary` matches each verdict to the nearest outcome on the same lane within 900 seconds; unlabelled verdicts and unlabelled outcomes are never counted as agreement.
It reports `pass` only when the same run's `manifest-end.json` records at least 24 hours elapsed, whenever its last verdict fell, with at least 20 labelled matches, agreement of 85% or more, no emitted `needs-restart` on an active build or against a non-restart outcome, and every day's spend under $0.50.

## Verification

`tests/fm-pane-judge.test.sh` pins the gate, request shape, redaction, verdict contract, filters, budget concurrency, collection exclusion, manifests, and summary through the executable with a loopback model stand-in.
