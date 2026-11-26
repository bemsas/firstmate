---
name: session-start
description: Load exactly once at session start before other work.
user-invocable: false
metadata:
  internal: true
---

# Session start

- Run `bin/fm-session-start.sh` exactly once at session start.
- Its header is the single owner of composed commands, ordering, and digest contents.
- `bin/fm-supervision-instructions.sh` renders the emitted supervision block from `docs/supervision-protocols/`.
- Do not reimplement it by separately running its lock, bootstrap, initial wake-drain, or deferred-network components.
- Run-tier harness surfaces run this command for you at session open while the rest only nudge it, so confirm the digest is present in this session and run it yourself when it is not; `docs/sessionstart-nudge.md` owns adapter tiers, source routing, and compatibility.

Read the complete digest once and trust it as this turn's startup and recovery input.
If the harness shows only a preview and persists the full output to a file, read that file before acting.
Do not separately re-read the context, backlog, metadata, or bulk status inputs it just printed unless a source was reported absent or corrupt, older history is specifically needed, or a targeted workflow must inspect before writing.
An `ABSENT` captain, shared-captain, secondmate, or learnings file means the firstmate repo's built-in defaults, no shared captain preferences, no registered secondmates, or no captured learnings; rebuild an absent or stale project registry from the clones before dispatch.

If the session lock cannot be acquired and verified, report its exact diagnostic and remain read-only; another active session is only one possible cause.
A lock-refused session must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or perform any other fleet mutation.

When the digest's `NETWORK CHECKS` section reports checks still in progress, treat none of the named checks as passed until `bin/fm-startup-network.sh report` returns the finished result; a failed or otherwise actionable result also arrives as a `check: startup-network` wake.
Load `session-start-recovery` when the digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
