# Orchestration cherry-picks

Research date: 2026-11-02. Scope: how comparable systems schedule, assign, land and merge work, handle memory, and keep supervisor cost down, and which mechanisms firstmate should copy.
This is research only. No code, config, or other file changed.

## 1. Summary and hard truths

Firstmate's four measured problems are:

1. The main supervisor is the bottleneck: 66% of wakes do nothing, each wake re-reads about 315k tokens, and the supervisor forgets and drifts.
2. Dispatch to PR takes about 11 minutes, but PR to merge takes a median of about 4 hours.
3. 18% of PRs are redone because of stacked or conflicting PRs.
4. 20 or more workers could run in parallel but rarely do.

What the evidence says:

- **No surveyed agent system solves landing.** Claude Code agent teams, Codex cloud, Devin, Hermes, Vibe Kanban and Conductor all stop at "open a PR". A human or the forge merges. The mechanisms that actually reduce merge latency and conflict redo come from merge queues (GitHub, Mergify, Graphite), not from agent frameworks. The four general frameworks (AutoGen/Magentic-One, CrewAI, LangGraph and, partly, OpenClaw) have no code-landing step at all.
- **The best supervisor-cost ideas come from Hermes Agent, Paperclip and Devin**: a non-LLM dispatcher, an event whitelist for waking the supervisor, wake coalescing, tiny capped memory, and notification instead of polling.
- **Much of what firstmate needs already has a seam in the repo** (section 2). The highest-value work is generalising and defaulting existing opt-in pieces, not inventing new subsystems.
- **Hard truth on problem 2.** The 4-hour median mixes at least three waits: supervisor routing, CI and queue time, and operator approval. `AGENTS.md` hard rule 2 says no merge without the operator's explicit word unless the project is `yolo`. Code can remove supervisor routing delay and can remove approval delay only on `yolo` projects. Measure the split before building (section 5, change 0), or a merge worker will be built for a delay that is mostly human.
- **Hard truth on problem 3.** `AGENTS.md:203` tells the supervisor to treat file overlap as a risk signal and dispatch immediately with no concurrency cap. That policy is a plausible contributor to the 18% redo rate. The data to confirm it (which redone PRs shared files with a concurrent PR) is not in this research and should be pulled from the fleet ledger.
- **Expected-impact figures below are my estimates**, reasoned from the mechanisms, not measurements. They are labelled as such. Effort labels: S under 1 day, M 1 to 3 days, L over 3 days, for one engineer or worker who knows the codebase.

## 2. Firstmate baseline (what exists today)

All claims cite the repo at commit `801ba22`.

| Capability | Where | Relevance |
| --- | --- | --- |
| Zero-token bash watcher classifies wakes and absorbs benign ones; actionable wakes go to a durable queue | `docs/architecture.md:13`, `:82`, `:124` | Already event-driven. The 66% no-op wakes are the ones that pass classification. |
| Turn-end pane-churn absorb exists but is opt-in | `docs/architecture.md:102-107` | Classification is conservative by design, so uncertain events wake the supervisor. |
| Heartbeat backs off from 600s to 7200s when nothing changes | `docs/configuration.md:3317-3318` | Heartbeat wakes are bounded but still LLM turns when they surface. |
| Merge on validated: code merges a validated PR instead of waiting for a supervisor wake. Off by default, dry-run first, only secondmate `validated` lines, only `yolo` tasks, only base `dev`, requires a recorded second-model review verdict and green checks | `bin/fm-merge-on-validated.sh` header; `docs/configuration.md:2350` | The closest existing seam to a code-owned merge worker. Today it is narrow. |
| Guarded merge: live checks green at the current head, `--match-head-commit`, no `--auto`/`--admin` | `bin/fm-pr-merge.sh`; `docs/architecture.md:428-447` | Reusable as the single merge primitive. |
| Judge-first: a private judge answers secondmate `needs-decision:` and `blocked:` lines before the supervisor spends a turn, default off, shadow mode first | `bin/fm-judge-first.sh`; `docs/configuration.md:999` | Existing pattern for taking decisions off the supervisor. |
| Lane capacity and project capacity: caps and host pressure for parallel dispatch | `bin/fm-capacity.sh`; `docs/configuration.md:817`, `:1745` | Existing inputs for a dispatcher. |
| Warm-cache compaction while the prompt cache is still warm | `bin/fm-warm-compact-lib.sh` header; gate `config/warm-compact` | Existing context-cost lever. It reduces cache-write cost, not transcript size. |
| Home summary published per home; fleet snapshot JSON | `docs/architecture.md:163-167` | A compact state source a lean supervisor can read instead of transcripts. |
| Cost and quality ledger, opt-in | `docs/cost-ledger.md` | The place to record per-wake outcome and redo cause. |
| Queue re-evaluation is done by the supervisor after every teardown and heartbeat | `AGENTS.md` section 10 | Dispatch of queued items waits on a supervisor turn. A likely cause of problem 4 (unverified). |
| Briefs are written by the supervisor before every spawn | `AGENTS.md` section 11 | Constrains any non-LLM dispatcher: briefs must exist before dispatch. |
| Overlap is not a reason to wait | `AGENTS.md:203` | Likely contributor to problem 3 (unverified). |

