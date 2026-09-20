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

Grok was launched with its working directory set to a LINKED worktree:

```
$ git -C <scratch>/wt rev-parse --show-toplevel
<scratch>/wt
$ git -C <scratch>/wt rev-parse --git-common-dir
<scratch>/proj/.git
```

The dialog named `<scratch>/proj`, not `<scratch>/wt`, and answering `y` wrote:

```
[folders."<scratch>/proj"]
trusted = true
decided_at = 1789874968
```

Two controls close the rule:

| Pre-registered key | Launch cwd | Dialog on next launch |
|---|---|---|
| `<scratch>/proj` (main root) | `<scratch>/wt` | none |
| `<scratch>/wt` (worktree only) | `<scratch>/wt` | still fires |

Registering the launch directory therefore writes a key Grok never reads.
`bin/fm-grok-trust.sh` derives the root from `git worktree list --porcelain`'s first entry and requires it to equal the `<project>` argument.

A launch through a symlink to the worktree recorded the same physical `<scratch>/proj`, so one physical key is sufficient and no logical form is registered.

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

## Not proven

- A grok SECONDMATE home is not pre-registered; that shape is out of this helper's scope and such a pane can still meet the dialog.
- `bin/fm-spawn.sh` does not forward `GROK_HOME` onto the launch, so a pane whose shell carries a different `GROK_HOME` than the registering process would read a different store.
- The binary is stripped, so the root-resolution rule is established from observed behavior and the vendor's own help text, not from source.
