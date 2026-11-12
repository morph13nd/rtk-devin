<p align="center">
  <a href="https://cyberreplay.com"><img src="https://cyberreplay.com/_astro/cyber-replay-logo.CqTbeedM_23sU9p.webp" width="96" alt="CyberReplay logo" /></a>
</p>

<h1 align="center">rtk-devin</h1>

<p align="center">
  Token compression for <a href="https://devin.ai">Devin.ai</a> shell commands, powered by
  <a href="https://github.com/rtk-ai/rtk">RTK</a> (Rust Token Killer).
</p>

<p align="center">
  <a href="https://github.com/morph13nd/rtk-devin/actions/workflows/ci.yml"><img src="https://github.com/morph13nd/rtk-devin/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/morph13nd/rtk-devin" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform: macOS" />
</p>

---

## What is this?

Every command Devin's `exec` tool runs sends its full output into the agent's
context window. Build logs, test suites, and `git status` spam burn tokens fast.

`rtk-devin` registers two Devin hooks that compress at both ends of the
command lifecycle:

**Before execution** (`PreToolUse`): supported commands are transparently
rewritten to their RTK equivalents:

```
git status        ->  rtk git status        (3-line summary instead of 40 lines)
cargo test        ->  rtk cargo test        (failures only, not 500 passing lines)
git log --oneline ->  rtk git log --oneline (compact history)
```

**After execution** (`PostToolUse`): output from *every* command, including
ones RTK cannot rewrite (heredocs, `python3` scripts, custom tools), is
compressed before the agent reads it: ANSI codes stripped, progress bars
removed, repeated lines collapsed, long output windowed, and oversized blobs
elided. The full original is always recoverable via `rtk recall <hash>`, and
the hook never makes output worse or blocks a command.

You never type `rtk`. The hooks intercept, rewrite, and compress
transparently. Compound commands (`&&`, `;`, pipes) are rewritten
per-segment, and anything RTK does not recognize still gets its output
compressed after it runs.

