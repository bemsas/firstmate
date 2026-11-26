#!/usr/bin/env python3
"""Worker pre-tool guardrail. Read one JSON hook payload from stdin.

Usage: fm-worker-pretool-check.py [--root WORKTREE] [--cursor] [--kimi] [--polytoken]
Exit 2 blocks vendor/basisone writes and git worktree add/remove/prune/move.
The vendor rule is CommercialEye's: it is skipped only when --root (bound at
launch, never the payload cwd) is a checkout whose origin verifies as another
repository. A missing or unverifiable identity keeps the rule.
Read tools remain available. Shell commands touching protected paths are allowed
only for known read operations, whose redirections name literal paths outside
the subtree. Quoted here-documents that cat writes to literal paths outside it
are data. This is a tool-call seatbelt, not an OS sandbox.
--kimi scopes the global hook to an authenticated Firstmate worker pointer.
--polytoken emits that harness's native allow outcome.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def protected(value, cwd, parents=False):
    if not isinstance(value, str) or not value:
        return False
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = Path(cwd) / path
    for candidate in (Path(os.path.abspath(path)), path.resolve()):
        parts = candidate.parts
        if any(parts[i:i + 2] == ("vendor", "basisone") for i in range(len(parts) - 1)):
            return True
        if parents and candidate.name == "vendor":
            return True
    return False


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def paths(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"path", "file_path", "filePath", "filename", "target_file",
                       "old_path", "new_path", "destination", "source", "uri"}:
                yield from strings(child)
            elif isinstance(child, (dict, list)):
                yield from paths(child)
    elif isinstance(value, list):
        for child in value:
            yield from paths(child)


READ_TOOLS = {"read", "readfile", "read_file", "file_read", "read_text_file", "glob", "grep",
              "list", "ls", "list_directory", "search", "search_file_content"}
READ_COMMANDS = {"cat", "head", "tail", "ls", "pwd", "rg", "grep", "wc", "stat",
                 "file", "test", "[", "diff", "less", "more", "readlink", "realpath"}
GIT_READ = {"status", "diff", "show", "log", "rev-parse", "ls-files", "grep",
            "blame", "describe", "cat-file"}


def tokens(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    # strip_heredocs already removed real comments; a mid-word # is literal and
    # must not hide a later redirection.
    lexer.commenters = ""
    return list(lexer)


def git_words(words):
    """Skip Git global flags, including options with separate arguments."""
    i = 1
    while i < len(words) and words[i].startswith("-"):
        word = words[i]
        i += 1
        if word in {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}:
            i += 1
    return words[i:]


def strip_heredocs(command):
    """Split here-document bodies out of the command text.

    Returns (text, bodies): text keeps every operator and word outside the
    bodies, bodies lists a (chunk, delimiter, tabs, literal) tuple for each
    << or <<- operator, so heredoc data with unbalanced quotes never breaks
    tokenisation. literal means a quoted delimiter whose terminator was found.
    """
    out = []
    bodies = []
    pending = []
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in {"'", '"'}:
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            # Kept as one chunk so an escaped space never starts a comment.
            out.append(command[i:i + 2])
            i += 2
            continue
        if ch == "#" and (not out or out[-1] in " \t\n;&|<>()"):
            while i < n and command[i] != "\n":
                i += 1
            continue
        if ch == "<" and command.startswith("<<", i):
            if command.startswith("<<<", i):
                out.append("<<<")
                i += 3
                continue
            j = i + 2
            tabs = command.startswith("-", j)
            if tabs:
                j += 1
            while j < n and command[j] in " \t":
                j += 1
            if j < n and command[j] in {"'", '"'}:
                close = command.find(command[j], j + 1)
                if close == -1:
                    out.append(ch)
                    i += 1
                    continue
                delimiter = command[j + 1:close]
                quoted = True
                j = close + 1
            else:
                end = j
                while end < n and command[end] not in " \t\n;&|<>()":
                    end += 1
                delimiter = command[j:end]
                quoted = "\\" in delimiter
                j = end
            if delimiter:
                pending.append((delimiter.replace("\\", ""), tabs, quoted))
            out.append(command[i:j])
            i = j
            continue
        if ch == "\n" and pending:
            out.append(ch)
            i += 1
            for delimiter, tabs, quoted in pending:
                body_start = i
                while i < n:
                    body_stop = i
                    line_end = command.find("\n", i)
                    line, after = ((command[i:], n) if line_end == -1
                                   else (command[i:line_end], line_end + 1))
                    i = after
                    probe = line.lstrip("\t") if tabs else line
                    if probe.endswith("\r"):
                        probe = probe[:-1]
                    if probe == delimiter:
                        bodies.append((command[body_start:body_stop], delimiter, tabs, quoted))
                        break
                else:
                    bodies.append((command[body_start:n], delimiter, tabs, False))
            pending = []
            continue
        out.append(ch)
        i += 1
    return "".join(out), bodies


def literal_target(word, cwd):
    """A redirection target that provably names a path outside the subtree."""
    return (not any(char in word for char in "$`*?[]{}()<>;&|\n")
            and (not word.startswith("~") or word.startswith("~/"))
            and not protected(word, cwd, parents=True))


def data_authoring(words, bodies, cwd):
    """True when every command is cat writing one literal here-document."""
    if not bodies or not all(body[3] for body in bodies):
        return False
    pending = list(bodies)
    segment = []
    for word in [*words, "\n"]:
        if not (set(word) <= set(";&\n") and word.strip("\n") in {"", ";", "&&"}):
            segment.append(word)
            continue
        if not segment:
            continue
        if segment[0] != "cat" or len(segment) % 2 == 0:
            return False
        feeds = 0
        for operator, target in zip(segment[1::2], segment[2::2]):
            if operator == "<<" and pending:
                _, delimiter, tabs, _ = pending.pop(0)
                if target != delimiter and not (tabs and target == "-" + delimiter):
                    return False
                feeds += 1
            elif operator not in {">", ">>"} or not literal_target(target, cwd):
                return False
        if feeds != 1:
            return False
        segment = []
    return not pending


def without_safe_redirects(words, cwd):
    """Drop redirections that cannot write the subtree; None if any might."""
    kept = []
    remaining = iter(words)
    for word in remaining:
        if "<" not in word and ">" not in word:
            kept.append(word)
            continue
        target = next(remaining, "")
        if word == ">&" and target.isdigit():
            continue
        if word not in {"<", ">", ">>", "&>"} or not target or not literal_target(target, cwd):
            return None
    return kept


def conservative_reason(command, vendor):
    """Raw-text fallback when the lexer still cannot tokenise the command."""
    if vendor and re.search(r"\bvendor/+basisone(?:/|\b)", command):
        return "worker edits to vendor/basisone are blocked"
    if re.search(r"\bgit\b[^;\n&|]*\bworktree\s+(?:add|remove|prune|move)\b", command):
        return "workers cannot administer git worktrees"
    return None


def shell_reason(command, cwd, vendor=True, depth=0):
    if depth > 8:
        return "shell nesting exceeds the worker guardrail limit"
    stripped, bodies = strip_heredocs(command)
    try:
        words = tokens(stripped)
    except ValueError:
        return conservative_reason(command, vendor)
    # Scan each command, including commands behind env, command, sudo and shell
    # operators. Quoted shell scripts are inspected recursively, never executed.
    for i, word in enumerate(words):
        if os.path.basename(word) == "git":
            args = git_words(words[i:])
            if len(args) >= 2 and args[0] == "worktree" and args[1] in {"add", "remove", "prune", "move"}:
                return "workers cannot administer git worktrees"
        if os.path.basename(word) in {"bash", "sh", "zsh", "dash", "fish"}:
            rest = words[i + 1:]
            for j, arg in enumerate(rest[:-1]):
                if arg.startswith("-") and "c" in arg:
                    reason = shell_reason(rest[j + 1], cwd, vendor, depth + 1)
                    if reason:
                        return reason
                    break
    mentions = vendor and (protected(cwd, cwd) or any(
        protected(word, cwd, parents=True) or re.search(r"\bvendor/+basisone(?:/|\b)", word)
        for word in words
    ))
    if not mentions:
        # Heredoc bodies can feed interpreters or hide paths, so each stripped
        # body is inspected like a quoted shell script. Proven data keeps every
        # rule except the vendor one, since only its literal targets are written.
        body_vendor = vendor and not data_authoring(words, bodies, cwd)
        for body in bodies:
            denied = shell_reason(body[0], cwd, body_vendor, depth + 1)
            if denied:
                return denied
        return None
    # Substitutions, unproven redirections and unknown interpreters with a
    # protected path are not read-only. Require explicit read commands throughout.
    words = without_safe_redirects(words, cwd)
    if words is None or any(word in {"(", ")"} for word in words) or "$" in command or "`" in command:
        return "shell writes or indirection involving vendor/basisone are blocked"
    segments = [[]]
    for word in words:
        if set(word) <= set(";&|\n"):
            segments.append([])
        else:
            segments[-1].append(word)
    for segment in segments:
        if not segment:
            continue
        name = os.path.basename(segment[0])
        if name in READ_COMMANDS:
            # ripgrep --pre and --hostname-bin execute arbitrary programs.
            if name == "rg" and any(w.startswith(("--pre", "--hostname-bin")) for w in segment[1:]):
                return "read command subprocesses involving vendor/basisone are blocked"
            continue
        if name == "git" and git_words(segment)[:1] in [[cmd] for cmd in GIT_READ] and not any(
            w.startswith(("--output", "--open-files-in-pager")) for w in segment[1:]
        ):
            continue
        return "worker edits to vendor/basisone are blocked"
    return None


# Reuse the role library's offline remote normalization for repository identity.
IDENTITY_SCRIPT = r"""
. "$1" || exit 1
[ "$(git -C "$2" rev-parse --show-toplevel)" -ef "$2" ] || exit 1
remotes=$(git -C "$2" remote) || exit 1
for remote in $remotes; do
  url=$(git -C "$2" remote get-url "$remote") || exit 1
  printf '%s\t%s\n' "$remote" "$(fm_role_remote_identity "$url" "$2")"
