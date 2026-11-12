<p align="center">
  <a href="https://cyberreplay.com"><img src="assets/cyberreplay-logo.png" width="96" alt="CyberReplay logo" /></a>
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

`rtk-devin` registers a Devin `PreToolUse` hook that transparently rewrites
supported commands to their RTK equivalents before they run:

```
git status        ->  rtk git status        (3-line summary instead of 40 lines)
cargo test        ->  rtk cargo test        (failures only, not 500 passing lines)
git log --oneline ->  rtk git log --oneline (compact history)
```

You never type `rtk`. The hook intercepts, rewrites, and the agent reads the
compressed output. Compound commands (`&&`, `;`, pipes) are rewritten
per-segment, and anything RTK does not recognize passes through unchanged.

Upstream RTK does not ship a Devin installer yet
([rtk-ai/rtk#4097](https://github.com/rtk-ai/rtk/issues/4097)), so this repo
provides a drop-in integration plus a one-command installer for macOS.

## Features

- **Transparent rewriting**: no agent or workflow changes required
- **Idempotent installer**: safe to re-run, backs up your config before writing
- **Global or per-project**: one flag chooses `~/.config/devin` or `.devin/`
- **Fail-safe**: malformed input, missing `rtk`, or hook errors never block a command
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
3. Merge the hook into `~/.config/devin/config.json` (backs up to `.bak.<timestamp>` first)
4. Skip cleanly if the hook is already installed

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

1. Restart open Devin.ai sessions (hooks load at session start).
2. Ask Devin to run `git status` in any repository.
3. You will see RTK's compact summary instead of raw git output.
4. Check cumulative savings at any time:

```bash
rtk gain
```

In the Devin CLI you can also run `/hooks` to list loaded hooks and their
source files.

## How it works

```
Devin exec tool call
        |
        v
PreToolUse hook: /opt/homebrew/bin/rtk hook claude
        |
        |-- reads JSON payload from stdin (tool_name, tool_input.command)
        |-- rewrites supported commands to rtk equivalents
        |-- prints {"hookSpecificOutput": {"updatedInput": {"command": "..."}}}
        v
Devin merges updatedInput and runs the rewritten command
        |
        v
Agent receives compressed output; savings tracked by rtk gain
```

Devin implements Claude Code's hook schema natively
(`hookSpecificOutput.updatedInput`, `permissionDecisionReason`), so RTK's
existing Claude hook processor works unmodified. No wrapper script needed.

The hook only fires on the `exec` tool (`matcher: "^exec$"`). File and search
tools bypass it; use `rtk read`, `rtk grep`, and `rtk find` through `exec` for
the same compact output there. `AGENTS.md` in this repo shows the pattern.

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
  ]
}
```

| Field | Description |
| --- | --- |
| `matcher` | Regex on the tool name. `^exec$` covers shell commands only |
| `command` | The hook processor. `rtk hook claude` handles the payload format |
| `timeout` | Seconds before the hook is abandoned (command still runs) |

## Uninstall

```bash
./install.sh --uninstall              # global
./install.sh --uninstall --project .  # this project only
```

This removes only the RTK hook entries and leaves all other hooks and settings
untouched.

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

<p align="center">
  Built by <a href="https://cyberreplay.com">CyberReplay</a>: cybersecurity
  services and tools for modern teams.
  <br />
  <a href="https://cyberreplay.com">cyberreplay.com</a>
</p>
