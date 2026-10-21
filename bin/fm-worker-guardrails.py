#!/usr/bin/env python3
"""Install worker tool hooks after fm-spawn's lifecycle wiring.

Usage: fm-worker-guardrails.py HARNESS WORKTREE STATE TASK
Called only for workers, never secondmates. Uses existing lifecycle artifacts
where possible; Cursor gets a private plugin so project hooks stay untouched.
Codex uses the same handler through fm-codex-worker.py's task-private home.
Muse, rovo and agy have no enabled blocking surface and print a coverage gap.
The evaluator's CLI header owns the policy and its limits.
"""

import json
from pathlib import Path
import shlex
import sys


CHECK = Path(__file__).with_name("fm-worker-pretool-check.py").resolve()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def command_handler(worktree):
    command = shlex.join(["python3", str(CHECK), "--root", str(worktree)])
    return {"type": "command", "command": command + " || exit 2", "timeout": 10}


def install(harness, worktree, state, task):
    wt, state = Path(worktree), Path(state)
    command = shlex.join(["python3", str(CHECK), "--root", str(wt)])
    handler = command_handler(wt)
    group = [{"matcher": "*", "hooks": [handler]}]
    if harness == "claude":
        path, event = wt / ".claude/settings.local.json", "PreToolUse"
    elif harness == "gemini":
        path, event = state / f"{task}.gemini-settings.json", "BeforeTool"
        # Gemini matchers are regexes, unlike Claude's wildcard matcher.
        group[0]["matcher"] = ".*"
    elif harness == "devin":
        path, event = state / f"{task}.devin-config.json", "PreToolUse"
        group[0].pop("matcher")
    elif harness == "polytoken":
        script = state / f"{task}.polytoken-guardrails.sh"
        script.write_text("#!/usr/bin/env bash\n" + command + " --polytoken || exit 2\n")
        script.chmod(0o700)
        path = wt / ".polytoken/hooks.json"
        value = json.loads(path.read_text())
        value = [entry for entry in value if not isinstance(entry, dict) or entry.get("name") != "fm-worker-guardrails"]
        value.append({"name": "fm-worker-guardrails", "event": "pre_tool_use", "handler": {"bash": str(script)}})
        write_json(path, value)
        return
    elif harness == "grok":
        path, event = wt / ".grok/hooks/fm-worker-guardrails.json", "PreToolUse"
        group[0]["matcher"] = ".*"
    elif harness == "cursor":
        plugin = state / f"{task}.cursor-guardrails"
        write_json(plugin / ".cursor-plugin/plugin.json", {
            "name": "fm-worker-guardrails", "version": "1.0.0", "hooks": "hooks/hooks.json",
        })
        handler["command"] = command + " --cursor || exit 2"
        write_json(plugin / "hooks/hooks.json", {"version": 1, "hooks": {"preToolUse": [handler]}})
        return
    elif harness in {"pi", "pi-signed", "omp", "opencode"}:
        # These adapters use native extension/plugin blocking instead of shell
        # exit codes. Only 0 allows; missing evaluator or process failure blocks.
        callback = """
const fmWorkerGuard = (payload) => new Promise((resolve) => {
  const child = fmGuardSpawn("python3", [CHECK_PATH, "--root", WORKTREE],
    { stdio: ["pipe", "ignore", "pipe"] });
  let error = "";
  child.stderr.on("data", chunk => { error += chunk.toString(); });
  child.stdin.on("error", () => {});
  child.on("error", () => resolve("worker guardrail could not start"));
  child.on("close", code => resolve(code === 0 ? "" : (error.trim() || "worker guardrail failed")));
  child.stdin.end(JSON.stringify(payload));
});
""".replace("CHECK_PATH", json.dumps(str(CHECK))).replace("WORKTREE", json.dumps(str(wt)))
        if harness == "opencode":
            path = wt / ".opencode/plugins/fm-worker-guardrails.js"
            source = "import { spawn as fmGuardSpawn } from 'node:child_process';\n" + callback
            source += """
export const FmWorkerGuardrails = async () => ({
  "tool.execute.before": async (input, output) => {
    const denied = await fmWorkerGuard({tool_name: input.tool, tool_input: output.args});
    if (denied) throw new Error(denied);
  },
});
"""
        else:
            path = state / f"{task}.{'omp' if harness == 'omp' else 'pi'}-ext.ts"
            source = path.read_text().split("\n// Firstmate worker guardrail begin\n", 1)[0]
            source = source.replace("\n  fmInstallWorkerGuard(pi);", "")
            # A named second extension is unnecessary: append a registration
            # helper and call it in the existing worker extension's factory.
            source = source.replace("export default function (pi: any) {",
                                    "export default function (pi: any) {\n  fmInstallWorkerGuard(pi);")
            callback = callback.replace("(payload) =>", "(payload: any) =>", 1)
            source += "\n// Firstmate worker guardrail begin\nimport { spawn as fmGuardSpawn } from 'node:child_process';\n" + callback
            source += """
function fmInstallWorkerGuard(pi: any) {
  pi.on("tool_call", async (event: any, ctx: any) => {
    const denied = await fmWorkerGuard({tool_name: event.toolName, tool_input: event.input, cwd: ctx?.cwd});
    return denied ? {block: true, reason: denied} : {};
  });
}
"""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        return
    elif harness == "codex":
        # The launch wrapper installs this handler into a task-private home.
        return
    elif harness in {"kimi", "commandcode"}:
        # Its global guarded PreToolUse entry is installed by the same
        # format-preserving installer that owns its Stop hook and token store.
        return
    else:
        print(f"WORKER_GUARDRAILS: {harness}: no enabled blocking tool-hook surface; brief restrictions still apply", file=sys.stderr)
        return
    value = json.loads(path.read_text()) if path.exists() else {}
    hooks = value.setdefault("hooks", {})
    existing = hooks.get(event, [])
    existing = [entry for entry in existing if not any(
        "fm-worker-pretool-check.py" in hook.get("command", "") for hook in entry.get("hooks", [])
    )]
    hooks[event] = existing + group
    write_json(path, value)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("usage: fm-worker-guardrails.py HARNESS WORKTREE STATE TASK")
    try:
        install(*sys.argv[1:])
    except (OSError, ValueError, TypeError) as error:
        print(f"worker guardrail installation failed: {error}", file=sys.stderr)
        sys.exit(1)
