#!/usr/bin/env python3
"""Durable outbound and inbound records for the VM Build / Ops Boston relay."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


MAX_BYTES = 64 * 1024
MAX_DETAIL_BYTES = 512
ROLE = {"request": "vm-build-mate", "result": "ops"}
REQUEST_HEADER = "# Boston test requests from vm-build-mate (report PASS/FAIL with head)"
RESULT_HEADER = "# Boston test results for vm-build-mate"
ROW = re.compile(
    r"- https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*"
    r" head [0-9a-f]{40}(?: base [0-9a-f]{40})?"
    r" \| (\S(?:.*\S)?) \| from [A-Za-z0-9][A-Za-z0-9._-]*"
)
BIN = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def correlation(value):
    require(re.fullmatch(r"[0-9a-f]{16}", value), "expected a 16-digit lowercase hex correlation")
    return value


def local_role(home):
    config = home / "config/boston-batch-relay"
    require(config.is_file() and not config.is_symlink(), "Boston peer route is disabled")
    lines = config.read_text(encoding="utf-8").splitlines()
    require(len(lines) == 2 and lines[0] in ROLE.values(), "invalid Boston peer route")
    peer = ROLE["result"] if lines[0] == ROLE["request"] else ROLE["request"]
    require(lines[1].startswith(f"- {peer} - "), "Boston peer route must name the opposite role")
    return lines[0]


def read_batch(stream):
    body = stream.read(MAX_BYTES + 1)
    require(0 < len(body) <= MAX_BYTES, "Boston batch must be 1 to 65536 bytes")
    return body


def batch_lines(body, header):
    text = body.decode("utf-8")
    require(all(c == "\n" or c.isprintable() for c in text), "invalid character in Boston batch")
    lines = text.splitlines()
    require(lines and lines[0] == header, "invalid Boston batch header")
    return [line for line in lines[1:] if line]


def request_rows(body):
    rows = batch_lines(body, REQUEST_HEADER)
    require(rows, "Boston batch has no rows")
    require(all(ROW.fullmatch(row) for row in rows),
            "invalid Boston row (need PR URL, full head, suite and requester)")
    unique = set(rows)
    require(len(unique) == len(rows), "duplicate Boston request row")
    return unique


def result_row(body):
    lines = batch_lines(body, RESULT_HEADER)
    require(lines, "Boston result needs one originating request row")
    row, _, outcome = lines[0].rpartition(" | ")
    require(outcome in ("PASS", "FAIL", "INFRA"), "Boston result needs PASS, FAIL or INFRA")
    require(ROW.fullmatch(row), "invalid Boston result row")
    seen = set()
    for line in lines[1:]:
        field, sep, text = line.partition(": ")
        require(sep and field in ("Evidence", "Counts") and field not in seen,
                "Boston result accepts one row and optional Evidence and Counts lines")
        require(0 < len(text.encode("utf-8")) <= MAX_DETAIL_BYTES and text == text.strip(),
                "Boston evidence and counts must be 1 to 512 bytes each")
        seen.add(field)
    return row


def read_record(path):
    require(path.is_file() and not path.is_symlink() and not path.parent.is_symlink(),
            f"missing or unsafe Boston record at {path}")
    with path.open("rb") as stream:
        return read_batch(stream)


def receipt_name(root, request_box, kind, corr, body):
    request_name = f"request-{corr}.md"
    if kind == "request":
        request_rows(body)
        return request_name

    row = result_row(body)
    request = root / request_box / request_name
    require(request.is_file(), "no matching Boston request for this correlation")
    require(row in request_rows(read_record(request)), "Boston result row is absent from the correlated request")
    case_id = hashlib.sha256(row.encode("utf-8")).hexdigest()
    return f"result-{corr}-{case_id}.md"


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def safe_dir(path):
    path.mkdir(mode=0o700, exist_ok=True)
    require(path.is_dir() and not path.is_symlink(), f"unsafe Boston directory at {path}")


def store(destination, body):
    # Publish a full record exactly once, even with concurrent senders. A replay
    # must match byte for byte. Sync payload and directory before acknowledging.
    safe_dir(destination.parent.parent)
    safe_dir(destination.parent)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".staging-") as staged:
        staged.write(body)
        staged.flush()
        os.fsync(staged.fileno())
        try:
            os.link(staged.name, destination)
        except FileExistsError:
            require(read_record(destination) == body, f"conflicting Boston record at {destination}")
        for directory in destination.parents[:3]:
            sync_dir(directory)


def deliver(kind, corr, path):
    sent = path.with_suffix(".sent")
    if sent.is_file() and not sent.is_symlink():
        return True
    body = read_record(path)
    peer = ROLE["result"] if kind == "request" else ROLE["request"]
    digest = hashlib.sha256(body).hexdigest()
    completed = subprocess.run(
        [str(BIN / "fm-on.sh"), "--stdin", peer, "fm-boston-batch-receive.sh", kind, corr, digest],
        input=body, check=False,
    )
    if completed.returncode != 0:
        print(f"Boston delivery unconfirmed (exit {completed.returncode}). Kept {path} for retry.",
              file=sys.stderr)
        return False
    store(sent, b"delivered\n")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    send = commands.add_parser("send", help="stage and deliver a request from VM Build or result from Ops")
    send.add_argument("correlation")
    send.add_argument("file", type=Path, help="Markdown request or single-case result")
    commands.add_parser("retry", help="deliver all staged records without a confirmed receipt")
    receive = commands.add_parser("receive", help="validate wire input for the remote receiver")
    receive.add_argument("kind", choices=ROLE)
    receive.add_argument("correlation")
    receive.add_argument("digest")
    args = parser.parse_args()

    home_value = os.environ.get("FM_HOME")
    require(home_value and Path(home_value).is_absolute(), "set FM_HOME to an absolute home path")
    home = Path(home_value)
    role = local_role(home)
    root = home / "data/boston-batch-relay"
    require(root.parent.is_dir() and not root.parent.is_symlink() and not root.is_symlink(),
            "unsafe Boston home data directory")
    kind = "request" if role == ROLE["request"] else "result"

    if args.command == "retry":
        outbox = root / "outbox"
        require(not outbox.is_symlink(), "unsafe Boston outbox")
        success = True
        for path in sorted(outbox.glob(f"{kind}-*.md")):
            corr = correlation(path.stem.split("-", 2)[1])
            success = deliver(kind, corr, path) and success
        return 0 if success else 1

    corr = correlation(args.correlation)
    if args.command == "send":
        with args.file.open("rb") as stream:
            body = read_batch(stream)
        name = receipt_name(root, "inbox", kind, corr, body)
        path = root / "outbox" / name
        store(path, body)
        return 0 if deliver(kind, corr, path) else 1

    require(args.kind != kind, "Boston payload reached the wrong role")
    body = read_batch(sys.stdin.buffer)
    require(hashlib.sha256(body).hexdigest() == args.digest, "Boston payload digest mismatch")
    name = receipt_name(root, "outbox", args.kind, corr, body)
    path = root / "inbox" / name
    store(path, body)
    print(path.relative_to(home))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(f"Boston relay: {error}")
