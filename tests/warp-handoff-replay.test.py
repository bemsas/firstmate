"""Offline replay of four handoff failures through the current owner entry points.

Each case drives real bin/ scripts against a synthetic home. Only the forge, the
SSH transport and the receiving endpoint are faked, and each fake logs what
reached it. Identities, repositories and commits are invented for the fixture.
Run through tests/warp-handoff-replay.test.sh.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
REPO_NAME = "acme/widget"
PR_URL = f"https://github.com/{REPO_NAME}/pull/8"
SHIP = "replay-ship"
BUILDER = {"generation": "s100.200.300", "harness": "claude", "model": "claude-sonnet-4-6"}
RESUMED = {"generation": "s101.200.301", "harness": "claude", "model": "claude-opus-4-6"}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def executable(path, text):
    path.write_text(textwrap.dedent(text).lstrip())
    path.chmod(0o755)


class Fixture(unittest.TestCase):
    """A disposable home whose environment carries nothing from the caller's fleet."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="warp-handoff-replay.")
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(scratch.name).resolve()
        self.home = self.tmp / "home"
        self.state = self.home / "state"
        self.data = self.home / "data"
        self.config = self.home / "config"
        self.fake = self.tmp / "fakebin"
        for path in (self.state, self.data, self.config, self.home / "projects", self.fake, self.tmp / "user"):
            path.mkdir(parents=True)
        self.env = {
            name: value for name, value in os.environ.items()
            if not name.startswith(("FM_", "GIT_", "GH_", "GITHUB_"))
            and name != "NO_MISTAKES_GATE"
        }
        self.env.update(
            HOME=str(self.tmp / "user"), PATH=f"{self.fake}{os.pathsep}{os.environ['PATH']}",
            FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.state),
            FM_DATA_OVERRIDE=str(self.data), FM_CONFIG_OVERRIDE=str(self.config),
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Fixture Author", GIT_AUTHOR_EMAIL="author@example.invalid",
            GIT_COMMITTER_NAME="Fixture Author", GIT_COMMITTER_EMAIL="author@example.invalid",
        )
        # Nothing here may reach a real forge, host or runtime.
        for tool in ("gh", "gh-axi", "ssh", "tmux", "herdr", "treehouse", "no-mistakes"):
            executable(self.fake / tool, """
                #!/usr/bin/env bash
                echo "unexpected external call: ${0##*/} $*" >&2
                exit 97
            """)

    def run_cmd(self, *argv, cwd=None, **env):
        return subprocess.run(
            [str(part) for part in argv], cwd=cwd or self.tmp, env={**self.env, **env},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=120,
        )

    def ok(self, *argv, **options):
        result = self.run_cmd(*argv, **options)
        self.assertEqual(0, result.returncode, f"{argv}\n{result.stdout}{result.stderr}")
        return result.stdout

    def refused(self, reason, *argv, **options):
        result = self.run_cmd(*argv, **options)
        self.assertNotEqual(0, result.returncode, f"unexpected success: {argv}\n{result.stdout}")
        self.assertIn(reason, result.stdout + result.stderr, f"wrong refusal for {argv}")

    def meta(self, task, **fields):
        (self.state / f"{task}.meta").write_text("".join(f"{k}={v}\n" for k, v in fields.items()))

    def meta_values(self, task, key):
        lines = (self.state / f"{task}.meta").read_text().splitlines()
        return [line.split("=", 1)[1] for line in lines if line.startswith(f"{key}=")]

    def lines(self, path):
        return path.read_text().splitlines() if path.exists() else []


