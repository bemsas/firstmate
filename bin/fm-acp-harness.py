#!/usr/bin/env python3
"""fm-acp-harness.py - firstmate's own Agent Client Protocol (ACP) harness.

PILOT: scout tasks only, ACP v1 only, off by default (`fm-spawn.sh --backend acp`).
It owns one agent child process per task instead of a terminal pane, so a
finished scout leaves no pane, shell, or process behind. Python standard
library only. bin/backends/acp.sh and docs/acp-backend.md own the integration
and the operator view; this header owns the command surface.

  fm-acp-harness.py spawn  <id> <project> --brief FILE [--model M] [--worktree PATH]
                           [--agent opencode] [--agent-cmd 'CMD ...'] [--max-cost USD]
                           [--read-root DIR]... [--allow-fetch] [--no-report-gate]
        Lease a worktree (treehouse get --lease, or adopt --worktree), write
        state/<id>.meta, start a detached harness for the task, wait until the
        brief was delivered, and print one `ready` line.
  fm-acp-harness.py lease  <id> <project>      print a leased worktree path
  fm-acp-harness.py state  <id> [--json]       running|idle|blocked|starting|exited|dead|missing
  fm-acp-harness.py tail   <id> [-n N] [-f]    readable view of events.jsonl
  fm-acp-harness.py steer  <id> TEXT           prompt the agent (queued while a turn runs)
  fm-acp-harness.py cancel <id>                session/cancel; pending permissions get `cancelled`
  fm-acp-harness.py permissions <id>           list queued permission requests
  fm-acp-harness.py answer <id> <n> allow|reject
  fm-acp-harness.py stop   <id>                EOF, 5 s, SIGTERM the group, SIGKILL; idempotent
  fm-acp-harness.py resume <id>                restart a dead run and session/load the saved id

Files, all under the firstmate home (FM_HOME, default: the code root):
  state/<id>.acp.json      state file: pids, sessionId, command, turn, cost
  state/<id>.events.jsonl  every frame, with oversized strings shortened
  state/<id>.acp/          cmd/ (command queue), pending/ (queued permissions), logs
  state/<id>.status        the lines fm-watch.sh already reads
  state/<id>.turn-ended    touched at every stopReason, like the harness stop hooks

Exit rule: a turn that ends with a last status line of `done` (and, for a scout,
data/<id>/report.md present) or `failed` closes the agent and the harness exits.
"""
import argparse, fcntl, json, os, queue, re, shlex, signal, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERMINAL = ("done", "failed")
HOLDING = ("blocked", "needs-decision", "paused")
AGENTS = {"opencode": ["opencode", "acp"]}
# Route every non-read tool and every outside-the-worktree path through the harness policy
# instead of the agent default, which allows everything.
AGENT_ENV = {"opencode": {"OPENCODE_PERMISSION": json.dumps(
    {"*": "ask", "read": "allow", "glob": "allow", "grep": "allow", "external_directory": "ask"})}}
RISKY = re.compile(r"\b(sudo|ssh|scp|rsync|nc|ncat|docker|kubectl|systemctl|shutdown|reboot|mkfs|dd)\b"
                   r"|git\s+(push|remote|config)\b|\bgh\s+(pr|issue|api|repo|release)\b|\bcurl\b|\bwget\b"
                   r"|\brm\s+-[a-zA-Z]*r|\|\s*(ba)?sh\b|>\s*/dev/(sd|nvme)")


def now(): return time.time()
def die(msg, rc=1): print(f"error: {msg}", file=sys.stderr); sys.exit(rc)


def write_atomic(path, text):
    tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.{os.getpid()}.tmp")
    with open(tmp, "w") as f: f.write(text)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path) as f: return json.load(f)
    except (OSError, ValueError): return default


class Paths:
    def __init__(self, tid):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", tid or ""): die(f"invalid task id {tid!r}")
        self.id = tid
        self.home = os.path.abspath(os.environ.get("FM_HOME") or ROOT)
        self.state, self.data = os.path.join(self.home, "state"), os.path.join(self.home, "data")
        s = os.path.join(self.state, tid)
        self.meta, self.status, self.turnend = s + ".meta", s + ".status", s + ".turn-ended"
        self.acp, self.events, self.dir = s + ".acp.json", s + ".events.jsonl", s + ".acp"
        self.cmd, self.pending = os.path.join(self.dir, "cmd"), os.path.join(self.dir, "pending")
        self.lock, self.log = os.path.join(self.dir, "lock"), os.path.join(self.dir, "harness.log")
        self.stderr = os.path.join(self.dir, "agent.stderr")
        self.report = os.path.join(self.data, tid, "report.md")

    def ensure(self):
        for d in (self.cmd, self.pending): os.makedirs(d, exist_ok=True)


