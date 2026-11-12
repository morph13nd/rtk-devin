# RTK for Devin.ai

RTK (Rust Token Killer) compresses shell command output before it reaches the
agent's context. Upstream `rtk init --agent devin` does not exist yet
(rtk-ai/rtk#4097 — PR #3144 was closed unmerged), so this directory contains a
manual integration that does the same thing.

## How it works

Devin fires `PreToolUse` hooks before the `exec` tool runs and accepts
`hookSpecificOutput.updatedInput` to transparently rewrite the tool's arguments.
That output shape is identical to Claude Code's, and Devin's hook parser
natively understands Claude's schema (`ClaudeHookSpecificOutput`,
`permissionDecisionReason`, etc. are built into the binary). So RTK's existing
Claude hook processor — `rtk hook claude` — works unmodified:

- Reads the Devin hook payload from stdin (`tool_name`, `tool_input.command`, …)
- Rewrites supported commands (`git status` → `rtk git status`, `cargo test` →
  `rtk cargo test`, compound `&&`/`;` chains, etc.)
- Emits `updatedInput` with the rewritten command; commands with no RTK
  equivalent, denies, and already-rewritten commands pass through untouched

## Install locations

| Scope | File | Effect |
|-------|------|--------|
| Global (all Devin sessions) | `hooks` key in `~/.config/devin/config.json` | registered |
| This project only | `.devin/hooks.v1.json` (this directory) | registered |

Both point at `/opt/homebrew/bin/rtk hook claude`. The rewrite is idempotent —
if both fire for a session rooted here, the second sees an already-`rtk`
command and stays silent.

## Verify

```sh
# unit-level: feed a fake Devin PreToolUse payload
echo '{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"git status"}}' \
  | /opt/homebrew/bin/rtk hook claude
# → {"hookSpecificOutput":{"hookEventName":"PreToolUse",...,"updatedInput":{"command":"rtk git status"}}}

# end-to-end: ask a Devin session to run a command, or check savings
rtk gain
```

In Devin Desktop, `/hooks` lists loaded hooks and their source files.

## Uninstall

Remove the `hooks` key block from `~/.config/devin/config.json` and delete this
directory's `.devin/hooks.v1.json`.