class AcceptanceFixture(Fixture):
    """A protected ship, its synthetic forge and independent native review scouts."""

    def setUp(self):
        super().setUp()
        self.repo = self.home / "projects" / "widget"
        self.origin = self.tmp / "origin.git"
        self.forge = self.tmp / "forge.json"
        self.forge_log = self.tmp / "forge.log"
        self.real_git = shutil.which("git")
        stub = self.tmp / "root" / "bin"
        stub.mkdir(parents=True)
        executable(stub / "fm-guard.sh", "#!/usr/bin/env bash\nexit 0\n")
        self.env["FM_ROOT_OVERRIDE"] = str(stub.parent)

        self.ok("git", "init", "-q", "--bare", self.origin)
        self.ok("git", "init", "-q", "-b", "dev", self.repo)
        (self.repo / "app.py").write_text("value = 1\n")
        self.git("add", "app.py")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", f"fm/{SHIP}")

        # The supervisor's pinned fetch is answered by the local bare repository.
        executable(self.fake / "git", f"""
            #!{sys.executable}
            import os, sys
            args = sys.argv[1:]
            remote = "https://github.com/{REPO_NAME}.git"
            if remote in args:
                args[args.index(remote)] = {str(self.origin)!r}
            os.execv({self.real_git!r}, ["git", *args])
        """)
        executable(self.fake / "gh-axi", f"""
            #!{sys.executable}
            import base64, json, sys
            from pathlib import Path
            forge = json.loads(Path({str(self.forge)!r}).read_text())
            path = sys.argv[2] if sys.argv[1:2] == ["api"] else ""
            with open({str(self.forge_log)!r}, "a") as log:
                log.write(" ".join(sys.argv[1:3]) + "\\n")
            if path == "/repos/{REPO_NAME}/pulls/8":
                facts = ["{PR_URL}", "{REPO_NAME}", "dev", "{REPO_NAME}", "fm/{SHIP}",
                         forge["head"], "open", False]
            elif path == "/repos/{REPO_NAME}/branches/dev":
                facts = ["dev", forge["base"]]
            else:
                sys.exit(98)
            body = base64.b64encode(json.dumps(facts).encode()).decode()
            print("api_response:\\n  body: " + body + "\\n  truncated: false")
        """)

        policies = self.config / "done-acceptance"
        policies.mkdir(mode=0o755)
        self.policy = policies / f"{SHIP}.json"
        self.policy.write_text(json.dumps({
            "repo": REPO_NAME, "base_branch": "dev", "base": self.base, "kind": "feature",
            "allow": ["app.py"], "tests": [], "criteria": "The value is two.",
        }))
        self.policy.chmod(0o600)
        (self.data / "projects.md").write_text("- widget [direct-PR] - fixture (added 2026-01-01)\n")
        (self.state / ".last-watcher-beat").touch()
        self.ship_meta([BUILDER])
        self.status = self.state / f"{SHIP}.status"
        self.journal = self.state / "review-verdicts.jsonl"
        self.receipt = self.state / f"{SHIP}.accepted.json"

    def git(self, *args):
        return self.ok(self.real_git, "-C", self.repo, *args).strip()

    def ship_meta(self, history):
        current = history[-1]
        self.meta(
            SHIP, window=f"firstmate:fm-{SHIP}", endpoint_task_id=SHIP, kind="ship",
            mode="direct-PR", project=self.repo, worktree=self.repo, branch=f"fm/{SHIP}",
            base_branch="dev", spawn_gen=current["generation"], harness=current["harness"],
            model=current["model"], yolo="off",
            builder_history=",".join(":".join(builder[k] for k in ("generation", "harness", "model"))
                                     for builder in history),
        )

    def publish_head(self, value):
        (self.repo / "app.py").write_text(f"value = {value}\n")
        self.git("commit", "-qam", f"value {value}")
        head = self.git("rev-parse", "HEAD")
        self.git("push", "-q", str(self.origin), f"{head}:refs/fixtures/{head}")
        self.forge.write_text(json.dumps({"head": head, "base": self.base}))
        return head

    def ready(self, head, at):
        with self.status.open("a") as status:
            status.write(f"done [at={at}]: PR {PR_URL} head {head}\n")

    def done_check(self, action, *args):
        return (BIN / "fm-done-check.sh", action, SHIP, PR_URL, *args)

    def review_scout(self, scout, head):
        """Prepare a refute brief, then write what a native merge review leaves behind."""
        (self.data / scout).mkdir()
        self.ok(*self.done_check("review-brief", scout))
        self.meta(
            scout, kind="scout", spawn_gen=f"s200.300.{len(scout)}", project=self.repo,
            harness="codex", model="gpt-5.6-sol",
            refute_context=sha256(self.state / f"{scout}.refute.json"),
        )
        verdict = f"Refute {self.base} {head} merge"
        (self.data / scout / "report.md").write_text(f"{verdict}\n\nChecked app.py. No blocker.\n")
        (self.state / f"{scout}.status").write_text(f"done [at=500]: {verdict}\n")

    def record(self, scout, head):
        return (BIN / "fm-review-verdict.sh", "refute", SHIP, scout, head)

    def journal_actors(self):
        return [
            (row["reviewer"], row["head"], row["verdict"], row["refute"]["model"],
             row["refute"]["candidate"]["generation"])
            for row in map(json.loads, self.lines(self.journal))
        ]

    def accepted_candidate(self):
        candidate = json.loads(self.receipt.read_text())["candidate"]
        return candidate["generation"], candidate["head"], candidate["builders"]

    def assert_not_registered(self):
        self.assertEqual([], self.meta_values(SHIP, "pr"))
        self.assertEqual([], self.meta_values(SHIP, "pr_head"))
        self.assertFalse((self.state / f"{SHIP}.check.sh").exists(), "a refused candidate armed a PR poll")