def append_status(p, verb, note, key=None):
    """One status line in the format fm-classify-lib.sh reads; mirrors the worker brief's append."""
    tag = (f" [key={key}]" if key else "") + f" [at={int(now())}]"
    with open(p.status, "a") as f: f.write(f"{verb}{tag}: {note}\n")
    ledger, cfg = os.path.join(p.home, "bin/fm-fleet-ledger.sh"), os.path.join(p.home, "config")
    if os.path.exists(os.path.join(cfg, "fleet-ledger")) and os.access(ledger, os.X_OK):
        subprocess.run([ledger, "appended", cfg, p.status], capture_output=True)


def last_status_verb(p):
    try:
        with open(p.status) as f: lines = [l for l in f.read().splitlines() if l.strip()]
    except OSError: return ""
    return re.split(r"[\s:\[]", lines[-1], 1)[0] if lines else ""


def proc_start(pid):
    """Start time ticks from /proc: with the pid it identifies a process across pid reuse."""
    try:
        with open(f"/proc/{pid}/stat") as f: return f.read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError): return None


def alive(pid, start):
    return bool(pid) and proc_start(pid) is not None and proc_start(pid) == start


def group_gone(pgid):
    try: os.killpg(pgid, 0); return False
    except ProcessLookupError: return True
    except PermissionError: return False


def kill_group(pgid, grace=3.0):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try: os.killpg(pgid, sig)
        except ProcessLookupError: return
        end = now() + grace
        while now() < end:
            if group_gone(pgid): return
            time.sleep(0.05)


def shrink(o, limit=2000):
    if isinstance(o, str): return o if len(o) <= limit else o[:limit] + f"...[+{len(o) - limit} chars]"
    if isinstance(o, list): return [shrink(x, limit) for x in o]
    if isinstance(o, dict): return {k: shrink(v, limit) for k, v in o.items()}
    return o


def in_roots(path, roots):
    path = os.path.realpath(os.path.expanduser(path))
    return any(path == r or path.startswith(r + os.sep) for r in roots)


def policy(call, write_roots, read_roots, allow_fetch):
    """Return the allow_once option id to auto-answer, or None to queue for the supervisor."""
    tc, kind = call["params"]["toolCall"], call["params"]["toolCall"].get("kind") or "other"
    once = next((o["optionId"] for o in call["params"].get("options", []) if o.get("kind") == "allow_once"), None)
    paths = [l["path"] for l in tc.get("locations") or [] if l.get("path")]
    if once is None: return None
    if kind in ("read", "search", "think"):
        ok = all(in_roots(x, read_roots) for x in paths)
    elif kind in ("edit", "delete", "move"):
        ok = bool(paths) and all(in_roots(x, write_roots) for x in paths)
    elif kind == "fetch":
        ok = allow_fetch
    elif kind == "other" and (tc.get("rawInput") or {}).get("directories"):
        # OpenCode's external_directory request: kind other, the directories it wants in rawInput.
        dirs = (tc.get("rawInput") or {}).get("directories") or []
        ok = bool(dirs) and all(in_roots(x, write_roots) for x in dirs)
    elif kind in ("execute", "other"):
        cmd = str((tc.get("rawInput") or {}).get("command") or tc.get("title") or "")
        toks = [t for t in re.split(r"[\s;|&<>()=\"']+", cmd) if t.startswith(("/", "~", "../"))]
        ok = bool(cmd) and not RISKY.search(cmd) and all(
            t == "/dev/null" or in_roots(t, read_roots) for t in toks)
    else:
        ok = False
    return once if ok else None