## 3. Systems surveyed

Provenance key. **V** means I re-fetched the primary source myself this session. **R** means a research agent read the cited primary source and I did not re-fetch it. Doc pages were often read through a summarising fetch tool, so treat quoted config names as close paraphrase until checked. **U** means unverified.

### 3.1 Nous Research Hermes Agent

- **What it is.** A self-improving agent with memory, skills, cron and a multi-platform gateway. Profiles are separate model, config and memory homes. Kanban is a durable multi-profile task board. V (licence), R (rest). https://github.com/NousResearch/hermes-agent, docs https://hermes-agent.nousresearch.com/docs
- **Scheduling and assignment.** A dispatcher inside the gateway ticks about every 60s. It reclaims stale claims, promotes ready tasks, claims atomically, and spawns `hermes -p <assignee>`. One assignee profile per task. `kanban.max_in_progress` caps total running tasks (unset means unlimited) and `max_in_progress_per_profile` caps per profile. A child task stays `todo` until all parents are `done`, and the child receives the parents' summaries. Workers heartbeat. Tasks running past `dispatch_stale_timeout_seconds` (default 4h) with no heartbeat in the last hour are reclaimed. A consecutive-failure circuit breaker auto-blocks after `failure_limit` (default 2). Rate-limit exits requeue with a 300s cooldown. V for the 4h reclaim, `max_in_progress`, `active_pr` guard and breaker. R for the 60s tick and the SQLite path. https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban
- **Landing and merge.** There is no auto-merge. "A commit or diff alone never automatically completes a task." `--completion-contract OWNER/REPO` blocks completion until GitHub required checks pass on the exact PR head. A review loop exists (`kanban_request_review`, `kanban_request_changes`). Conflicts between workers: the doc says not to let either worker self-adjudicate. Create a reconciliation card for a neutral profile with both conflicted cards as parents, which then receives both diffs and intents. An optional skill `agent-merge-conflict-arbiter` carries the procedure. Workers leave `hotspot: <path>` comments, and two or more on one path tell the orchestrator to create a refactor card before queuing more work on that file. An `active_pr` guard stops respawning a card that already links a PR. V for all of these. Same URL.
- **Memory.** `MEMORY.md` is capped at 2,200 characters and `USER.md` at 1,375, loaded as a frozen snapshot at session start to preserve prefix cache. Writes over the cap error, so the agent must consolidate. Memory is per profile. Past sessions are searchable with FTS5 and no LLM call. R. https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- **Supervisor cost control.** Notification delivery modes `notify`, `notify+wake`, `wake` exist (V). The doc lists the events that raise an alert (`completed`, `blocked`, `gave_up`, `crashed`, `timed_out`, `block_loop_detected`) (V). The claim that the supervisor wakes only on a fixed whitelist is R and partly inferred. Per-task `--model`, `--goal-max-turns` and `max_runtime_seconds` exist. R.
- **Maturity.** About 259.8k stars, release v0.22.6, last commit on the research date. R (badge and repo page, approximate).
- **Licence.** MIT. V. https://raw.githubusercontent.com/NousResearch/hermes-agent/main/LICENSE

### 3.2 OpenClaw

- **What it is.** A personal-assistant gateway: a local control plane for sessions, tools and channels, with agent harnesses as plugins. Not a coding-PR orchestrator. R. https://github.com/openclaw/openclaw, docs https://docs.openclaw.ai
- **Scheduling.** Lane-aware FIFO queue with per-session serialisation. Concurrency settings: `agents.defaults.maxConcurrent`, sub-agents `agents.defaults.subagents.maxConcurrent` (default 8 per session), swarm children `tools.swarm.maxConcurrent` (default 32 per group). Queue modes `steer`, `followup`, `collect`, `interrupt`, with a 500 ms debounce and a cap of 20 with summarise-on-drop. R. https://docs.openclaw.ai/concepts/queue
- **Heartbeat.** The old heartbeat is retired and migrated to ordinary automation jobs. Quiet-outcome primitives: `NO_REPLY` and `record_result no_change` suppress delivery, `skipIfScratchEmpty`, `activeHours`, `idleOnly`, isolated fresh context. R. https://docs.openclaw.ai/gateway/heartbeat
- **Landing.** No merge model found. U.
- **Memory.** Auto-compaction at the smaller of 75% of the window or window minus reserve, preceded by a silent "memory flush" turn that writes durable notes. Per-agent workspace and session store. R. https://docs.openclaw.ai/concepts/compaction
- **Maturity.** About 393.7k stars, release v2026.10.9, governed by an "OpenClaw Foundation". R.
- **Licence.** MIT. V. https://raw.githubusercontent.com/openclaw/openclaw/main/LICENSE

