#!/usr/bin/env python3
"""Devin PostToolUse hook: compress tool output via `rtk hook claude`.

Devin fires this after tool calls with a normalized payload on stdin:
{tool_name, tool_input, tool_response: {success, output, error}}. The
model-facing text always lives in tool_response.output, regardless of tool.

This adapter translates each supported Devin tool into the Claude Code
payload shape that `rtk hook claude` understands, runs the RTK posthook
pipeline (rtk:posthook term chain plus rtk-devin mcp/subagent rules), and
emits hookSpecificOutput.updatedToolOutput with the compressed text.

Supported tools: exec, get_output, write_to_process, kill_shell (shell
term chain); read, notebook_read (lockfile rule); grep (matches rule);
webfetch, web_search (web chain); run_subagent, read_subagent, and all
mcp_* tools (term chain via custom pipeline rules). Everything else exits
silently.

Fail-safe by design: any error or empty result exits silently, leaving the
original output untouched. Requires python3.9+.
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

# Devin tool_name -> Claude tool_name (drives rtk's subject + extract shape)
TOOL_MAP = {
    "exec": "Bash",
    "get_output": "Bash",
    "write_to_process": "Bash",
    "kill_shell": "Bash",
    "read": "Read",
    "notebook_read": "Read",
    "grep": "Grep",
    "webfetch": "WebFetch",
    "web_search": "WebSearch",
    "run_subagent": "Task",
    "read_subagent": "Task",
}


def find_rtk():
    for c in RTK_CANDIDATES:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def claude_name(devin_name):
    if devin_name in TOOL_MAP:
        return TOOL_MAP[devin_name]
    if devin_name.startswith("mcp__"):
        return devin_name
    if devin_name.startswith("mcp_"):
        return "mcp__devin__" + devin_name
    return None


def build_claude_response(claude, out, err, tool_input):
    """Shape tool_response the way rtk's extract() expects per tool."""
    if claude == "Bash":
        return {"stdout": out, "stderr": err, "interrupted": False}
    if claude == "Read":
        path = (tool_input.get("file_path") or tool_input.get("notebook_path")
                or tool_input.get("path") or "")
        lines = out.count("\n") + 1 if out else 0
        return {"file": {"content": out, "numLines": lines,
                         "totalLines": lines, "filePath": path},
                "type": "text"}
    if claude == "Grep":
        return {"mode": "content", "content": out}
    if claude == "WebFetch":
        return {"result": out}
    if claude == "WebSearch":
        return {"results": [out]}
    # Task / mcp__* / anything else: mcp_text() result-string arm
    return {"result": out}


def build_claude_input(claude, tool_input):
    """tool_input with the source fields rtk's source_of() looks up."""
    ti = dict(tool_input or {})
    if claude == "Read":
        ti.setdefault("file_path",
                      ti.get("file_path") or ti.get("notebook_path")
                      or ti.get("path") or "")
    elif claude == "Grep":
        ti.setdefault("file_path", ti.get("path") or ti.get("file_path") or "")
    elif claude == "WebFetch":
        ti.setdefault("url", ti.get("url") or "")
    return ti


def extract_compressed(ut):
    """Pull the compressed text back out of rtk's rebuilt tool_response."""
    if isinstance(ut, str):
        return ut
    if not isinstance(ut, dict):
        return None
    # Shell: whole tool_response clone with stdout/stderr filtered
    if "stdout" in ut or "stderr" in ut:
        parts = [p for p in (ut.get("stdout"), ut.get("stderr")) if p]
        return "\n".join(parts) if parts else None
    # Read
    f = ut.get("file")
    if isinstance(f, dict) and isinstance(f.get("content"), str):
        return f["content"]
    # Grep / generic string content
    if isinstance(ut.get("content"), str):
        return ut["content"]
    # WebFetch / MCP result string
    if isinstance(ut.get("result"), str):
        return ut["result"]
    # WebSearch results array (string elements only)
    res = ut.get("results")
    if isinstance(res, list):
        texts = [r for r in res if isinstance(r, str)]
        if texts:
            return "\n\n".join(texts)
    # MCP content array of text blocks
    c = ut.get("content")
    if isinstance(c, list):
        texts = [b["text"] for b in c
                 if isinstance(b, dict) and b.get("type") == "text"
                 and isinstance(b.get("text"), str)]
        if texts:
            return "\n".join(texts)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("hook_event_name") != "PostToolUse":
        return
    tool = data.get("tool_name") or ""
    claude = claude_name(tool)
    if not claude:
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
            json.dump({"tool": tool, "keys": list(data.keys()),
                       "resp_keys": list(resp.keys())}, f)
    except OSError:
        pass

    rtk = find_rtk()
    if not rtk:
        return

    tool_input = data.get("tool_input") or {}
    claude_event = {
        "hook_event_name": "PostToolUse",
        "tool_name": claude,
        "tool_input": build_claude_input(claude, tool_input),
        "tool_response": build_claude_response(
            claude, out, resp.get("error") or "", tool_input),
        "session_id": data.get("session_id", ""),
    }
    try:
        p = subprocess.run(
            [rtk, "hook", "claude"],
            input=json.dumps(claude_event),
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
    compressed = extract_compressed(ut)
    if not compressed:
        return
    # Mirror Devin's normalized envelope: replace only the output text.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "updatedToolOutput": {
                "success": resp.get("success", True),
                "output": compressed,
                "error": resp.get("error"),
            },
        }
    }))


if __name__ == "__main__":
    main()
