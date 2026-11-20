#!/usr/bin/env python3
# Exercise the launch wrapper's protocol as well as the delivered prompt.
# Vendor enforcement is covered by fm-codex-hook-layer-live-e2e.test.sh.
import hashlib
import json
import os
from pathlib import Path
import sys
import tomllib

if "app-server" in sys.argv:
    home = Path(os.environ["CODEX_HOME"])
    path = home / "hooks.json"
    group = json.loads(path.read_text())["hooks"]["PreToolUse"][0]
    handler = group["hooks"][0]
    digest = "sha256:" + hashlib.sha256(handler["command"].encode()).hexdigest()
    key = str(path) + ":pre_tool_use:0:0"
    config = tomllib.loads((home / "config.toml").read_text())
    trusted = config.get("hooks", {}).get("state", {}).get(key, {}).get("trusted_hash") == digest
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("method") == "initialize":
            print(json.dumps({"id": message["id"], "result": {}}), flush=True)
        elif message.get("method") == "hooks/list":
            hook = {"key": key, "eventName": "preToolUse", "handlerType": "command",
                    "command": handler["command"], "matcher": group["matcher"], "async": False,
                    "timeoutSec": handler["timeout"], "enabled": True, "isManaged": False,
                    "source": "user", "sourcePath": str(path), "pluginId": None,
                    "currentHash": digest, "trustStatus": "trusted" if trusted else "untrusted"}
            print(json.dumps({"id": message["id"], "result": {"data": [
                {"cwd": message["params"]["cwds"][0], "errors": [], "hooks": [hook]}]}}), flush=True)
else:
    pane = Path(sys.argv[0]).with_suffix(".pane")
    os.execv(pane, [str(pane), *sys.argv[1:]])
