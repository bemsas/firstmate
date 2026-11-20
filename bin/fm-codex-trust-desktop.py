#!/usr/bin/env python3
"""Inspect or answer native trust dialogs for recorded Linux Herdr Codex workers.

Use --dry-run (stdout only) before --apply. Both resolve the same pane, process,
Git and dialog evidence. Apply reports refusals on stdout for the Main watcher
and keeps a private, fsynced JSONL journal under Main/state/codex-trust-desktop.
The Herdr adapter owns the idle-shell proof used to skip retired endpoints.
--task limits an attended check to HOME_ID/TASK (main, ops, or a local registry
ID). The watcher leaves it unset. See configuration.md for registration.
"""

import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import stat
import subprocess
import sys
import time


BIN = Path(__file__).resolve().parent
SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
TARGET = re.compile(r"(?P<session>[A-Za-z0-9][A-Za-z0-9._-]*):(?P<pane>(?P<workspace>w[A-Za-z0-9]+):p[A-Za-z0-9]+)")
HERDR_VERSION = "0.9.5"
CODEX_VERSION = "codex-cli 0.171.0"
HOOK_COUNT = re.compile(r"(?:(1) hook is|([2-9]|[1-9][0-9]+) hooks are) new or changed\.")
HOOK_WARNING = "Hooks can run outside the sandbox after you trust them."
HOOK_CHOICES = ("Review hooks", "Trust all and continue", "Continue without trusting (hooks won't run)")
HOOK_FOOTERS = {"enter confirm · esc skip", "Press enter to confirm or esc to go back"}
SGR = re.compile(r"\x1b\[[0-9;:]*m")
OTHER_CONTROLS = re.compile(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]")
FOLDER_COPY = (
    "Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. "
    "Folder settings can run code automatically, even without a model request. Continue only if you trust "
    "these files. Your trust decision will be saved."
)
FOLDER_CHOICES = ("Trust and continue", "Back to Agent Command Center")
DENIED = re.compile(r"venipak|veni-recon|megodata", re.I)
DEADLINE = 23
INPUT_UNCERTAIN = "keypress outcome uncertain; inspect this lane before any further input"


class Refusal(Exception):
    """A fixed diagnostic safe to publish without native output."""


class Uncertain(Refusal):
    """Stop this sweep after an uncertain input operation."""


class AuditError(Exception):
    """Stop before any further input when the journal cannot persist."""


def command(*args, timeout=2, env=None, stdin=None):
    try:
        return subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, check=True, timeout=timeout, input=stdin).stdout
    except (OSError, UnicodeError, subprocess.SubprocessError):
        raise Refusal("required command failed or timed out") from None


def own(path, kind):
    info = path.lstat()
    return info.st_uid == os.getuid() and not info.st_mode & 0o022 and kind(info.st_mode)


def canonical(path):
    if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
        raise Refusal("directory is not a canonical path")
    return path


def registry(main, ops):
    """Delegate secondmate record interpretation to its existing parser."""
    result = {"main": main, "ops": ops}
    excluded = set()
    routes = main / "data/secondmates.md"
    if not routes.exists() and not routes.is_symlink():
        return result, excluded
    if not own(routes, stat.S_ISREG):
        raise Refusal("Main secondmate registry requires a regular owner file")
    script = r'''
source "$1"
while IFS= read -r row || [ -n "$row" ]; do
  [[ "$row" == "- "* ]] || continue
  secondmate_registry_parse_line "$row" || exit 1
  printf '%s\t%s\t%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_REMOTE" \
    "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_PROJECTS"
done < "$2"
'''
    seen = set()
    for row in command("bash", "--noprofile", "--norc", "-c", script, "_",
                       BIN / "fm-secondmate-registry-lib.sh", routes,
                       env={k: v for k, v in os.environ.items() if k != "BASH_ENV"}).splitlines():
        name, remote, path, projects = row.split("\t")
        if name in seen or name in result:
            raise Refusal("Main secondmate registry has duplicate or reserved names")
        seen.add(name)
        if DENIED.search(name):
            excluded.update(project.strip().casefold() for project in projects.split(","))
        elif remote == "0" and not DENIED.search(path):
            home = Path(path)
            if home != ops:
                result[name] = canonical(home)
    if len(set(result.values())) != len(result):
        raise Refusal("Main secondmate registry has duplicate local homes")
    return result, excluded