Upstream RTK does not ship a Devin installer yet
([rtk-ai/rtk#4097](https://github.com/rtk-ai/rtk/issues/4097)), so this repo
provides a drop-in integration plus a one-command installer for macOS.

## Features

- **Two-stage compression**: command rewriting before execution, output
  compression after, covering every `exec` call
- **Transparent**: no agent or workflow changes required
- **Idempotent installer**: safe to re-run, backs up your config before writing
- **Global or per-project**: one flag chooses `~/.config/devin` or `.devin/`
- **Fail-safe**: malformed input, missing `rtk`, or hook errors never block a command
- **Recoverable**: full output stays available through `rtk recall`
- **Savings tracking**: `rtk gain` shows tokens saved across all sessions

## Install (macOS)

**One-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/morph13nd/rtk-devin/main/install.sh | bash
```

**Or from a clone:**

```bash
git clone https://github.com/morph13nd/rtk-devin.git
cd rtk-devin
./install.sh
```

The installer will:

1. Check for `rtk` and offer to install it via Homebrew if missing
2. Smoke-test `rtk hook claude` against a sample Devin hook payload
3. Install `rtk-posthook.py` to `~/.local/share/rtk-devin/`
4. Ensure your RTK pipeline extends `rtk:posthook` (required for output
   compression; writes `pipeline.toml` into RTK's user config directory,
   existing custom pipelines are left untouched with a warning)
5. Merge both hooks into `~/.config/devin/config.json` (backs up to
   `.bak.<timestamp>` first)
6. Skip cleanly if everything is already installed

### Options

| Flag | Effect |
| --- | --- |
| `--project [dir]` | Write `.devin/hooks.v1.json` in a project instead of the global config |
| `--uninstall` | Remove the hook (combine with `--project` for local removal) |
| `--dry-run` | Preview changes without writing anything |
| `-y`, `--yes` | Auto-confirm prompts (for CI or unattended runs) |

### Requirements

- macOS with Devin.ai Desktop (primary target; Devin CLI on Linux also works)
- [`rtk`](https://github.com/rtk-ai/rtk) 1.x (`brew install rtk`)
- `python3` (preinstalled on macOS with Command Line Tools)

## Verify it is working

1. Restart open Devin.ai sessions (hooks load at session start; run `/hooks`
   in the Devin CLI to list them).
2. Ask Devin to run `git status` in any repository.
3. You will see RTK's compact summary instead of raw git output.
4. Ask Devin to run something verbose (a build or test suite). Long output
   comes back windowed with `[N lines elided]` markers and a
   `[full output: rtk recall <hash>]` pointer instead of the raw dump.
5. Check cumulative savings at any time:

```bash
rtk gain
```

## How it works

```
Devin exec tool call
        |
        v
PreToolUse hook: rtk hook claude
        |-- reads JSON payload from stdin (tool_name, tool_input.command)
        |-- rewrites supported commands to rtk equivalents
        |-- prints {"hookSpecificOutput": {"updatedInput": {"command": "..."}}}
        v
Devin merges updatedInput and runs the (possibly rewritten) command
        |
        v
PostToolUse hook: rtk-posthook.py
        |-- translates the Devin payload into RTK's expected shape
        |-- runs `rtk hook claude`, which applies the rtk:posthook pipeline
        |-- term chain: ansi strip, progress filter, dedup, base64 elide, cap
        |-- prints {"hookSpecificOutput": {"updatedToolOutput": "..."}}
        v
Agent receives compressed output; full text recoverable via rtk recall
```

Devin implements Claude Code's hook schema natively
(`hookSpecificOutput.updatedInput` for PreToolUse,
`hookSpecificOutput.updatedToolOutput` for PostToolUse), so RTK's existing
hook processor does the heavy lifting. `rtk-posthook.py` is a thin adapter
that translates Devin's `tool_response` shape into the Claude shape RTK
expects and maps the result back. It is fail-safe: any error, empty result,
or already-compact output exits silently and Devin keeps the original text.

Both hooks only fire on the `exec` tool (`matcher: "^exec$"`). File and
search tools bypass them; use `rtk read`, `rtk grep`, and `rtk find` through
`exec` for the same compact output there. `AGENTS.md` in this repo shows the
pattern.

The PostToolUse layer needs RTK's `rtk:posthook` pipeline active. The
installer writes a `pipeline.toml` containing `extends = "rtk:posthook"`
into RTK's user config directory (for both global and project installs;
project-level `.rtk/` pipelines are trust-gated, and the user-level file
only adds `hook.after_tool` rules that fire on PostToolUse events alone).
If you already manage a custom pipeline, add that `extends` line yourself
or the output hook stays inert.

## Configuration

The installer detects your `rtk` binary and writes its absolute path into the
hook command, so it works regardless of the PATH Devin's hook runner sees.

To customize, edit the `hooks` block in `~/.config/devin/config.json`:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "^exec$",
      "hooks": [
        {
          "type": "command",
          "command": "/opt/homebrew/bin/rtk hook claude",
          "timeout": 10
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "^exec$",
      "hooks": [
        {
          "type": "command",
          "command": "/usr/bin/python3 $HOME/.local/share/rtk-devin/rtk-posthook.py",
          "timeout": 10
        }
      ]
    }
  ]
}
```

| Field | Description |
| --- | --- |
| `matcher` | Regex on the tool name. `^exec$` covers shell commands only |
| `command` | PreToolUse runs `rtk hook claude`; PostToolUse runs the adapter script |
| `timeout` | Seconds before the hook is abandoned (command still runs) |

## Uninstall

```bash
./install.sh --uninstall              # global
./install.sh --uninstall --project .  # this project only
```

This removes only the RTK hook entries, the posthook script (when no other
scope still references it), and installer-managed `pipeline.toml` files. All
other hooks, pipelines, and settings are left untouched.

## Documentation

- [RTK repository](https://github.com/rtk-ai/rtk): the compression engine
- [RTK docs](https://www.rtk-ai.app): supported commands and savings
- [Devin hooks docs](https://docs.devin.ai/cli/extensibility/hooks/overview):
  the `PreToolUse` / `updatedInput` mechanism this repo builds on
- [Upstream request for native support](https://github.com/rtk-ai/rtk/issues/4097)

## Community

Questions, bug reports, and ideas are welcome in
[GitHub Discussions](https://github.com/morph13nd/rtk-devin/discussions).

## Contributing

Contributions are welcome. Please open an issue first for anything non-trivial,
and keep `install.sh` POSIX-friendly `bash` with `shellcheck` clean (CI enforces
it). Test the full lifecycle locally:

```bash
./install.sh --dry-run
./install.sh --project /tmp/some-dir
./install.sh --uninstall --project /tmp/some-dir
```

## Security

This project runs a local hook on every shell command Devin executes. The hook
binary is `rtk` from [rtk-ai/rtk](https://github.com/rtk-ai/rtk); review it
before installing. The installer never transmits your config anywhere and
makes timestamped local backups before modifying files.

If you believe you have found a security vulnerability in this project, please
disclose it privately via
[GitHub Security Advisories](https://github.com/morph13nd/rtk-devin/security/advisories/new)
rather than opening a public issue.

## License

[MIT](LICENSE) © 2026 CyberReplay

---

## Your agents ship fast. Your security should keep up.

RTK saves you tokens. Breaches cost you the company.

[CyberReplay](https://cyberreplay.com) protects teams that move at AI speed:

- **24/7 MDR**: monitored detection and response while you sleep
- **Agentic Application Security**: security built for how software gets built now
- **Penetration Testing**: see what attackers see, before they do

Book a free 15-minute gap review. You leave knowing your real exposure,
what fixing it costs, and whether we are even the right fit.

No pitch deck. No pressure. Just clarity.

**[Grab a time on our calendar](https://cal.com/cyberreplay/15mincr)**

*P.S. Worst case: you lose 15 minutes and learn exactly where you stand.
Best case: you just avoided your first breach.*
