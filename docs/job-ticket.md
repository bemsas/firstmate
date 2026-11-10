# Job ticket

The optional job ticket records the flow of one software-feature ship job through eight ordered layers.
It is private bookkeeping, explicitly invoked by an operator, with no automatic callers or live dispatch integration.
It supports only `kind: ship`, `job_type: software-feature` in this pilot.
The [script header and help](../bin/fm-job-ticket.sh) own exact flags, path overrides, and exits.

## Activation and boundaries

Recording is off unless the selected home's local, gitignored `config/job-ticket` presence flag exists.
No flag is shipped or created by the command.
An explicit absolute `FM_HOME` is required, even for reads; data and config overrides are described in the command header.
Without the flag, every mutating command prints a disabled notice, exits successfully, and creates no directories, locks, or files.
Removing the flag disables future recording while existing tickets remain readable with `show` and `check`.
Activation for real work is a separate operator decision.

The sole durable output is `data/<task>/job-ticket.json` in the selected data directory.
Mutations use the portable lock helper from `fm-wake-lib.sh`, with its initialization confined to the ticket directory, and a private temporary file plus atomic rename beside the ticket.
The task data directory must already exist.
The command reads its brief and explicitly supplied artifact files as data, never as executable instructions.
It never writes task instructions, projects, status, metadata, backlog, or inbox records and never calls a model, forge, browser, scheduler, or native task lifecycle command.
It neither reads nor supplies a validation pipeline's intent.

## Layers and declared owners

| Order | Layer | Question and usual owner | Handoff |
|---|---|---|---|
| 1 | intake | What was asked and approved? Supervisor | Raw intent section pinned by hash, plus intake artifact |
| 2 | research | What is known or unknown? Routing mate | Known and unknown list with sources |
| 3 | strategy | What approach and evidence? Domain mate | Approach and acceptance ledger |
| 4 | production | What was made? Worker | Artifact and full version |
| 5 | qa | What did the selected delivery path report? Delivery path | Artifact or path reference, optionally its newer version |
| 6 | reality | What was observed at that version? Each truth's proof owner | Explicit observations and a handoff artifact |
| 7 | delivery | What delivery was recorded? Existing approval owner | Artifact or delivery reference |
| 8 | learning | What should endure? Supervisor | Artifact or reference `none` |

Size is an operator classification `S`, `M`, or `L`, not a dispatch policy.
Any size may consolidate adjacent layers into one call by one actor when one artifact satisfies their contracts; no layer may be omitted.
Owners and actor labels are caller assertions.
Different maker and observer labels do not authenticate people or prove independent model calls.
Ordered records do not prove a worker was absent before intake.

## Schema

`schema` is `fm-job-ticket.v1`.
The top-level object contains `task`, `size`, `kind`, `job_type`, `intent`, `ledger_frozen`, `layers`, `ledger`, and `returns`.

- `intent` stores `file`, `section`, `sha256`, and `history`, never a rewritten copy of the ask.
  The hash covers the raw section body emitted by the existing brief heading reader for exactly `## Captain's intent`, preserving its emitted leading and trailing blank lines and excluding `## Firstmate spec`.
  That reader's line-oriented output normalizes the final line terminator; this is not a hash of the entire brief file.
  When intake accepts a changed body, history retains each previous hash and the replacement time.
- `layers` always contains the eight ordered objects, each with `layer`, `state`, `actor`, `artifact`, `ref`, `version`, `at`, and `history`.
  State is `open`, `passed`, or `stale`.
  A pass appends the previous record without its nested history, including the initial open record, then replaces current handoff fields.
  Times are Unix seconds.
  Absent artifact, reference, version, actor, or time fields are null.
- `artifact` is a binding object with `file`, `role`, and `sha256`; recorded paths are absolute.
  Hashes bind existing nonempty file bytes, not the artifact's content quality.
- `ledger` rows contain `id`, `text`, `proof`, `owner`, `observation`, and `history`.
  Proof type is `command`, `desktop`, `document`, or `none`.
  A row starts with null observation, reported as `UNOBSERVED`; no verdict is inferred from its proof type.
