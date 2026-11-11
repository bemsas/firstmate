# Wake router (prototype)

The wake router is a deterministic bash layer between [`bin/fm-wake-drain.sh`](../bin/fm-wake-drain.sh) and the supervising model.
It routes every queued wake to one of three classes so that only wakes needing a real decision cost a model turn.
It is a prototype: it is opt-in, runs in shadow mode by default, and is not yet wired into any harness's emitted supervision protocol.

[`bin/fm-wake-router-lib.sh`](../bin/fm-wake-router-lib.sh) owns per-row classification, and [`bin/fm-wake-route.sh`](../bin/fm-wake-route.sh) owns presentation, action execution, acknowledgement, and replay; their headers own exact flags and file formats.
This document owns the design, the rule rationale, the safety limits, and the measured routing split.

## Problem

The watcher already absorbs most benign events in bash before they reach the durable queue ([`docs/architecture.md`](architecture.md) "Event-driven supervision").
Every row that does reach the queue still wakes the supervisor, which re-reads its whole context to decide what to do.
Many of those rows resolve to no action: a worker that declared a wait, a stale pane whose worker is provably running again by the time the queue is drained, a heartbeat over an unchanged fleet, or a merge outcome whose only follow-up is the guarded cleanup.
Others resolve to exactly one scripted action that a guard-owning script already performs and re-verifies.

## Where it sits

```
watcher -> durable wake queue -> fm-wake-route.sh route
                                   |- runs fm-wake-drain.sh (one ordered transcript)
                                   |- classifies every row and every presented line
                                   |- live: runs guarded auto-act scripts
                                   |- all routed: runs the drain's own WAKE_ACK_REQUIRED, exit 0, no model turn
                                   '- otherwise: filtered presentation, exit 10, model turn
```

The router never invents an acknowledgement: it runs only the exact `--ack-through` command the drain printed, so the queue's sequence and recovery-generation contract ([`docs/watcher-continuity.md`](watcher-continuity.md)) is unchanged.
When any row needs the supervisor, the supervisor still owns that same acknowledgement, which then covers the routed rows too.

## Classes

| Class | Meaning | Examples |
| --- | --- | --- |
| `auto-ack` | Nothing needs doing; safe to acknowledge unread. | A `paused:` declaration; a no-verb signal or plain stale pane whose current state reads working; a declared-wait recheck still inside its age bound; a merge outcome for a task already cleaned up; the first completed secondmate relaunch; a heartbeat over an unchanged fleet. |
| `auto-act` | One known scripted action handles it completely. | A yolo ship PR whose ready line reports checks green (merge through `bin/fm-pr-merge.sh`); a merge outcome for a recorded ship (cleanup through `bin/fm-teardown.sh`). |
| `needs-llm` | A real decision, or anything the router cannot prove safe. | Every `needs-decision:`, `blocked:`, `failed:`, `captain-held`, and `note:` event; scout and secondmate results; yolo-off PRs; wedge escalations; captain inbox notes; process-event results; any unrecognized shape. |

`needs-llm` is the default.
A rule must positively match both a row's shape and its current evidence before either other class is returned, so a new, renamed, or malformed wake shape always reaches the supervisor.

### Evidence a rule may use

- The row's kind, key, and payload.
- The drain's own annotation lines for that row, which are the status events the supervisor would have been shown; every unread event is classified and the most severe wins (`needs-llm` > `auto-act` > `auto-ack`).
- The task's `state/<id>.meta` fields: `kind`, `mode`, `yolo`, `forge`, `x_request`.
- One `bin/fm-crew-state.sh` line, read only for rows whose answer depends on live state, with the forge fallback disabled.
- The secondmate relaunch ledger.
- The heartbeat fleet fingerprint described below.

A signal row with no annotation (bytes already presented, or a bare turn-end) falls back to the newest recorded event and current state; it may be acknowledged but never acted on, because the router cannot prove a replayed event was not already handled.

### Batch rule

A batch is routed only when every row is `auto-ack` or `auto-act`, the drain printed its acknowledgement command, and every other presented line is owned by the router.
The router owns only queue rows, the acknowledgement line, row annotations, the benign "queued wakes pending" reminder, and outcome-backstop items covered by a routed row that decided on that exact event.
Any other line, including `OPEN DECISIONS`, `UNREAD STATUS`, `RECORD DIVERGENCE`, `BRANCH OUTCOMES`, guard banners, and drain diagnostics, forces a model turn and is presented verbatim.

## Modes

- **Off:** no `config/wake-router` file, an away or quiet record (`state/.afk`), or a branch actor; the transcript is printed unchanged and the drain's status returned.
- **Shadow:** `config/wake-router` without `live`, or `route` without `--execute`; the transcript is printed unchanged and each verdict is appended to `state/.wake-router.log` so a home can measure its own split before trusting it.
- **Live:** `config/wake-router` names `live` and `route --execute`; auto-act scripts run, then the batch is either acknowledged by the router or presented filtered.

Auto-merge needs its own `auto-merge` token in `config/wake-router` in addition to the project's `yolo` posture.

## Actions and their guards

| Action | Script | Re-verified by the script at run time |
| --- | --- | --- |
| `merge <task> <url>` | `bin/fm-pr-merge.sh` | Open, non-draft, mergeable, every check green at the exact head, required checks reported, head-bound merge, merge metadata recorded. |
| `cleanup <task>` | `bin/fm-teardown.sh` | The landed-work test; uncommitted or unlanded work refuses, and `--force` is never passed. |