def metadata(home, task):
    meta = home / "state" / f"{task}.meta"
    if not own(meta, stat.S_ISREG):
        raise Refusal("task metadata is not a regular owner file")
    fields = {}
    for line in meta.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            if key in fields:
                raise Refusal("task metadata contains duplicate keys")
            fields[key] = value
    return fields


@dataclass(frozen=True)
class Task:
    home_id: str
    home: Path
    task: str
    fields: dict

    @property
    def lane(self):
        return self.fields.get("window", "")

    @property
    def target(self):
        return TARGET.fullmatch(self.lane)

    @property
    def worktree(self):
        return Path(self.fields.get("worktree", ""))

    @property
    def project(self):
        return Path(self.fields.get("project", ""))

    @property
    def private(self):
        return self.home / "state" / f"{self.task}.codex-home"

    @property
    def record(self):
        return {"home": self.home_id, "task": self.task, "lane": self.lane if self.target else "",
                "worktree": str(self.worktree) if self.worktree.is_absolute() else "",
                "hook_keys": [], "hook_names": []}

    def binding(self, homes, excluded):
        f = self.fields
        if (not self.target or f.get("endpoint_task_id") != self.task
                or f.get("herdr_session") != self.target["session"]
                or f.get("herdr_workspace_id") != self.target["workspace"]
                or f.get("herdr_pane_id") != self.target["pane"]
                or not re.fullmatch(re.escape(self.target["workspace"]) + r":t[A-Za-z0-9]+", f.get("herdr_tab_id", ""))
                or not SLUG.fullmatch(f.get("spawn_gen", ""))):
            raise Refusal("task metadata does not bind one explicit Herdr endpoint")
        if self.home not in homes or metadata(self.home, self.task) != f:
            raise Refusal("task owner or metadata changed")
        if DENIED.search(str(self.project)) or DENIED.search(str(self.worktree)):
            raise Refusal("project is excluded from desktop trust")
        if self.project not in homes:
            if self.project.parent != self.home / "projects" or self.project.name.casefold() in excluded:
                raise Refusal("project is outside the owning home's registered projects")
            project_registry = self.home / "data/projects.md"
            if not own(project_registry, stat.S_ISREG):
                raise Refusal("project registry requires a regular owner file")
            prefix = "- " + self.project.name
            rows = [row for row in project_registry.read_text().splitlines()
                    if row == prefix or row.startswith((prefix + " [", prefix + " - "))]
            if len(rows) != 1 or DENIED.search(rows[0]):
                raise Refusal("project is unregistered, ambiguous, or excluded")
        project, worktree = canonical(self.project), canonical(self.worktree)
        canonical(self.private)
        if not own(self.private, stat.S_ISDIR):
            raise Refusal("worker Codex home is not owned by this user")
        if worktree in (*homes, project):
            raise Refusal("worktree is a fleet home or primary project")
        git_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        git_env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
        common = command("git", "-C", project, "rev-parse", "--path-format=absolute",
                         "--show-toplevel", "--git-common-dir", env=git_env).splitlines()
        linked = command("git", "-C", worktree, "rev-parse", "--path-format=absolute",
                         "--show-toplevel", "--git-common-dir", "--absolute-git-dir", env=git_env).splitlines()
        if (len(common) != 2 or len(linked) != 3 or common[0] != str(project)
                or linked[0] != str(worktree) or linked[1] != common[1] or linked[2] == linked[1]):
            raise Refusal("worktree is not linked to the registered project")
        git_dir = Path(linked[2])
        if (git_dir.parent != Path(linked[1]) / "worktrees" or canonical(git_dir) != git_dir
                or (git_dir / "gitdir").read_text().strip() != str(worktree / ".git")):
            raise Refusal("Git administrative record does not own the recorded worktree")
        return git_dir


@dataclass(frozen=True)
class Modal:
    kind: str
    selected: int
    count: int = 0


def selection(rows, labels):
    selected = []
    for index, (row, label) in enumerate(zip(rows, labels, strict=True), 1):
        expected = f"{index}. {label}"
        if row == "› " + expected:
            selected.append(index)
        elif row != expected:
            raise Refusal("unrecognized native Codex menu options")
    if len(selected) != 1:
        raise Refusal("native Codex selection is ambiguous")
    return selected[0]