class Daemon:
    def __init__(self, p, resume):
        self.p, self.resume = p, resume
        self.cfg = read_json(p.acp, {})
        self.q = queue.Queue()
        self.ids, self.responses, self.next_id = {}, {}, 0
        self.agent, self.turn_id, self.queued_prompts, self.perm_rpc = None, None, [], {}
        self.session, self.cancelling, self.finishing, self.replay = None, 0.0, False, False
        self.last_frame, self.stale_flagged, self.last_text, self.exit_reason = now(), False, "", None
        self.loaded = False
        self.counts = {"frames": 0, "bytes": 0, "available_commands_bytes": 0}

    # --- state file and event log -------------------------------------------------
    def save(self, **kw):
        self.cfg.update(kw, updated_at=int(now()))
        write_atomic(self.p.acp, json.dumps(self.cfg, indent=1, sort_keys=True) + "\n")

    def log(self, direction, frame, **extra):
        raw = json.dumps(frame)
        self.counts["frames"] += 1; self.counts["bytes"] += len(raw)
        upd = (frame.get("params") or {}).get("update") or {}
        if upd.get("sessionUpdate") == "available_commands_update":
            self.counts["available_commands_bytes"] += len(raw)
            frame = {**frame, "params": {**frame["params"], "update": {
                "sessionUpdate": "available_commands_update", "count": len(upd.get("availableCommands", []))}}}
        rec = {"t": round(now(), 3), "d": direction, **extra, "f": shrink(frame)}
        with open(self.p.events, "a") as f: f.write(json.dumps(rec) + "\n")

    def note(self, text):
        self.log("sys", {"note": text})
        with open(self.p.log, "a") as f: f.write(f"{time.strftime('%H:%M:%S')} {text}\n")

    # --- JSON-RPC ----------------------------------------------------------------
    def send(self, method, params=None, rid=None, notify=False, result=None, error=None):
        frame = {"jsonrpc": "2.0"}
        if method:
            frame["method"] = method
            frame["params"] = params or {}
            if not notify:
                self.next_id += 1
                frame["id"] = self.next_id
                self.ids[self.next_id] = method
        else:
            frame["id"] = rid
            if error: frame["error"] = error
            else: frame["result"] = result
        self.log("out", frame)
        try:
            self.agent.stdin.write(json.dumps(frame) + "\n"); self.agent.stdin.flush()
        except (OSError, ValueError): pass
        return frame.get("id")

    def reader(self):
        for line in self.agent.stdout:
            line = line.strip()
            if not line: continue
            try: self.q.put(("frame", json.loads(line)))
            except ValueError: self.q.put(("junk", line))
        self.q.put(("eof", None))

    def pump(self, wait=0.2):
        try: kind, item = self.q.get(timeout=wait)
        except queue.Empty: return
        if kind == "eof":
            if not self.finishing: self.agent_died()
            return
        if kind == "junk": self.note(f"non-JSON line from agent: {item[:200]}"); return
        self.last_frame, self.stale_flagged = now(), False
        self.log("in", item, **({"replay": True} if self.replay else {}))
        if "method" in item:
            (self.on_request if "id" in item else self.on_notify)(item)
        elif item.get("id") in self.ids:
            method = self.ids.pop(item["id"])
            if item["id"] == self.turn_id: self.on_turn_end(item)
            else: self.responses[item["id"]] = item

    def call(self, method, params, timeout=60):
        rid = self.send(method, params)
        end = now() + timeout
        while rid not in self.responses:
            if now() > end: raise RuntimeError(f"{method} timed out after {timeout}s")
            if self.agent.poll() is not None and self.q.empty(): raise RuntimeError(f"agent exited during {method}")
            self.pump()
        res = self.responses.pop(rid)
        if "error" in res: raise RuntimeError(f"{method} failed: {res['error']}")
        return res.get("result") or {}

    # --- agent callbacks -----------------------------------------------------------
    def on_notify(self, m):
        if m["method"] != "session/update" or self.replay: return
        u = m["params"].get("update", {})
        kind = u.get("sessionUpdate")
        if kind == "usage_update":
            cost = u.get("cost") or {}
            self.save(usage=u.get("used"), cost=cost)
            cap = self.cfg.get("max_cost")
            if cap is not None and (cost.get("amount") or 0) > cap and not self.finishing:
                append_status(self.p, "failed", f"agent reported cost {cost} above the cap of {cap}; stopped")
                self.exit_reason = "cost-cap"; self.finishing = True
        elif kind == "agent_message_chunk":
            self.last_text = (self.last_text + (u.get("content") or {}).get("text", ""))[-300:]

    def on_request(self, m):
        if m["method"] == "session/request_permission":
            return self.on_permission(m)
        self.send(None, rid=m["id"], error={"code": -32601, "message": f"harness does not implement {m['method']}"})

    def on_permission(self, m):
        pick = policy(m, self.write_roots(), self.read_roots(), self.cfg.get("allow_fetch", False))
        tc = m["params"]["toolCall"]
        if pick:
            self.note(f"auto-allowed {tc.get('kind')}: {tc.get('title')}")
            return self.send(None, rid=m["id"], result={"outcome": {"outcome": "selected", "optionId": pick}})
        n = self.cfg.get("perm_seq", 0) + 1
        self.save(perm_seq=n)
        self.perm_rpc[n] = m["id"]
        write_atomic(os.path.join(self.p.pending, f"{n}.json"), json.dumps({"n": n, "rpc_id": m["id"],
                     "queued_at": int(now()), "toolCall": tc, "options": m["params"].get("options", [])}, indent=1))
        append_status(self.p, "needs-decision", f"permission {n} queued: {tc.get('kind')} {tc.get('title')} "
                      f"(answer: bin/fm-acp-harness.py answer {self.p.id} {n} allow|reject)", key=f"acp-perm-{n}")

    def answer(self, n, decision):
        rpc, f = self.perm_rpc.pop(n, None), os.path.join(self.p.pending, f"{n}.json")
        rec = read_json(f)
        if rpc is None or rec is None: return self.note(f"answer for unknown permission {n}")
        want = {"allow": "allow_once", "reject": "reject_once"}.get(decision)
        opt = next((o["optionId"] for o in rec["options"] if o.get("kind") == want), None)
        out = {"outcome": "selected", "optionId": opt} if opt else {"outcome": "cancelled"}
        self.send(None, rid=rpc, result={"outcome": out})
        os.replace(f, os.path.join(self.p.pending, f"{n}.answered"))
        append_status(self.p, "resolved", f"permission {n} {decision}", key=f"acp-perm-{n}")

    def cancel_pending_permissions(self):
        for n in list(self.perm_rpc):
            self.send(None, rid=self.perm_rpc.pop(n), result={"outcome": {"outcome": "cancelled"}})
            try: os.replace(os.path.join(self.p.pending, f"{n}.json"), os.path.join(self.p.pending, f"{n}.answered"))
            except OSError: pass
            append_status(self.p, "resolved", f"permission {n} cancelled with the turn", key=f"acp-perm-{n}")

    def write_roots(self):
        return [self.wt, os.path.join(self.p.data, self.p.id), os.path.join(self.p.state, self.p.id + ".status"),
                os.path.join(self.p.state, self.p.id + ".inbox"), f"/tmp/fm-{self.p.id}"]

    def read_roots(self):
        return self.write_roots() + [os.path.realpath(r) for r in self.cfg.get("read_roots", [])]

    # --- turns -----------------------------------------------------------------------
    def start_turn(self, text):
        self.last_text = ""
        self.turn_id = self.send("session/prompt", {"sessionId": self.session,
                                 "prompt": [{"type": "text", "text": text}]})
        self.save(turn_open=True, turn=self.cfg.get("turn", 0) + 1, state="running", turn_started_at=int(now()))
        append_status(self.p, "working", f"turn {self.cfg['turn']} started")

    def on_turn_end(self, res):
        stop = (res.get("result") or {}).get("stopReason") or f"error:{res.get('error')}"
        self.turn_id, self.cancelling = None, 0.0
        self.cancel_pending_permissions()
        with open(self.p.turnend, "a"): os.utime(self.p.turnend, None)
        self.save(turn_open=False, stop_reason=stop, state="idle", usage_last=(res.get("result") or {}).get("usage"))
        if self.finishing: return
        verb = last_status_verb(self.p)
        if verb == "done" and not os.path.isfile(self.p.report) and self.cfg.get("report_gate", True):
            append_status(self.p, "blocked", f"done reported but data/{self.p.id}/report.md is missing; harness stays up for a steer")
        elif verb in TERMINAL:
            self.exit_reason = verb; self.finishing = True
        elif stop in ("refusal", "max_tokens", "max_turn_requests") or "error" in res:
            append_status(self.p, "failed", f"turn ended with {stop}"); self.exit_reason = "failed"; self.finishing = True
        elif verb not in HOLDING and stop != "cancelled":
            append_status(self.p, "blocked", f"turn ended ({stop}) without a done/failed/blocked status line")
        if not self.finishing and self.queued_prompts: self.start_turn(self.queued_prompts.pop(0))

    # --- commands --------------------------------------------------------------------
    def poll_commands(self):
        for name in sorted(os.listdir(self.p.cmd)):
            if name.startswith("."): continue
            f = os.path.join(self.p.cmd, name)
            c = read_json(f)
            if c is None: continue
            os.unlink(f)
            kind = c.get("kind")
            if kind == "steer":
                if self.turn_id is None: self.start_turn(c["text"])
                else: self.queued_prompts.append(c["text"])
            elif kind == "cancel" and self.turn_id is not None:
                self.cancelling = now()
                self.send("session/cancel", {"sessionId": self.session}, notify=True)
                self.cancel_pending_permissions()
                self.queued_prompts.clear()
            elif kind == "answer": self.answer(c["n"], c["decision"])
            elif kind == "stop": self.exit_reason, self.finishing = "stopped", True

    def tick(self):
        stale = self.cfg.get("stale_secs", 900)
        if self.turn_id is not None and not self.stale_flagged and now() - self.last_frame > stale:
            self.stale_flagged = True
            append_status(self.p, "blocked", f"no agent output for {int(now() - self.last_frame)}s during a turn")
        if self.cancelling and now() - self.cancelling > 15:
            append_status(self.p, "blocked", "agent did not finish the cancelled turn within 15s; stopping it")
            self.cancelling = 0.0; self.exit_reason, self.finishing = "cancel-timeout", True

    def agent_died(self):
        rc = self.agent.wait()
        self.note(f"agent exited rc={rc}")
        if last_status_verb(self.p) not in TERMINAL:
            append_status(self.p, "failed", f"agent process exited (rc={rc}) before reporting done; "
                          f"resume with bin/fm-acp-harness.py resume {self.p.id}")
        self.exit_reason, self.finishing = "agent-died", True
        self.save(state="dead", turn_open=False)

    # --- lifecycle -------------------------------------------------------------------
    def run(self):
        p = self.p
        p.ensure()
        self.lockf = open(p.lock, "w")
        try: fcntl.flock(self.lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: die(f"a harness already runs task {p.id}")
        self.wt = os.path.realpath(self.cfg["worktree"])
        self.kill_orphan()
        for stale_cmd in os.listdir(p.cmd): os.unlink(os.path.join(p.cmd, stale_cmd))   # addressed a previous run
        for stale in os.listdir(p.pending):
            if stale.endswith(".json"): os.replace(os.path.join(p.pending, stale), os.path.join(p.pending, stale[:-5] + ".answered"))
        env = {**os.environ, **AGENT_ENV.get(self.cfg.get("agent"), {}), "FM_TASK_ID": p.id}
        self.agent = subprocess.Popen(self.cfg["agent_cmd"], cwd=self.wt, env=env, text=True, bufsize=1,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=open(p.stderr, "a"), start_new_session=True)
        threading.Thread(target=self.reader, daemon=True).start()
        self.save(pid=os.getpid(), pid_start=proc_start(os.getpid()), agent_pid=self.agent.pid,
                  agent_pgid=self.agent.pid, agent_start=proc_start(self.agent.pid), state="starting", ready=False,
                  started_at=int(now()), turn_open=False if not self.resume else self.cfg.get("turn_open", False))
        was_open = self.cfg.get("turn_open", False)
        try:
            self.handshake()
            note = ("The harness was restarted and your previous turn was cut off. Continue the task from where "
                    "you stopped; your status file and the worktree show what you already did.")
            if not self.resume: self.start_turn(self.cfg["brief"])
            elif not self.loaded: self.start_turn(self.cfg["brief"] + "\n\n" + note)   # fresh session, no history
            elif was_open: self.start_turn(note)
            else: self.save(state="idle")
            self.save(ready=True)
            while not self.finishing:
                self.pump(); self.poll_commands(); self.tick()
        except Exception as e:  # startup or protocol failure
            self.note(f"harness error: {e}")
            if self.exit_reason != "agent-died": append_status(p, "failed", f"acp harness error: {e}")
            self.exit_reason = self.exit_reason or "error"
        self.finish()

    def handshake(self):
        init = self.call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "fm-acp-harness", "version": "0.1"},
                         "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
        if init.get("protocolVersion") != 1: raise RuntimeError(f"agent speaks ACP v{init.get('protocolVersion')}, only v1 is supported")
        caps = init.get("agentCapabilities") or {}
        self.save(agent_info=init.get("agentInfo"), load_session=bool(caps.get("loadSession")))
        old = self.cfg.get("session_id")
        if self.resume and old and caps.get("loadSession"):
            self.replay = True
            try: res = self.call("session/load", {"sessionId": old, "cwd": self.wt, "mcpServers": []}, timeout=120)
            finally:
                while not self.q.empty(): self.pump(0.05)   # drain the replayed history
                self.replay = False
            self.session, self.loaded = old, True
        else:
            if self.resume: self.note("agent cannot session/load; starting a fresh session in the same worktree")
            res = self.call("session/new", {"cwd": self.wt, "mcpServers": []})
            self.session, self.loaded = res["sessionId"], False
        self.save(session_id=self.session)
        want = self.cfg.get("model")
        opt = next((o for o in res.get("configOptions") or [] if o.get("id") == "model"), None)
        if want and (opt is None or opt.get("currentValue") != want):
            self.call("session/set_config_option", {"sessionId": self.session, "configId": "model", "value": want})
        self.note(f"session {self.session} ready on model {want or (opt or {}).get('currentValue')}")

    def kill_orphan(self):
        pgid, start = self.cfg.get("agent_pgid"), self.cfg.get("agent_start")
        if pgid and alive(self.cfg.get("agent_pid"), start): kill_group(pgid)

    def finish(self):
        a, pgid = self.agent, self.cfg.get("agent_pgid")
        if a is not None:
            try: a.stdin.close()
            except OSError: pass
            end = now() + 5
            while a.poll() is None and now() < end: time.sleep(0.05)
            if pgid and not group_gone(pgid): kill_group(pgid)   # also reaps the agent's tool children
            a.wait()
        left = pgid is not None and not group_gone(pgid)
        self.save(state="exited" if self.exit_reason != "agent-died" else "dead", exit_reason=self.exit_reason,
                  turn_open=False, leftover_processes=left, counts=self.counts)
        self.note(f"harness exit: {self.exit_reason}")