A refusal or nonzero exit turns that row into `needs-llm` with the refusal's last line as its reason, and the batch then reaches the supervisor.
After a successful cleanup the router checks the markdown backlog for `## Queued` items; queued work, or a backlog backend it cannot read, makes the row `needs-llm` so the supervisor re-evaluates dispatch.
"Re-arming" is not a separate action: a fully routed batch exits 0 and the host that invoked the router re-parks its next cycle exactly as after any handled wake, so the router never starts a watcher itself.

Each successful auto-act appends a captain-facing outcome line to `state/.wake-router-outcomes`.
The next filtered presentation prints those lines once under `WAKE ROUTER OUTCOMES` and moves them to `state/.wake-router-outcomes.presented`, so the supervisor relays them in its next natural reply, as [`AGENTS.md`](../AGENTS.md) section 9 asks for non-urgent updates.

## Heartbeat fingerprint

A heartbeat is `auto-ack` only when the fleet is unchanged since the last heartbeat a supervisor actually reviewed.
The fingerprint digests each status log's size and newest event and each meta file's `kind`, `mode`, `yolo`, `pr`, and `pr_head`.
Commitment is two-phase so an interrupted turn cannot launder a review: the presented fingerprint is written as `state/.wake-router-heartbeat.pending` with its row sequence, and is promoted to `state/.wake-router-heartbeat` only once that sequence has left the queue, meaning a supervisor acknowledged it after handling.

## Safety limits

- The router cannot judge whether a merge is destructive, irreversible, or security-sensitive; [`AGENTS.md`](../AGENTS.md) section 7 still escalates those, so auto-merge requires both `yolo` and an explicit `auto-merge` opt-in, and a home that cannot accept that limit leaves `auto-merge` off.
- Only the no-mistakes "checks green" ready line is merge-eligible; a direct-PR ready line, a `forge=` binding, a Relay-linked task, local-only landing, and every non-ship task stay `needs-llm`.
- The router never passes `--force`, `--allow-red`, `--allow-missing`, or `--attended-override`, and never writes to a project.
- Current-state reads are only as good as `bin/fm-crew-state.sh`; an unknown or unreadable answer is never absorb evidence.
- A declared-wait recheck is acknowledged only while the declaration is younger than `FM_WAKE_ROUTE_PAUSE_MAX_SECS` (default 86400) and its declared clearing time, if any, has not passed, so a forgotten wait still reaches the supervisor within a day.
- Classification is per drain: a router bug can cost an extra model turn but cannot hide a wake, because a parse or classification failure prints the raw transcript and exits 10.
- The router must be run only by the session that holds the supervision lock, exactly like the drain it wraps; it adds no lock of its own.
- Not yet wired into any primary harness: each supported harness's park or Stop-hook loop must call `route --execute` and treat exit 0 as a handled wake, and that integration needs the per-harness review [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md) requires.

## Replay corpus

`bin/fm-wake-route.sh replay <corpus>` builds an isolated fixture home per row and classifies it through the same library, then prints per-row verdicts, mismatches, and the per-class share.
Corpus rows are tab-separated with `#` comment lines; the columns are id, source, expected class, kind, key, payload, events (status lines joined by ` || `), meta (comma-separated `k=v`), a crew-state line, and extras (`relaunches=<n>`, `heartbeat=unchanged|changed`, `config=<token>+<token>`, `paused_age=<seconds>`); `-` means none.

- [`tests/fixtures/wake-router-shapes.tsv`](../tests/fixtures/wake-router-shapes.tsv) holds one row per wake shape documented in `bin/` headers, skills, [`AGENTS.md`](../AGENTS.md), or existing tests, each citing its source.
- [`tests/fixtures/wake-router-session.tsv`](../tests/fixtures/wake-router-session.tsv) reuses those shapes weighted by the documented lifecycle each belongs to.

## Measured routing split

Measured on 2026-11-02 with `bin/fm-wake-route.sh replay`; no production wake log was available, so neither corpus is traffic-weighted evidence.

| Corpus | Rows | auto-ack | auto-act | needs-llm |
| --- | --- | --- | --- | --- |
| Documented shapes, one row each | 51 | 11 (21.6%) | 2 (3.9%) | 38 (74.5%) |
| Modeled session, auto-merge on | 60 | 26 (43.3%) | 15 (25.0%) | 19 (31.7%) |
| Modeled session, auto-merge off | 60 | 26 (43.3%) | 9 (15.0%) | 25 (41.7%) |

The shape catalogue shows rule coverage, not frequency: most distinct shapes are decisions, which is why it is dominated by `needs-llm`.
The modeled session is one attended day of four yolo no-mistakes ships, two yolo-off ships, one ship with an external wait, one ship with a decision, one ship that wedged and recovered, two scouts, one secondmate relaunch and reply, two captain inbox notes, and six heartbeats of which two found the fleet unchanged.
Its wake sequence per lifecycle follows [`ship-landing`](../.agents/skills/ship-landing/SKILL.md) and the watcher reasons in [`bin/fm-watch.sh`](../bin/fm-watch.sh); the counts are assumptions, so a home should replace them with its own shadow-mode log before relying on the figure.
In that model the router spares the supervisor 68.3% of wakes with auto-merge on and 58.3% with it off.

## Verification

`tests/fm-wake-route.test.sh` replays both corpora, drives `route` in off, away, shadow, and live modes against recorded stand-in drain, merge, and teardown programs, proves refusals and unowned lines reach the supervisor, proves the two-phase heartbeat commitment, and classifies a transcript from the real `bin/fm-wake-drain.sh`.