def modal(screen, worktree):
    # Raw Herdr output contains the styled visible grid. Only discard color
    # and rendition changes, which cannot move or erase terminal cells.
    screen = SGR.sub("", screen)
    if OTHER_CONTROLS.search(screen):
        raise Refusal("visible viewport contains unsupported terminal controls")
    rows = [row.strip(" ") for row in screen.split("\n") if row.strip(" ")]
    if not rows:
        raise Refusal("visible viewport is empty")
    if rows[-1] == "enter continue · esc back" or rows[0] == "Folder access":
        if (len(rows) < 6 or rows[0] != "Folder access" or rows[1] != str(worktree)
                or " ".join(rows[2:-3]) != FOLDER_COPY or rows[-1] != "enter continue · esc back"):
            raise Refusal("folder dialog does not match the recorded worktree and native menu")
        return Modal("folder", selection(rows[-3:-1], FOLDER_CHOICES))
    if rows[0] == "Hooks need review" or rows[-1] in HOOK_FOOTERS:
        if len(rows) != 7 or rows[0] != "Hooks need review" or rows[2] != HOOK_WARNING:
            raise Refusal("unrecognized native Codex hook dialog")
        match = HOOK_COUNT.fullmatch(rows[1])
        if not match or rows[-1] not in HOOK_FOOTERS:
            raise Refusal("unrecognized visible hook count or confirmation footer")
        return Modal("hooks", selection(rows[3:6], HOOK_CHOICES), int(match[1] or match[2]))
    return None


def process(pid, pgid, task, codex):
    proc = Path("/proc") / str(pid)
    stamp = (proc / "stat").read_text().rsplit(") ", 1)[1].split()
    if (not own(proc, stat.S_ISDIR) or (proc / "exe").resolve(strict=True) != codex
            or (proc / "cwd").resolve(strict=True) != task.worktree
            or int(stamp[2]) != pgid or int(stamp[5]) != pgid or int(stamp[4]) == 0):
        raise Refusal("foreground process is not the expected native Codex worker")
    expected = {"FM_TASK_ID": task.task, "FM_TASK_INBOX": str(task.home / "state" / f"{task.task}.inbox"),
                "CODEX_HOME": str(task.private), "HERDR_PANE_ID": task.target["pane"]}
    entries = (proc / "environ").read_bytes().split(b"\0")
    for name, value in expected.items():
        prefix = os.fsencode(name + "=")
        if [item for item in entries if item.startswith(prefix)] != [prefix + os.fsencode(value)]:
            raise Refusal("foreground Codex task, home, or pane binding differs from its record")
    # Verify discovery will see the same hook-affecting configuration as the
    # TUI. Standard worker overrides change only model, reasoning and notify.
    args = iter(os.fsdecode((proc / "cmdline").read_bytes()).rstrip("\0").split("\0")[1:])
    for arg in args:
        if arg in {"--model", "-m"}:
            next(args)
        elif arg in {"-c", "--config"}:
            if next(args).partition("=")[0] not in {"model_reasoning_effort", "notify"}:
                raise Refusal("worker has an unsupported Codex config override")
        elif arg == "--enable":
            if next(args) != "hooks":
                raise Refusal("worker has an unsupported Codex feature override")
        elif arg.startswith("\u2063FIRSTMATE_OP: v1 launch-brief:") and next(args, None) is None:
            break
        elif arg not in {"--no-alt-screen", "--dangerously-bypass-approvals-and-sandbox",
                         "resume", "--last"}:
            raise Refusal("worker uses an unrecognized Codex launch shape")
    return stamp[19]


