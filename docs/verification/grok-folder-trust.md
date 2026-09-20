# Verification: Grok folder trust and the key Firstmate must register

Active empirical facts for `bin/fm-grok-trust.sh` and the grok branch of `bin/fm-spawn.sh`.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/grok.md`](../../.agents/skills/harness-adapters/references/harness/grok.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `grok 1.0.34 (3736acbc8658) [stable]` |
| Verified | 2026-09-20 |
| Binary | `.../node_modules/@xai-official/grok/bin/grok-native`, an ELF 64-bit static-PIE executable, stripped |
| Platform | Linux x64 (kernel 7.2.5-3-omarchy) |
| Backend | tmux, in a disposable firstmate task worktree |

Every run below used a throwaway `GROK_HOME` under the session scratch directory.
The captain's live `~/.grok/trusted_folders.toml` was read and copied but never written; each assertion about it is a read or a check against a copy.

## The store

```
$ stat -c '%a %n' ~/.grok/trusted_folders.toml
600 /home/bemsas/.grok/trusted_folders.toml
$ grep -c '^\[folders\.' ~/.grok/trusted_folders.toml
13
```

The format is one TOML table per trusted root, keyed by absolute path:

```
[folders."/home/bemsas/Projects/firstmate"]
trusted = true
decided_at = 1789669934
```

`GROK_HOME` selects the home; it falls back to `~/.grok`.
Strings in the binary confirm both the path and the env var, and name a sibling `trusted_folders.toml.lock`.

## The dialog, and what actually triggers it

The prompt is rendered only for a workspace carrying trust-relevant surfaces.
A bare git repository with one text file did NOT raise it; the same worktree raised it immediately once an `AGENTS.md` and a `.grok/settings.json` hooks block were committed.
Grok's own help text states the reason from the other side: a grant covers "MCP, LSP, hooks, project instructions, and project skills" together.
Every firstmate worktree carries project instructions, so every firstmate grok launch is in the triggering class.

```
Do you trust the contents of this directory?
<path>
Grok Build may run or modify contents in this directory,
posing security risks.
    Yes, proceed   y
    No, quit       n
```

Answering `n` quits and records nothing: the store was still absent afterwards.
So a `trusted = false` value cannot come from the ordinary decline path, and `bin/fm-grok-trust.sh` refuses such an entry rather than flipping it.

## The key is the repository's MAIN worktree root

This is the load-bearing fact, and it is the opposite of the per-exact-path model the claude, agy and kimi stores use.
**The per-exact-path model is FALSE for grok 1.0.34**: a grant keyed to the worktree path alone provably does not suppress the dialog.

Grok was launched with its working directory set to a LINKED worktree:

```
$ git -C <scratch>/wt rev-parse --show-toplevel
<scratch>/wt
$ git -C <scratch>/wt rev-parse --git-common-dir
<scratch>/proj/.git
```

The dialog named `<scratch>/proj`, not `<scratch>/wt`.

### The three-arm control

Re-run cleanly after review raised the objection that the registering process and the launched pane might resolve different stores, because `bin/fm-spawn.sh` does not forward `GROK_HOME` onto the launch.
That confound is now closed: for every arm the launched pane's own `/proc/<pid>/environ` was read and its `GROK_HOME` proved identical to the one the seeding used.
Every arm started from a FRESH store holding at most one key, so no arm could be rescued by a grant another arm left behind.
Launch cwd was the LINKED worktree `<scratch>/wt`; the repository's main worktree root was `<scratch>/proj`.

| Arm | Store seeded with | Same store proven | Dialog |
|---|---|---|---|
| control | nothing | yes | FIRES |
| worktree-key-only | `<scratch>/wt` | yes | FIRES |
| main-root-key-only | `<scratch>/proj` | yes | suppressed |

The worktree key alone does not suppress the dialog; the main-root key alone does.
The experiment separates the two models cleanly, so only the main root is registered - writing both keys would satisfy either model at the cost of an entry Grok never reads.
`bin/fm-grok-trust.sh` derives that root from `git worktree list --porcelain`'s first entry and requires it to equal the `<project>` argument.

A launch through a symlink to the worktree recorded the same physical `<scratch>/proj`, so one physical key is sufficient and no logical form is registered.

## Corroboration from the live store and session history

Grok writes a session directory per workspace under `~/.grok/sessions`, keyed by URL-encoded workspace path, which gives an independent audit trail on the captain's own machine - not a synthetic fixture.
All five findings below are reads; nothing was written.

1. **Provenance of the ten `basisone` worktree keys.** `~/.grok/trusted_folders.toml.bak-1789783903` shows the store held only TWO entries immediately before those ten appeared, and all ten carry the identical `decided_at 1789783903`. Ten identical seconds is a programmatic bulk write, not ten answered dialogs.
2. **Those keys enabled nothing.** Between that bulk write (1789783903) and the main-root entry (1789785068) there are ZERO grok session files in any of the ten worktrees. Worktrees 4 through 10 have no session directory at all: keys written, never used.
3. **The competing explanation is refuted.** The main-root entry did not come from launching at the project root: grok has NO session directory for `/home/bemsas/Projects/firstmate/projects/basisone`, so it was never launched there. The earliest session in any `basisone` worktree is `1789785068.605` - the same second as the main-root `decided_at` - so that entry was written by a launch IN A WORKTREE.
4. **A second independent instance, two days earlier.** `projects/neuronet.com` carries a trust entry at `decided_at 1789679011` while grok has sessions only for `.treehouse/neuronet.com-f2fd67/3/neuronet.com`, earliest `1789679011.501` - same second - and no session directory for `projects/neuronet.com`. Launch in a worktree, trust recorded on the main root.
5. **The one genuine main-root launch behaves consistently.** `/home/bemsas/Projects/firstmate` has sessions at `1789669934.867` and a trust entry at `1789669934`.

## Consequence: the grant is repository-wide

Because that root is the only key Grok consults, trusting it trusts the whole repository - the primary checkout and every worktree and subdirectory of it - for MCP, LSP, hooks, project instructions and project skills together, until the entry is removed.
This is wider than the disposable worktree the other three trust helpers register, and it is not scoped to one task.
It remains the narrowest option Grok offers: the only alternative is `GROK_FOLDER_TRUST=0` / `[folder_trust] enabled = false`, which ungates those surfaces for every repository at once.

## End-to-end proof of the fix

Against a throwaway home, in the same worktree, with no other change:

```
$ grok --no-alt-screen        # control
  -> "Do you trust the contents of this directory?"

