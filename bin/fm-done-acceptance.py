#!/usr/bin/env python3
"""Supervisor-owned exact-commit acceptance. The CLI contract lives in fm-done-check.sh."""

import ast
import base64
from collections import Counter
import hashlib
import json
import operator
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import time

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


def private_bytes(path, private=True):
    # O_NONBLOCK avoids waiting on a FIFO. Open the same inode we validate.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as file:
        info = os.fstat(file.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == os.getuid() and not info.st_mode & (0o077 if private else 0o022),
                f"{path.name} is not a suitable owned record")
        return file.read()


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


def done_note(task):
    path = STATE / f"{task}.status"
    private_bytes(path, private=False)
    return subprocess.check_output(
        ["bash", "-c",
         '. "$1"; line=$(last_crew_status_line "$2"); '
         'if [ "$(status_line_verb "$line")" = "done" ]; then status_line_note "$line"; fi',
         "fm-acceptance", BIN / "fm-classify-lib.sh", path], timeout=10, text=True
    ).strip()


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
        "repo", "base_branch", "base", "kind", "allow", "tests", "criteria", "regression"
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
    if policy["kind"] == "bug":
        spec = policy.get("regression")
        require(isinstance(spec, dict) and set(spec) == {"path", "test_sha256", "runner_sha256"}
                and relative(spec["path"]) and matches(SHA256, spec["test_sha256"])
                and matches(SHA256, spec["runner_sha256"]),
                "bug policy requires a pinned new regression test and runner")
        require(contains(spec["path"], policy["allow"]), "regression path is outside allowed scope")
    else:
        require("regression" not in policy, "only a bug policy accepts a regression specification")
    return policy, digest(data)


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
    model = meta.get("model")
    harness = meta.get("harness")
    require(harness in MODEL and matches(MODEL[harness], model),
            "native ship must record an explicit Codex or Claude model ID")
    event = done_note(task)
    submission = re.fullmatch(rf"PR {re.escape(url)}( checks green)? head ({SHA})(?: proof=\S+)?", event)
    require(submission and bool(submission[1]) == (meta["mode"] == "no-mistakes"),
            f"no current exact-head done candidate for {task}")
    identity = {
        "task": task, "generation": meta["spawn_gen"], "branch": meta["branch"],
        "worktree": meta["worktree"], "project": meta.get("project"),
        "candidate": event, "pr": url, "head": submission[2],
        "base": policy["base"], "base_branch": policy["base_branch"], "policy": policy_digest,
        "builder": {"harness": harness, "model": model},
    }
    return identity, policy


def forge_check(identity, policy):
    parsed = re.fullmatch(URL, identity["pr"])
    # gh-axi renders scalar jq results in an envelope. Base64 makes the fixed
    # projection independent of the renderer's quoting and forge-supplied prose.
    projection = ("[.html_url,.base.repo.full_name,.base.ref,.base.sha,"
                  ".head.repo.full_name,.head.ref,.head.sha,.state,.draft] | @json | @base64")
    result = subprocess.check_output(
        ["gh-axi", "api", f"/repos/{parsed[1]}/pulls/{parsed[2]}",
         "--hostname", "github.com", "--jq", projection], timeout=10, text=True
    )
    envelope = re.fullmatch(r"api_response:\n  body: ([A-Za-z0-9+/=]+)\n  truncated: false\s*", result)
    require(envelope, "GitHub PR facts are unreadable")
    facts = decode(base64.b64decode(envelope[1], validate=True))
    require(isinstance(facts, list) and len(facts) == 9, "GitHub PR facts are incomplete")
    url, repo, branch, base, fork, source, head, state, draft = facts
    require(url == identity["pr"] and repo == policy["repo"] and fork == policy["repo"]
            and branch == identity["base_branch"] and source == identity["branch"],
            "GitHub repository, task branch or target branch does not match the pinned candidate")
    require(base == identity["base"] and head == identity["head"],
            "live GitHub base or head differs from the pinned candidate")
    require(state == "open" and draft is False, "candidate PR must be open and ready for review")


def git_env():
    return {
        "PATH": os.environ["PATH"], "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1",
    }


def git(identity, *args, check=True):
    return subprocess.run(
        ["git", "-C", identity["worktree"], *args], env=git_env(), timeout=30,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check
    )


