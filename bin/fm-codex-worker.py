#!/usr/bin/env python3
"""Task-private Codex worker hooks and trust; never used for secondmates.

Usage: fm-codex-worker.py prepare WORKTREE STATE TASK
       fm-codex-worker.py launch PRIVATE_HOME WORKTREE codex [ARGS...]
       fm-codex-worker.py remove PRIVATE_HOME
Prepare creates STATE/TASK.codex-home/{config.toml,hooks.json,auth.json}; auth.json
is only a symlink to the original CODEX_HOME/auth.json (never opened or copied).
Non-secret user configuration is copied; inline secrets fail closed by key name
or credential-bearing URL. Existing hook trust/definitions are not copied: the
old worker launch disabled them all. Managed-hook directory settings survive.
User rules and AGENTS.md/AGENTS.override.md are linked without reading them.
Other Codex home state, plugins and credentials are not copied or linked.
Launch discovers and vets the generated hook through a private stdio app-server,
writes only its exact hash trust into the private config, verifies trust, and
executes the unchanged worker arguments with hooks enabled. No model turn runs
during discovery. Remove deletes only this task-private home, not link targets.
"""

import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import subprocess
import sys
import threading
import tomllib
from urllib.parse import urlsplit


GUARDRAILS = runpy.run_path(str(Path(__file__).with_name("fm-worker-guardrails.py")))
SECRET_KEY = re.compile(r"(?:^|_)(?:api_?key|token|secret|password|authorization|cookie|credentials?)$", re.I)
SECRET_TEXT = re.compile(r"(?i)(?:--(?:api[-_]?key|token|secret|password)(?:=|$)|"
                         r"(?:api[-_]?key|access_token|password)=|authorization:|\bbearer\s+\S+|\bsk-[a-z0-9_-]{12,})")
ENV_REFERENCE = {"env_key", "bearer_token_env_var", "env_http_headers", "http_headers_helper",
                 "cli_auth_credentials_store", "mcp_oauth_credentials_store"}


def non_secret(value, trail=()):
    if isinstance(value, dict):
        for key, child in value.items():
            if key not in ENV_REFERENCE and child and (
                SECRET_KEY.search(key.replace("-", "_")) or key in {"env", "http_headers"}
            ):
                raise ValueError("inline credential setting requires environment-based auth: " + ".".join((*trail, key)))
            non_secret(child, (*trail, key))
    elif isinstance(value, list):
        for child in value:
            non_secret(child, trail)
    elif isinstance(value, str):
        if SECRET_TEXT.search(value):
            raise ValueError("inline credential argument cannot be copied")
        if "://" in value:
            url = urlsplit(value)
            if url.password or url.username or re.search(r"(?i)(?:token|key|secret|password)=", url.query):
                raise ValueError("credential-bearing URL setting cannot be copied")


def preserve_paths(value, source):
    # These documented file references resolve against their declaring config
    # layer. Moving the layer must not change the instructions or role policy.
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"model_instructions_file", "experimental_compact_prompt_file",
                       "model_catalog_json", "config_file"} and isinstance(child, str):
                path = Path(child).expanduser()
                if not path.is_absolute():
                    value[key] = str(source / path)
            else:
                preserve_paths(child, source)
    elif isinstance(value, list):
        for child in value:
            preserve_paths(child, source)


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return "[" + ",".join(toml_value(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + "=" + toml_value(v) for k, v in value.items()) + "}"
    raise ValueError("unsupported configuration value type")


def write_config(home, config):
    text = "\n".join(json.dumps(k) + "=" + toml_value(v) for k, v in config.items()) + "\n"
    # Refuse serialization drift before publishing settings.
    if tomllib.loads(text) != config:
        raise ValueError("cannot preserve Codex configuration")
    path = home / "config.toml"
    temporary = home / "config.toml.tmp"
    temporary.write_text(text)
    temporary.chmod(0o600)
    temporary.replace(path)


def prepare(worktree, state, task):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task):
        raise ValueError("invalid task identifier")
    source = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).absolute()
    home = Path(state).resolve() / (task + ".codex-home")
    if source.resolve().is_relative_to(home):
        raise ValueError("worker home cannot replace its source Codex home")
    config_path = source / "config.toml"
    config = tomllib.loads(config_path.read_text()) if config_path.exists() else {}
    non_secret(config)
    preserve_paths(config, source)
    # The prior worker had all hooks disabled. Do not inherit blanket or stale
    # trust; retain managed hook roots, which remain trusted by vendor policy.
    original_hooks = config.pop("hooks", {})
    config["hooks"] = {k: v for k, v in original_hooks.items() if k in {"managed_dir", "windows_managed_dir"}}
    config.setdefault("features", {})["hooks"] = True
    if home.exists() or home.is_symlink():
        remove(home)
    home.mkdir(mode=0o700)
    write_config(home, config)
    handler = GUARDRAILS["command_handler"](Path(worktree).resolve())
    (home / "hooks.json").write_text(json.dumps({"hooks": {"PreToolUse": [
        {"matcher": ".*", "hooks": [handler]}]}}) + "\n")
    (home / "hooks.json").chmod(0o600)
    # Never inspect the credential file, including when the link is dangling.
    (home / "auth.json").symlink_to(source / "auth.json")
    for name in ("AGENTS.md", "AGENTS.override.md", "rules"):
        if (source / name).exists():
            (home / name).symlink_to(source / name, target_is_directory=(name == "rules"))
    return home