$ bin/fm-grok-trust.sh <scratch>/wt <scratch>/proj
trusted: <scratch>/proj (covers worktree <scratch>/wt)
$ grok --no-alt-screen
  -> no dialog; the composer rendered and the worker was ready
```

## Preservation against the real 13-entry store

Run against a COPY of the captain's live store:

```
entries before: 13
$ GROK_HOME=<copy> bin/fm-grok-trust.sh <scratch>/wt <scratch>/proj
trusted: <scratch>/proj (covers worktree <scratch>/wt)
entries after: 14
mode: 600
all 13 original entries intact
```

The original file's bytes remained an exact prefix of the result (identical SHA-256 over the first `<original size>` bytes), which is the mechanism: a new grant is appended and no existing byte is rewritten, so unrelated entries, ordering, spacing and comments survive.
A second run left `decided_at` unchanged and added no duplicate.

## Refusals confirmed by hand

Each exited non-zero and wrote no store: the primary checkout, a subdirectory of the worktree, a worktree of an unrelated project, the home directory, the filesystem root, the Grok home, a plain non-git directory, a missing path, a relative `GROK_HOME`, and any argument count other than two.
An unparseable store, a non-table `folders` value, and a folder already recorded `trusted = false` were each refused with the store left byte-identical.

## Regression coverage

[`tests/fm-grok-trust.test.sh`](../../tests/fm-grok-trust.test.sh) pins all of the above that can be proven without the grok binary, including the main-root-not-worktree key, append-only preservation, every refusal, and both spawn-wiring outcomes.
It was confirmed non-vacuous: with the `grok*)` branch of `bin/fm-spawn.sh` reverted, the spawn case fails.
That suite pins the chosen contract; it cannot decide whether the contract still matches grok, because no assertion over a TOML file can observe the dialog.

[`tests/fm-grok-trust-live-e2e.test.sh`](../../tests/fm-grok-trust-live-e2e.test.sh) is the guard that can.
It reproduces the three-arm control above against the installed binary - including the `/proc/<pid>/environ` check that each arm's pane read the store that arm seeded - and seeds its main-root arm by running `bin/fm-grok-trust.sh` itself, so a future grok that keys trust differently fails it by name.
It submits no prompts, so it is default-on wherever grok is installed, and it reports a capability skip rather than passing quietly when grok, credentials, or `/proc` are absent.

## Not proven

- A grok SECONDMATE home is not pre-registered; that shape is out of this helper's scope and such a pane can still meet the dialog.
- `bin/fm-spawn.sh` does not forward `GROK_HOME` onto the launch, so a pane whose shell carries a different `GROK_HOME` than the registering process would read a different store.
- The binary is stripped, so the root-resolution rule is established from observed behavior and the vendor's own help text, not from source.
- The author of the ten bulk-written `basisone` worktree keys could not be identified from fleet records. Only their effect is established: they were written programmatically in one second and no grok session ever used them.