# ------------------------------------------------------------------- commands (client side)
def lease_worktree(tid, project):
    project = os.path.realpath(project)
    r = subprocess.run(["treehouse", "get", "--lease", "--lease-holder", tid], cwd=project, capture_output=True, text=True)
    out = r.stdout.strip().splitlines()
    if r.returncode or not out: die(f"treehouse get --lease failed: {r.stderr.strip()}")
    return check_isolated(out[-1], project)


def check_isolated(wt, project):
    def top(d): return subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    wt, t = os.path.realpath(wt), None
    t = os.path.realpath(top(wt) or "/nonexistent")
    if t != wt or wt == os.path.realpath(project) or t == os.path.realpath(top(project) or "/nonexistent"):
        die(f"{wt} is not an isolated worktree of {project}; refusing to launch in the primary checkout")
    return wt


def status_of(p):
    cfg = read_json(p.acp)
    if cfg is None: return "missing", {}
    if cfg.get("state") in ("exited", "dead"): return cfg["state"], cfg
    if not alive(cfg.get("pid"), cfg.get("pid_start")):
        return ("starting" if cfg.get("state") == "starting" and now() - cfg.get("updated_at", 0) < 90 else "dead"), cfg
    if cfg.get("state") == "starting": return "starting", cfg
    if os.path.isdir(p.pending) and any(n.endswith(".json") for n in os.listdir(p.pending)): return "blocked", cfg
    return ("running" if cfg.get("turn_open") else "idle"), cfg


