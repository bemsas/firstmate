#!/usr/bin/env python3
"""Worker pre-tool guardrail. Read one JSON hook payload from stdin.

Usage: fm-worker-pretool-check.py [--root WORKTREE] [--cursor] [--kimi] [--polytoken]
Exit 2 blocks vendor/basisone writes and git worktree add/remove/prune/move.
Read tools remain available. Shell commands touching protected paths are allowed
only for known read operations; this is a tool-call seatbelt, not an OS sandbox.
--kimi scopes the global hook to an authenticated Firstmate worker pointer.
--polytoken emits that harness's native allow outcome.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
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
    lexer.commenters = "#"
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


def shell_reason(command, cwd, depth=0):
    if depth > 8:
        return "shell nesting exceeds the worker guardrail limit"
    try:
        words = tokens(command)
    except ValueError:
        return "cannot parse shell command for worker guardrails"
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
                    reason = shell_reason(rest[j + 1], cwd, depth + 1)
                    if reason:
                        return reason
                    break
    mentions = protected(cwd, cwd) or any(
        protected(word, cwd, parents=True) or re.search(r"\bvendor/+basisone(?:/|\b)", word)
        for word in words
    )
    if not mentions:
        return None
    # Redirections, substitutions and unknown interpreters with a protected
    # path are not proven read-only. Require explicit read commands throughout.
    if any("<" in word or ">" in word or word in {"(", ")"} for word in words) or "$" in command or "`" in command:
        return "shell writes or indirection involving vendor/basisone are blocked"
    segments = [[]]
    for word in words:
        if word in {";", "&&", "||", "|", "&", "\n"}:
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


def reason(payload, root):
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
            denied = shell_reason(command, cwd)
            if denied:
                return denied
        if name not in READ_TOOLS and any(protected(p, cwd, parents=True) for p in paths(args)):
            return "worker edits to vendor/basisone are blocked"
    if "patch" in name:
        for text in strings(args):
            for match in re.finditer(r"^(?:\*\*\* (?:Add|Update|Delete|Move to) File: |\*\*\* Move to: |(?:rename|copy) (?:from|to) )(.+)$", text, re.M):
                if protected(match[1], cwd):
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
