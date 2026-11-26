#!/usr/bin/env python3
"""Join the facts bin/fm-review-eligibility-preview.sh collects and print them.

Usage: fm-review-eligibility-preview.py [--json] < facts.jsonl

Reads one JSON object per line from stdin and writes only to stdout and stderr.
This file owns each row's disposition; the first that applies wins:

  unknown            the pull request was not observed
  draft              it is a draft
  reviewed-head      a verdict is already recorded for the observed head
  held               a held task names it, or is its owner's task
  owned              an owner's last status event is neither done nor failed
  review-dispatched  a live refute scout was dispatched for the observed head
  unknown            an input could not be read, a refute dispatch for this head
                     has neither a verdict nor a live scout, or no eligible
                     prior verdict joins
  fix-evidenced      the head changed and an owner's latest ready report for this
                     pull request names the observed head
  verify-fix         the head changed with no such report

A changed head alone never counts as a fix. No disposition authorizes a review.
"""

import json
import re
import sys
import time

NOTE = ("Advice only, bound to the observed head and time. Other-home owner and hold evidence is "
        "unknown; the dispatch owner rechecks the live head, holds, owners, capacity, proof and model.")
FINISHED = ("done", "failed")


def shown(show, field):
    found = re.search(rf"^  {field}: (.*)$", show, re.M)
    if not found:
        return ""
    value = found[1]
    if value.startswith('"'):
        try:
            value = json.loads(value)
        except ValueError:
            pass
    return "" if value == "-" else value


def owners_of(url, pr, records):
    owners = []
    for record in records:
        by_pr = record["pr"].lower() == url.lower()
        # A recorded pr= names the record's only pull request, whatever its branch.
        by_branch = (not record["pr"] and record["branch"] == pr["branch"]
                     and pr["head_repo"].replace("%2F", "/") in record["sources"])
        if by_pr or by_branch:
            owners.append({**record, "joined_by": "pr" if by_pr else "branch"})
    return owners


def holds_of(url, owners, holds):
    named = re.compile(re.escape(url) + r"(?![0-9])", re.I)
    tasks = {(owner["state"], owner["id"]) for owner in owners}
    found = []
    for hold in holds:
        text = "\n".join(shown(hold["show"], field) for field in ("title", "hold_reason", "links", "body"))
        if (hold["state"], hold["id"]) in tasks or named.search(text):
            found.append({"id": hold["id"], "state": hold["state"]})
    return found


def judge(url, pr, facts):
    verdicts = [row for row in facts["verdict"] if row["pr"].lower() == url.lower()]
    current = {}
    latest_prior = {}
    refute_merges = []
    for row in verdicts:
        if not row["eligible"]:
            refute_merges.append({key: row[key] for key in ("head", "verdict")})
            continue
        record = {key: row[key] for key in ("head", "verdict")}
        # Journal order is the only order, so the last row of each home wins.
        if row["head"] == pr["head"]:
            current[row["state"]] = record
        else:
            latest_prior[row["state"]] = record
    priors = list(latest_prior.values())
    owners = owners_of(url, pr, facts["record"])
    holds = holds_of(url, owners, facts["hold"])
    evidence = []
    for owner in owners:
        reports = [report for report in owner["done"] if report["url"].lower() == url.lower()]
        if reports and reports[-1]["head"] == pr["head"]:
            evidence.append({"head": reports[-1]["head"]})
    tickets = [row for row in facts["ticket"] if row["pr"].lower() == url.lower() and row["head"] == pr["head"]]
    recorded = list(current.values()) or [row for row in refute_merges if row["head"] == pr["head"]]
    live = [row for row in tickets if row["live"]]
    owner_status_unreadable = any(owner["verb"] == "unreadable" for owner in owners)
    ticket_status_unreadable = any(ticket.get("status_unreadable", False) for ticket in tickets)
    active = [owner for owner in owners if owner["verb"] not in FINISHED and owner["verb"] != "unreadable"]
    unreadable = ["local evidence unavailable"] if (
        facts["unreadable"] or owner_status_unreadable or ticket_status_unreadable) else []

    if pr["draft"]:
        status, reason = "draft", "the pull request is a draft"
    elif recorded:
        names = ", ".join(sorted({row["verdict"] for row in recorded}))
        kind = "" if current else " refute"
        status, reason = "reviewed-head", f"a{kind} {names} verdict is already recorded for this head; no repeat review"
    elif holds:
        status, reason = "held", "a local hold applies"
    elif unreadable:
        status, reason = "unknown", "unreadable input: " + "; ".join(unreadable)
    elif active:
        status = "owned"
        reason = "a local task is active"
    elif live:
        status = "review-dispatched"
        reason = "review dispatched for this head"
    elif tickets:
        status = "unknown"
        reason = "a local review dispatch record has neither a verdict nor a live scout"
    elif not priors:
        status, reason = "unknown", "no eligible prior verdict joins this pull request"
    elif evidence:
        status, reason = "fix-evidenced", "the head changed and its owner reported this exact head ready"
    else:
        status, reason = "verify-fix", "the head changed with no published fix evidence; verify the fix before re-review"

    return {
        "status": status,
        "reason": reason,
        "head": pr["head"],
        "current_verdicts": list(current.values()),
        "prior_verdicts": priors,
        "refute_merges": refute_merges[-1:],
        "fix_evidence": [{"present": True}] if evidence else None,
        "owners": ([{"present": True} for _ in owners] if owners else None),
        "holds": ([{"present": True}] if holds else None),
        "unreadable": unreadable,
    }