def commit(identity, sha):
    require(git(identity, "cat-file", "-t", sha).stdout == b"commit\n", f"{sha} is not a commit")


def tree(identity, sha):
    entries = {}
    for row in git(identity, "ls-tree", "-rz", "--full-tree", sha).stdout.split(b"\0")[:-1]:
        entry, path = row.split(b"\t", 1)
        mode, kind, oid = entry.decode().split()
        entries[os.fsdecode(path)] = mode, kind, oid
    return entries


def changed_paths(identity):
    raw = git(identity, "diff", "--name-status", "-z", "--no-renames", "--no-ext-diff",
              "--no-textconv", identity["base"], identity["head"], "--").stdout
    fields = raw.split(b"\0")
    require(fields[-1] == b"" and len(fields) % 2 == 1, "Git returned incomplete path evidence")
    return [(os.fsdecode(fields[i]), os.fsdecode(fields[i + 1])) for i in range(0, len(fields) - 1, 2)]


def test_path(path, policy):
    return (contains(path, policy["tests"])
            or bool(re.search(r"(?:^|/)(?:tests?|specs?)/|(?:^|/)test_[^/]+|[._-](?:test|spec)\.[^/]+$", path)))


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
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not) and isinstance(node.operand, ast.Constant):
        return not node.operand.value
    if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
        return any(isinstance(term, ast.Constant) and term.value for term in node.values)
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
    tests, assertions, skips, tautologies = [], [], [], []
    for node in ast.walk(tree_ast):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test"):
            tests.append(node.name)
        if isinstance(node, ast.Assert):
            assertions.append(ast.dump(node.test))
            if trivial(node.test):
                tautologies.append(ast.dump(node.test))
        if isinstance(node, (ast.With, ast.AsyncWith)):
            for item in node.items:
                if isinstance(item.context_expr, ast.Call) and dotted(item.context_expr.func) == "pytest.raises":
                    assertions.append(ast.dump(item.context_expr))
        if isinstance(node, ast.Call):
            name = dotted(node.func)
            method = name.rsplit(".", 1)[-1]
            if re.fullmatch(r"assert[A-Z]\w*", method):
                assertions.append(ast.dump(node))
                if ((method == "assertTrue" and node.args and trivial(node.args[0]))
                        or (method == "assertEqual" and len(node.args) >= 2
                            and trivial(ast.Compare(node.args[0], [ast.Eq()], [node.args[1]])))):
                    tautologies.append(ast.dump(node))
            if method in ("skip", "skipIf", "skipUnless", "skipTest", "xfail", "expectedFailure"):
                skips.append(name)
        if isinstance(node, ast.Attribute) and (
                dotted(node).startswith("pytest.mark.") or dotted(node).startswith("unittest.")):
            if node.attr in ("skip", "skipif", "xfail", "skipIf", "skipUnless", "expectedFailure"):
                skips.append(dotted(node))
    return tests, assertions, skips, tautologies


def shell_signals(data):
    all_lines = [line.strip() for line in data.decode().splitlines()]
    lines = [line for line in all_lines if not line.startswith("#")]
    tests = [line for line in lines if re.match(r"(?:function\s+)?test_[\w-]+\s*\(\)", line)]
    assertions = [line for line in lines if re.search(
        r"(?:^|[;&|]\s*|\bthen\s+)(?:assert[\w-]*\b|expect[\w-]*\b|"
        r"\[\[?\s|test\s|fail\b|not_ok\b)", line)]
    skips = [line for line in lines if re.search(
        r"(?:^|[;&|]\s*)(?:skip[\w-]*\b|exit\s+77\b)|#\s*SKIP\b", line, re.I)]
    skips.extend(line for line in all_lines if re.match(r"#\s*SKIP\b", line, re.I))
    tautologies = [line for line in lines if re.match(
        r"(?:assert(?:_true)?\s+(?:true|1)|(?:test\s|\[\[?\s)(?:1\s*=\s*1|true))\s*(?:$|[;\]])", line)]
    return tests, assertions, skips, tautologies