### 3.3 ClaudeClaw (ambiguous name)

Three repositories share the name: `moazbuilds/claudeclaw` (the README's original, about 1.3k stars), `fenrur/claudeclaw`, and `sorrygoodbye/claudeclaw`. Only the first was inspected. R.

- **What it is.** A Claude Code plugin that runs a background daemon with heartbeat, cron, chat bridges (Telegram, Discord, Slack) and a web dashboard. https://github.com/moazbuilds/claudeclaw
- **Scheduling.** Periodic heartbeat with quiet hours, cron, one session per Discord thread. No work queue, claiming or concurrency cap documented. U.
- **Landing.** None documented. **Memory.** Claude's own memory and `CLAUDE.md`.
- **Maturity.** About 1.3k stars. The last-commit badge indicated July, so roughly 4 months stale on the research date. R.
- **Licence.** MIT. V.
- **Relevance.** Low. It is a heartbeat-prompt design, which is the pattern behind firstmate's no-op wakes. Treat it as an anti-pattern, not a source.

### 3.4 Paperclip (paperclipai)

- **What it is.** An open-source company orchestrator: org chart, goals, tickets, budgets and governance, with runtimes including Claude Code, Codex, Cursor, Gemini and HTTP. R. https://github.com/paperclipai/paperclip, docs https://docs.paperclip.ing
- **Scheduling.** A database-backed wakeup queue with coalescing, a budget check, workspace resolution, then adapter invocation. Agents wake for assigned work, follow-up messages, optional timers, or routines (cron, webhook, API). A mention alone does not wake or assign. One assignee per task with atomic checkout and execution locks. Blocker dependencies are first-class. `README.md`, `doc/SPEC.md`, `doc/execution-semantics.md`. R. Per-agent concurrency number: U.
- **Landing.** Optional isolated workspaces (git worktrees) and review or approval execution policies. Who merges to main and conflict handling: U.
- **Memory.** Shared org skills with version history and per-agent task sessions with continuation. Compaction policy: U.
- **Cost control.** Scoped budgets (org, agent, project), a warning at 80% and a hard stop at 100% that pauses further heartbeats, and an optional reserve-per-run so parallel runs cannot overshoot. R. https://docs.paperclip.ing/guides/day-to-day/costs/
- **Maturity.** About 110.3k stars, release v2026.1023.0, default branch `master`. R.
- **Licence.** MIT. V.

### 3.5 Claude Code: agent teams, subagents, background sessions

- **What it is.** Teams are a lead plus teammate sessions with a shared file-backed task list and per-agent mailboxes. Subagents are Markdown-defined helpers with their own context. Background sessions (`claude --bg`, agent view) run under a supervisor daemon. R. https://code.claude.com/docs/en/agent-teams, https://code.claude.com/docs/en/sub-agents, https://code.claude.com/docs/en/agent-view
- **Scheduling.** Tasks have states and dependencies. Teammates self-claim the next unblocked task, with file locking against races. Blocked tasks are not self-claimed. The docs advise 3 to 5 teammates. `TeammateIdle`, `TaskCreated` and `TaskCompleted` hooks can block with exit code 2 to keep a teammate working or stop a task being marked complete. R.
- **Landing.** None for teams. The only guidance is that each teammate owns a different set of files. Background sessions are told to push, open a draft PR and never push to main, force-push or merge. R.
- **Memory.** Teammates load `CLAUDE.md`, MCP servers and skills; the lead's history does not carry over. Subagents may have persistent `MEMORY.md` memory, of which the first 200 lines or 25KB load. Subagent transcripts are separate from main-conversation compaction. R.
- **Cost.** Agent teams use about 7x the tokens of a standard session in plan mode. The costs page states that idle scheduled tasks, cross-session messages and goal check-ins each send full context, with controls such as `crossSessionInbound: hold`. https://code.claude.com/docs/en/costs. R.
- **Maturity.** Agent teams are "experimental and disabled by default". Agent view is a "research preview". Worktree isolation for subagents is documented as a normal feature. R.
- **Licence.** Proprietary. U: the docs state none.
- **Not verified.** The background-session concurrency cap (the page was truncated for the reader).

### 3.6 OpenAI Codex (cloud tasks, AGENTS.md, memories, CLI)

- **What it is.** Cloud tasks run in containers from a published environment. Multiple tasks can start from one environment, each with its own workspace. Docs now live at `learn.chatgpt.com/docs/...` (the old `developers.openai.com/codex/*` URLs redirect). R. https://learn.chatgpt.com/docs/cloud
- **Landing.** The result is a final answer plus a diff; the user commits or opens a PR. `@codex review` flags only P0 and P1 issues. Codex does not fix issues automatically: a comment such as `@codex fix the CI failures` starts a cloud run that may push to the branch. GitHub branch protections and required approvals still apply. How the PR is created, and best-of-N attempts, are U. https://learn.chatgpt.com/docs/third-party/github.md
- **Memory.** `AGENTS.md` chain read root to leaf, capped at 32 KiB by default. Memories are opt-in and local, extracted when a chat is idle, and the docs call them "a recall layer, not a rule source". R.
- **Subagents.** Enabled by default in the app, CLI and IDE. `agents.max_concurrent_threads_per_session` is unset by default. R.
- **Maturity and licence.** Maturity dates U. Codex CLI is Apache-2.0 (R, https://github.com/openai/codex). The cloud service is proprietary.

### 3.7 Devin (Cognition)

- **What it is.** An autonomous coding agent product with Managed Devins (a coordinator spawning children in separate VMs), Dynamic Workflows, automations, review, stacked PRs and memory. R. https://docs.devin.ai
- **Scheduling.** The coordinator is notified when a child finishes or needs input, even while asleep, so it does not poll. Each child has its own prompt and ACU limit; "Auto-approve child sessions" can be turned off so batches are reviewed. Dynamic Workflows are deterministic Python scripts that record each agent call and are resumable (budget up to 7 days). Automations trigger on Slack, GitHub, Linear, schedules and webhooks, with a default limit of 50 runs per hour and an optional queue that drops events when full. `.../advanced-capabilities.md`, `.../dynamic-workflows.md`, `.../automations.md`. R.
- **Landing.** "Devin does not merge autonomously." Merging is a user action, and the user can use GitHub auto-merge; an Autoapprover can satisfy approval requirements so existing auto-merge or a merge queue proceeds. Stacked PRs (GitHub.com only, 2 to 100 PRs) merge atomically bottom-up, and a conflicting layer is resolved by Devin itself. `.../devin-review.md`, `.../stacked-prs.md`. R.
- **Memory.** A per-user git repository of Markdown notes. `MEMORY.md` is an index, and each session reads the index plus only the notes it needs. A background "Dreaming" session runs about daily to merge overlapping notes and prune stale ones. Task state such as PR numbers is explicitly not stored. Beta status U. `.../memory.md`. R.
- **Licence.** Proprietary. U for SPDX.
- **Not verified.** Knowledge pages and DeepWiki were not read.

### 3.8 Magentic-One and AutoGen (and Microsoft Agent Framework)

- **Status.** AutoGen is archived. Its README says "Project archived and no longer maintained" and points to Microsoft Agent Framework (MAF). R. https://github.com/microsoft/autogen, https://github.com/microsoft/agent-framework
- **Scheduling.** One orchestrator runs an outer loop (a task ledger of facts and plan) and an inner loop (an LLM-produced progress ledger each round naming exactly one next speaker). Dispatch is serial. A stall counter increments when no progress is made or a loop is detected, decays otherwise, and at `max_stalls` (default 3) triggers re-plan, which resets all agents and clears the thread before re-seeding from the updated ledger. MAF Magentic exposes `max_round_count`, `max_stall_count`, `max_reset_count`. R (source file `_magentic_one_orchestrator.py`). MAF's page says it is "untested how well the Magentic orchestration will perform outside of the original Magentic-One design". R. https://learn.microsoft.com/en-us/agent-framework/user-guide/workflows/orchestrations/magentic
- **Landing.** None. The output is a synthesised final answer.
- **Memory.** Orchestrator state is small and serialisable (task, facts, plan, round and stall counters). No long-term memory or compaction in the orchestrator. R.
- **Licence.** MIT for code, CC-BY-4.0 for docs (AutoGen). MAF is MIT. R. **Maturity.** MAF PyPI 1.24.0 (2026-10-30). R.
- **Relevance.** The per-round LLM-in-the-loop dispatch is the same shape as firstmate's bottleneck, so do not copy it. The explicit ledger and stall counter are useful.

### 3.9 CrewAI Flows

- **What it is.** A Python framework with Crews (role-based agents) and Flows (event-driven orchestration with `@start`, `@listen`, `@router`, `or_`, `and_`). R. https://github.com/crewAIInc/crewAI, https://docs.crewai.com/en/concepts/flows
- **Scheduling.** A hierarchical process needs a manager agent that plans, delegates and validates. The docs give no stall detection or concurrency cap. Tasks may be `async_execution`, with later tasks waiting through `context`. R. https://docs.crewai.com/en/concepts/processes
- **Landing.** None. Acceptance is by task guardrails (retry up to 3 by default) and `@human_feedback`. R.
- **Memory.** Flow state with a `@persist` option (SQLite by default). A unified `Memory` class with hierarchical scopes, read-only slices, LLM-driven consolidation, and a no-LLM `shallow` recall mode. R. https://docs.crewai.com/en/concepts/memory
- **Maturity and licence.** About 60.4k stars, `crewai` 1.15.34 (2026-11-01), MIT. R (licence V by file text per agent).

### 3.10 LangGraph supervisors

- **What it is.** LangGraph is a low-level stateful orchestration framework. `langgraph-supervisor` and `langgraph-swarm` are thin libraries over it. R. https://github.com/langchain-ai/langgraph
- **Status.** `langgraph-supervisor-py` was archived on 2026-09-20 (R). Its README, which I re-fetched, says: "We now recommend using the supervisor pattern directly via tools rather than this library" (V). The current guidance is subagents as tools, where all routing passes through the main agent. https://github.com/langchain-ai/langgraph-supervisor-py, https://docs.langchain.com/oss/python/langchain/multi-agent
- **Scheduling.** Parallel fan-out through the `Send` API with reducers merging branch outputs. The only built-in brake is `recursion_limit`. There is no stall detector. A `max_concurrency` setting was not found (U). R. https://docs.langchain.com/oss/python/langgraph/graph-api
- **Landing.** None. `interrupt()` plus `Command(resume=...)` gives pausable approve or reject gates; the node restarts on resume, so side effects must be idempotent. R. https://docs.langchain.com/oss/python/langgraph/interrupts
- **Memory.** Checkpointers per thread, a namespaced long-term `Store`, `trim_messages`, `RemoveMessage`, and summarisation nodes. Subagents are stateless by design. `create_forward_message_tool` passes a worker's last message to output without supervisor paraphrase. R. https://docs.langchain.com/oss/python/langgraph/add-memory
- **Maturity and licence.** `langgraph` 1.2.19 (2026-10-30), MIT; `langgraph-swarm` last released 2025-12-04, maintenance status U. R.

### 3.11 Vibe Kanban

- **What it is.** A kanban board plus per-issue workspaces (branch, terminal, dev server) running 10+ agents, with diff review and PR creation. R. https://github.com/BloopAI/vibe-kanban
- **Scheduling and landing.** Human-driven. The README lists "create pull requests and merge" but no merge queue, stacked-PR handling or rebase handling. U beyond that.
- **Maturity.** **Sunsetting.** The README headline is "Vibe Kanban is sunsetting" and the vendor announced shutdown on 2026-04-10, with community-maintained open source continuing. R. https://vibekanban.com/blog/shutdown. Do not build on it.
- **Licence.** Apache-2.0. V.

### 3.12 Conductor (Melty Labs)

- **What it is.** A macOS-only app running Claude Code, Codex, Cursor and OpenCode in parallel workspaces, each with its own branch and working tree. R. https://www.conductor.build/docs/
- **Landing.** Human-driven. "The workspace is the unit of delegation, and the branch and pull request are the unit of integration." Work is split into independent pieces that can be merged on their own, and agents can be asked to help resolve conflicts. There is no queue. Merge is a human click after checks pass. R. https://www.conductor.build/docs/concepts/workflow
- **Maturity and licence.** Active, with a paid Cloud tier. Proprietary (inferred; U). Checkpoints: U, no primary doc found.

### 3.13 GitHub merge queue

- **Model.** Each queued PR is tested on a temporary branch containing the latest base, the PRs ahead, and itself, on branches prefixed `gh-readonly-queue/`. Actions need the `merge_group` trigger. Settings: merge method, build concurrency (1 to 100), min and max group size, wait time, status-check timeout. A PR that fails or conflicts is removed, and the rest are rebuilt without it. R. https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- **Availability.** Public repositories owned by an organisation, or private repositories owned by organisations on GitHub Enterprise Cloud. V (re-fetched from the page). This likely rules it out for personal-account or Team-plan private repos. Check each of the 8 projects.
- **Maturity.** GA since July 2023. R. **Licence.** Proprietary SaaS.

### 3.14 Mergify merge queue

- **Model.** A GitHub App configured in `.mergify.yml`. Modes: serial, parallel (needs scopes) and isolated. `max_parallel_checks` defaults to 5. Each PR is tested on top of those ahead of it. Priority rules; `allow_checks_interruption` defaults to false. Scopes (path-based) let unrelated changes batch and merge independently, with `barrier_files` serialising whole-repo changes. Batching splits a failed batch to find the culprit. A PR conflicting with one ahead is held; if that one merges, the held PR is removed and must be rebased and re-queued. Stacks enter bottom-up and dequeuing cascades to successors. After a partial landing, the rest are not rebased automatically. `max_checks_retries` and `checks_timeout: auto` handle flaky checks. R. https://docs.mergify.com/merge-queue/ and its `lifecycle`, `scopes`, `batches`, `stacks`, `priority`, `rules` pages.
- **Pricing.** Merge Queue is stated to be on every plan, with a free tier for open source and for small private teams. R. https://mergify.com/pricing
- **Licence.** Proprietary SaaS; any open-source client is U.

### 3.15 Graphite

- **Model.** The `gt` CLI plus a stack-aware merge queue. The stack is the queue unit and stack merges are atomic: if any PR fails, the whole stack fails. Optional fast-forward merge runs CI on all PRs in a stack in parallel. Parallel CI runs temporary `gtmq_` draft PRs for speculative groupings. Graphite claims 1.5x faster merges on average. Batching is in private beta. R. https://graphite.com/docs/graphite-merge-queue, https://graphite.com/docs/merge-queue-optimizations
- **Maturity.** Cursor agreed to acquire Graphite in December 2025. Whether it still operates independently is U. R.
- **Pricing.** The merge queue is on the Team tier, at $40 per user per month in the pricing page read. R. https://graphite.com/pricing
- **Licence.** Proprietary; CLI licence U. Conflict handling inside the queue is U.

## 4. Ranked top 10 mechanisms to copy

Ranking weighs expected impact on the four measured problems, effort, and fit with firstmate's rules (`VISION.md` and `AGENTS.md`: scripts own mechanics, agents own judgment; merge authority is explicit; no extra layers between intent and action). Impact is my estimate. "Load" means supervisor wakes and tokens; "Throughput" means parallel workers actually running.

| Rank | Mechanism | Source systems | Expected impact (estimate) | Effort | Firstmate seam |
| --- | --- | --- | --- | --- | --- |
| 1 | **Code-owned merge worker.** A watcher check that merges any PR meeting a declared policy (project `yolo`, checks green at the exact head, review verdict recorded, not held) through `fm-pr-merge.sh`, plus an update-onto-base step before merging and a pause sentinel file. Generalise the hook beyond secondmate `validated` lines and base `dev`. | Mergify queue lifecycle and `update_method` (`docs.mergify.com/merge-queue/rules`); GitHub merge queue; Graphite queue; Hermes completion contract (exact-head required checks) | Load: high, removes the supervisor wake from the merge path. Throughput: indirect. Problem 2: removes the supervisor-routing share of the 4h; the rest is CI plus operator approval (see section 1). | M | `bin/fm-merge-on-validated.sh` and `docs/configuration.md:2350` already do this for one narrow case |
| 2 | **Wake tiering: event whitelist, notify-only for the rest, and coalescing.** Only a fixed set of event classes (done or PR ready, blocked, failed, crashed, timed out, review requested, loop detected) wake the LLM. Everything else is appended to a digest that is read at the next natural wake. Bursts within a window are merged into one wake. | Hermes delivery modes and alert events; Paperclip wake coalescing; OpenClaw `collect` mode and `no_change` quiet outcomes; Devin notification instead of polling | Load: high. Aims directly at the 66% no-op wakes. Needs the wake-class breakdown to size it. | S to M | `bin/fm-watch.sh` triage, `state/.watch-triage.log`, the opt-in churn absorb (`docs/architecture.md:102`) |
| 3 | **Conflict hold, then redispatch to the original worker.** When a queued PR conflicts because its predecessor merged, steer the owning worker to rebase and re-validate, and re-queue it, instead of a fresh task. If two workers' branches collide twice, create a reconciliation task for a third neutral worker that receives both summaries. | Mergify lifecycle (hold, then remove on predecessor merge); Hermes reconciliation card and `agent-merge-conflict-arbiter`; Conductor "ask an agent to resolve conflicts" | Problem 3: high on the share of redo caused by base drift after a sibling merged. Load: medium. | M | `bin/fm-send.sh`, `fm-control.sh`, task metadata `pr=` and `pr_head=` |
| 4 | **Overlap and hotspot-aware dispatch.** At dispatch compute the declared or predicted path set. Disjoint tasks run in parallel at once. Tasks sharing a hotspot path (or a barrier file such as a lockfile or schema) take a dependency edge so the second starts after the first merges. Workers flag `hotspot: <path>`; two flags on one path create a refactor task first. | Mergify scopes and `barrier_files`; Hermes hotspot comments; Devin non-overlapping work packages; Conductor independent slices; Claude teams "each teammate owns different files" | Problem 3: high if overlap explains the 18% (to be measured). Problem 4: preserves parallelism by serialising only true overlaps. | M | `AGENTS.md:203` policy needs amending (a shared-surface change through the normal pipeline); backlog dependencies already exist (`AGENTS.md` section 10) |
| 5 | **Non-LLM dispatch tick with pre-written briefs.** A script claims the next ready backlog item (dependencies and time gates cleared, brief already on disk), checks `fm-capacity.sh --admit`, and calls `fm-spawn.sh`. The supervisor writes briefs in batches, not one per dispatch. Stale-claim reclaim and retry cooldowns live in the script. | Hermes dispatcher tick, atomic claim, `max_in_progress` and per-profile caps; Paperclip atomic checkout; Claude teams file-locked self-claim | Throughput: high. Today queue re-evaluation waits on supervisor turns (`AGENTS.md` section 10). Load: medium to high. Problem 4. | L | `fm-spawn.sh`, `fm-capacity.sh`, `fm-project-capacity-lib.sh`, `fm-tasks-axi.sh`. Brief authoring stays an agent job (`VISION.md`: scripts own mechanics). |
| 6 | **Lean supervisor context.** Wake from a compact state document (fleet snapshot, open decisions, and a small capped durable memory) in a fresh or reseeded session, not an ever-growing transcript. Treat cross-session messages and check-ins as full-context costs and batch or hold them. Keep task state out of memory. | Hermes capped frozen-snapshot memory (2,200 characters) and FTS recall; Devin index-only memory loaded lazily; Magentic-One ledger plus reset-and-reseed on stall; Claude costs page on full-context re-send; LangGraph subagent isolation | Load: high on tokens per wake (the 315k re-read) and on drift. Problem 1. | M to L | `bin/fm-fleet-snapshot.sh`, `state/home-summary.json`, `bin/fm-warm-compact-lib.sh` (cuts cache-write cost, not size), `/stow` memory routing |
| 7 | **Parent-first merge order and child retargeting for dependent PRs.** Record `depends_on` in task metadata. Merge parents first, retarget children to base after, and fail dependents when a parent is dequeued. Prefer independent slices over stacks in the first place. | Graphite atomic stacks; Mergify stack ordering and `stack-predecessor-dequeued`; Devin stacked PRs (GitHub.com only); Hermes parent-to-child gating | Problem 3: medium. Mostly needed if stacking cannot be avoided. | M | Merge worker (rank 1), task metadata |
| 8 | **Retry circuit breaker and active-PR respawn guard.** After N consecutive failures a task auto-blocks and surfaces once. Rate-limit exits requeue with a cooldown without counting as failure. A task that already has a PR is never respawned. | Hermes `failure_limit`, exit-code cooldowns, `active_pr` guard | Load: medium (stops thrash and repeat alarms). Problem 4: keeps lanes free of wedged tasks. | S | `fm-spawn.sh`, wedge ladder (`docs/architecture.md:14-80`) already bounds alarms |
| 9 | **Scheduled memory consolidation.** A periodic background pass merges overlapping notes and prunes stale ones, writing nothing about transient task state. | Devin "Dreaming"; Hermes consolidate-on-cap; OpenClaw pre-compaction memory flush | Drift: medium. Load: low to medium (smaller startup memory). Problem 1. | S to M | `/stow`, `fm-startup-memory-budget.sh` |
| 10 | **Spend caps and reserve-per-run.** Per-project or per-fleet budget with a warning threshold and a hard pause, and an estimate reserved before each spawn so parallel spawns cannot overshoot. A per-task model override for cheap routine work, within the operator's standing model rules. | Paperclip scoped budgets and reserve-per-run; Devin per-child ACU limits and auto-approve switch; Hermes per-task `--model` | Throughput: enabler. It makes raising parallelism safe. Load: low. | M | `docs/cost-ledger.md`, `config/lane-capacity`, `fm-pipeline-spend.sh` |

### Considered and not recommended

- **Per-round LLM orchestration (Magentic-One style).** It reproduces the bottleneck. Only the ledger and stall counter are worth taking.
- **`langgraph-supervisor`, AutoGen, Vibe Kanban.** All archived or sunsetting.
- **ClaudeClaw-style heartbeat prompts.** The pattern behind the no-op wakes.
- **Hosted merge queues as the first step.** GitHub's native queue is unavailable on many repository types (section 3.13), and Mergify or Graphite add a paid third-party dependency that sits outside `VISION.md`'s "fleet outlives any vendor". Revisit only if a local worker proves insufficient. Batching and bisection also pay off only with slow or costly CI.
- **Worker self-claim from a shared mailbox (Claude teams).** It changes the supervision model and is experimental. Rank 5 gets most of the throughput benefit with a script.
- **Cheaper-model supervisor by default.** `VISION.md` forbids downgrading the intelligence doing the work without explicit standing permission. Only triage steps already gated by judge-first-style shadow mode are candidates.

## 5. First three changes for firstmate

**Change 0 (prerequisite, effort S): measure before building.** Using the existing ledgers (`docs/cost-ledger.md`, `docs/fleet-ledger.md`, `state/.watch-triage.log`), split the 4h PR-to-merge median into time waiting for the supervisor, time in CI, and time waiting for operator approval, per project and per `yolo` setting. Separately classify each redone PR by cause: shared files with a concurrent PR, base drift after a sibling merged, or an actual defect. Break the 66% no-op wakes down by wake class. This makes the next three changes falsifiable and costs under a day.

1. **Generalise the merge worker (rank 1 plus the conflict half of rank 3). Effort M.**
   Extend `fm-merge-on-validated.sh` from "secondmate `validated` line, base `dev`" to any `yolo` ship task on a project's default branch, behind the same opt-in `dry-run` then `live` gate, using `fm-pr-merge.sh` as the only merge primitive. Add (a) an update-onto-base step before merging, (b) on conflict, a steer to the owning worker to rebase and re-queue, and (c) a pause sentinel. Run dry-run first and compare "would merge" against what the supervisor actually did. Merge authority is unchanged: `yolo` is already the operator's explicit grant, so `AGENTS.md` hard rule 2 stays intact. Non-`yolo` projects keep the operator in the loop and stay unaffected, which is why change 0 comes first.
2. **Wake tiering and coalescing (rank 2). Effort S to M.**
   In the watcher's triage, define a whitelist of wake classes that reach the LLM and route all other classes to a digest drained at the next real wake, with a coalescing window for bursts. Roll out the way judge-first rolled out: shadow mode first, logging what would have been suppressed, then on. Because failures to surface are the unsafe direction, keep the existing fail-toward-wake default for any class not on a reviewed list. The shadow log shows how many of the 66% are recoverable before anything is suppressed.
3. **Overlap-aware dispatch (rank 4). Effort M.**
   Add a path-scope check at dispatch. Compute the predicted touched paths from the brief, compare with active lanes' recorded paths, and add a dependency edge only when scopes overlap on a hotspot or barrier path (lockfiles, schema, generated files, shared indexes). Amend `AGENTS.md:203` to say that overlap on a declared hotspot is a dependency, while other overlap stays a risk signal. That text change is shared tracked material and must go through the pipeline and PR path (`AGENTS.md` section 1). The dispatch tick (rank 5) is the natural next step once these three land, and covers problem 4 directly.

Why these three: they attack problems 1, 2 and 3 using existing seams, each is independently shippable and reversible, and each has a shadow or dry-run mode so it can be validated against real fleet behaviour first. Problem 4 is addressed by rank 5, which is larger (L) and depends on briefs being written ahead of time.

## 6. Risks and open questions

- **The 4h median may be mostly human.** If most of it is operator approval on non-`yolo` projects, change 1 yields little. Change 0 settles this.
- **Redo causes are unverified.** The overlap hypothesis for the 18% is plausible, not shown.
- **Auto-merge widens blast radius.** A merge worker with a bug merges wrongly at machine speed. Keep dry-run first, bind merges to the verified head (`FM_PR_MERGE_EXPECTED_HEAD` already exists), keep the pause sentinel, and keep destructive and security-sensitive merges escalating (`AGENTS.md` section 7).
- **Whitelist errors hide real events.** Suppression is the unsafe direction, hence shadow mode and fail-toward-wake for unknown classes.
- **GitHub queue availability** must be checked per project before any plan that depends on it.
- Questions to settle with the operator: which projects are `yolo`; whether the 8 projects live in organisation-owned repositories; whether secondmate-routed work and direct crewmate work should share one merge worker.

## 7. Method and limits

- Sources were read on 2026-11-02 by four research agents using official docs and raw repository files. GitHub's API was blocked for some repositories, so star counts and release dates came from repository pages, package indexes and badges and are approximate.
- Where I re-fetched a source myself it is marked **V** in section 3. I re-fetched the Hermes kanban documentation, five repository licences, the `langgraph-supervisor` README and the GitHub merge-queue availability sentence. Everything marked **R** rests on an agent's reading of the cited page.
- Several documentation pages were summarised by the fetch tool, so config names in quotation or code font should be checked against the source before implementation.
- Not covered or unverified: Codex best-of-N, Devin Knowledge and DeepWiki, Claude background-session concurrency cap, Paperclip per-agent concurrency and merge path, OpenClaw landing, ClaudeClaw's other two repositories, Conductor checkpoints and source licence, Graphite CLI licence and conflict handling, and the current status of Graphite after its acquisition.
- I did not read the contents of `bin/fm-warm-compact-lib.sh` beyond its header, `docs/fleet-ledger.md`, or the wake-classification code, so the claims about how firstmate classifies wakes come from `docs/architecture.md` and `docs/configuration.md`, not from the code.
- Firstmate figures (66%, 315k, 11 minutes, 4 hours, 18%, 20 workers) were supplied in the task and not independently measured.