def report(lines):
    facts = {kind: [] for kind in ("observation", "pr", "record", "ticket", "verdict", "hold", "unreadable")}
    for line in lines:
        if line.strip():
            row = json.loads(line)
            facts[row["t"]].append(row)
    if len(facts["observation"]) != 1:
        raise ValueError("the facts carry no single observation")
    seen = facts["observation"][0]
    observed = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seen["at"]))
    repo = seen["repo"]
    by_number = {pr["number"]: pr for pr in facts["pr"]}
    rows = []
    for number in dict.fromkeys(seen["requested"] or by_number):
        url = f"https://{repo}/pull/{number}"
        pr = by_number.get(number)
        if pr is None:
            why = ("the forge could not be observed" if seen["error"]
                   else "not among the observed open pull requests (closed, merged, absent, or past one page)")
            row = {"status": "unknown", "reason": why, "head": None, "current_verdicts": [],
                   "prior_verdicts": [], "refute_merges": [], "fix_evidence": [], "owners": [],
                   "holds": [], "unreadable": [why]}
        else:
            row = judge(url, pr, facts)
        rows.append({"pr": url, "observed_at": observed, **row})
    return {"repository": repo, "observed_at": observed, "open_total": None if seen["error"] else seen["total"],
            "error": "forge could not be observed" if seen["error"] else None, "rows": rows, "note": NOTE}


def text(result):
    total = "unknown" if result["open_total"] is None else result["open_total"]
    out = [f"review eligibility preview: {result['repository']} observed {result['observed_at']} "
           f"({len(result['rows'])} shown, {total} open)"]
    if result["error"]:
        out.append(f"error: {result['error']}")
    for row in result["rows"]:
        unknown = "unknown" if row["unreadable"] else "none"
        verdicts = [f"{v['verdict']} {v['head']}"
                    for v in row["current_verdicts"] + row["prior_verdicts"]]
        verdicts += [f"refute {v['verdict']} {v['head']} (not eligible)"
                     for v in row["refute_merges"]]
        owners = "present" if row["owners"] else "unknown"
        holds = "present" if row["holds"] else "unknown"
        fixes = "present" if row["fix_evidence"] else "unknown"
        out += ["", f"{row['pr']}  {row['status']}",
                f"  head: {row['head'] or 'unknown'}",
                f"  observed: {row['observed_at']}",
                f"  verdicts: {'; '.join(verdicts) or unknown}",
                f"  fix evidence: {fixes if row['fix_evidence'] else unknown}",
                f"  owner: {owners}",
                f"  hold: {holds}",
                f"  reason: {row['reason']}"]
    counts = {}
    for row in result["rows"]:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    out += ["", "counts: " + (", ".join(f"{name} {counts[name]}" for name in sorted(counts)) or "none"),
            result["note"]]
    return "\n".join(out)


def main(argv):
    if argv not in ([], ["--json"]):
        print("usage: fm-review-eligibility-preview.py [--json] < facts.jsonl", file=sys.stderr)
        return 2
    try:
        result = report(sys.stdin)
    except (ValueError, KeyError, TypeError) as error:
        print(f"fm-review-eligibility-preview: unusable facts: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2) if argv else text(result))
    return 1 if result["error"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
