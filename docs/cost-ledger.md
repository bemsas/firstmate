# Cost and quality ledger

The cost and quality ledger is an opt-in, append-only file that firstmate can query to compare harnesses and tasks on outcomes, intervention load, rework, and no-mistakes pipeline token totals when those are recorded separately.

## Turning it on and off

Create the presence flag `config/cost-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by secondmate homes.

While the flag is absent, teardown skips recording and the recorder exits before reading task metadata or the ledger.

## The file

The ledger is `data/cost-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, at most once per task incarnation (`task` plus `spawn_gen`).

Every record carries `v` (currently `1`), `task`, `spawn_gen`, `recorded_at` (UTC), `harness`, `model`, `effort`, `profile` (reserved, currently null), `kind`, `project`, `mode`, `outcome` (`done`, `failed`, or null), a `quality` object, a `spend` object, and a `timing` object.

The `quality` object counts status-line verbs from the task's status log at teardown: `needs_decision`, `blocked`, `paused`, `resolved`, and `rework` (extra terminal `done` or `failed` reports beyond the first).

The `spend` object always marks worker harness spend as `"unknown"` in this version.
When `config/pipeline-spend` is also enabled and a matching pipeline-spend line exists for the same incarnation, `spend.pipeline` carries that tally or an unavailable reason; otherwise `spend.pipeline` is null.

The `timing` object carries `first_status_at`, `outcome_at`, and `duration_sec` derived from `[at=<epoch>]` stamps on status lines when present.

## Query

Run `bin/fm-cost-ledger.sh query` from any directory with the home's environment variables set as usual.

Optional filters:

- `--harness <name>` limits to one harness.
- `--task <id>` limits to one task id.
- `--since <epoch>` drops records whose `recorded_at` is before that Unix time.

With `--json`, the command prints one object with schema `fm-cost-ledger-query.v1`, the matching `records`, and a `by_harness` summary of task counts, outcomes, and summed quality counters.
Without `--json`, it prints a tab-separated table of the matching rows.

## Limits

- Recording happens at ship and scout teardown only, while the task metadata file still exists.
- Worker-side token or dollar spend is not collected yet; do not infer cross-harness costs from subscription quotas.
- Status parsing uses the same leading-verb shape as the fleet activity ledger, without correlation-token stripping beyond `[at=...]` removal.
- There is no rotation; truncate `data/cost-ledger.jsonl` manually when you want a fresh file.

`bin/fm-cost-ledger.sh`'s header owns the writer mechanics and exact record schema.