def send_cmd(p, wait=10, **cmd):
    st, _ = status_of(p)
    if st not in ("running", "idle", "blocked"): die(f"no live harness for {p.id} (state {st})")
    name = os.path.join(p.cmd, f"{time.time_ns()}-{cmd['kind']}.json")
    write_atomic(name, json.dumps(cmd))
    end = now() + wait
    while os.path.exists(name) and now() < end: time.sleep(0.05)
    if os.path.exists(name): die(f"harness did not take the {cmd['kind']} command within {wait}s")


def start_daemon(p, resume):
    p.ensure()
    log = open(p.log, "a")
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "_run", p.id] + (["--resume"] if resume else []),
                     stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    end = now() + 90
    while now() < end:
        cfg = read_json(p.acp, {})
        if cfg.get("ready"): return cfg
        if cfg.get("state") in ("exited", "dead"): break
        time.sleep(0.2)
    die(f"harness for {p.id} did not become ready; see {p.log}")


def cmd_spawn(a):
    p = Paths(a.id)
    os.makedirs(p.state, exist_ok=True)
    if (not a.meta_out and os.path.exists(p.meta)) or os.path.exists(p.acp): die(f"task {a.id} already has state; refusing to overwrite")
    brief = open(a.brief).read()
    if not brief.strip(): die("empty brief")
    wt = check_isolated(a.worktree, a.project) if a.worktree else lease_worktree(a.id, a.project)
    agent_cmd = shlex.split(a.agent_cmd) if a.agent_cmd else AGENTS.get(a.agent) or die(f"unknown agent {a.agent}")
    cfg = {"task": a.id, "worktree": wt, "project": os.path.realpath(a.project), "agent": a.agent, "agent_cmd": agent_cmd,
           "model": a.model, "brief": brief, "max_cost": a.max_cost, "allow_fetch": a.allow_fetch,
           "read_roots": a.read_root, "report_gate": not a.no_report_gate, "state": "starting", "updated_at": int(now())}
    p.ensure()
    write_atomic(p.acp, json.dumps(cfg, indent=1) + "\n")
    meta = [f"window=acp:{a.id}", f"endpoint_task_id={a.id}", f"worktree={wt}", f"project={cfg['project']}",
            f"harness={a.agent}", "kind=scout", f"model={a.model or 'default'}", "effort=default", "backend=acp",
            f"spawn_gen=s{int(now())}.{os.getpid()}"]
    write_atomic(a.meta_out or p.meta, "\n".join(meta) + "\n")
    cfg = start_daemon(p, resume=False)
    print(f"ready id={a.id} session={cfg.get('session_id')} worktree={wt} pid={cfg.get('pid')}")


