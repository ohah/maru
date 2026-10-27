#!/usr/bin/env python3
"""Review 10: install and execute real Maru hooks using synthetic events in private config."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    executable = str(Path(sys.argv[1]).resolve())
    current_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    user_files = [current_home / "hooks.json", current_home / "config.toml"]
    before = [digest(path) for path in user_files]
    with tempfile.TemporaryDirectory(prefix="maru-hook-probe-") as directory:
        root = Path(directory)
        (root / "codex").mkdir(mode=0o700)
        (root / "events").mkdir(mode=0o700)
        env = os.environ.copy()
        for name in list(env):
            if name.startswith("MARU_HOOK_") or name in ("TMUX", "TMUX_PANE", "MARU_AGENT_LOG_FORMAT"):
                env.pop(name)
        env.update(CODEX_HOME=str(root / "codex"), XDG_CACHE_HOME=str(root / "cache"),
                   LC_MARU_PANE="probe_a", LC_MARU_LOG_FORMAT="1")
        installed = subprocess.run(
            [executable, "agent-hooks", "install", "--provider=codex", "--scope=remote", "--dir=" + str(root / "events")],
            env=env, capture_output=True, text=True, timeout=20, check=True)
        check(json.loads(installed.stdout)["changed"], "private hook installation did not run")
        hooks = json.loads((root / "codex" / "hooks.json").read_text())["hooks"]
        for event in ("SessionStart", "UserPromptSubmit"):
            command = hooks[event][0]["hooks"][0]["command"]
            for sid in ("probe-session-A", "probe-session-B"):
                payload = {"session_id": sid, "hook_event_name": event, "cwd": "/probe/same-cwd", "source": "startup"}
                result = subprocess.run(command, input=json.dumps(payload) + "\n", shell=True,
                                        executable="/bin/sh", env=env, capture_output=True, text=True, timeout=10, check=True)
                check(not result.stdout and not result.stderr, "recording hooks should stay silent")
        path = root / "events" / "probe_a.ndjson"
        records = [json.loads(line.split("\t", 1)[1]) for line in path.read_text().splitlines()]
        check([item["session_id"] for item in records] == ["probe-session-A", "probe-session-B"] * 2,
              "hooks lost session identities")
        check(len(list((root / "events").glob("*.ndjson"))) == 1,
              "identical inherited pane environments should select one record file")
        env["LC_MARU_PANE"] = "probe_b"
        payload = {"session_id": "probe-session-B", "hook_event_name": "SessionStart", "cwd": "/probe/same-cwd"}
        subprocess.run(hooks["SessionStart"][0]["hooks"][0]["command"], input=json.dumps(payload) + "\n",
                       shell=True, executable="/bin/sh", env=env, capture_output=True, text=True, timeout=10, check=True)
        check((root / "events" / "probe_b.ndjson").exists(), "a distinct pane environment must select a distinct file")
    check([digest(path) for path in user_files] == before, "the real provider configuration changed")
    print(json.dumps({"review": 10, "synthetic_events": True, "session_ids_recorded": True,
                      "shared_environment_reproduced_wrong_pane": True, "distinct_environment_control": True,
                      "user_config_unchanged": True}))


if __name__ == "__main__":
    main()
