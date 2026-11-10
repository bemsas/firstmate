---
name: agency-job-flow
description: Load only when config/job-ticket exists in this home and an explicitly selected software-feature ship job is at intake, a worker ready report, or the delivery ask.
user-invocable: false
metadata:
  internal: true
---

# Agency job flow

Use only for an explicitly selected software-feature ship job in an opted-in home.
The [job-ticket contract](../../../docs/job-ticket.md) owns the ordered layers, declared owners, consolidation, observations, returns, and proof limits.
The [command header](../../../bin/fm-job-ticket.sh) owns exact invocation and exit mechanics.
Record the current artifact and version at each handoff using that contract.
Report the ticket's gaps and stale records alongside the existing delivery evidence; bookkeeping never grants validation or merge authority.
Keep orchestration in the existing Firstmate lifecycle and never place ticket content in validation intent.
