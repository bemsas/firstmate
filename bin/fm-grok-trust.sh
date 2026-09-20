#!/usr/bin/env bash
# Pre-register Grok Build's folder trust for the repository a ship/scout spawn
# is about to launch a grok crewmate into, so the worker reaches its brief
# instead of parking on the directory-security dialog it cannot be steered past.
#
# Usage: fm-grok-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Grok 1.0.34 gates a workspace it has not trusted behind "Do
# you trust the contents of this directory?" / "Grok Build may run or modify
# contents in this directory, posing security risks", offering "Yes, proceed y"
# and "No, quit n". No launch flag suppresses it. The dialog needs a `y`, and
# firstmate's control plane carries Enter, Escape and Ctrl-C only, so the pane
# wedges and even exit refuses because composer state never reads as proven
# empty. Answering it by hand once leaves the same worker running normally, so
# the launch itself is sound and only the unanswerable prompt blocks it.
#
# THE KEY IS THE REPOSITORY'S MAIN WORKTREE ROOT, NOT THE LAUNCH DIRECTORY.
# This is the one fact the whole helper turns on, and it is the opposite of the
# per-exact-path model the other three trust stores use. Verified on grok 1.0.34
# by launching in a LINKED worktree and answering the dialog: the prompt named
# the primary checkout, and the record written was keyed to the primary
# checkout, not to the worktree the pane started in. Grok's own documentation
# states the rule from the other side - a grant "covers subdirectories of the
# same repository", while "a nested git checkout under that folder is a separate
# workspace and is not covered". A control run pre-registering the WORKTREE path
# alone left the dialog firing exactly as before, and pre-registering the main
# worktree root suppressed it. Registering the launch directory would therefore
# write a key Grok never reads. docs/verification/grok-folder-trust.md holds the
# dated commands and output for all three runs.
#
# CONSEQUENCE, STATED PLAINLY BECAUSE IT IS WIDER THAN A DISPOSABLE WORKTREE.
# Because that root is the only key Grok consults, trusting it necessarily
# trusts the whole repository - the primary checkout and every worktree and
# subdirectory of it - and Grok unifies MCP, LSP, hooks, project instructions
# and project skills under that single grant. The grant persists until removed
# and is not scoped to this task. It is still the narrowest thing that works:
# the only alternative Grok offers is GROK_FOLDER_TRUST=0 / [folder_trust]
# enabled = false, which ungates those surfaces for every repository at once.
# This helper never widens beyond the one repository the spawn names, and the
# scope test below is what holds it there.
#
# THE STORE, verified against the installed 1.0.34 binary and the records Grok
# itself wrote on this machine:
#   - ${GROK_HOME:-$HOME/.grok}/trusted_folders.toml, mode 0600. Grok resolves
#     its home as GROK_HOME first, then ~/.grok.
#   - One TOML table per trusted root, keyed by absolute path:
#       [folders."/absolute/path"]
#       trusted = true
#       decided_at = <epoch seconds>
#   - Paths are physical: a launch through a symlinked worktree recorded the
#     resolved root, so one key is enough and no logical form is registered.
#   - Grok refuses to record an over-broad root (home, filesystem root, or a
#     non-absolute path) and leaves a store it cannot read untouched. Both
#     refusals are mirrored below so this never writes what Grok would reject.
#
# PRESERVATION IS BYTE-EXACT. The store is one shared file holding every folder
# the user has ever trusted, so losing it would re-wedge every previously
# trusted directory. A new grant is APPENDED and no existing byte is rewritten,
# which keeps unrelated entries, ordering, spacing and comments exactly as they
# were. A store that does not parse as TOML is refused rather than rewritten. A
# root already recorded as trusted is left alone with its original decided_at,
# so re-running is a no-op. A root recorded as explicitly NOT trusted is
# refused, never flipped: that value can only have been set deliberately, and
# silently overriding a declined folder is not this helper's call to make. The
# write lands as an exclusive-create temp file renamed over the store, mode
# 0600, with a fingerprint check before the rename and a re-read after it,
# because Grok rewrites this same file whenever a dialog is answered.
#
# SECONDMATE HOMES ARE OUT OF SCOPE, AND THAT IS A GAP, NOT A PROOF. This helper
# covers crewmate and scout launches only: it has the worktree shape and nothing
# else, and bin/fm-spawn.sh calls it for those two kinds. A grok SECONDMATE is a
# supported launch whose home is NOT pre-registered, so such a pane still meets
# the dialog. Closing that gap means a --secondmate-home mode like
# bin/fm-claude-trust.sh's, whose seed evidence proves the home is the one the
# spawn is about to launch into; it is not a widening of this scope test.
#
# GROK_HOME. This honours it because Grok does, but bin/fm-spawn.sh does not
# forward it onto the launch: the pane's own shell must carry the same value for
# the worker to read the store written here. A relative value is refused rather
# than guessed at, because it would resolve against this process's cwd here and
# the pane's cwd there.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect a relative `cd` operand, and an inherited GIT_DIR with GIT_WORK_TREE
# makes a primary checkout report a linked worktree's git dir, so the
# primary-checkout refusal would pass. Clear the whole class once here so every
# subshell inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-grok-trust.sh <worktree> <project>" >&2
  exit 2
}

