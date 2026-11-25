#!/usr/bin/env python3
"""Supervisor-owned exact-commit acceptance. The CLI contract lives in fm-done-check.sh."""

import ast
import base64
import hashlib
import json
import operator
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

BIN = Path(__file__).resolve().parent
HOME_DIR = Path(os.environ["FM_HOME"])
STATE = Path(os.environ.get("FM_STATE_OVERRIDE", HOME_DIR / "state"))
DATA = Path(os.environ.get("FM_DATA_OVERRIDE", HOME_DIR / "data"))
CONFIG = Path(os.environ.get("FM_CONFIG_OVERRIDE", HOME_DIR / "config"))
POLICY_DIR = CONFIG / "done-acceptance"
JOURNAL = STATE / "review-verdicts.jsonl"
SHA = r"[0-9a-f]{40}"
SHA256 = r"[0-9a-f]{64}"
ID = r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
REPO = r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+"
URL = rf"https://github\.com/({REPO})/pull/([1-9][0-9]*)"
MODEL = {"codex": r"gpt-[0-9][a-z0-9.-]*", "claude": r"claude-[a-z0-9]+-[0-9][a-z0-9.-]*"}


class Refusal(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value)


def private_bytes(path, private=True, with_stat=False):
    # O_NONBLOCK avoids waiting on a FIFO. Open the same inode we validate.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as file:
        info = os.fstat(file.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == os.getuid() and not info.st_mode & (0o077 if private else 0o022),
                f"{path.name} is not a suitable owned record")
        data = file.read()
        return (data, info) if with_stat else data


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate record field {key}")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique_fields)


