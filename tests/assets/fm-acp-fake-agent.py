#!/usr/bin/env python3
"""Scripted ACP v1 agent for tests/fm-acp-harness.test.sh (stdlib only).

The prompt text picks the behavior: PERM-IN / PERM-OUT ask for a permission, HANG waits for
session/cancel, DONE reports done with a report, NOREPORT only claims done and leaves a child process behind, COST
reports a nonzero cost, anything else answers and ends the turn. FAKE_DIR keeps session
history so session/load can replay it; FAKE_IGNORE_EOF=1 mimics an agent that outlives stdin.
"""
import json, os, subprocess, sys, threading, time

FAKE = os.environ["FAKE_DIR"]
HOME, TID = os.environ.get("FM_HOME", ""), os.environ.get("FM_TASK_ID", "t")
lock, cancel, pending = threading.Lock(), threading.Event(), {}


def out(o):
    with lock:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", **o}) + "\n"); sys.stdout.flush()


def update(sid, **u): out({"method": "session/update", "params": {"sessionId": sid, "update": u}})
def chunk(sid, text, kind="agent_message_chunk"): update(sid, sessionUpdate=kind, content={"type": "text", "text": text})
def hist(sid): return os.path.join(FAKE, sid + ".json")


def ask(sid, kind, title, path):
    rid = f"perm-{time.time_ns()}"
    ev = pending[rid] = {"ev": threading.Event()}
    out({"id": rid, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": {
        "toolCallId": "tc1", "title": title, "kind": kind, "status": "pending", "locations": [{"path": path}]},
        "options": [{"optionId": "once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}})
    ev["ev"].wait(30)
    return ev.get("res", {}).get("outcome", {})


def prompt(rid, p):
    sid, text = p["sessionId"], p["prompt"][0]["text"]
    cancel.clear()
    h = json.load(open(hist(sid)))
    h.append(text); json.dump(h, open(hist(sid), "w"))
    chunk(sid, "working on it. ")
    stop = "end_turn"
    if "PERM-IN" in text:
        o = ask(sid, "edit", "write notes.txt", os.path.join(os.getcwd(), "notes.txt"))
        chunk(sid, f"perm-in outcome {o.get('outcome')}:{o.get('optionId')}")
    elif "PERM-OUT" in text:
        o = ask(sid, "edit", "write /etc/hosts-copy", "/etc/hosts-copy")
        chunk(sid, f"perm-out outcome {o.get('outcome')}:{o.get('optionId')}")
    elif "HANG" in text:
        stop = "cancelled" if cancel.wait(60) else "end_turn"
    elif "COST" in text:
        update(sid, sessionUpdate="usage_update", used=10, size=100, cost={"amount": 0.5, "currency": "USD"})
        time.sleep(0.5)
    elif "DONE" in text:
        os.makedirs(os.path.join(HOME, "data", TID), exist_ok=True)
        open(os.path.join(HOME, "data", TID, "report.md"), "w").write("# report\nfindings\n")
        open(os.path.join(HOME, "state", TID + ".status"), "a").write("done [at=1]: report written\n")
        child = subprocess.Popen(["sleep", "300"])      # a tool child that must die with the group
        open(os.path.join(FAKE, "child.pid"), "w").write(str(child.pid))
    elif "NOREPORT" in text:
        open(os.path.join(HOME, "state", TID + ".status"), "a").write("done [at=1]: claimed\n")
    elif "BIGCMDS" in text:
        update(sid, sessionUpdate="available_commands_update", availableCommands=[{"name": f"c{i}"} for i in range(500)])
    out({"id": rid, "result": {"stopReason": stop, "usage": {"inputTokens": 1, "outputTokens": 1}}})


def main():
    for line in sys.stdin:
        m = json.loads(line)
        meth, rid = m.get("method"), m.get("id")
        if meth is None and rid in pending:
            pending[rid]["res"] = m.get("result", {}); pending[rid]["ev"].set()
        elif meth == "initialize":
            out({"id": rid, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake", "version": "0"},
                 "agentCapabilities": {"loadSession": os.environ.get("FAKE_NO_LOAD") != "1"}}})
        elif meth in ("session/new", "session/load"):
            sid = m["params"].get("sessionId") or f"fake-{time.time_ns()}"
            if meth == "session/new": json.dump([], open(hist(sid), "w"))
            else:
                for t in json.load(open(hist(sid))): chunk(sid, t, "user_message_chunk")
            out({"id": rid, "result": {"sessionId": sid, "configOptions": [
                {"id": "model", "currentValue": "fake/default", "options": []}]} if meth == "session/new" else {}})
        elif meth == "session/set_config_option":
            out({"id": rid, "result": {}})
        elif meth == "session/prompt":
            threading.Thread(target=prompt, args=(rid, m["params"]), daemon=True).start()
        elif meth == "session/cancel":
            cancel.set()
    if os.environ.get("FAKE_IGNORE_EOF") == "1":
        time.sleep(600)


main()