class SupersededHeadOnResume(AcceptanceFixture):
    def test_resumed_owner_cannot_carry_an_old_head_forward(self):
        old = self.publish_head(2)
        self.ready(old, 100)
        self.review_scout("first-review", old)
        self.ok(*self.record("first-review", old))
        self.ok(*self.done_check("accept"))
        self.assertEqual((BUILDER["generation"], old, [BUILDER]), self.accepted_candidate())
        receipt, journal = self.receipt.read_bytes(), self.journal.read_bytes()

        # The head moves, the task is relaunched, and the new owner repeats the old head.
        new = self.publish_head(3)
        self.ship_meta([BUILDER, RESUMED])
        self.ready(old, 200)

        self.refused("accepted evidence no longer matches", *self.done_check("passing", old))
        self.refused("live GitHub head differs", *self.done_check("accept"))
        self.refused("live GitHub head differs", *self.done_check("review-brief", "stale-review"))
        self.refused("review did not sign off", *self.record("first-review", old))
        self.refused("accepted evidence no longer matches", BIN / "fm-pr-check.sh", SHIP, PR_URL)
        self.assertEqual(receipt, self.receipt.read_bytes(), "a refused replay rewrote the receipt")
        self.assertEqual(journal, self.journal.read_bytes(), "a refused replay appended a review")
        self.assert_not_registered()

        # Reporting the current head is still only a candidate until it is reviewed.
        self.ready(new, 300)
        self.refused("missing passing fresh-context review", *self.done_check("accept"))
        self.assertEqual(receipt, self.receipt.read_bytes())
        self.review_scout("second-review", new)
        self.ok(*self.record("second-review", new))
        self.assertEqual(f"{new}\n", self.ok(*self.done_check("accept")))

        self.assertEqual([
            ("first-review", old, "merge", "gpt-5.6-sol", BUILDER["generation"]),
            ("second-review", new, "merge", "gpt-5.6-sol", RESUMED["generation"]),
        ], self.journal_actors())
        self.assertEqual((RESUMED["generation"], new, [BUILDER, RESUMED]), self.accepted_candidate())
        self.assertEqual(
            [f"done [at={at}]: PR {PR_URL} head {head}" for at, head in ((100, old), (200, old), (300, new))],
            self.lines(self.status),
        )