- An observation contains `by`, caller-supplied `status`, `version`, `reason`, `synthetic`, `evidence`, `at`, and freshness `state` (`current` or `stale`).
  Evidence is an array of file bindings whose role is `evidence`, `baseline`, or `after`.
  Re-observation appends the previous observation to row history and replaces it.
  The synthetic flag is an explicit assertion, reported separately from status counts.
- `returns` is an append-only array containing `code`, layer `index` (`-1` for environment), `by`, `note`, `at`, `escalate`, and `reopened` (layer name or null).
  Return counts belong to this ticket only, independent of native QA retries.

## Record rules

| Rule | Contract |
|---|---|
| R1 - order | Earlier layers must be currently passed; re-passing a layer retains its previous record and makes later recorded handoffs stale; a refused multi-layer call commits nothing. |
| R2 - artifacts | Every pass needs an existing nonempty artifact, except QA and delivery may use a nonempty reference, and learning may use `none`; file bytes are hashed. |
| R3 - ledger | Strategy requires at least one truth and freezes additions; only an accepted intent or approach return unfreezes the ledger. |
| R4 - labels | The observer label must differ from the recorded production actor label. |
| R5 - owner | Observation must use the row's owner label; a desktop `PROVEN` observation needs both baseline and after file bindings; other statuses need no captures. |
| R6 - binding | Production and every observation need a full lower-case 40-hex version; reality requires all observations current at QA's version, falling back to production's version when QA has none. |
| R7 - status | `PROVEN` needs evidence; `GAP`, `NOT_DETERMINED`, and `NOT_RUN` each need a reason; reality may pass with any of these explicit statuses. |
| R8 - returns | Intent reopens intake, approach strategy, craft production, proof reality; environment reopens nothing; the third local return to a layer records escalation without reopening it. |
| R9 - changed ask | Check re-hashes the actual intent body; passing any later layer refuses a mismatch; re-passing intake refreshes its hash, retains history, and stales downstream recorded handoffs. |
| R10 - freshness | An upstream pass or accepted layer return stales observations; re-observation stales reality and later layers; check also reports differing requested versions or changed bound files. |
| R11 - opt-in | Mutations are disabled without the local presence flag, while reads remain available. |
| R12 - custody | A ticket mutation is locked and atomic; no existing task lifecycle, native validation, or approval authority changes. |

Observations kept after a return remain stale until explicitly recorded again, even if the version string has not changed.
The first two returns to each layer reopen that layer and stale its recorded descendant handoffs; environment returns have no escalation counter limit.
Layers that have never passed remain open during upstream passes, observations, and returns, so ordinary partial progress reports incomplete rather than stale.
The escalation flag remains visible in the historical verdict even if subsequent bookkeeping completes.

## Reading a verdict

`check` reports `flow` as `complete`, `incomplete`, `stale`, or `intent-changed`, plus per-layer states and actors, all five status counts, the synthetic count, returns by code, historical `escalate`, and `changed_artifacts` paths.
Changed intent takes precedence over other stale records, then stale over incomplete.
The verdict's layer states reflect detected intent or version staleness without rewriting the ticket.
`show` prints the stored ticket without interpreting it.

Complete means bookkeeping complete, never work correct, independently reviewed, visually verified, approved, landed, or merge-ready.
A Desktop owner label and image-named files do not prove browser execution, baseline suitability, image content, or product behavior.
Synthetic captures in the fixture are text explicitly marked synthetic, not actual UI proof.
The ticket informs existing delivery review and grants no authority to block, retry, bounce, or merge native work.

## Verification

Run `bash bin/fm-test-run.sh tests/fm-job-ticket.test.sh` for the public CLI fixture.
It walks one fictional feature job through all layers and checks refusals, honest unavailable proof, version and raw-intent recovery, file binding, disabled behavior, and preservation of outside files.
The fixture creates its opt-in only inside a throwaway synthetic home.