def publish(path, data, replace=False):
    path.parent.mkdir(mode=0o700, exist_ok=True)
    require(path.parent.is_dir() and not path.parent.is_symlink(),
            f"{path.parent.name} is not an ordinary directory")
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
        if replace:
            os.replace(name, path)
        else:
            os.link(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def metadata(task):
    records = private_bytes(STATE / f"{task}.meta", private=False).decode().splitlines()
    return unique_fields(line.split("=", 1) for line in records if "=" in line)


def done_event(task):
    path = STATE / f"{task}.status"
    snapshot, info = private_bytes(path, private=False, with_stat=True)
    # Only home-recorded byte ranges can identify supervisor operational
    # annotations. A worker can write the same words into the status log.
    operational = re.compile(
        rb"^paused(?: \[[^\n]+\])*:|"
        rb"^blocked \[key=paused-overdue-" + re.escape(task.encode()) +
        rb"\](?: \[at=[0-9]+\])?: paused [0-9]+s, wait overdue - decide or release$",
        re.M,
    )
    ranges = []
    if operational.search(snapshot):
        ledger = path.with_name(f".{task}.home-appends")
        if os.path.lexists(ledger):
            private_bytes(ledger, private=False)
            records = subprocess.check_output(
                ["bash", "-c", '. "$1"; status_home_appends_ranges "$2"',
                 "fm-acceptance", BIN / "fm-classify-lib.sh", path], timeout=10, text=True
            )
            ranges = [tuple(map(int, row.split())) for row in records.splitlines()]
    retained = []
    offset = 0
    for line in snapshot.splitlines(keepends=True):
        end = offset + len(line)
        if not (operational.match(line) and any(start <= offset and end <= stop for start, stop in ranges)):
            retained.append((line, end))
        offset = end
    result = subprocess.check_output(
        ["bash", "-c",
         '. "$1"; scan=$(_fm_crew_status_event_scan); line=${scan##*$\'\\n\'}; '
         'if [ "$(status_line_verb "$line")" = done ]; then '
         'printf "%s\\n" "$line"; status_line_note "$line"; fi',
         "fm-acceptance", BIN / "fm-classify-lib.sh"],
        input=b"".join(line for line, _ in retained), timeout=10,
    )
    current = path.lstat()
    require((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            == (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns),
            "candidate status changed during verification")
    if not result:
        return "", ""
    raw, note = result.split(b"\n", 1)
    end = next((end for line, end in reversed(retained) if line.rstrip(b"\n") == raw), 0)
    require(end, "candidate status event is unreadable")
    return note.decode().strip(), digest(snapshot[:end])


def relative(path, prefix=False):
    if not isinstance(path, str) or not path or any(c in path for c in "\n\r\t\0\\"):
        return False
    stripped = path.removesuffix("/") if prefix else path
    return all(piece not in ("", ".", "..", ".git") for piece in stripped.split("/"))


def contains(path, rules):
    return any(path.startswith(rule) if rule.endswith("/") else path == rule for rule in rules)


def policy_for(task):
    directory = POLICY_DIR.lstat()
    require(stat.S_ISDIR(directory.st_mode) and directory.st_uid == os.getuid()
            and not directory.st_mode & 0o022, "done-acceptance is not a supervisor-owned directory")
    data = private_bytes(POLICY_DIR / f"{task}.json")
    policy = decode(data)
    require(isinstance(policy, dict) and set(policy) <= {
        "repo", "base_branch", "base", "kind", "allow", "tests", "criteria", "regression", "new_tests"
    }, "invalid acceptance policy fields")
    require(matches(REPO, policy.get("repo")) and matches(SHA, policy.get("base"))
            and isinstance(policy.get("base_branch"), str) and policy["base_branch"]
            and policy.get("kind") in ("feature", "bug")
            and isinstance(policy.get("criteria"), str) and policy["criteria"].strip(),
            "policy must pin repository, base branch, commit, task kind and criteria")
    for field in ("allow", "tests"):
        rules = policy.get(field)
        require(isinstance(rules, list) and (field != "allow" or rules)
                and all(relative(path, prefix=True) for path in rules),
                f"invalid policy {field} paths")
    new_tests = policy.get("new_tests", {})
    require(isinstance(new_tests, dict) and all(
        relative(path) and contains(path, policy["allow"]) and matches(SHA256, sha)
        for path, sha in new_tests.items()
    ), "new_tests must pin approved paths and SHA-256 values inside scope")
    if policy["kind"] == "bug":
        spec = policy.get("regression")
        require(isinstance(spec, dict) and set(spec) == {"path", "test_sha256", "runner_sha256"}
                and relative(spec["path"]) and matches(SHA256, spec["test_sha256"])
                and matches(SHA256, spec["runner_sha256"]),
                "bug policy requires a pinned new regression test and runner")
        require(contains(spec["path"], policy["allow"]), "regression path is outside allowed scope")
        require(new_tests.get(spec["path"], spec["test_sha256"]) == spec["test_sha256"],
                "regression and new_tests pins disagree")
    else:
        require("regression" not in policy, "only a bug policy accepts a regression specification")
    return policy, digest(data)


def builder_lineage(meta):
    history = meta.get("builder_history", "").split(",")
    builders = []
    generations = set()
    for entry in history:
        parts = entry.split(":")
        require(len(parts) == 3, "builder lineage is missing or incomplete")
        generation, harness, model = parts
        require(matches(r"s[0-9]+\.[0-9]+\.[0-9]+", generation) and generation not in generations
                and harness in MODEL and matches(MODEL[harness], model),
                "builder lineage has an unknown identity or ambiguous generation")
        generations.add(generation)
        builders.append({"generation": generation, "harness": harness, "model": model})
    current = {key: meta.get(key) for key in ("harness", "model")}
    require(builders[-1] == {**current, "generation": meta["spawn_gen"]},
            "builder lineage does not match the current native dispatch")
    return builders


def same_project(first, second):
    return bool(first and second) and Path(first).resolve() == Path(second).resolve()


def independent_model(identity, harness, model):
    return (harness in MODEL and matches(MODEL[harness], model)
            and all(harness != builder["harness"] for builder in identity["builders"]))


def context(task, url):
    meta = metadata(task)
    policy, policy_digest = policy_for(task)
    parsed = matches(URL, url)
    require(parsed and parsed[1].lower() == policy["repo"].lower(),
            "candidate PR is outside the pinned GitHub repository")
    require(meta.get("kind") == "ship" and meta.get("mode") in ("direct-PR", "no-mistakes")
            and meta.get("branch") and meta.get("spawn_gen") and meta.get("project")
            and meta.get("worktree")
            and meta.get("base_branch", policy["base_branch"]) == policy["base_branch"],
            "task lacks matching native ship identity; recover its metadata before acceptance")
    builders = builder_lineage(meta)
    event, event_digest = done_event(task)
    submission = re.fullmatch(rf"PR {re.escape(url)}( checks green)? head ({SHA})(?: proof=\S+)?", event)
    require(submission and bool(submission[1]) == (meta["mode"] == "no-mistakes"),
            f"no current exact-head done candidate for {task}")
    identity = {
        "task": task, "generation": meta["spawn_gen"], "branch": meta["branch"],
        "worktree": meta["worktree"], "project": meta.get("project"),
        "candidate": event, "candidate_event": event_digest, "pr": url, "head": submission[2],
        "base": policy["base"], "base_branch": policy["base_branch"], "policy": policy_digest,
        "builders": builders,
    }
    return identity, policy


def github_facts(path, projection):
    # gh-axi renders scalar jq results in an envelope. Base64 makes the fixed
    # projection independent of the renderer's quoting and forge-supplied prose.
    try:
        result = subprocess.check_output(
            ["gh-axi", "api", path, "--hostname", "github.com", "--jq", projection + " | @json | @base64"],
            timeout=10, text=True, stderr=subprocess.DEVNULL,
        )
        envelope = re.fullmatch(r"api_response:\n  body: ([A-Za-z0-9+/=]+)\n  truncated: false\s*", result)
        if envelope:
            return decode(base64.b64decode(envelope[1], validate=True))
    except (subprocess.SubprocessError, OSError, ValueError):
        pass
    raise Refusal("temporary forge read unavailable")


def forge_check(identity, policy):
    parsed = re.fullmatch(URL, identity["pr"])
    facts = github_facts(
        f"/repos/{parsed[1]}/pulls/{parsed[2]}",
        "[.html_url,.base.repo.full_name,.base.ref,.head.repo.full_name,.head.ref,.head.sha,.state,.draft]",
    )
    require(isinstance(facts, list) and len(facts) == 8, "GitHub PR facts are incomplete")
    url, repo, branch, fork, source, head, state, draft = facts
    # GitHub repository names ignore letter case, as the candidate URL check does.
    require(all(matches(REPO, name) and name.lower() == policy["repo"].lower() for name in (repo, fork)),
            "GitHub repository does not match the pinned candidate")
    require(url == identity["pr"] and branch == identity["base_branch"] and source == identity["branch"],
            "GitHub PR, task branch or target branch does not match the pinned candidate")
    require(head == identity["head"], "live GitHub head differs from the pinned candidate")
    require(state == "open" and draft is False, "candidate PR must be open and ready for review")
    target = github_facts(f"/repos/{repo}/branches/{quote(branch, safe='')}", "[.name,.commit.sha]")
    require(target == [branch, identity["base"]], "live GitHub target branch differs from the pinned base")


def git_env():
    return {
        "PATH": os.environ["PATH"], "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }


def git(identity, *args, check=True, env=None, timeout=30):
    return subprocess.run(
        ["git", "-C", identity["worktree"], *args], env=env or git_env(), timeout=timeout,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check
    )


def has_commit(source, sha):
    return git(source, "cat-file", "-t", sha, check=False).stdout == b"commit\n"


def inspection_repository(identity, policy):
    pins = (identity["base"], identity["head"])
    # The trust root is the supervisor's bare store populated through the
    # validated forge identity. Never read objects or configuration from the
    # worker's repository, even if it claims to have both object IDs.
    cache = STATE / f"{identity['task']}.acceptance-git"
    cache.mkdir(mode=0o700, exist_ok=True)
    info = cache.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            "acceptance Git directory is not private")
    source = {**identity, "worktree": str(cache)}
    if not (cache / "HEAD").is_file():
        git(source, "init", "--bare", "--template=")
    if not all(has_commit(source, sha) for sha in pins):
        remote = f"https://github.com/{policy['repo']}.git"
        refspecs = [f"{sha}:refs/firstmate/acceptance/{sha}" for sha in pins]
        env = {**git_env(), "GH_PROMPT_DISABLED": "1"}
        config_root = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        config = Path(os.environ.get("GH_CONFIG_DIR") or config_root / "gh").resolve()
        require(not any(config.is_relative_to(Path(identity[key]).resolve()) for key in ("worktree", "project")),
                "supervisor GitHub credential configuration must be outside worker-controlled paths")
        env["GH_CONFIG_DIR"] = str(config)
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "DBUS_SESSION_BUS_ADDRESS"):
            if name in os.environ:
                env[name] = os.environ[name]
        helper = shutil.which("gh")
        credential = ["-c", "credential.helper="]
        if helper:
            credential += ["-c", f"credential.https://github.com.helper=!{shlex.quote(os.path.abspath(helper))} auth git-credential"]
        try:
            fetched = git(source, *credential, "-c", "http.followRedirects=false", "-c", "fetch.fsckObjects=true",
                          "fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                          remote, *refspecs, check=False, env=env, timeout=120)
        except subprocess.TimeoutExpired:
            raise Refusal("timed out fetching pinned commits from GitHub") from None
        require(fetched.returncode == 0,
                "could not fetch pinned commits from GitHub; check supervisor GitHub credentials and repository access")
    require(all(has_commit(source, sha) for sha in pins), "fetched objects do not contain both pinned commits")
    return source


def tree(identity, sha):
    entries = {}
    for row in git(identity, "ls-tree", "-rz", "--full-tree", sha).stdout.split(b"\0")[:-1]:
        entry, path = row.split(b"\t", 1)
        mode, kind, oid = entry.decode().split()
        entries[os.fsdecode(path)] = mode, kind, oid
    return entries


def changed_paths(before, after):
    return [
        ("A" if path not in before else "D" if path not in after else "M", path)
        for path in sorted(before.keys() | after.keys()) if before.get(path) != after.get(path)
    ]


def test_path(path, policy):
    return (contains(path, policy["tests"])
            or bool(re.search(
                r"(?:^|/)(?:tests?|specs?|__tests__|e2e|[^/]+\.tests?)/"
                r"|(?:^|/)(?:test_[^/]+|tests?\.[^/]+|conftest\.py|\.?pytest\.(?:ini|toml)|tox\.ini|\.mocharc[^/]*)$"
                r"|(?:^|/)(?:jest|vitest|cypress|playwright|karma|testcafe)\.config\.[^/]+$"
                r"|(?:^|/)karma\.conf\.(?:js|coffee|ts)$"
                r"|[._-](?:tests?|specs?|cy)\.[^/]+$"
                r"|(?:tests?|specs?)\.(?:java|kt|kts|cs|scala|swift)$", path, re.I,
            )))


EMBEDDED_TEST = {
    ".rs": rb"#\s*\[\s*(?:cfg(?:_attr)?\s*\(\s*test\b|(?:[a-zA-Z_]\w*::)*test\s*\])",
    ".go": rb"^\s*func\s+Test[A-Z_]\w*\s*\(",
    ".py": rb"^\s*(?:async\s+)?def\s+test_[A-Za-z_]\w*\s*\(",
    ".java": rb"^\s*@(?:org\.junit\.[\w.]+\.)?(?:Test|ParameterizedTest)\b",
    ".kt": rb"^\s*@(?:Test|ParameterizedTest)\b",
    ".cs": rb"^\s*\[(?:Fact|Theory|Test|TestCase|TestMethod)\b",
}

PYTEST_CONFIG = {
    "pyproject.toml": rb"^[ \t]*\[[ \t]*tool\.pytest(?:\.ini_options)?[ \t]*\]",
    "setup.cfg": rb"^[ \t]*\[tool:pytest\]",
}


def has_test_marker(identity, entries, path, marker):
    if not marker or path not in entries:
        return False
    mode, kind, _ = entries[path]
    return (kind == "blob" and mode in ("100644", "100755")
            and bool(re.search(marker, blob(identity, entries, path), re.M)))


def blob(identity, entries, path):
    mode, kind, oid = entries[path]
    require(kind == "blob" and mode in ("100644", "100755"), f"test path is not regular: {path!r}")
    return git(identity, "cat-file", "blob", oid).stdout


def dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{dotted(node.value)}.{node.attr}"
    return ""


def trivial(node):
    if isinstance(node, ast.Constant):
        return bool(node.value)
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        return any(not isinstance(element, ast.Starred) for element in node.elts)
    if isinstance(node, ast.Dict):
        return any(key is not None for key in node.keys)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not) and isinstance(node.operand, ast.Constant):
        return not node.operand.value
    if isinstance(node, ast.BoolOp):
        return (any if isinstance(node.op, ast.Or) else all)(trivial(term) for term in node.values)
    if isinstance(node, ast.Compare) and len(node.ops) == 1:
        left, right = node.left, node.comparators[0]
        op = type(node.ops[0])
        if isinstance(left, ast.Name) and isinstance(right, ast.Name):
            return op is ast.Eq and left.id == right.id
        comparison = {
            ast.Eq: operator.eq, ast.NotEq: operator.ne, ast.Lt: operator.lt,
            ast.LtE: operator.le, ast.Gt: operator.gt, ast.GtE: operator.ge,
            ast.Is: operator.is_, ast.IsNot: operator.is_not,
        }.get(op)
        if comparison and isinstance(left, ast.Constant) and isinstance(right, ast.Constant):
            try:
                return comparison(left.value, right.value)
            except TypeError:
                return False
    return False


def python_signals(data, path):
    tree_ast = ast.parse(data, filename=path)
    test_functions = (ast.FunctionDef, ast.AsyncFunctionDef)
    aliases = {"pytest": "pytest", "unittest": "unittest"}
    for node in ast.walk(tree_ast):
        if isinstance(node, ast.Import):
            for item in node.names:
                if item.name in ("pytest", "unittest"):
                    aliases[item.asname or item.name] = item.name
        if isinstance(node, ast.ImportFrom) and node.module in ("pytest", "unittest"):
            for item in node.names:
                aliases[item.asname or item.name] = f"{node.module}.{item.name}"
    for node in ast.walk(tree_ast):
        if isinstance(node, test_functions) and node.name.startswith("test"):
            body = list(node.body)
            while body:
                part = body.pop()
                if isinstance(part, ast.Return):
                    return "added early-return marker"
                if not isinstance(part, (*test_functions, ast.ClassDef)):
                    body.extend(ast.iter_child_nodes(part))
        if ((isinstance(node, ast.Name) and node.id == "__test__")
                or (isinstance(node, ast.Attribute) and node.attr == "__test__")):
            return "added collection override"
        if isinstance(node, ast.Assert) and trivial(node.test):
            return "added trivial assertion"
        if isinstance(node, (ast.Name, ast.Attribute)):
            first, _, rest = dotted(node).partition(".")
            qualified = ".".join(filter(None, (aliases.get(first, first), rest)))
            if re.fullmatch(
                r"pytest\.(?:mark\.)?(?:skip|skipif|xfail|importorskip)"
                r"|unittest\.(?:case\.)?(?:skip|skipIf|skipUnless|SkipTest|expectedFailure)"
                r"|self\.skipTest", qualified,
            ):
                return "added skip"
        if isinstance(node, ast.Call):
            method = dotted(node.func).rsplit(".", 1)[-1]
            if method == "assertTrue" and node.args and trivial(node.args[0]):
                return "added trivial assertion"
            if method == "assertEqual" and len(node.args) >= 2 and trivial(
                    ast.Compare(node.args[0], [ast.Eq()], [node.args[1]])):
                return "added trivial assertion"
            if method in ("assertIsNotNone", "assertIn") and node.args:
                try:
                    first = ast.literal_eval(node.args[0])
                    passes = first is not None if method == "assertIsNotNone" else (
                        len(node.args) >= 2 and first in ast.literal_eval(node.args[1])
                    )
                except (ValueError, TypeError, SyntaxError):
                    passes = False
                if passes:
                    return "added trivial assertion"
    return None


SHELL_QUOTED = re.compile(r"""\\.|'[^']*'|"(?:\\.|[^"\\])*\"""")


def shell_commands(lines):
    # Separators inside a complete quoted argument are data. A line whose quotes
    # do not pair starts text this line reader cannot follow, so from there every
    # separator counts, as it does where quoted text holds or becomes code. An
    # eval or trap spelled inside quoted text with a space in it runs nothing:
    # only an unquoted word or one whole quoted word can be the command.
    paired = True
    for line in lines:
        paired = paired and not re.search(r"['\"]", SHELL_QUOTED.sub("", line))
        words = SHELL_QUOTED.sub(lambda quoted: "''" if re.search(r"\s", quoted[0]) else quoted[0], line)
        if paired and not (re.search(r"\$'|[$<>]\(|`|\s-\w*c\s", line) or re.search(r"\b(?:eval|trap)\b", words)):
            line = SHELL_QUOTED.sub(lambda quoted: re.sub(r"[;&|]", " ", quoted[0]), line)
        yield re.split(r"[;&|]+\s*", line)


def shell_signals(data, _path):
    lines = []
    heredoc = None
    for line in data.decode().splitlines():
        if heredoc:
            if line.lstrip("\t") == heredoc:
                heredoc = None
            continue
        delimiter = re.search(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1(?:\s|$)", line)
        if delimiter:
            heredoc = delimiter[2]
        line = line.strip()
        if re.search(r"#\s*SKIP\b", line, re.I):
            return "added skip"
        if line and not line.startswith("#"):
            lines.append(line)
    in_function = False
    for index, (line, parts) in enumerate(zip(lines, shell_commands(lines))):
        if re.match(r"(?:function\s+[\w-]+(?:\s*\(\s*\))?|[\w-]+\s*\(\s*\))\s*\{", line):
            in_function = not line.endswith("}")
        for part_index, part in enumerate(parts):
            if re.match(r"(?:skip[\w-]*\b|exit\s+77\b)", part):
                return "added skip"
            if not in_function and re.fullmatch(r"exit(?:\s+0)?\s*", part) and (
                index == 0 or index < len(lines) - 1 or any(parts[part_index + 1:])
            ):
                return "added early-exit marker"
            # A literal stays trivial with a message after it. A comparison
            # operator makes it an operand instead.
            if re.match(
                r"(?:assert(?:_true)?\s+(?:true|1)|test\s+true)(?:\s|$)"
                r"(?!\s*(['\"]?)(?:[=!]?=|=~|\\?[<>]|-(?:eq|ne|lt|le|gt|ge|nt|ot|ef|a))\1\s)", part,
            ):
                return "added trivial assertion"
            if re.match(
                r"(?:(?:test|assert(?:_true)?)\s+|\[\[?\s+)([\w.-]+)\s+(?:=|==|-eq)\s+\1(?:\s|$)", part,
            ):
                return "added trivial assertion"
            if re.match(r"assert_(?:equals|eq)\s+([\w.-]+)\s+\1(?:\s|$)", part):
                return "added trivial assertion"
        if line.startswith("}"):
            in_function = False
    return None


def js_signals(data, _path):
    # Consume comments, strings, regular expressions and template text before
    # reaching code spelled inside them. Template interpolations hold real code,
    # so they are scanned like the rest. Keep the string tokens available to the
    # assertion pattern.
    comment = r"//[^\r\n]*|/\*[\s\S]*?\*/"
    quoted = r"'(?:\\[\s\S]|[^'\\\r\n])*'" r'|"(?:\\[\s\S]|[^"\\\r\n])*"'
    regex = (
        r"""(?:[(,=:\[&|?;]|=>|(?<![.#\w$])(?:return\b|(?:if|while|for)\s*\([^(){}'"`/\r\n]*\)))\s*"""
        r"/(?![*/])(?:\\.|\[(?:\\.|[^\]\\\r\n])*\]|[^/\\\[\r\n])+/"
    )
    gap = rf"(?:\s|{comment})*"
    dot = rf"{gap}\.{gap}"
    # A keyword after a dot is a property name, however far the dot is. Consume
    # both so it cannot start a statement whose regular expression hides code.
    member = rf"\.{gap}(?:return|if|while|for)\b"
    modifier = rf"(?:(?:concurrent|sequential){dot})?(?:skip|skipIf|runIf|todo|only)"
    skip = (
        rf"\b(?:describe|it|test){dot}{modifier}(?:{gap}\(|{dot}each{gap}[(`])"
        rf"|\b(?:xdescribe|xit|xtest|fdescribe|fit){gap}\("
    )
    literal = rf"true|false|null|-?\d+(?:\.\d+)?|{quoted}"
    expect = (
        rf"\bexpect{gap}\({gap}(?P<expected>{literal}){gap}\){dot}"
        rf"to(?:Be|Equal|StrictEqual){gap}\({gap}(?P=expected){gap}\)"
    )
    signals = re.compile(
        rf"{comment}|{quoted}|{member}|{regex}|(?P<skip>{skip})|(?P<trivial>{expect})|(?P<template>[`{{}}])"
    )
    template_text = re.compile(r"(?:\\[\s\S]|[^\\`$]|\$(?!\{))*(?P<end>`|\$\{|)")
    text = data.decode()
    position = 0
    interpolations = []  # Open braces inside each enclosing interpolation.
    while True:
        match = signals.search(text, position)
        if match is None:
            if not interpolations:
                return None
            break
        position = match.end()
        if match["skip"]:
            return "added skip"
        if match["trivial"]:
            return "added trivial assertion"
        token = match["template"]
        if token == "{" and interpolations:
            interpolations[-1] += 1
        if token == "}" and interpolations:
            interpolations[-1] -= 1
        if token == "`" or (token == "}" and interpolations and interpolations[-1] < 0):
            if token == "}":
                interpolations.pop()
            part = template_text.match(text, position)
            position = part.end()
            if not part["end"]:
                break
            if part["end"] == "${":
                interpolations.append(0)
    # An unpaired backtick or brace means this scan misread a template. Check the
    # whole file as code rather than excluding part of it.
    for match in re.finditer(rf"{comment}|{quoted}|(?P<skip>{skip})|(?P<trivial>{expect})", text):
        if match["skip"]:
            return "added skip"
        if match["trivial"]:
            return "added trivial assertion"
    return None


def go_signals(data, _path):
    # Blank comments and string and rune literals first, so a skip counts only as
    # code. The leftmost token wins, so a quote or slash inside one opens nothing.
    # An unterminated token stays in place and is checked as code.
    code = re.sub(
        rb"//[^\n]*|/\*[\s\S]*?\*/"
        rb'|"(?:\\.|[^"\\\n])*"|`[^`]*`'
        rb"|'(?:\\.|[^'\\\n])+'",
        lambda token: b" " if token[0].startswith(b"/") else b'""', data,
    )
    if re.search(rb"\b[A-Za-z_]\w*\s*\.\s*Skip(?:f|Now)?\s*\(", code):
        return "added skip"
    return None


def tamper_check(identity, policy, before, after, paths):
    approved = dict(policy.get("new_tests", {}))
    if "regression" in policy:
        regression = policy["regression"]
        approved[regression["path"]] = regression["test_sha256"]
    for change, path in paths:
        require(relative(path) and contains(path, policy["allow"]), f"out-of-scope change: {path!r}")
        file = PurePosixPath(path)
        suffix = file.suffix.lower()
        marker = PYTEST_CONFIG.get(file.name) or EMBEDDED_TEST.get(suffix)
        if path not in approved and not test_path(path, policy) and not (
            has_test_marker(identity, before, path, marker) or has_test_marker(identity, after, path, marker)
        ):
            continue
        require(change == "A", f"existing test entry changed: {path!r}")
        new = blob(identity, after, path)
        detector = {".py": python_signals, ".sh": shell_signals, ".go": go_signals}.get(suffix)
        if re.fullmatch(r"\.[cm]?[jt]sx?", suffix):
            detector = js_signals
        signal = detector(new, path) if detector else None
        require(signal is None, f"{signal}: {path!r}")
        require(digest(new) == approved.get(path), f"new test has no matching supervisor byte pin: {path!r}")


def materialize(entries, root, blocks):
    # Materialize exact tree blobs, without checkout filters, archive attributes,
    # hooks, a worktree allocation, or a writable mount into the original repo.
    for path, (mode, kind, oid) in entries.items():
        require(relative(path) and kind == "blob", f"unsupported regression tree entry {path!r}")
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        data = blocks(oid)
        if mode == "120000":
            target.symlink_to(os.fsdecode(data))
        else:
            require(mode in ("100644", "100755"), f"unsupported regression file mode at {path!r}")
            target.write_bytes(data)
            target.chmod(0o755 if mode == "100755" else 0o644)


def regression_check(identity, policy, before, after):
    spec = policy["regression"]
    path = spec["path"]
    require(path not in before and path in after, "regression test must be new at the candidate head")
    test = blob(identity, after, path)
    runner = private_bytes(DATA / identity["task"] / "regression")
    require(digest(test) == spec["test_sha256"] and digest(runner) == spec["runner_sha256"],
            "regression test or supervisor runner differs from its approved bytes")
    require(sys.platform == "linux" and shutil.which("bwrap"), "isolated regression requires Linux bubblewrap")

    def run(root, fixture):
        args = ["bwrap", "--unshare-all", "--new-session", "--die-with-parent", "--clearenv",
                "--ro-bind", "/usr", "/usr", "--dev", "/dev", "--tmpfs", "/tmp",
                "--ro-bind", root, "/src", "--ro-bind", fixture, "/regression",
                "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/tmp",
                "--setenv", "LC_ALL", "C", "--chdir", "/src"]
        for directory in ("bin", "lib", "lib64"):
            location = Path("/") / directory
            if location.is_symlink():
                args.extend(("--symlink", os.readlink(location), str(location)))
            elif location.is_dir():
                args.extend(("--ro-bind", str(location), str(location)))
        return subprocess.run([*args, "--", "/regression", path], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              env=git_env(), timeout=120)

    def execution(result, label, expected):
        try:
            evidence = decode(result.stdout)
        except (ValueError, UnicodeError):
            raise Refusal(f"{label} regression did not report test execution evidence") from None
        require(isinstance(evidence, dict) and type(evidence.get("tests_run")) is int
                and evidence == {"test": path, "tests_run": 1, "result": expected},
                f"{label} regression did not prove the expected test execution")
        return evidence

    # Use one batch reader so extracting a tree is not one Git process per blob.
    with tempfile.TemporaryDirectory(prefix="fm-regression-", dir="/var/tmp") as scratch:
        scratch = Path(scratch)
        fixture = scratch / "runner"
        fixture.write_bytes(runner)
        fixture.chmod(0o500)
        roots = []
        with subprocess.Popen(["git", "-C", identity["worktree"], "cat-file", "--batch"],
                              env=git_env(), stdin=subprocess.PIPE, stdout=subprocess.PIPE) as reader:
            def blocks(oid):
                reader.stdin.write(f"{oid}\n".encode())
                reader.stdin.flush()
                header = reader.stdout.readline().split()
                require(len(header) == 3 and header[0].decode() == oid and header[1] == b"blob",
                        "could not materialize exact regression tree")
                size = int(header[2])
                data = reader.stdout.read(size)
                require(len(data) == size and reader.stdout.read(1) == b"\n", "truncated Git blob")
                return data

            try:
                for name, entries in (("base", before), ("head", after)):
                    root = scratch / name
                    root.mkdir()
                    materialize(entries, root, blocks)
                    roots.append(root)
            finally:
                reader.stdin.close()
                reader.wait(timeout=10)
        dest = roots[0] / path
        # A symlink at a former parent path must never redirect an overlay into
        # the host or into other snapshot content.
        require(all(not parent.is_symlink() and (not parent.exists() or parent.is_dir())
                    for parent in dest.parents if parent != scratch),
                "base regression path has an incompatible parent")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(test)
        dest.chmod(0o755 if after[path][0] == "100755" else 0o644)
        base = run(roots[0], fixture)
        if base.returncode == 0:
            raise Refusal("regression already passes at the pinned base (exit 0)")
        require(base.returncode == 10, f"base regression did not reach the expected failure (exit {base.returncode})")
        base_proof = execution(base, "base", "expected-failure")
        head = run(roots[1], fixture)
        require(head.returncode == 0, f"head regression did not pass (exit {head.returncode})")
        head_proof = execution(head, "head", "pass")
    return {**spec, "base_exit": base.returncode, "head_exit": head.returncode,
            "base_execution": base_proof, "head_execution": head_proof}


def inspect(identity, policy):
    forge_check(identity, policy)
    source = inspection_repository(identity, policy)
    require(git(source, "merge-base", "--is-ancestor", identity["base"], identity["head"],
                check=False).returncode == 0, "candidate is not based on the pinned commit")
    before, after = (tree(source, identity[key]) for key in ("base", "head"))
    changes = changed_paths(before, after)
    require(changes, "candidate has no changes against the pinned base")
    tamper_check(source, policy, before, after, changes)
    regression = regression_check(source, policy, before, after) if policy["kind"] == "bug" else None
    return {"paths": changes, "regression": regression}, source["worktree"]


def evidence_matches(evidence, policy):
    paths = evidence["paths"]
    if not paths or not all(change in ("A", "D", "M", "T") and contains(path, policy["allow"])
                            for change, path in paths):
        return False
    regression = evidence["regression"]
    if policy["kind"] == "feature":
        return regression is None
    path = policy["regression"]["path"]
    return regression == {
        **policy["regression"], "base_exit": 10, "head_exit": 0,
        "base_execution": {"test": path, "tests_run": 1, "result": "expected-failure"},
        "head_execution": {"test": path, "tests_run": 1, "result": "pass"},
    }


def ticket_for(reviewer):
    return STATE / f"{reviewer}.refute.json"


def prepare(identity, policy, reviewer):
    require(reviewer != identity["task"] and not os.path.lexists(STATE / f"{reviewer}.meta")
            and not os.path.lexists(STATE / f"{reviewer}.status"),
            "review requires a fresh scout ID")
    checked, source = inspect(identity, policy)
    task, url, base, head = (identity[key] for key in ("task", "pr", "base", "head"))
    spec = f"""Try to refute completion of {task} using the approved criteria and these exact commits.
PR {url}
Base {base}
Head {head}

Inspect the two exact commits with `git --no-replace-objects -C {shlex.quote(source)} diff --no-ext-diff --no-textconv --ignore-submodules=none {base} {head} --`.
Keep the project read-only and use only this review brief and committed source.
Make the first line of the scout report exactly one of these verdicts:
- Refute {base} {head} merge
- Refute {base} {head} fix
Below it, record a criterion, file and line, and a reproducing case for each blocker.
Use that same line as the conclusion of the normal scout done report; a different verdict is refused.
If the evidence is unavailable, report blocked.

The result applies only to these commits and carries no merge permission."""
    brief = DATA / reviewer / "brief.md"
    require(not os.path.lexists(brief) and not os.path.lexists(ticket_for(reviewer)),
            "reviewer already has a brief or dispatch record")
    subprocess.run(
        [BIN / "fm-brief.sh", reviewer, Path(identity["project"]).name, "--scout"],
        env={**os.environ, "FM_ROOT_OVERRIDE": ""}, stdout=subprocess.DEVNULL,
        timeout=30, check=True,
    )
    try:
        scaffold = private_bytes(brief, private=False).decode()
        require(scaffold.count("{TASK}") == 1 and scaffold.count("{FIRSTMATE_SPEC}") == 1,
                "native review scaffold is missing its unambiguous task sections")
        text = scaffold.replace("{FIRSTMATE_SPEC}", spec).replace("{TASK}", policy["criteria"]).encode()
        record = {"candidate": identity, "reviewer": reviewer, "brief": digest(text), "checks": checked}
        publish(brief, text, replace=True)
        publish(ticket_for(reviewer), json_bytes(record))
    except (OSError, Refusal):
        brief.unlink()
        raise
    print(brief)


def spawn_review(reviewer, kind, relaunch, harness, model, project, brief):
    record = private_bytes(ticket_for(reviewer))
    ticket = decode(record)
    ship = ticket["candidate"]
    require(kind == "scout" and relaunch == "0" and ticket["reviewer"] == reviewer,
            "refute dispatch requires a fresh native scout ID")
    require(independent_model(ship, harness, model),
            "reviewer must dispatch with an explicit provider absent from the builder lineage")
    require(same_project(project, ship["project"]) and digest(private_bytes(Path(brief))) == ticket["brief"],
            "refute dispatch project or brief does not match its prepared context")
    current, policy = context(ship["task"], ship["pr"])
    require(current == ship, "refute dispatch candidate has changed")
    forge_check(current, policy)
    print(digest(record))


def journal_rows():
    for line in private_bytes(JOURNAL).splitlines():
        if not line:
            continue
        row = decode(line)
        require(isinstance(row, dict) and isinstance(row.get("pr"), str)
                and matches(SHA, row.get("head")) and row.get("verdict") in ("merge", "fix"),
                "review verdict journal contains an invalid row")
        refute = row.get("refute")
        require("refute" not in row or isinstance(refute, dict) and isinstance(refute.get("candidate"), dict)
                and matches(SHA256, refute.get("event")), "refute review evidence is unreadable")
        yield row


def review_event(row):
    # What a recorded review stands for, without when it was recorded. A merge
    # counts again only on new evidence. A fix also counts again when the scout
    # reports it again, so a repeated blocker is never dropped.
    ignored = ("recorded_ns", "event") if row["verdict"] == "merge" else ("recorded_ns",)
    return {**row, "refute": {key: value for key, value in row["refute"].items() if key not in ignored}}


def review_result(task, reviewer, head):
    ticket_bytes = private_bytes(ticket_for(reviewer))
    ticket = decode(ticket_bytes)
    identity, _ = context(task, ticket["candidate"]["pr"])
    require(identity == ticket["candidate"] and head == identity["head"]
            and ticket["reviewer"] == reviewer and reviewer != task,
            "review did not sign off on this exact task, base and head")
    meta = metadata(reviewer)
    require(meta.get("kind") == "scout" and meta.get("spawn_gen")
            and same_project(meta.get("project"), identity["project"])
            and meta.get("refute_context") == digest(ticket_bytes),
            "review lacks a matching fresh native scout dispatch")
    model, harness = meta.get("model"), meta.get("harness")
    require(independent_model(identity, harness, model),
            "reviewer model is not independent of the builder")
    note, event = done_event(reviewer)
    report = private_bytes(DATA / reviewer / "report.md", private=False)
    title, _, findings = report.decode().partition("\n")
    verdict = re.fullmatch(rf"Refute {identity['base']} {identity['head']} (merge|fix)", title)
    require(verdict and findings.strip(), "scout report lacks findings under a verdict for the exact pinned base and head")
    require(note == title, "scout status and report verdicts disagree")
    row = {
        "pr": identity["pr"], "head": head, "reviewer": reviewer, "verdict": verdict[1],
        "refute": {"candidate": identity, "model": model, "harness": harness,
                   "generation": meta["spawn_gen"], "ticket": digest(ticket_bytes), "report": digest(report),
                   "event": event, "recorded_ns": time.time_ns()},
    }
    # fm-review-verdict.sh holds the writer lock from this read through its
    # append, so a retry keeps the first row's identity, time and position.
    recorded = list(journal_rows()) if os.path.lexists(JOURNAL) else []
    if any("refute" in old and review_event(old) == review_event(row) for old in recorded):
        print("review already recorded; the journal is unchanged", file=sys.stderr)
        return
    print(json_bytes(row).decode().strip())


def reviewer_record(identity, reviewer, ticket, row):
    # What a reviewer reports now, and whether its report and status are the ones
    # its last saved row stands for under the retry rule in review_event.
    status = STATE / f"{reviewer}.status"
    note, event = done_event(reviewer) if os.path.lexists(status) else ("", "")
    path = DATA / reviewer / "report.md"
    report = private_bytes(path, private=False) if os.path.lexists(path) else b""
    title = report.partition(b"\n")[0].decode(errors="replace")
    if row is None:
        return note, title, False, False
    refute = row["refute"]
    verdict = f"Refute {identity['base']} {identity['head']} {row['verdict']}"
    same_report = title == verdict and refute["report"] == digest(report) and refute["ticket"] == ticket
    same_event = (note == verdict and (row["verdict"] == "merge" or refute["event"] == event)
                  and metadata(reviewer).get("spawn_gen") == refute["generation"])
    return note, title, same_report, same_event


def require_saved_reports(identity, saved, latest):
    # A native report displaces the saved verdict when it is written, not when a
    # supervisor records it. Compare each reviewer of this candidate with its own
    # last saved row. A retired scout keeps its ticket and report but no status;
    # retire_review keeps a status that is the only evidence of a blocker.
    tickets = {}
    for path in STATE.glob("*.refute.json"):
        data = private_bytes(path)
        ticket = decode(data)
        if ticket["candidate"] == identity:
            require(path == ticket_for(ticket["reviewer"]), "review dispatch record names another scout")
            tickets[ticket["reviewer"]] = digest(data)
    require(latest["reviewer"] in tickets, "recorded review has no dispatch record for this candidate")
    pins = f"Refute {identity['base']} {identity['head']} "
    verdicts = (pins + "merge", pins + "fix")
    for reviewer, ticket in sorted(tickets.items()):
        live = any(os.path.lexists(STATE / f"{reviewer}.{record}") for record in ("meta", "status"))
        note, title, same_report, same_event = reviewer_record(identity, reviewer, ticket, saved.get(reviewer))
        own = reviewer == latest["reviewer"]
        # A retired scout's unsaved merge can no longer be recorded and cannot
        # weaken a later saved verdict. Its unsaved fix still blocks.
        reported = title in verdicts and (live or title == pins + "fix")
        require((same_report or not (own or reported))
                and (same_event or not ((own and live) or note in verdicts)),
                f"native review report from {reviewer} is not the saved verdict; record the current review and accept again")


def saved_reviews(identity):
    latest = None
    saved = {}
    for row in journal_rows():
        if row.get("pr") != identity["pr"] or row.get("head") != identity["head"]:
            continue
        if "refute" not in row:
            # A standard exact-head fix is still a blocker, but an ordinary
            # merge verdict cannot substitute for the native refute dispatch.
            if row.get("verdict") == "fix":
                latest = row
            continue
        refute = row["refute"]
        if refute["candidate"] != identity:
            continue
        harness, model = refute.get("harness"), refute.get("model")
        require(independent_model(identity, harness, model) and refute.get("generation")
                and matches(SHA256, refute.get("ticket")) and matches(SHA256, refute.get("report"))
                and matches(ID, row.get("reviewer")) and row["reviewer"] != identity["task"],
                "recorded review does not identify an independent native scout")
        latest = saved[row["reviewer"]] = row
    return latest, saved


def passing_review(identity):
    latest, saved = saved_reviews(identity)
    require(latest and latest.get("verdict") == "merge" and "refute" in latest,
            "missing passing fresh-context review for this task and exact head")
    require_saved_reports(identity, saved, latest)
    return digest(json_bytes(latest))


def retire_review(reviewer):
    # Teardown removes the scout's status, which can be the only evidence of a
    # blocker nobody recorded. Hold retirement until the journal carries it. A
    # candidate whose ship retired or reported again can no longer be accepted.
    data = private_bytes(ticket_for(reviewer))
    ticket = decode(data)
    identity = ticket["candidate"]
    task = identity["task"]
    require(ticket["reviewer"] == reviewer, "review dispatch record names another scout")
    if not os.path.lexists(POLICY_DIR) or not os.path.lexists(STATE / f"{task}.meta"):
        return
    if (done_event(task)[1] != identity["candidate_event"]
            or metadata(task).get("spawn_gen") != identity["generation"]):
        return
    saved = saved_reviews(identity)[1] if os.path.lexists(JOURNAL) else {}
    note, title, same_report, same_event = reviewer_record(identity, reviewer, digest(data), saved.get(reviewer))
    fix = f"Refute {identity['base']} {identity['head']} fix"
    require((same_report or title != fix) and (same_event or note != fix),
            f"{reviewer} reports a blocker that is not its saved verdict; record it with "
            f"fm-review-verdict.sh refute {task} {reviewer} {identity['head']} before retiring the scout")


def main():
    action, task, *args = sys.argv[1:]
    require(matches(ID, task), "invalid task ID")
    require(not os.environ.get("FM_TASK_ID") or action in ("passing", "assert", "retire-review"),
            "acceptance and review intake are supervisor operations")
    if action == "spawn-review" and len(args) == 6:
        spawn_review(task, *args)
        return
    if action == "retire-review" and not args:
        retire_review(task)
        return
    if action == "review-result" and len(args) == 2 and matches(ID, args[0]) and matches(SHA, args[1]):
        review_result(task, *args)
        return
    require(action in ("accept", "passing", "assert", "review-brief") and args, "invalid acceptance request")
    url, *rest = args
    identity, policy = context(task, url)
    if action == "review-brief":
        require(len(rest) == 1 and matches(ID, rest[0]), "review-brief requires a valid fresh scout ID")
        prepare(identity, policy, rest[0])
        return
    require(not rest or (action in ("assert", "passing") and rest == [identity["head"]]),
            "acceptance evidence does not name the requested head")
    receipt = STATE / f"{task}.accepted.json"
    if action == "accept":
        checked, _ = inspect(identity, policy)
        review = passing_review(identity)
        forge_check(identity, policy)
        require(context(task, url)[0] == identity, "candidate or policy changed during verification")
        require(passing_review(identity) == review, "review changed during verification")
        publish(receipt, json_bytes({"candidate": identity, "review": review, "checks": checked}), replace=True)
    else:
        accepted = decode(private_bytes(receipt))
        require(accepted["candidate"] == identity and accepted["review"] == passing_review(identity),
                "accepted evidence no longer matches this candidate or review")
        require(evidence_matches(accepted["checks"], policy), "accepted check evidence is incomplete")
        if action == "assert":
            forge_check(identity, policy)
            require(context(task, url)[0] == identity, "candidate or policy changed during verification")
            require(accepted["review"] == passing_review(identity), "review changed during verification")
    print(identity["head"])


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, KeyError, TypeError, SyntaxError, subprocess.SubprocessError) as error:
        print(f"error: done acceptance: {error}", file=sys.stderr)
        sys.exit(1)