def cmd_state(a):
    st, cfg = status_of(Paths(a.id))
    if a.json: print(json.dumps({"state": st, **cfg}, indent=1, sort_keys=True))
    else: print(st)
    return 0 if st in ("running", "idle", "blocked", "starting") else 1


def fmt_event(r):
    f, d = r["f"], r["d"]
    if "note" in f: return f"sys   {f['note']}"
    m = f.get("method")
    if m == "session/update":
        u = f["params"]["update"]; k = u.get("sessionUpdate")
        if k in ("agent_message_chunk", "agent_thought_chunk"): return None
        if k == "tool_call": return f"tool  {u.get('kind')} {u.get('title')}"
        if k == "tool_call_update" and u.get("status") in ("completed", "failed"): return f"tool  -> {u['status']} {u.get('toolCallId', '')[-8:]}"
        if k == "usage_update": return f"usage used={u.get('used')} cost={u.get('cost')}"
        return f"upd   {k}"
    if m: return f"{d:5} {m}"
    return f"{d:5} result {json.dumps(f.get('result') or f.get('error'))[:120]}" if "result" in f or "error" in f else None


def cmd_tail(a):
    p, pos, text = Paths(a.id), 0, ""
    def drain(lines):
        nonlocal text
        for l in lines:
            r = json.loads(l)
            u = (r["f"].get("params") or {}).get("update") or {}
            if u.get("sessionUpdate") == "agent_message_chunk" and not r.get("replay"):
                text += (u.get("content") or {}).get("text", ""); continue
            if text: print(f"agent {text.strip()[:300]!r}"); text = ""
            s = fmt_event(r)
            if s: print(f"{time.strftime('%H:%M:%S', time.localtime(r['t']))} {s}")
    try: lines = open(p.events).read().splitlines()
    except OSError: die(f"no events for {a.id}")
    drain(lines[-a.n:]); pos = len(lines)
    while a.follow:
        time.sleep(0.5)
        lines = open(p.events).read().splitlines()
        drain(lines[pos:]); pos = len(lines)
        if status_of(p)[0] in ("exited", "dead", "missing"): break
    if text: print(f"agent {text.strip()[:300]!r}")


