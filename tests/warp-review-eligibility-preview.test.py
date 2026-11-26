#!/usr/bin/env python3
"""Synthetic fixture for bin/fm-review-eligibility-preview.sh.

Every run builds throwaway homes and a twenty-pull-request forge answer served by
a fake gh-axi that applies the preview's own jq program. No network is used.

Held tasks are read through the real bin/fm-tasks-axi.sh. Behind it, a direct run
uses the synthetic tasks-axi below, so the file runs without any package install;
FM_PREVIEW_TASKS_AXI=real runs the same assertions against the installed
tasks-axi and bin/fm-captain-hold.sh instead, which keeps the synthetic one
honest. A missing prerequisite is an error, never a skip.
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / "bin" / "fm-review-eligibility-preview.sh"
VERDICT = ROOT / "bin" / "fm-review-verdict.sh"
TASKS = ROOT / "bin" / "fm-tasks-axi.sh"
HOLD = ROOT / "bin" / "fm-captain-hold.sh"
REPO = "acme/widget"
REAL_TASKS = os.environ.get("FM_PREVIEW_TASKS_AXI") == "real"

FAKE_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FM_FAKE_GH_LOG"
[ "${FM_FAKE_GH_RC:-0}" = 0 ] || exit "$FM_FAKE_GH_RC"
expr=
while [ "$#" -gt 0 ]; do
  [ "$1" != --jq ] || { expr=$2; shift; }
  shift
done
body=$(jq -r "$expr" "$FM_FAKE_GH_JSON") || exit 1
printf 'api_response:\\n  body: "%s"\\n  truncated: false\\n' "$body"
"""

# The two reads the preview makes, answered in tasks-axi's shapes from a JSON
# list stored as the home's backlog file.
FAKE_TASKS = """#!/usr/bin/env python3
import json
import os
import sys

path = os.environ["TASKS_AXI_FILE"]
tasks = []
if os.path.exists(path):
    with open(path) as stream:
        tasks = json.load(stream)
args = sys.argv[1:]
if args[:3] == ["list", "--state", "held"]:
    print(f"count: {len(tasks)}")
    if tasks:
        print(f"tasks[{len(tasks)}]{{id,state,kind,repo,title}}:")
        for task in tasks:
            print(f'  {task["id"]},queued,captain,"-",{json.dumps(task["title"])}')
elif args[:1] == ["show"] and args[2:] == ["--full"]:
    task = next(task for task in tasks if task["id"] == args[1])
    print("task:")
    for field in ("id", "title", "hold_reason", "hold_kind", "links", "body"):
        print(f"  {field}: {json.dumps(task[field])}")
else:
    sys.exit(f"synthetic tasks-axi does not answer {args}")
"""

EXPECTED = {
    101: "reviewed-head",      # fix recorded for the observed head
    102: "reviewed-head",      # merge recorded for the observed head
    103: "reviewed-head",      # only a refute merge for the observed head
    104: "draft",
    105: "held",               # hold names the pull request
    106: "held",               # hold sits on the owning task
    107: "held",               # hold requires a review of an older head
    108: "owned",              # pr= owner still working
    109: "owned",              # branch owner with no status yet
    110: "fix-evidenced",      # owner reported the observed head ready
    111: "verify-fix",         # owner reported only an older head
    112: "verify-fix",         # changed head, nobody reports it
    113: "unknown",            # no verdict joins
    114: "review-dispatched",
    115: "unknown",            # dispatch record without verdict or scout
    116: "unknown",            # homes disagree about the prior verdict
    117: "held",               # hold lives in a secondmate home
    118: "verify-fix",         # same branch name on a fork is not the owner
    119: "verify-fix",         # a newer ready report withdrew the observed head
    120: "verify-fix",         # a hold on pull/1200 is not a hold on pull/120
}


def sha(label):
    return hashlib.sha1(str(label).encode()).hexdigest()


def url(number):
    return f"https://github.com/{REPO}/pull/{number}"


class PreviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        needed = ["bash", "git", "jq", "perl", "python3"] + (["tasks-axi"] if REAL_TASKS else [])
        missing = [tool for tool in needed if not shutil.which(tool)]
        if missing:
            raise RuntimeError(f"missing test prerequisite: {', '.join(missing)}")

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name).resolve()
        self.home = self.tmp / "home"
        self.mate = self.tmp / "mate"
        for home in (self.home, self.mate):
            (home / "state").mkdir(parents=True)
            (home / "data").mkdir()
        (self.home / "data" / "secondmates.md").write_text(
            f"- mate - synthetic (home: {self.mate}; scope: synthetic; projects: widget; added 2026-01-01)\n")
        self.project = self.tmp / "widget"
        self.git("init", "-q", str(self.project))
        self.git("-C", str(self.project), "remote", "add", "origin", f"https://github.com/{REPO}.git")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh-axi").write_text(FAKE_GH)
        (bin_dir / "gh-axi").chmod(0o755)
        if not REAL_TASKS:
            (bin_dir / "tasks-axi").write_text(FAKE_TASKS)
            (bin_dir / "tasks-axi").chmod(0o755)
        self.forge = self.tmp / "forge.json"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("FM_", "TASKS_AXI_"))}
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FM_HOME=str(self.home),
                        FM_FAKE_GH_JSON=str(self.forge), FM_FAKE_GH_LOG=str(self.tmp / "gh.log"),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.pulls([self.node(number, draft=number == 104) for number in EXPECTED])

    def git(self, *args):
        subprocess.run(["git", *args], check=True, capture_output=True)

    def node(self, number, draft=False, head_repo=REPO):
        return {"number": number, "isDraft": draft, "baseRefName": "main", "headRefName": f"fm/task+{number}",
                "headRefOid": sha(number), "headRepository": {"nameWithOwner": head_repo}}

    def pulls(self, nodes, total=None):
        self.forge.write_text(json.dumps({"data": {"repository": {"pullRequests": {
            "totalCount": len(nodes) if total is None else total, "nodes": nodes}}}}))

    def verdict(self, number, head, verdict, home=None, **extra):
        row = {"pr": url(number), "head": head, "verdict": verdict, "reviewer": f"rv-{number}", **extra}
        with ((home or self.home) / "state" / "review-verdicts.jsonl").open("a") as stream:
            stream.write(json.dumps(row) + "\n")

    def record(self, task, *fields, status=None, home=None, kind="ship"):
        state = (home or self.home) / "state"
        (state / f"{task}.meta").write_text("".join(
            f"{line}\n" for line in (f"kind={kind}", "mode=no-mistakes", f"project={self.project}", *fields)))
        if status is not None:
            (state / f"{task}.status").write_text("".join(f"{line}\n" for line in status))

    def ticket(self, number, reviewer):
        (self.home / "state" / f"{reviewer}.refute.json").write_text(json.dumps(
            {"candidate": {"pr": url(number), "head": sha(number)}, "reviewer": reviewer}))

    def hold(self, task, title, review=None, home=None):
        reason = "synthetic (choice)\npending"
        if not REAL_TASKS:
            body = "Captain hold set: 2026-01-01T00:00:00Z"
            if review:
                body += f"\nCaptain hold review: {review[0]} {review[1]}"
            backlog = (home or self.home) / "data" / "backlog.md"
            tasks = json.loads(backlog.read_text()) if backlog.exists() else []
            tasks.append({"id": task, "title": title, "hold_kind": "captain", "body": body,
                          "hold_reason": "fm-hold-v1:" + base64.b64encode(reason.encode()).decode(),
                          "links": f"pr:{review[0]}" if review else "none"})
            backlog.write_text(json.dumps(tasks))
            return
        extra = ["--require-review", *review] if review else []
        env = {**self.env, "FM_HOME": str(home or self.home)}
        subprocess.run([TASKS, "add", task, title, "--kind", "captain"], env=env, check=True, capture_output=True)
        subprocess.run([HOLD, "hold", task, "--reason", reason, *extra],
                       env=env, check=True, capture_output=True)

    def ready(self, number, head):
        return f"done [at=1]: PR {url(number)} checks green head {head}"

    def seed(self):
        for number in EXPECTED:
            if number not in (101, 102, 103, 113, 116):
                self.verdict(number, sha(f"old-{number}"), "fix")
        self.verdict(101, sha(101), "fix")
        self.verdict(102, sha(102), "merge")
        self.verdict(103, sha(103), "merge", refute={"event": "x"})
        self.hold("h105", f"Decide {url(105)}")
        self.record("t106", f"pr={url(106)}", status=["done: ready"])
        self.hold("t106", "Decide the owning task")
        self.hold("h107", "Decide after review", review=(url(107), sha("old-107")))
        self.record("t108", f"pr={url(108)}", status=[
            "working [at=1]: fixing", "resolved [at=2] [key=x]: annotation"])
        self.record("t109", "branch=fm/task+109")
        self.record("t110", f"pr={url(110)}", status=[
            "working: fixing", self.ready(110, sha(110))])
        self.record("t111", "branch=fm/task+111", status=[self.ready(111, sha("old-111"))])
        self.ticket(114, "scout114")
        self.record("scout114", status=["working: reviewing"], kind="scout")
        self.ticket(115, "scout115")
        self.verdict(116, sha("a-116"), "fix")
        self.verdict(116, sha("b-116"), "merge", home=self.mate)
        self.hold("h117", f"Decide {url(117)}", home=self.mate)
        self.pulls([self.node(number, draft=number == 104,
                              head_repo="fork/widget" if number == 118 else REPO) for number in EXPECTED])
        self.record("t118", "branch=fm/task+118", status=["working: other repository"])
        self.record("t119", f"pr={url(119)}", status=[
            self.ready(119, sha(119)), self.ready(119, sha("old-119"))])
        self.hold("h120", f"Decide https://github.com/{REPO}/pull/1200")

    def run_preview(self, *args, code=0, **env):
        done = subprocess.run([PREVIEW, REPO, *args], env={**self.env, **env}, text=True,
                              capture_output=True, timeout=120)
        self.assertEqual(done.returncode, code, done.stdout + done.stderr)
        return done

    def rows(self, *args, code=0, **env):
        result = json.loads(self.run_preview("--json", *args, code=code, **env).stdout)
        return {int(row["pr"].rsplit("/", 1)[1]): row for row in result["rows"]}

    def snapshot(self):
        return {str(path.relative_to(self.tmp)): path.read_bytes() if path.is_file() else None
                for root in (self.home, self.mate, self.project) for path in sorted(root.rglob("*"))}

    def test_twenty_rows_join_every_input_and_change_nothing(self):
        self.seed()
        before = self.snapshot()
        rows = self.rows()
        self.assertEqual({number: row["status"] for number, row in rows.items()}, EXPECTED,
                         json.dumps(rows, indent=1))
        self.assertEqual(self.snapshot(), before, "the preview changed a home or the project")
        calls = (self.tmp / "gh.log").read_text().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertNotIn("mutation", calls[0])
        evidenced = rows[110]
        self.assertEqual(evidenced["head"], sha(110))
        self.assertRegex(evidenced["observed_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(evidenced["prior_verdicts"][0]["head"], sha("old-110"))
        self.assertEqual(evidenced["fix_evidence"][0]["report"], self.ready(110, sha(110)))
        self.assertEqual(evidenced["owners"][0]["id"], "t110")
        self.assertEqual(rows[105]["holds"][0]["reason"], "synthetic (choice) pending")
        self.assertEqual(rows[109]["owners"][0]["joined_by"], "branch")
        self.assertEqual(rows[118]["owners"], [])
        self.assertEqual(rows[103]["refute_merges"][0]["head"], sha(103))
        text = self.run_preview().stdout
        for part in (f"{url(110)}  fix-evidenced", f"head: {sha(110)}", f"fix {sha('old-110')} by rv-110",
                     "hold: h105 (captain)", "dispatch owner rechecks"):
            self.assertIn(part, text)

    def test_unreadable_inputs_leave_eligibility_unknown(self):
        self.seed()
        (self.mate / "state" / "review-verdicts.jsonl").write_text("not json\n")
        rows = self.rows()
        for number in (110, 111, 112):
            self.assertEqual(rows[number]["status"], "unknown")
            self.assertIn("review verdict journal", rows[number]["reason"])
        # Positive exclusions already proven stay visible.
        for number in (101, 104, 105, 108, 114):
            self.assertEqual(rows[number]["status"], EXPECTED[number])
        (self.mate / "state" / "review-verdicts.jsonl").unlink()
        (self.home / "state" / "bad.refute.json").write_text("{}")
        self.assertIn("review dispatch record", self.rows()[112]["reason"])
        (self.home / "state" / "bad.refute.json").unlink()
        (self.mate / "data" / "backlog.md").unlink()
        # A linked backlog is refused by bin/fm-tasks-axi.sh itself.
        (self.mate / "data" / "backlog.md").symlink_to(self.tmp / "nowhere")
        self.assertIn("held tasks", self.rows()[112]["reason"])

    def test_terminal_refute_scouts_are_not_live(self):
        self.seed()
        for terminal in ("done: review complete", "failed: review failed"):
            (self.home / "state" / "scout114.status").write_text(terminal + "\n")
            row = self.rows("--pr", "114")[114]
            self.assertEqual(row["status"], "unknown")
            self.assertIn("neither a recorded verdict nor a live scout", row["reason"])

    def test_unrelated_pr_prefix_does_not_poison_selected_pr(self):
        self.seed()
        self.record("t1120", f"pr={url(112)}0", status=["working: unrelated"])
        (self.home / "state" / "t1120.status").unlink()
        (self.home / "state" / "t1120.status").symlink_to(self.tmp / "missing-status")
        row = self.rows("--pr", "112")[112]
        self.assertEqual(row["status"], "verify-fix")

    def test_unreadable_owner_status_makes_disposition_unknown(self):
        self.seed()
        self.record("t111", f"pr={url(111)}", status=[self.ready(111, sha("old-111"))])
        (self.home / "state" / "t111.status").unlink()
        (self.home / "state" / "t111.status").symlink_to(self.tmp / "missing-status")
        row = self.rows("--pr", "111")[111]
        self.assertEqual(row["status"], "unknown")
        self.assertIn("status log", row["reason"])
        self.assertEqual(row["owners"][0]["last_status"], "unreadable")

    def test_selection_and_forge_failure(self):
        self.seed()
        self.assertEqual(list(self.rows("--limit", "3")), [101, 102, 103])
        rows = self.rows("--pr", "112", "--pr", "999")
        self.assertEqual({n: r["status"] for n, r in rows.items()}, {112: "verify-fix", 999: "unknown"})
        self.assertIsNone(rows[999]["head"])
        rows = self.rows("--pr", "112", code=1, FM_FAKE_GH_RC="1")
        self.assertEqual(rows[112]["status"], "unknown")
        self.assertIn("could not be observed", rows[112]["reason"])

    def test_missing_state_directory_is_refused_not_created(self):
        absent = self.tmp / "absent"
        done = self.run_preview(code=2, FM_HOME=str(absent))
        self.assertIn("does not exist", done.stderr)
        self.assertFalse(absent.exists())

    def test_verdict_history_lists_without_creating_state(self):
        state = self.tmp / "fresh" / "state"
        env = {**self.env, "FM_STATE_OVERRIDE": str(state)}

        def history():
            return subprocess.run([VERDICT, "history"], env=env, text=True, capture_output=True)

        self.assertEqual((history().returncode, history().stdout), (0, ""))
        self.assertFalse(state.exists())
        self.verdict(1, sha(1), "merge", refute={"event": "x"})
        self.verdict(1, sha(1), "fix")
        env["FM_STATE_OVERRIDE"] = str(self.home / "state")
        self.assertEqual([json.loads(line)["eligible"] for line in history().stdout.splitlines()], [False, True])

    def test_verdict_receipts_reject_noncanonical_pr_and_incomplete_head(self):
        state = self.home / "state"
        journal = state / "review-verdicts.jsonl"
        valid = {"pr": url(1), "head": sha(1), "verdict": "merge", "reviewer": "reviewer"}
        for invalid in ({**valid, "pr": "https://github.com/example/widget/pull/01"},
                        {**valid, "head": "invalid"}):
            journal.write_text(json.dumps(invalid) + "\n")
            history = subprocess.run([VERDICT, "history"], env=self.env, text=True, capture_output=True)
            self.assertNotEqual(history.returncode, 0)
            passing = subprocess.run([VERDICT, "passing", url(1), sha(1)], env=self.env,
                                      text=True, capture_output=True)
            self.assertNotEqual(passing.returncode, 0)


if __name__ == "__main__":
    unittest.main()