class Desktop:
    def __init__(self, main, ops, herdr, codex):
        self.main, self.ops, self.herdr, self.codex = main, ops, herdr, codex
        self.discover = None

    def call(self, task, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
        return command(self.herdr, "--session", task.target["session"], *args, env=env)

    def pane(self, task):
        pane = task.target["pane"]
        view = json.loads(self.call(task, "pane", "get", pane))["result"]["pane"]
        if (view["pane_id"] != pane or view["workspace_id"] != task.target["workspace"]
                or view["tab_id"] != task.fields["herdr_tab_id"]
                or view["foreground_cwd"] != str(task.worktree) or not SLUG.fullmatch(view["terminal_id"])):
            raise Refusal("Herdr pane identity, foreground directory, or visible viewport changed")
        return view

    def retired(self, task, raw_info, foreground, shell):
        if len(foreground) != 1 or foreground[0]["cwd"] != str(task.worktree):
            return False
        view = self.pane(task)
        if view.get("agent") is not None or view["agent_status"] != "unknown":
            return False
        proc = Path("/proc") / str(shell)
        if (not own(proc, stat.S_ISDIR)
                or (proc / "exe").resolve(strict=True).name != Path(foreground[0]["name"]).name
                or (proc / "cwd").resolve(strict=True) != task.worktree
                or os.getpgid(shell) != shell):
            return False
        # Feed the adapter the exact process-info sample already read through
        # the pinned Herdr client. It checks the real process table for children.
        script = r'''
source "$1"
fm_backend_herdr_cli() { cat; }
fm_backend_herdr_pane_idle_shell_sample "$2" "$3"
'''
        try:
            return command("bash", "--noprofile", "--norc", "-ec", script, "_", BIN / "backends/herdr.sh",
                           task.target["session"], task.target["pane"], stdin=raw_info,
                           env={"PATH": os.environ.get("PATH", os.defpath), "LC_ALL": "C"}).strip() == str(shell)
        except Refusal:
            return False

    def identity(self, task, *, allow_retired=False):
        homes, excluded = registry(self.main, self.ops)
        git_dir = task.binding(homes.values(), excluded)
        status = json.loads(self.call(task, "status", "--json"))
        server = status["server"]
        if (status["client"]["version"] != HERDR_VERSION or not server["running"]
                or server["version"] != HERDR_VERSION or not server["compatible"]):
            raise Refusal(f"requires a running, compatible Herdr client and server {HERDR_VERSION}")
        pane = task.target["pane"]
        raw_info = self.call(task, "pane", "process-info", "--pane", pane)
        info = json.loads(raw_info)["result"]["process_info"]
        if info["pane_id"] != pane:
            raise Refusal("Herdr returned a different foreground pane")
        pgid, shell = info["foreground_process_group_id"], info["shell_pid"]
        if type(pgid) is not int or pgid <= 1 or type(shell) is not int or shell <= 1:
            raise Refusal("Herdr cannot identify the pane foreground group")
        foreground = info["foreground_processes"]
        candidates = [p for p in foreground if p["name"] == "codex"]
        if not candidates and allow_retired and pgid == shell and self.retired(task, raw_info, foreground, shell):
            return None
        if len(candidates) != 1 or type(candidates[0]["pid"]) is not int:
            raise Refusal("pane has no unique native foreground Codex worker")
        pid = candidates[0]["pid"]
        if pid <= 1 or candidates[0]["cwd"] != str(task.worktree):
            raise Refusal("foreground Codex worktree differs from its owner record")
        start = process(pid, pgid, task, self.codex)
        view = self.pane(task)
        if view.get("agent") != "codex" or view["scroll"]["offset_from_bottom"] != 0:
            raise Refusal("Herdr pane identity, foreground directory, or visible viewport changed")
        return (git_dir, shell, pgid, pid, start, view["terminal_id"])

    def observe(self, task, expected=None):
        identity = self.identity(task, allow_retired=expected is None)
        if identity is None:
            return None, None
        if expected is not None and identity != expected:
            raise Refusal("pane or foreground process changed")
        screen = self.call(task, "pane", "read", task.target["pane"], "--source", "visible", "--raw")
        result = modal(screen, task.worktree)
        if self.identity(task) != identity:
            raise Refusal("pane identity changed while reading the viewport")
        return identity, result


HOOK_EVENTS = frozenset("""
preModelRequest postModelRequest preToolUse permissionRequest postToolUse
preCompact postCompact sessionStart sessionEnd userPromptSubmit subagentStart
subagentStop stop interrupt
""".split())


def hook_inventory(desktop, task):
    if desktop.discover is None:
        desktop.discover = runpy.run_path(str(BIN / "fm-codex-worker.py"))["discover"]
    try:
        entries = desktop.discover(str(desktop.codex), str(task.worktree), task.private, timeout=3)["data"]
        entry, = entries
        if entry["cwd"] != str(task.worktree) or entry["errors"] or entry["warnings"]:
            raise ValueError
        hooks = {}
        for hook in entry["hooks"]:
            key = hook["key"]
            if (key in hooks or type(hook["enabled"]) is not bool
                    or hook["trustStatus"] not in {"trusted", "managed", "untrusted", "modified"}):
                raise ValueError
            hooks[key] = hook
        guard = hooks[str(task.private / "hooks.json") + ":pre_tool_use:0:0"]
        if not guard["enabled"] or guard["source"] != "user" or guard["trustStatus"] != "trusted":
            raise ValueError
        return hooks
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        raise Refusal("native hooks/list could not verify this task or its generated guard") from None


def pending_hooks(desktop, task, count, identity):
    roots = {task.project, task.worktree}
    if task.project in registry(desktop.main, desktop.ops)[0].values():
        roots.add(desktop.main)
    origins = {str(root / ".codex" / name) for root in roots for name in ("hooks.json", "config.toml")}
    # A current inventory cannot identify a modal built from an older copy
    # of its hook file. ctime also detects replacement and backdated writes.
    started = time.time() - time.clock_gettime(time.CLOCK_BOOTTIME) + int(identity[4]) / os.sysconf("SC_CLK_TCK")
    result = {}
    for key, hook in hook_inventory(desktop, task).items():
        if hook["trustStatus"] in {"trusted", "managed"}:
            continue
        path, event = hook["sourcePath"], hook["eventName"]
        if (not hook["enabled"] or hook["source"] != "project" or hook["pluginId"] is not None
                or hook["isManaged"] is not False or path not in origins):
            raise Refusal("untrusted hook is disabled or outside approved project origins")
        source = Path(path)
        if source.resolve(strict=True) != source or not own(source, stat.S_ISREG):
            raise Refusal("project hook origin is missing, unowned, or redirected")
        if source.stat().st_ctime > started:
            raise Refusal("project hook origin changed after the foreground worker started")
        suffix = re.sub(r"[A-Z]", lambda match: "_" + match[0].lower(), event)
        fingerprint = hook["currentHash"]
        if (event not in HOOK_EVENTS or not re.fullmatch(re.escape(f"{path}:{suffix}:") + r"[0-9]+:[0-9]+", key)
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", fingerprint)):
            raise Refusal("native hook key, event name, or hash has an unsupported format")
        result[key] = (event, fingerprint)
    if len(result) != count:
        raise Refusal("visible hook count differs from native pending inventory")
    return result


class Journal:
    def __init__(self, main, apply):
        self.apply = apply
        self.rows = []
        self.messages = []
        self.fd = None
        self.lock = None
        self.directory = main / "state/codex-trust-desktop"

    def __enter__(self):
        if not self.apply:
            return self
        try:
            self.directory.mkdir(mode=0o700, exist_ok=True)
            if (self.directory.resolve(strict=True) != self.directory
                    or not own(self.directory, stat.S_ISDIR)
                    or self.directory.stat().st_mode & 0o077):
                raise Refusal("Main audit directory must be private, canonical and owner-only")
            self.lock = self.open("lock")
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return None
            self.fd = self.open("events.jsonl")
            directory = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            parent = os.open(self.directory.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
            with os.fdopen(os.dup(self.fd), encoding="utf-8") as source:
                for row in source:
                    if not row.endswith("\n"):
                        raise Refusal("Main audit journal has an incomplete event")
                    event = json.loads(row)
                    if not isinstance(event, dict) or not isinstance(event.get("phase"), str):
                        raise Refusal("Main audit journal has an invalid event")
                    self.rows.append(event)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def open(self, name):
        fd = os.open(self.directory / name, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            os.close(fd)
            raise Refusal("Main audit files must be private regular owner files")
        return fd

    def __exit__(self, *_):
        for fd in (self.fd, self.lock):
            if fd is not None:
                os.close(fd)

    def event(self, record, phase, **data):
        row = dict(record, **data, phase=phase, at=datetime.now(timezone.utc).isoformat())
        if self.apply:
            payload = (json.dumps(row, ensure_ascii=True, sort_keys=True) + "\n").encode()
            try:
                if os.write(self.fd, payload) != len(payload):
                    raise OSError("short audit journal append")
                os.fsync(self.fd)
            except OSError:
                raise AuditError from None
            self.rows.append(row)
        else:
            print(json.dumps(row, ensure_ascii=True, sort_keys=True))

    def refuse(self, record, reason):
        signature = dict(record, reason=reason, phase="refusal")
        if any(all(row.get(key) == value for key, value in signature.items()) for row in self.rows):
            return
        self.event(record, "refusal", reason=reason)
        self.messages.append(f"{record['home']}/{record['task']}: {reason}")


def observe_transition(desktop, task, identity, accepted):
    until = time.monotonic() + 1.2
    while True:
        _, current = desktop.observe(task, identity)
        if accepted(current):
            return
        if time.monotonic() >= until:
            raise Refusal("native viewport did not show the expected transition")
        time.sleep(0.08)


def press(desktop, task, identity, expected, key, accepted, journal, record, effect, pending, deadline):
    if time.monotonic() > deadline - 2:
        raise Refusal("watcher time budget expired before the next key")
    if pending and pending_hooks(desktop, task, expected.count, identity) != pending:
        raise Refusal("native pending hooks changed before keypress")
    if desktop.observe(task, identity)[1] != expected:
        raise Refusal("native modal or selection changed before keypress")
    journal.event(record, "keypress-attempt", effect=effect, key=key)
    try:
        # No retries even when the CLI fails. Its exit is not an input receipt.
        if desktop.observe(task, identity)[1] != expected:
            raise Refusal("native modal changed after journaling the key")
        desktop.call(task, "pane", "send-keys", task.target["pane"], key)
        observe_transition(desktop, task, identity, accepted)
        if key == "enter" and pending:
            inventory = hook_inventory(desktop, task)
            for hook_key, (_, fingerprint) in pending.items():
                hook = inventory.get(hook_key, {})
                if hook.get("trustStatus") != "trusted" or hook.get("currentHash") != fingerprint:
                    raise Refusal("native hooks/list did not confirm the approved hashes")
    except (Refusal, OSError, ValueError, TypeError, IndexError, KeyError, StopIteration):
        journal.event(record, "keypress-observed", effect=effect, key=key, result="uncertain")
        raise Uncertain(INPUT_UNCERTAIN) from None
    result = "affirmative selection visible" if key == "down" else "dialog cleared"
    if key == "enter" and pending:
        result = "dialog cleared and exact hook hashes trusted"
    journal.event(record, "keypress-observed", effect=effect, key=key, result=result)


def check_task(desktop, task, journal, deadline):
    identity, current = desktop.observe(task)
    epoch = [task.home_id, task.task, task.fields["spawn_gen"], task.lane]
    effect = [*epoch, current.kind] if current else None
    attempts = [row for row in journal.rows if row["phase"] == "keypress-attempt"
                and row.get("effect", [])[:-1] == epoch]
    for attempt in attempts:
        already_cleared = any(row.get("effect") == attempt["effect"] and row.get("key") == "enter"
                              and row.get("result", "").startswith("dialog cleared") for row in journal.rows)
        if not already_cleared:
            raise Refusal(INPUT_UNCERTAIN)
        if attempt["effect"] == effect:
            raise Refusal("a previously cleared modal reappeared; automatic retry suppressed")
    if current is None:
        return
    record = task.record
    if current.selected != 1:
        raise Refusal("native modal is not at its expected initial selection")
    pending = pending_hooks(desktop, task, current.count, identity) if current.kind == "hooks" else {}
    record.update(hook_keys=sorted(pending), hook_names=[pending[key][0] for key in sorted(pending)])
    keys = ["down", "enter"] if pending else ["enter"]
    if not journal.apply:
        journal.event(record, "dry-run", dialog=current.kind, planned_keys=keys)
        return
    if pending:
        affirmative = Modal("hooks", 2, current.count)
        press(desktop, task, identity, current, "down", lambda seen: seen == affirmative,
              journal, record, effect, pending, deadline)
        current = affirmative
    press(desktop, task, identity, current, "enter",
          lambda seen: seen is None or (current.kind == "folder" and seen.kind == "hooks"),
          journal, record, effect, pending, deadline)


def sweep(desktop, journal, only):
    deadline = time.monotonic() + DEADLINE
    homes, _ = registry(desktop.main, desktop.ops)
    tasks = []
    targets, worktrees = Counter(), Counter()
    for name, home in homes.items():
        state = home / "state"
        if not state.exists():
            continue
        canonical(state)
        if not own(state, stat.S_ISDIR):
            raise Refusal("fleet state directory must be owner-controlled")
        for path in sorted(state.glob("*.meta")):
            task_id = path.stem
            if not SLUG.fullmatch(task_id):
                continue
            try:
                fields = metadata(home, task_id)
            except (OSError, UnicodeError, Refusal):
                if only in (None, f"{name}/{task_id}"):
                    journal.refuse(Task(name, home, task_id, {}).record, "recorded task metadata is unreadable or ambiguous")
                continue
            task = Task(name, home, task_id, fields)
            if task.target:
                targets[task.lane] += 1
            if fields.get("kind") in {"ship", "scout"}:
                if task.worktree.is_absolute():
                    worktrees[task.worktree] += 1
                if fields.get("harness") == "codex" and only in (None, f"{name}/{task_id}"):
                    tasks.append(task)
    if only and not tasks:
        raise Refusal("requested task is outside the recorded desktop Codex worker inventory")
    if not tasks:
        return
    if command(desktop.codex, "--version").strip() != CODEX_VERSION:
        raise Refusal(f"requires the verified native {CODEX_VERSION}")
    for task in tasks:
        if time.monotonic() >= deadline - 5:
            raise Refusal("watcher time budget expired before all recorded workers could be inspected")
        try:
            if task.fields.get("backend") != "herdr":
                raise Refusal("recorded Codex worker uses an unverified desktop backend")
            if targets[task.lane] > 1:
                raise Refusal("multiple fleet task records claim this Herdr endpoint")
            if worktrees[task.worktree] > 1:
                raise Refusal("multiple fleet task records claim this worktree")
            check_task(desktop, task, journal, deadline)
        except Uncertain as error:
            journal.refuse(task.record, str(error))
            break
        except Refusal as error:
            journal.refuse(task.record, str(error))
        except (OSError, ValueError, TypeError, IndexError, KeyError, StopIteration):
            journal.refuse(task.record, "worker, native capability, or audit evidence could not be verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true", help="report candidates without sending keys or writing state")
    modes.add_argument("--apply", action="store_true", help="send verified keys and audit them in Main state")
    parser.add_argument("--main-home", type=Path, required=True)
    parser.add_argument("--ops-home", type=Path, required=True)
    parser.add_argument("--herdr-bin", type=Path, required=True, help="absolute path to the installed Herdr binary")
    parser.add_argument("--codex-bin", type=Path, required=True, help="absolute path to the native Codex binary")
    parser.add_argument("--task", help="restrict the sweep to HOME_ID/TASK")
    args = parser.parse_args()
    if args.task and not re.fullmatch(f"{SLUG.pattern}/{SLUG.pattern}", args.task):
        parser.error("--task must be HOME_ID/TASK")
    try:
        if not sys.platform.startswith("linux"):
            raise Refusal("desktop Codex trust requires Linux foreground process evidence")
        main_home, ops = canonical(args.main_home), canonical(args.ops_home)
        if main_home == ops or not own(main_home, stat.S_ISDIR) or not own(ops, stat.S_ISDIR):
            raise Refusal("Main and Ops must be separate owner-controlled homes")
        for binary in (args.herdr_bin, args.codex_bin):
            if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
                raise Refusal("installed Herdr and native Codex executable paths are required")
        desktop = Desktop(main_home, ops, args.herdr_bin.resolve(strict=True), args.codex_bin.resolve(strict=True))
        root_record = {"home": "main", "task": "desktop", "lane": "", "worktree": "", "hook_keys": [], "hook_names": []}
        with Journal(main_home, args.apply) as journal:
            if journal is None:
                return 0
            try:
                sweep(desktop, journal, args.task)
            except Refusal as error:
                journal.refuse(root_record, str(error))
            if args.apply and journal.messages:
                print("Codex trust refused | " + " | ".join(journal.messages))
            return 2 if journal.messages else 0
    except AuditError:
        print("Codex trust stopped: a Main audit event could not be persisted")
    except Refusal as error:
        print(f"Codex trust refused: {error}")
    except (OSError, ValueError, TypeError, IndexError, KeyError):
        print("Codex trust refused: desktop setup or audit journal is unavailable or invalid")
    return 2


if __name__ == "__main__":
    sys.exit(main())