def cmd_permissions(a):
    p = Paths(a.id)
    for n in sorted(os.listdir(p.pending)) if os.path.isdir(p.pending) else []:
        if n.endswith(".json"):
            r = read_json(os.path.join(p.pending, n))
            print(f"{r['n']}\t{r['toolCall'].get('kind')}\t{r['toolCall'].get('title')}")


def cmd_stop(a):
    p = Paths(a.id)
    st, cfg = status_of(p)
    if st == "missing": return 0
    if st in ("running", "idle", "blocked"):
        write_atomic(os.path.join(p.cmd, f"{time.time_ns()}-stop.json"), json.dumps({"kind": "stop"}))
        end = now() + 20
        while status_of(p)[0] in ("running", "idle", "blocked") and now() < end: time.sleep(0.1)
        if status_of(p)[0] in ("running", "idle", "blocked"):
            kill_group(cfg["agent_pgid"]); os.kill(cfg["pid"], signal.SIGTERM)
        cfg = read_json(p.acp, {})
    elif cfg.get("agent_pgid") and alive(cfg.get("agent_pid"), cfg.get("agent_start")):
        kill_group(cfg["agent_pgid"])   # harness is dead but its agent group survived
    if cfg.get("agent_pgid") and not group_gone(cfg["agent_pgid"]) and alive(cfg.get("agent_pid"), cfg.get("agent_start")):
        die(f"agent group {cfg['agent_pgid']} of {a.id} is still alive", 2)
    return 0


