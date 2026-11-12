#!/usr/bin/env python3
"""Devin PostToolUse hook: compress exec output via `rtk hook claude`.

Devin fires this after every exec call with the tool payload on stdin.
The script translates Devin's payload into the Claude Code shape that
`rtk hook claude` understands, runs the RTK posthook pipeline (the
rtk:posthook term chain: ansi, progress, dedup, base64-elide, cap), and
emits hookSpecificOutput.updatedToolOutput with the compressed text.

Fail-safe by design: any error or empty result exits silently, leaving
the original output untouched. Requires python3.9+.
"""

import json
import os
import shutil
import subprocess
import sys

RTK_CANDIDATES = [
    os.environ.get("RTK_BIN", ""),
    shutil.which("rtk") or "",
    "/opt/homebrew/bin/rtk",
    "/usr/local/bin/rtk",
    os.path.expanduser("~/.local/bin/rtk"),
    os.path.expanduser("~/.cargo/bin/rtk"),
]
TIMEOUT = 10
STATE_FILE = "/tmp/rtk-posthook/last-payload.json"


def find_rtk():
    for c in RTK_CANDIDATES:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("hook_event_name") != "PostToolUse":
        return
    if data.get("tool_name") != "exec":
        return
    resp = data.get("tool_response") or {}
    if not isinstance(resp, dict):
        return
    out = resp.get("output")
    if not isinstance(out, str) or not out.strip():
        return

    # Debug aid: keep the last payload shape for troubleshooting.
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump({"keys": list(data.keys()), "resp_keys": list(resp.keys())}, f)
    except OSError:
        pass

    rtk = find_rtk()
    if not rtk:
        return

    # Translate Devin's payload into the Claude Code shape rtk expects.
    claude = {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": data.get("tool_input") or {},
        "tool_response": {
            "stdout": out,
            "stderr": resp.get("error") or "",
            "interrupted": False,
        },
        "session_id": data.get("session_id", ""),
    }
    try:
        p = subprocess.run(
            [rtk, "hook", "claude"],
            input=json.dumps(claude),
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except Exception:
        return
    if p.returncode != 0 or not p.stdout.strip():
        return
    try:
        r = json.loads(p.stdout)
    except Exception:
        return
    ut = (r.get("hookSpecificOutput") or {}).get("updatedToolOutput")
    if not ut:
        return
    if isinstance(ut, dict):
        text = ut.get("stdout") or ""
        err = ut.get("stderr") or ""
    else:
        text, err = str(ut), ""
    if not text:
        return
    if err.strip():
        text = text + "\n" + err
    # Plain-string form: verified to replace the tool result in Devin.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "updatedToolOutput": text,
        }
    }))


if __name__ == "__main__":
    main()
