#!/usr/bin/env python3
"""Implementation for fm-procevent-archive.sh and fm-vm-handed.sh; see their headers."""
import argparse
import datetime
import fcntl
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import tempfile
import time
import uuid


def regular(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return info if stat.S_ISREG(info.st_mode) else None


def fingerprint(path):
    info = regular(path)
    if info is None:
        raise ValueError(f"not a regular file: {path}")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def atomic_write(path, data):
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def archive(state, apply):
    inbox = state / "procevent-inbox"
    if not inbox.exists():
        print("eligible_pairs=0")
        return
    if inbox.is_symlink() or not inbox.is_dir():
        raise ValueError("inbox must be a real directory")
    cutoff = time.time() - 7 * 86400
    pairs = []
    for result in sorted(inbox.glob("*.json")):
        marker = result.with_suffix(".handled")
        infos = [regular(result), regular(marker)]
        if all(info is not None and info.st_mtime < cutoff for info in infos):
            pairs.append((result, marker))
    print(f"eligible_pairs={len(pairs)}")
    if not apply or not pairs:
        return
    destination = state / "procevent-archive"
    if destination.is_symlink():
        raise ValueError("archive directory cannot be a symlink")
    destination.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    target = destination / f"acknowledged-{stamp}-{uuid.uuid4().hex}.tar.gz"
    fd, name = tempfile.mkstemp(prefix=".archive-", dir=destination)
    snapshots = {}
    try:
        with os.fdopen(fd, "wb") as out:
            with tarfile.open(fileobj=out, mode="w:gz") as bundle:
                for pair in pairs:
                    for path in pair:
                        before = fingerprint(path)
                        data = path.read_bytes()
                        if fingerprint(path) != before:
                            raise ValueError(f"changed during capture: {path}")
                        snapshots[path] = (before, data)
                        info = tarfile.TarInfo(path.name)
                        info.size = len(data)
                        info.mode = 0o600
                        bundle.addfile(info, io.BytesIO(data))
            out.flush()
            os.fsync(out.fileno())
        with tarfile.open(name, "r:gz") as bundle:
            for path, (_, data) in snapshots.items():
                if bundle.extractfile(path.name).read() != data:
                    raise ValueError(f"archive verification failed: {path}")
        os.replace(name, target)
        directory_fd = os.open(destination, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        removed = 0
        for pair in pairs:
            # Leave the entire pair live if either member changed after capture.
            if all(fingerprint(path) == snapshots[path][0] for path in pair):
                for path in pair:
                    path.unlink()
                removed += 1
        print(f"archived_pairs={removed} archive={target}")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def pair(pr, sha):
    if not re.fullmatch(r"[1-9][0-9]*", pr):
        raise ValueError("pull request number must be positive digits")
    if not re.fullmatch(r"[a-fA-F0-9]{40}", sha):
        raise ValueError("head must be a full 40-character Git SHA")
    return f"{pr} {sha.lower()}"


def api_body(path, query, paginate=False):
    command = ["gh-axi", "api", path, "--jq", query, "--full"]
    if paginate:
        command.append("--paginate")
    reply = subprocess.run(command, check=True, capture_output=True,
                           text=True, timeout=30).stdout.strip()
    # gh-axi 0.1.35 exposes jq output as a TOON api_response envelope.
    # Only accept the bounded, untruncated scalar shape used by these queries.
    match = re.fullmatch(r'api_response:\n  body: (.*)\n  truncated: false', reply)
    if not match:
        raise ValueError("unrecognized or truncated gh-axi API response")
    value = match[1]
    return json.loads(value) if value.startswith('"') else value


def handed(state, action, args):
    ledger = state / "vm-handed.txt"
    if ledger.is_symlink():
        raise ValueError("handoff ledger cannot be a symlink")
    if action in ("pending", "pending-open"):
        repo = args[0]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("expected owner/repository")
        if action == "pending-open":
            body = api_body(f"/repos/{repo}/pulls?state=open&per_page=100",
                            '.[] | [.number, .head.sha] | @tsv', paginate=True)
            expected_pairs = [pair(*row.split()) for row in body.splitlines() if row]
            lines = ledger.read_text().lower().splitlines() if ledger.exists() else []
            for expected in expected_pairs:
                if expected not in lines:
                    print(expected)
            return 0
        pr = args[1]
        pair(pr, "0" * 40)
        sha = api_body(f"/repos/{repo}/pulls/{pr}",
                       'if .state == "open" then .head.sha else "" end')
        if not sha:
            return 0
        expected = pair(pr, sha)
    else:
        expected = pair(*args)
    if action == "record":
        state.mkdir(parents=True, exist_ok=True)
        lock = state / ".vm-handed.lock"
        if lock.is_symlink():
            raise ValueError("ledger lock cannot be a symlink")
        with lock.open("a") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            lines = ledger.read_text().splitlines() if ledger.exists() else []
            valid, legacy = [], []
            for line in lines:
                fields = line.split()
                if len(fields) == 1 and fields[0].isdigit():
                    legacy.append(line)
                elif len(fields) == 2:
                    valid.append(pair(*fields))
                elif line.strip():
                    raise ValueError("invalid handoff ledger row; refusing rewrite")
            if legacy:
                backup = state / "vm-handed.legacy.txt"
                if backup.is_symlink():
                    raise ValueError("legacy ledger cannot be a symlink")
                old = backup.read_text() if backup.exists() else ""
                atomic_write(backup, (old + "\n".join(legacy) + "\n").encode())
            atomic_write(ledger, ("\n".join(dict.fromkeys(valid + [expected])) + "\n").encode())
        print(expected)
        return 0
    lines = ledger.read_text().splitlines() if ledger.exists() else []
    found = any(line.lower() == expected for line in lines)
    if action == "pending":
        if not found:
            print(expected)
        return 0
    return 0 if found else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    archive_parser = sub.add_parser("archive")
    archive_parser.add_argument("--apply", action="store_true")
    handed_parser = sub.add_parser("handed")
    handed_parser.add_argument("action", choices=["check", "record", "pending", "pending-open"])
    handed_parser.add_argument("arguments", nargs="+")
    args = parser.parse_args()
    home = os.environ.get("FM_HOME", "")
    if not home or not Path(home).is_absolute():
        parser.error("FM_HOME must be an explicit absolute home path")
    state = Path(home) / "state"
    if state.is_symlink():
        parser.error("state cannot be a symlink")
    if args.command == "archive":
        if not args.apply or not state.exists():
            archive(state, args.apply)
        else:
            lock = state / ".procevent-archive.lock"
            if lock.is_symlink():
                raise ValueError("archive lock cannot be a symlink")
            with lock.open("a") as guard:
                fcntl.flock(guard, fcntl.LOCK_EX)
                archive(state, True)
        return 0
    expected_count = 1 if args.action == "pending-open" else 2
    if len(args.arguments) != expected_count:
        parser.error(f"{args.action} requires {expected_count} arguments")
    return handed(state, args.action, args.arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        raise SystemExit(f"housekeeping failed: {error}") from error