def cmd_resume(a):
    p = Paths(a.id)
    st, cfg = status_of(p)
    if st in ("running", "idle", "blocked", "starting"): die(f"harness for {a.id} is already {st}")
    if st == "missing": die(f"no state for {a.id}")
    cfg = start_daemon(p, resume=True)
    print(f"resumed id={a.id} session={cfg.get('session_id')} pid={cfg.get('pid')}")


def main():
    ap = argparse.ArgumentParser(prog="fm-acp-harness.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("spawn"); s.add_argument("id"); s.add_argument("project"); s.add_argument("--brief", required=True)
    s.add_argument("--model"); s.add_argument("--worktree"); s.add_argument("--agent", default="opencode")
    s.add_argument("--agent-cmd"); s.add_argument("--max-cost", type=float); s.add_argument("--read-root", action="append", default=[])
    s.add_argument("--meta-out"); s.add_argument("--allow-fetch", action="store_true"); s.add_argument("--no-report-gate", action="store_true")
    for name in ("lease",): x = sub.add_parser(name); x.add_argument("id"); x.add_argument("project")
    x = sub.add_parser("state"); x.add_argument("id"); x.add_argument("--json", action="store_true")
    x = sub.add_parser("tail"); x.add_argument("id"); x.add_argument("-n", type=int, default=40); x.add_argument("-f", dest="follow", action="store_true")
    x = sub.add_parser("steer"); x.add_argument("id"); x.add_argument("text", nargs="+")
    for name in ("cancel", "permissions", "stop", "resume"): x = sub.add_parser(name); x.add_argument("id")
    x = sub.add_parser("answer"); x.add_argument("id"); x.add_argument("n", type=int); x.add_argument("decision", choices=["allow", "reject"])
    x = sub.add_parser("_run"); x.add_argument("id"); x.add_argument("--resume", action="store_true")
    a = ap.parse_args()
    if a.cmd == "_run": return Daemon(Paths(a.id), a.resume).run()
    p = Paths(a.id)
    if a.cmd == "spawn": return cmd_spawn(a)
    if a.cmd == "lease": print(lease_worktree(a.id, a.project)); return 0
    if a.cmd == "state": return cmd_state(a)
    if a.cmd == "tail": return cmd_tail(a)
    if a.cmd == "steer": send_cmd(p, kind="steer", text=" ".join(a.text))
    elif a.cmd == "cancel": send_cmd(p, kind="cancel")
    elif a.cmd == "answer": send_cmd(p, kind="answer", n=a.n, decision=a.decision)
    elif a.cmd == "permissions": return cmd_permissions(a)
    elif a.cmd == "stop": return cmd_stop(a)
    elif a.cmd == "resume": return cmd_resume(a)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
