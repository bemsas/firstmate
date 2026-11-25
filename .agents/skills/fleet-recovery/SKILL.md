---
name: fleet-recovery
description: Load after the session-start digest and whenever reconciling a stopped or missing direct report.
user-invocable: false
metadata:
  internal: true
---

# Fleet recovery

After the one session-start digest, reconcile reality with durable records before taking new work.
Honor lock-refused read-only mode exactly as section 3 requires.
Treat digest status tails as wake-event history and use targeted current-state reconciliation when the live state matters.

Reconcile only this home's recorded direct reports and their recorded backend inventory; never sweep a shared endpoint namespace for matching names or claim another home's work.
For an ordinary direct report whose endpoint is dead or metadata has no window, load `stuck-crewmate-recovery` and preserve the recorded worktree and unlanded work while reconciling ownership.
For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its whole child tree from the main home.
Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work.

If `state/.afk` is present, load `/afk` in away mode or `/quiet` in quiet mode (`bin/fm-wake-lib.sh`'s `fm_afk_mode`); where its daemon runs, let the daemon own supervision rather than arming another cycle, and on Pi keep the ordinary supervision session, which runs in both postures with main parked while the record exists.
Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitted supervision protocol silently.
A restart must be a non-event because durable state and live backend inventory, not conversation memory, are authoritative.