done
"""


def commercialeye_scope(root):
    """False only when the launch root verifies as some other repository."""
    if not root:
        return True
    library = Path(__file__).resolve().with_name("fm-role-lib.sh")
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        result = subprocess.run(["bash", "-c", IDENTITY_SCRIPT, "identity", str(library), str(root)],
                                env=env, text=True, capture_output=True, timeout=5)
        identities = dict(line.split("\t", 1) for line in result.stdout.splitlines())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return True
    origin = identities.get("origin", "")
    if result.returncode or not origin or origin.startswith("path:"):
        return True
    return any(identity.rsplit("/", 1)[-1].lower().removesuffix(".git") == "commercialeye"
               for identity in identities.values())


def reason(payload, root):
    denied = evaluate(payload, root, True)
    if denied and not commercialeye_scope(root):
        return evaluate(payload, root, False)
    return denied


def evaluate(payload, root, vendor):
    name = str(payload.get("tool_name", payload.get("toolName", ""))).lower()
    args = payload.get("tool_input", payload.get("toolInput", payload.get("input", {})))
    cwd = payload.get("cwd") or root or os.getcwd()
    if not isinstance(cwd, str):
        return "invalid worker hook working directory"
    if isinstance(args, dict):
        command = args.get("command", args.get("cmd"))
        if isinstance(command, list):
            command = shlex.join(command)
        if isinstance(command, str):
            denied = shell_reason(command, cwd, vendor)
            if denied:
                return denied
        if vendor and name not in READ_TOOLS and any(protected(p, cwd, parents=True) for p in paths(args)):
            return "worker edits to vendor/basisone are blocked"
    if vendor and "patch" in name:
        for text in strings(args):
            for match in re.finditer(r"^(?:\*\*\* (?:Add|Update|Delete|Move to) File: |\*\*\* Move to: |(?:rename|copy) (?:from|to) )(.+)$", text, re.M):
                if protected(match[1], cwd, parents=True):
                    return "worker patches to vendor/basisone are blocked"
    return None


def kimi_worker(payload):
    cwd = payload.get("cwd")
    if not isinstance(cwd, str):
        return False
    try:
        pointer = (Path(cwd) / ".fm-kimi-turnend").read_text().strip()
        if not re.fullmatch(r"token=fm\.[A-Za-z0-9]{12}", pointer):
            return False
        target = (Path.home() / ".kimi-code/fm-turn-end.d" / pointer[6:]).read_text().strip()
        return target.startswith("/") and target.endswith(".turn-ended")
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root")
    parser.add_argument("--cursor", action="store_true")
    parser.add_argument("--kimi", action="store_true")
    parser.add_argument("--polytoken", action="store_true")
    options = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("expected a JSON object")
        if options.kimi and not kimi_worker(payload):
            return 0
        denied = reason(payload, options.root)
    except (ValueError, OSError, TypeError) as error:
        denied = f"cannot validate worker tool call: {error}"
    if denied:
        print(f"blocked: {denied}. (a) ask firstmate to arrange the change (recommended); (b) continue within the assigned worktree and scope", file=sys.stderr)
        return 2
    if options.cursor:
        print('{"permission":"allow"}')
    elif options.polytoken:
        print('{"outcome":"allow"}')
    else:
        print("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