def tamper_check(identity, policy, before, after, paths):
    for change, path in paths:
        require(relative(path) and contains(path, policy["allow"]), f"out-of-scope change: {path!r}")
        if not test_path(path, policy):
            continue
        require(change != "D", f"deleted or renamed test path: {path!r}")
        new = blob(identity, after, path)
        old = blob(identity, before, path) if path in before else b""
        detector = {".py": python_signals, ".sh": lambda data, _: shell_signals(data)}.get(
            PurePosixPath(path).suffix
        )
        if detector is None:
            # Other formats still receive the path/delete checks and refute review.
            continue
        previous = tuple(map(Counter, detector(old, path)))
        candidate = tuple(map(Counter, detector(new, path)))
        for i, reason in enumerate(("removed test", "removed assertion", "added skip", "added trivial assertion")):
            difference = previous[i] - candidate[i] if i < 2 else candidate[i] - previous[i]
            require(not difference, f"{reason}: {path!r}")


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
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              env=git_env(), timeout=120).returncode

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
        base_exit = run(roots[0], fixture)
        if base_exit == 0:
            raise Refusal("regression already passes at the pinned base (exit 0)")
        require(base_exit == 10, f"base regression did not reach the expected failure (exit {base_exit})")
        head_exit = run(roots[1], fixture)
        require(head_exit == 0, f"head regression did not pass (exit {head_exit})")
    return {**spec, "base_exit": base_exit, "head_exit": head_exit}


def inspect(identity, policy):
    forge_check(identity, policy)
    commit(identity, identity["base"])
    commit(identity, identity["head"])
    require(git(identity, "merge-base", "--is-ancestor", identity["base"], identity["head"],
                check=False).returncode == 0, "candidate is not based on the pinned commit")
    changes = changed_paths(identity)
    require(changes, "candidate has no changes against the pinned base")
    before, after = (tree(identity, identity[key]) for key in ("base", "head"))
    tamper_check(identity, policy, before, after, changes)
    regression = regression_check(identity, policy, before, after) if policy["kind"] == "bug" else None
    return {"paths": changes, "regression": regression}


def evidence_matches(evidence, policy):
    paths = evidence["paths"]
    if not paths or not all(change in ("A", "D", "M", "T") and contains(path, policy["allow"])
                            for change, path in paths):
        return False
    regression = evidence["regression"]
    if policy["kind"] == "feature":
        return regression is None
    return regression == {**policy["regression"], "base_exit": 10, "head_exit": 0}


def ticket_for(reviewer):
    return STATE / f"{reviewer}.refute.json"


