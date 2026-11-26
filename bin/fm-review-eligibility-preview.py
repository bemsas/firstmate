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
                     has neither a verdict nor a live scout, no eligible prior
                     verdict joins, or homes disagree about the prior one
  fix-evidenced      the head changed and an owner's latest ready report for this
                     pull request names the observed head
  verify-fix         the head changed with no such report

A changed head alone never counts as a fix. No disposition authorizes a review.
"""

import json
import re
import sys
import time

NOTE = ("Advice only, bound to the observed head and time. The dispatch owner rechecks the live "
        "head, holds, owners, capacity, proof and model before any review starts.")
FINISHED = ("done", "failed")


def clean(text, limit=300):
    text = " ".join("".join(c if c.isprintable() else " " for c in str(text)).split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


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
            found.append({"id": hold["id"], "state": hold["state"],
                          "kind": shown(hold["show"], "hold_kind"),
                          "reason": clean(shown(hold["show"], "hold_reason"))})
    return found


def judge(url, pr, facts):
    verdicts = [row for row in facts["verdict"] if row["pr"].lower() == url.lower()]
    current = {}
    latest_prior = {}
    refute_merges = []
    for row in verdicts:
        if not row["eligible"]:
            refute_merges.append({key: row[key] for key in ("head", "verdict", "reviewer", "state")})
            continue
        record = {key: row[key] for key in ("head", "verdict", "reviewer", "state")}
        # Journal order is the only order, so the last row of each home wins.
        if row["head"] == pr["head"]:
            current[row["state"]] = record
        else:
            latest_prior[row["state"]] = record
    priors = list(latest_prior.values())
    prior_conflict = len({(row["head"], row["verdict"]) for row in priors}) > 1
    owners = owners_of(url, pr, facts["record"])
    holds = holds_of(url, owners, facts["hold"])
    evidence = []
    for owner in owners:
        reports = [report for report in owner["done"] if report["url"].lower() == url.lower()]
        if reports and reports[-1]["head"] == pr["head"]:
            evidence.append({"owner": owner["id"], "state": owner["state"], "report": clean(reports[-1]["line"])})
    tickets = [row for row in facts["ticket"] if row["pr"].lower() == url.lower() and row["head"] == pr["head"]]
    recorded = list(current.values()) or [row for row in refute_merges if row["head"] == pr["head"]]
    live = [row for row in tickets if row["live"]]
    active = [owner for owner in owners if owner["verb"] not in FINISHED]
    unreadable = [f"{row['input']}: {clean(row['detail'])}" for row in facts["unreadable"]]

    if pr["draft"]:
        status, reason = "draft", "the pull request is a draft"
    elif recorded:
        names = ", ".join(sorted({row["verdict"] for row in recorded}))
        kind = "" if current else " refute"
        status, reason = "reviewed-head", f"a{kind} {names} verdict is already recorded for this head; no repeat review"
    elif holds:
        status, reason = "held", "held by " + ", ".join(hold["id"] for hold in holds)
    elif active:
        status = "owned"
        reason = "active owner " + ", ".join(f"{o['id']} ({o['verb'] or 'no status yet'})" for o in active)
    elif live:
        status = "review-dispatched"
        reason = "review dispatched for this head to " + ", ".join(row["reviewer"] for row in live)
    elif unreadable:
        status, reason = "unknown", "unreadable input: " + "; ".join(unreadable)
    elif tickets:
        status = "unknown"
        reason = ("a review dispatch record for this head has neither a recorded verdict nor a live scout: "
                  + ", ".join(row["reviewer"] for row in tickets))
    elif not priors:
        status, reason = "unknown", "no eligible prior verdict joins this pull request"
    elif prior_conflict:
        status, reason = "unknown", "local homes record different prior verdicts and no order between them"
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
        "fix_evidence": evidence,
        "owners": [{"id": o["id"], "state": o["state"], "kind": o["kind"], "last_status": o["verb"],
                    "joined_by": o["joined_by"]} for o in owners],
        "holds": holds,
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
            why = (f"the forge could not be observed: {seen['error']}" if seen["error"]
                   else "not among the observed open pull requests (closed, merged, absent, or past one page)")
            row = {"status": "unknown", "reason": why, "head": None, "current_verdicts": [],
                   "prior_verdicts": [], "refute_merges": [], "fix_evidence": [], "owners": [],
                   "holds": [], "unreadable": [why]}
        else:
            row = judge(url, pr, facts)
        rows.append({"pr": url, "observed_at": observed, **row})
    return {"repository": repo, "observed_at": observed, "open_total": None if seen["error"] else seen["total"],
            "error": seen["error"] or None, "rows": rows, "note": NOTE}


def text(result):
    total = "unknown" if result["open_total"] is None else result["open_total"]
    out = [f"review eligibility preview: {result['repository']} observed {result['observed_at']} "
           f"({len(result['rows'])} shown, {total} open)"]
    if result["error"]:
        out.append(f"error: {result['error']}")
    for row in result["rows"]:
        unknown = "unknown" if row["unreadable"] else "none"
        verdicts = [f"{v['verdict']} {v['head']} by {clean(v['reviewer'] or 'unnamed')}"
                    for v in row["current_verdicts"] + row["prior_verdicts"]]
        verdicts += [f"refute {v['verdict']} {v['head']} by {clean(v['reviewer'])} (not eligible)"
                     for v in row["refute_merges"]]
        owners = [f"{o['id']} ({o['last_status'] or 'no status yet'}, by {o['joined_by']}) in {o['state']}"
                  for o in row["owners"]]
        holds = [f"{h['id']} ({h['kind'] or 'unknown kind'}) in {h['state']}: {h['reason']}" for h in row["holds"]]
        fixes = [f"{e['owner']}: {e['report']}" for e in row["fix_evidence"]]
        out += ["", f"{row['pr']}  {row['status']}",
                f"  head: {row['head'] or 'unknown'}",
                f"  observed: {row['observed_at']}",
                f"  verdicts: {'; '.join(verdicts) or unknown}",
                f"  fix evidence: {'; '.join(fixes) or unknown}",
                f"  owner: {'; '.join(owners) or 'unknown'}",
                f"  hold: {'; '.join(holds) or unknown}",
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