case "${1:-}" in
  '' | -h | --help) usage ;;
esac
[ "$#" -eq 2 ] || usage
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Grok trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "task worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so Grok's home directory cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"

case ${GROK_HOME:-} in
  '') GROK_DIR="$HOME_REAL/.grok" ;;
  /*) GROK_DIR=$GROK_HOME ;;
  *) refuse "GROK_HOME '$GROK_HOME' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac

# The filesystem root, the home directory, and Grok's own home are never
# something this registers. Checked explicitly so the refusal names the real
# reason instead of the scope verdict behind it.
[ "$WT_REAL" != / ] || refuse "'/' is the filesystem root, not a task worktree"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
GROK_DIR_REAL=$(real_dir "$GROK_DIR") || true
if [ -n "$GROK_DIR_REAL" ]; then
  [ "$WT_REAL" != "$GROK_DIR_REAL" ] || refuse "'$WT_REAL' is the Grok home directory, not a task worktree"
fi

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

# The root Grok will look up: the repository's MAIN worktree, which is the first
# entry `git worktree list` reports. Derived from git rather than assumed from
# <project>, then required to BE <project>: the caller names the primary checkout
# it is registering, and a disagreement means this spawn's idea of the project
# and the key Grok reads have come apart, which is exactly when writing a grant
# blind would trust the wrong repository.
TRUST_ROOT=$(git -C "$WT_REAL" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}') || true
[ -n "$TRUST_ROOT" ] || refuse "'$WT_REAL' has no resolvable main worktree, so the folder Grok would look up is unknown"
TRUST_ROOT_REAL=$(real_dir "$TRUST_ROOT") || true
[ -n "$TRUST_ROOT_REAL" ] || refuse "main worktree '$TRUST_ROOT' is not an accessible directory"
[ "$TRUST_ROOT_REAL" = "$PROJ_REAL" ] || refuse "project '$PROJ_REAL' is not this repository's main worktree (Grok would look up '$TRUST_ROOT_REAL'), so the grant would not cover the launch"

# Mirror Grok's own over-broad refusals so this never writes a record Grok
# would reject, and never trusts a root far wider than one repository.
case $TRUST_ROOT_REAL in
  /*) ;;
  *) refuse "main worktree '$TRUST_ROOT_REAL' is not an absolute path" ;;
esac
[ "$TRUST_ROOT_REAL" != / ] || refuse "'/' is the filesystem root and is too broad to trust"
[ "$TRUST_ROOT_REAL" != "$HOME_REAL" ] || refuse "'$TRUST_ROOT_REAL' is the home directory and is too broad to trust"
if [ -n "$GROK_DIR_REAL" ]; then
  [ "$TRUST_ROOT_REAL" != "$GROK_DIR_REAL" ] || refuse "'$TRUST_ROOT_REAL' is the Grok home directory, not a project"
fi

# The store is TOML, so reading it back correctly needs a real parser: a store
# this cannot parse is refused rather than rewritten, and a missing interpreter
# refuses like every other failure here, because degrading would launch a worker
# straight into the dialog this registration exists to remove.
command -v python3 >/dev/null 2>&1 || refuse "python3 with tomllib is required to record folder trust and was not found on PATH"

# Grok creates its home itself; an absent one is created privately here so the
# store is never the thing that fails a launch. An existing directory keeps
# whatever mode it has. A dotfile manager may symlink it, so the link is
# followed and the target judged; ownership is the property that matters.
if [ ! -e "$GROK_DIR" ]; then
  mkdir -m 0700 "$GROK_DIR" 2>/dev/null || true
fi
GROK_DIR_REAL=$(real_dir "$GROK_DIR") || true
[ -n "$GROK_DIR_REAL" ] || refuse "Grok home '$GROK_DIR' does not exist and could not be created"
[ -d "$GROK_DIR_REAL" ] || refuse "Grok home '$GROK_DIR' is not a directory"
[ -O "$GROK_DIR_REAL" ] || refuse "Grok home '$GROK_DIR_REAL' is not owned by this user"
[ -w "$GROK_DIR_REAL" ] || refuse "Grok home '$GROK_DIR_REAL' is not writable"

STORE="$GROK_DIR_REAL/trusted_folders.toml"
if [ -L "$STORE" ]; then
  STORE_TARGET=$(python3 -c 'import os,sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_TARGET" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_TARGET
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

if ! python3 - "$STORE" "$TRUST_ROOT_REAL" <<'PY'
import hashlib
import os
import secrets
import sys
import time

try:
    import tomllib
except ImportError:
    print("python3 is too old to parse the trust store: tomllib is required", file=sys.stderr)
    raise SystemExit(1)

store, root = sys.argv[1], sys.argv[2]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_store():
    try:
        with open(store, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def fingerprint(raw):
    return "absent" if raw is None else hashlib.sha256(raw).hexdigest()


def parse(raw, label):
    """Parse the store, or refuse. A store that does not parse is never rewritten."""
    if raw is None or raw.strip() == b"":
        return {}
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"{label} is not UTF-8 ({error}); refusing to rewrite it")
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        fail(f"{label} is not valid TOML ({error}); refusing to rewrite it")


def folders_of(data, label):
    folders = data.get("folders", {})
    if not isinstance(folders, dict):
        fail(f'{label} has a non-table "folders" value; refusing to rewrite it')
    return folders


def state_of(folders, label):
    """already-trusted, explicitly-declined, or absent."""
    entry = folders.get(root)
    if entry is None:
        return "absent"
    if not isinstance(entry, dict):
        fail(f'{label} has a non-table entry for "{root}"; refusing to rewrite it')
    trusted = entry.get("trusted")
    if trusted is True:
        return "trusted"
    # Only a deliberate decision can have put a non-true value here, and
    # flipping it to trusted is not this helper's call to make.
    return "declined"


def toml_key(value):
    """Escape a path for a TOML basic string, the quoting Grok's own keys use."""
    out = []
    for char in value:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            out.append("\\u%04X" % ord(char))
        else:
            out.append(char)
    return "".join(out)


def attempt():
    original = read_store()
    before = fingerprint(original)
    state = state_of(folders_of(parse(original, store), store), store)
    if state == "trusted":
        return "recorded"
    if state == "declined":
        fail(
            f'"{root}" is recorded in {store} as not trusted; refusing to override a '
            "folder that was deliberately declined"
        )

    # Append only: every existing byte is preserved exactly, so unrelated
    # entries, ordering, spacing and comments survive untouched.
    block = '[folders."%s"]\ntrusted = true\ndecided_at = %d\n' % (
        toml_key(root),
        int(time.time()),
    )
    body = b"" if original is None else original
    if body and not body.endswith(b"\n"):
        block = "\n" + block
    if body:
        block = "\n" + block
    updated = body + block.encode("utf-8")

    # The appended result must itself parse and carry the grant, so a store
    # whose shape this did not anticipate is caught before it is installed.
    if state_of(folders_of(parse(updated, "the updated store"), "the updated store"), "the updated store") != "trusted":
        fail(f"the updated store would not record trust for {root}; refusing to install it")

    tmp = os.path.join(
        os.path.dirname(store) or ".",
        ".trusted_folders.toml.fm-trust.%d.%s" % (os.getpid(), secrets.token_hex(8)),
    )
    handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    renamed = False
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(updated)
        os.chmod(tmp, 0o600)
        # Grok rewrites this same file when a dialog is answered, so a store
        # that moved under us is retried rather than clobbered.
        if fingerprint(read_store()) != before:
            return "moved"
        os.replace(tmp, store)
        renamed = True
    finally:
        if not renamed:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass

    readback = read_store()
    if state_of(folders_of(parse(readback, store), store), store) != "trusted":
        return "dropped"
    return "recorded"


for index in range(3):
    result = attempt()
    if result == "recorded":
        raise SystemExit(0)
    if result == "moved" and index >= 1:
        fail(f"{store} was modified while trust was being recorded; refusing to overwrite it")

fail(f"{store} did not retain trust for {root} after 3 attempts")
PY
then
  refuse "could not record trust for '$TRUST_ROOT_REAL' in '$STORE'"
fi

echo "trusted: $TRUST_ROOT_REAL (covers worktree $WT_REAL)"