def remove(home):
    home = Path(home)
    if not home.name.endswith(".codex-home") or home.is_symlink():
        raise ValueError("refusing non-task Codex home removal")
    if home.exists():
        shutil.rmtree(home)


def discover(codex, worktree, home):
    env = dict(os.environ, CODEX_HOME=str(home))
    with subprocess.Popen([codex, "--enable", "hooks", "app-server"], cwd=worktree, env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, start_new_session=True) as process:
        def stop():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        timer = threading.Timer(30, stop)
        timer.start()
        try:
            def send(message):
                process.stdin.write(json.dumps(message) + "\n")
                process.stdin.flush()

            def receive(identity):
                for line in process.stdout:
                    message = json.loads(line)
                    if message.get("id") == identity:
                        if "error" in message:
                            raise ValueError("Codex hook discovery RPC failed")
                        return message["result"]
                raise ValueError("Codex hook discovery ended or timed out without a response")

            send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "firstmate-worker-guard", "version": "1"},
                "capabilities": {"experimentalApi": True}}})
            receive(1)
            send({"method": "initialized"})
            send({"id": 2, "method": "hooks/list", "params": {"cwds": [str(Path(worktree).resolve())]}})
            return receive(2)
        finally:
            timer.cancel()
            stop()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                stop()
                process.communicate()


def vetted_hook(codex, worktree, home):
    entries = discover(codex, worktree, home).get("data", [])
    if len(entries) != 1 or entries[0].get("errors"):
        raise ValueError("Codex hook discovery returned errors or no unique workspace")
    path = str(home / "hooks.json")
    hooks = [h for h in entries[0].get("hooks", []) if h.get("sourcePath") == path]
    handler = GUARDRAILS["command_handler"](Path(worktree).resolve())
    if len(hooks) != 1 or any(hooks[0].get(k) != v for k, v in {
        "key": path + ":pre_tool_use:0:0", "eventName": "preToolUse", "handlerType": "command",
        "command": handler["command"], "matcher": ".*", "async": False, "timeoutSec": 10,
        "enabled": True, "isManaged": False, "source": "user", "pluginId": None,
    }.items()):
        raise ValueError("Codex did not discover the exact generated worker guard")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", hooks[0].get("currentHash", "")):
        raise ValueError("Codex returned an unsupported hook hash")
    return hooks[0]


def launch(home, worktree, codex, args):
    home = Path(home)
    if home.is_symlink() or not home.name.endswith(".codex-home"):
        raise ValueError("refusing non-task Codex home launch")
    home = home.resolve()
    hook = vetted_hook(codex, worktree, home)
    config = tomllib.loads((home / "config.toml").read_text())
    config["hooks"]["state"] = {hook["key"]: {"trusted_hash": hook["currentHash"]}}
    write_config(home, config)
    if vetted_hook(codex, worktree, home)["trustStatus"] != "trusted":
        raise ValueError("Codex did not honor the private guard trust")
    os.execvpe(codex, [codex, "--enable", "hooks", *args], dict(os.environ, CODEX_HOME=str(home)))


def main():
    action, *args = sys.argv[1:]
    if action == "prepare" and len(args) == 3:
        prepare(*args)
    elif action == "remove" and len(args) == 1:
        remove(*args)
    elif action == "launch" and len(args) >= 3:
        launch(*args[:3], args[3:])
    else:
        raise ValueError("usage: fm-codex-worker.py prepare|launch|remove (see header)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, IndexError) as error:
        sys.exit(f"Codex worker guard trust failed: {error}")