class ReadyWithoutDurableAcceptance(AcceptanceFixture):
    def merge_refused(self, reason):
        self.refused(reason, BIN / "fm-pr-merge.sh", SHIP, PR_URL)
        self.assert_not_registered()

    def test_ready_wording_never_stands_in_for_the_acceptance_record(self):
        (self.home / ".tasks.toml").write_text(
            'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n'
        )
        (self.data / "backlog.md").write_text(
            f"## In flight\n\n- [ ] {SHIP} - synthetic ship (repo: widget)\n\n## Queued\n\n## Done\n"
        )
        head = self.publish_head(2)
        self.ready(head, 100)
        (self.data / SHIP).mkdir()
        (self.data / SHIP / "report.md").write_text("Tests passed. The independent reviewer says merge.\n")

        # A convincing report plus an ordinary verdict row is not a native review.
        self.ok(BIN / "fm-review-verdict.sh", PR_URL, head, "merge", "ordinary-reviewer")
        self.refused("missing passing fresh-context review", *self.done_check("accept"))
        self.merge_refused("accepted.json")

        # A native report on disk counts only after the supervisor records it.
        self.review_scout("native-review", head)
        self.refused("missing passing fresh-context review", *self.done_check("accept"))
        self.merge_refused("accepted.json")

        # A recorded review still needs the separate acceptance step.
        self.ok(*self.record("native-review", head))
        self.assertFalse(self.receipt.exists(), "recording a review accepted the candidate")
        self.refused("accepted.json", *self.done_check("passing", head))
        self.merge_refused("accepted.json")

        self.ok(*self.done_check("accept"))
        self.ok(*self.done_check("passing", head))
        durable = json.loads(self.receipt.read_text())
        self.assertEqual([["M", "app.py"]], durable["checks"]["paths"])

        # A receipt naming the right candidate and review, with its evidence missing.
        hollow = {**durable, "checks": {"paths": [], "regression": None}}
        self.receipt.write_text(json.dumps(hollow))
        self.refused("accepted check evidence is incomplete", *self.done_check("passing", head))
        self.merge_refused("accepted check evidence is incomplete")

        # The right bytes in a record others can read are not a supervisor record.
        self.receipt.write_text(json.dumps(durable))
        self.receipt.chmod(0o644)
        self.refused("not a suitable owned record", *self.done_check("passing", head))
        self.merge_refused("not a suitable owned record")

        self.receipt.chmod(0o600)
        self.ok(*self.done_check("passing", head))
        self.assertEqual(
            [("ordinary-reviewer", None), ("native-review", "gpt-5.6-sol")],
            [(row["reviewer"], row.get("refute", {}).get("model"))
             for row in map(json.loads, self.lines(self.journal))],
        )
        self.assertEqual([f"done [at=100]: PR {PR_URL} head {head}"], self.lines(self.status))
        self.assertEqual(["yolo=off"], [f"yolo={v}" for v in self.meta_values(SHIP, "yolo")])