def prepare(identity, policy, reviewer):
    require(reviewer != identity["task"] and not os.path.lexists(STATE / f"{reviewer}.meta")
            and not os.path.lexists(STATE / f"{reviewer}.status"),
            "review requires a fresh scout ID")
    checked = inspect(identity, policy)
    task, url, base, head = (identity[key] for key in ("task", "pr", "base", "head"))
    spec = f"""Try to refute completion of {task} using the approved criteria and these exact commits.
PR {url}
Base {base}
Head {head}

Inspect the two exact commits with `git -C {shlex.quote(identity["worktree"])} diff --no-ext-diff --no-textconv {base} {head} --`.
Keep the project read-only and use only this review brief and committed source.
Record a criterion, file and line, and a reproducing case for each blocker in the scout report.
If the evidence is unavailable, report blocked.
For the conclusion of the normal scout done report, use one of these exact values:
- Refute {base} {head} merge
- Refute {base} {head} fix

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
    builder = ship["builder"]
    require(kind == "scout" and relaunch == "0" and ticket["reviewer"] == reviewer,
            "refute dispatch requires a fresh native scout ID")
    require(harness in MODEL and matches(MODEL[harness], model) and harness != builder["harness"],
            "reviewer must dispatch with an explicit model from the other supported provider")
    require(project == ship["project"] and digest(private_bytes(Path(brief))) == ticket["brief"],
            "refute dispatch project or brief does not match its prepared context")
    current, _ = context(ship["task"], ship["pr"])
    require(current == ship, "refute dispatch candidate has changed")
    print(digest(record))


def review_result(task, reviewer, head):
    ticket_bytes = private_bytes(ticket_for(reviewer))
    ticket = decode(ticket_bytes)
    identity, _ = context(task, ticket["candidate"]["pr"])
    require(identity == ticket["candidate"] and head == identity["head"]
            and ticket["reviewer"] == reviewer and reviewer != task,
            "review did not sign off on this exact task, base and head")
    meta = metadata(reviewer)
    require(meta.get("kind") == "scout" and meta.get("spawn_gen") and meta.get("project") == identity["project"]
            and meta.get("refute_context") == digest(ticket_bytes),
            "review lacks a matching fresh native scout dispatch")
    model, harness = meta.get("model"), meta.get("harness")
    require(harness in MODEL and matches(MODEL[harness], model) and harness != identity["builder"]["harness"],
            "reviewer model is not independent of the builder")
    verdict = re.fullmatch(rf"Refute {identity['base']} {identity['head']} (merge|fix)", done_note(reviewer))
    require(verdict, "scout did not report a verdict for the exact pinned base and head")
    report = private_bytes(DATA / reviewer / "report.md", private=False)
    require(report.strip(), "independent review report is empty")
    print(json_bytes({
        "pr": identity["pr"], "head": head, "reviewer": reviewer, "verdict": verdict[1],
        "refute": {"candidate": identity, "model": model, "harness": harness,
                   "generation": meta["spawn_gen"], "ticket": digest(ticket_bytes), "report": digest(report),
                   "recorded_ns": time.time_ns()},
    }).decode().strip())


def passing_review(identity):
    latest = None
    for line in private_bytes(JOURNAL).splitlines():
        if not line:
            continue
        row = decode(line)
        require(isinstance(row, dict) and isinstance(row.get("pr"), str)
                and matches(SHA, row.get("head")) and row.get("verdict") in ("merge", "fix"),
                "review verdict journal contains an invalid row")
        if row.get("pr") != identity["pr"] or row.get("head") != identity["head"]:
            continue
        if "refute" not in row:
            # A standard exact-head fix is still a blocker, but an ordinary
            # merge verdict cannot substitute for the native refute dispatch.
            if row.get("verdict") == "fix":
                latest = row
            continue
        refute = row["refute"]
        require(isinstance(refute, dict) and isinstance(refute.get("candidate"), dict),
                "refute review evidence is unreadable")
        if refute.get("candidate") != identity:
            continue
        harness, model = refute.get("harness"), refute.get("model")
        require(harness in MODEL and matches(MODEL[harness], model)
                and harness != identity["builder"]["harness"] and refute.get("generation")
                and matches(SHA256, refute.get("ticket")) and matches(SHA256, refute.get("report"))
                and matches(ID, row.get("reviewer")) and row["reviewer"] != identity["task"],
                "recorded review does not identify an independent native scout")
        latest = row
    require(latest and latest.get("verdict") == "merge" and "refute" in latest,
            "missing passing fresh-context review for this task and exact head")
    return digest(json_bytes(latest))


def main():
    action, task, *args = sys.argv[1:]
    require(matches(ID, task), "invalid task ID")
    require(not os.environ.get("FM_TASK_ID") or action in ("passing", "assert"),
            "acceptance and review intake are supervisor operations")
    if action == "spawn-review" and len(args) == 6:
        spawn_review(task, *args)
        return
    if action == "review-result" and len(args) == 2 and matches(ID, args[0]) and matches(SHA, args[1]):
        review_result(task, *args)
        return
    require(action in ("accept", "passing", "assert", "review-brief") and args, "invalid acceptance request")
    url, *rest = args
    identity, policy = context(task, url)
    if action == "review-brief" and len(rest) == 1 and matches(ID, rest[0]):
        prepare(identity, policy, rest[0])
        return
    require(not rest or (action in ("assert", "passing") and rest == [identity["head"]]),
            "acceptance evidence does not name the requested head")
    receipt = STATE / f"{task}.accepted.json"
    if action == "accept":
        checked = inspect(identity, policy)
        review = passing_review(identity)
        require(context(task, url)[0] == identity, "candidate or policy changed during verification")
        forge_check(identity, policy)
        require(passing_review(identity) == review, "review changed during verification")
        publish(receipt, json_bytes({"candidate": identity, "review": review, "checks": checked}), replace=True)
    else:
        accepted = decode(private_bytes(receipt))
        require(accepted["candidate"] == identity and accepted["review"] == passing_review(identity),
                "accepted evidence no longer matches this candidate or review")
        require(evidence_matches(accepted["checks"], policy), "accepted check evidence is incomplete")
        if action == "assert":
            forge_check(identity, policy)
    print(identity["head"])


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, KeyError, TypeError, SyntaxError, subprocess.SubprocessError) as error:
        print(f"error: done acceptance: {error}", file=sys.stderr)
        sys.exit(1)