class RepeatedReadyWhileHeld(Fixture):
    def captain(self, *args):
        return self.ok(BIN / "fm-captain-hold.sh", *args)

    def test_repeated_ready_notices_leave_the_held_decision_in_place(self):
        task, head = "held-ship", "1" * 40
        url = "https://github.com/sample/sample/pull/32"
        gh_log = self.tmp / "gh.log"
        (self.home / ".tasks.toml").write_text(
            'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n'
            'archive = "data/done-archive.md"\ndone_keep = 10\n'
        )
        backlog = self.data / "backlog.md"
        backlog.write_text("## In flight\n\n## Queued\n\n## Done\n")
        # A forge that would merge, so only the hold can stop the merge entry point.
        check = json.dumps({
            "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
            "headRefOid": head, "baseRefName": "main",
            "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "status": "COMPLETED",
                                   "conclusion": "SUCCESS"}],
        })
        executable(self.fake / "gh", f"""
            #!{sys.executable}
            import sys
            args = " ".join(sys.argv[1:])
            with open({str(gh_log)!r}, "a") as log:
                log.write(args + "\\n")
            if args.startswith("pr view"):
                if "statusCheckRollup" in args:
                    print({check!r})
                elif "headRefOid" in args:
                    print({head!r})
            elif args.startswith("pr merge"):
                print("merged:\\n  status: ok")
            elif args.startswith("api graphql"):
                print("state=MERGED\\nmerged=true\\nqueued=false\\nbase=main")
            elif args.startswith("api --paginate"):
                if "merge_queue" not in args:
                    print("[]")
            elif args.startswith("api repos/"):
                print('{{"name":"main","protected":false}}')
        """)
        executable(self.fake / "gh-axi", """
            #!/usr/bin/env bash
            [ "${1:-} ${2:-}" != "pr view" ] || printf 'pull_request:\\n  number: %s\\n  state: merged\\n' "$3"
        """)
        repo = self.home / "projects" / "sample"
        worktree = self.home / "projects" / task
        self.ok("git", "init", "-q", "-b", "main", repo)
        self.ok("git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "base")
        self.ok("git", "-C", repo, "worktree", "add", "-q", "-b", f"fm/{task}", worktree)
        self.ok("tasks-axi", "add", task, "Ship the held change", "--kind", "ship", "--repo", "sample",
                "--start", cwd=self.home)
        self.meta(task, window=f"firstmate:fm-{task}", endpoint_task_id=task, worktree=worktree,
                  project=repo, harness="codex", kind="ship", mode="no-mistakes", spawn_gen=f"fixture-{task}")
        self.captain("hold", task, "--reason", "captain merge approval pending")
        held = backlog.read_bytes()
        identity = self.captain("open", task, "--identity")
        status = self.state / f"{task}.status"
        merge = (BIN / "fm-pr-merge.sh", task, url)

        notices = [f"done [at={at}]: PR {url} checks green" for at in (100, 200, 300)]
        for notice in notices:
            with status.open("a") as log:
                log.write(notice + "\n")
            info = status.stat()
            # The same status identity the watcher captures before detaching intake.
            ident = self.ok("bash", "-c", '. "$1"; _fm_open_decisions_file_ident "$2"', "replay",
                            BIN / "fm-classify-lib.sh", status).strip()
            for _ in range(2):  # The same surfaced snapshot is also delivered twice.
                self.ok(BIN / "fm-worker-done.sh", task, info.st_size, ident)
                self.assertEqual([url], self.meta_values(task, "pr"), "intake recorded the PR twice")
            self.refused(f"{task} is still held for the captain", *merge)
            self.assertEqual(identity, self.captain("open", task, "--identity"))
            self.assertEqual(held, backlog.read_bytes(), "a ready notice changed the held decision")
            self.assertEqual([url], self.meta_values(task, "pr"))

        self.assertEqual(notices, self.lines(status))
        self.assertFalse([call for call in self.lines(gh_log) if call.startswith("pr merge")],
                         "a held task reached the forge merge")

        # Only the recorded captain answer frees it, after every notice above.
        words = self.tmp / "answer.txt"
        words.write_text("Merge the synthetic change.\n")
        self.captain("answer", task, "--release", "--decision-file", words)
        shown = self.ok("tasks-axi", "show", task, "--full", cwd=self.home)
        self.assertIn("Resolution mode: released", shown)
        self.assertIn("Merge the synthetic change.", shown)
        self.assertNotIn("hold_kind: captain", shown)
        self.ok(*merge)
        self.assertEqual(1, len([c for c in self.lines(gh_log) if c.startswith("pr merge 32 ")]))


class InterruptedAfterFirstCommit(Fixture):
    """A remote handoff killed once its first durable commit, the outbox, exists.

    The torn move is covered for a retry that names the key. The generic
    --resume-pending path after a torn move is not covered: it fails on the
    current owner.
    """

    def setUp(self):
        super().setUp()
        self.remote = self.tmp / "remote"
        for path in (self.remote / "data", self.remote / "state", self.remote / "bin"):
            path.mkdir(parents=True)
        (self.remote / "AGENTS.md").write_text("fixture\n")
        (self.remote / ".fm-secondmate-home").write_text("replay-mate\n")
        (self.data / "secondmates.md").write_text(
            f"- replay-mate - synthetic delivery (host: replay-host; root: {ROOT}; home: {self.remote}; "
            "scope: fixtures; projects: sample; added 2026-01-01)\n"
        )
        self.meta("replay-mate", window="fm-remote:w1:p1", endpoint_task_id="replay-mate",
                  harness="claude", kind="secondmate", mode="secondmate", remote_host="replay-host",
                  remote_root=ROOT, remote_backend="herdr", remote_herdr_session="fm-remote",
                  remote_target="fm-remote:w1:p1")
        self.main = self.data / "backlog.md"
        self.main.write_text(
            "## In flight\n\n## Queued\n"
            "- [ ] cut-item - synthetic routed work (repo: sample)\n"
            "- [ ] kept-item - stays with the sender (repo: sample)\n\n## Done\n"
        )
        self.outbox = self.data / "handoff" / "replay-mate.outbox.md"
        self.destination = self.remote / "data" / "backlog.md"
        self.events = self.tmp / "events.log"
        self.env["FM_SSH_BIN"] = str(self.fake / "replay-ssh")
        # The transport runs the real remote scripts locally. The endpoint is only logged.
        # Around the receiver commit it records what each durable file holds.
        executable(self.fake / "replay-ssh", f"""
            #!{sys.executable}
            import base64, json, os, subprocess, sys
            from pathlib import Path
            args = sys.argv[sys.argv.index("--") + 1:]
            assert args[:2] == ["replay-host", "fm-remote-entrypoint.sh"], args
            home = base64.b64decode(args[4]).decode()
            command = base64.b64decode(args[5]).decode().split("\\0")[:-1]
            event = {{"host": args[0], "home": home, "command": list(command)}}

            def record():
                with open({str(self.events)!r}, "a") as log:
                    log.write(json.dumps(event) + "\\n")

            def holdings():
                paths = {{"sender": {str(self.main)!r}, "outbox": {str(self.outbox)!r},
                         "receiver": {str(self.destination)!r}}}
                return {{name: sum(line.startswith("- [ ] cut-item ")
                                  for line in (Path(path).read_text().splitlines() if Path(path).exists() else []))
                        for name, path in paths.items()}}

            if command[0] == "fm-remote-secondmate-control.sh":
                record()
                sys.exit(0)
            assert command[0] in ("fm-remote-file.sh", "fm-backlog-receive.sh"), command
            env = {{k: v for k, v in os.environ.items() if not k.startswith("FM_")}}
            env.update(FM_HOME=home, FM_ROOT_OVERRIDE={str(ROOT)!r})
            command[0] = os.path.join({str(BIN)!r}, command[0])
            commit = event["command"][0] == "fm-backlog-receive.sh"
            if commit:
                event["before"] = holdings()
            status = subprocess.call(command, env=env)
            if commit:
                event["after"] = holdings()
                event["status"] = status
            record()
            sys.exit(status)
        """)

    def kill_after_staging(self, torn):
        """Run the handoff and SIGKILL it as soon as the outbox move has persisted."""
        real = shutil.which("tasks-axi")
        before = self.main.read_bytes()
        crash = self.tmp / "crash"
        crash.mkdir()
        executable(crash / "tasks-axi", f"""
            #!{sys.executable}
            import os, signal, subprocess, sys
            from pathlib import Path
            result = subprocess.call([{real!r}, *sys.argv[1:]])
            if sys.argv[1:2] == ["mv"] and "--to" in sys.argv and result == 0:
                if {torn!r}:
                    # The target persisted and the source write did not.
                    Path({str(self.main)!r}).write_bytes({before!r})
                # The mover may run in a subshell: walk up to the process the runner started.
                def parent(pid):
                    return int(subprocess.check_output(["ps", "-o", "ppid=", "-p", str(pid)]))
                script = os.getppid()
                while parent(script) != int(os.environ["REPLAY_RUNNER"]):
                    script = parent(script)
                os.kill(script, signal.SIGKILL)
            sys.exit(result)
        """)
        interrupted = self.run_cmd(
            BIN / "fm-backlog-handoff.sh", "replay-mate", "cut-item",
            PATH=f"{crash}{os.pathsep}{self.env['PATH']}", REPLAY_RUNNER=str(os.getpid()),
        )
        self.assertEqual(-signal.SIGKILL, interrupted.returncode, interrupted.stderr)

    def count(self, path, key):
        return sum(line.startswith(f"- [ ] {key} ") for line in self.lines(path))

    def holdings(self):
        return {name: self.count(path, "cut-item")
                for name, path in (("sender", self.main), ("outbox", self.outbox), ("receiver", self.destination))}

    def assert_delivered_once(self):
        self.assertEqual({"sender": 0, "outbox": 0, "receiver": 1}, self.holdings())
        self.assertFalse(self.outbox.exists(), "a confirmed receipt kept its outbox")
        self.assertFalse((self.state / ".backlog-handoff-replay-mate.wake-pending").exists())
        self.assertEqual((1, 0), (self.count(self.main, "kept-item"), self.count(self.destination, "kept-item")))
        self.assert_receiving_identity()
        self.assert_sender_clean_at_receiver_commit()

    def transport(self):
        return [json.loads(line) for line in self.lines(self.events)]

    def assert_receiving_identity(self):
        """Every transport call names the one registered host, home and receiving task."""
        put, receive, wake = events = self.transport()
        self.assertEqual([("replay-host", str(self.remote))] * 3, [(e["host"], e["home"]) for e in events])
        outbox = "state/handoff/replay-mate.outbox.md"
        self.assertEqual(["fm-remote-file.sh", "put", outbox], put["command"][:3])
        self.assertEqual(["fm-backlog-receive.sh", outbox], receive["command"][:2])
        self.assertEqual(put["command"][4:], receive["command"][2:], "the receiver committed other bytes")
        self.assertEqual(["fm-remote-secondmate-control.sh", "send-stdin", "replay-mate"], wake["command"])
        self.assertEqual("replay-mate\n", (self.remote / ".fm-secondmate-home").read_text())

    def assert_sender_clean_at_receiver_commit(self):
        """The sender has let go before the receiver commits, and the outbox outlives that commit."""
        receive = self.transport()[1]
        self.assertEqual(0, receive["status"])
        self.assertEqual({"sender": 0, "outbox": 1, "receiver": 0}, receive["before"])
        self.assertEqual({"sender": 0, "outbox": 1, "receiver": 1}, receive["after"])

    def test_kill_after_the_staged_move_resumes_to_exactly_one_delivery(self):
        self.kill_after_staging(torn=False)
        self.assertEqual({"sender": 0, "outbox": 1, "receiver": 0}, self.holdings())
        self.assertEqual([], self.lines(self.events), "work left this home before the interruption")

        self.ok(BIN / "fm-backlog-handoff.sh", "--resume-pending")
        self.assert_delivered_once()
        self.ok(BIN / "fm-backlog-handoff.sh", "--resume-pending")
        self.assert_delivered_once()

    def test_torn_staged_move_removes_the_sender_copy_before_delivery(self):
        self.kill_after_staging(torn=True)
        self.assertEqual({"sender": 1, "outbox": 1, "receiver": 0}, self.holdings())
        self.assertEqual([], self.lines(self.events))

        self.ok(BIN / "fm-backlog-handoff.sh", "replay-mate", "cut-item")
        self.assert_delivered_once()


if __name__ == "__main__":
    missing = [tool for tool in ("bash", "git", "jq", "tasks-axi") if not shutil.which(tool)]
    if missing:
        sys.exit(f"warp-handoff-replay: required tools missing: {', '.join(missing)}")
    unittest.main(verbosity=2)
