#!/usr/bin/env bash
#
# rtk-devin installer for Devin.ai (macOS first, Devin CLI elsewhere)
#
# Registers a PreToolUse hook so every exec tool call is transparently
# rewritten through "rtk hook claude", which compresses command output
# before it reaches the agent's context.
#
# Usage:
#   ./install.sh                  Install the global hook (~/.config/devin)
#   ./install.sh --project [dir]  Install a project hook (.devin/hooks.v1.json)
#   ./install.sh --uninstall      Remove the hook (add --project for local)
#   ./install.sh --dry-run        Preview changes without writing anything
#
# Requires: rtk (https://github.com/rtk-ai/rtk), python3, Devin.ai
#
set -euo pipefail

HOOK_MATCHER='^exec$'
HOOK_TIMEOUT=10

DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0
GLOBAL=1
PROJECT_DIR=""

usage() {
  cat <<'EOF'
rtk-devin installer for Devin.ai (macOS first, Devin CLI elsewhere)

Usage:
  ./install.sh                  Install the global hook (~/.config/devin)
  ./install.sh --project [dir]  Install a project hook (.devin/hooks.v1.json)
  ./install.sh --uninstall      Remove the hook (add --project for local)
  ./install.sh --dry-run        Preview changes without writing anything
  ./install.sh -y, --yes        Auto-confirm prompts (e.g. brew install rtk)
  ./install.sh -h, --help       Show this help
EOF
  exit "${1:-0}"
}

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    --project)
      GLOBAL=0
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
        PROJECT_DIR="$2"; shift
        [ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
      else
        PROJECT_DIR="$PWD"
      fi
      ;;
    --project=*)
      GLOBAL=0
      PROJECT_DIR="${1#--project=}"
      [ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
      ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[ "$DRY_RUN" = 1 ] && info "dry run: no files will be written"

# ---------------------------------------------------------------- rtk check

find_rtk() {
  local p
  if command -v rtk >/dev/null 2>&1; then
    command -v rtk; return 0
  fi
  for p in /opt/homebrew/bin/rtk /usr/local/bin/rtk "$HOME/.local/bin/rtk" "$HOME/.cargo/bin/rtk"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

RTK_BIN="$(find_rtk || true)"

if [ -z "$RTK_BIN" ] && [ "$UNINSTALL" = 0 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    warn "rtk not found; a real run would offer to install it via Homebrew"
    RTK_BIN="rtk"
  elif command -v brew >/dev/null 2>&1; then
    if [ "$ASSUME_YES" = 1 ] || [ -t 0 ]; then
      printf "rtk is not installed. Install it with Homebrew now? [Y/n] "
      read -r reply || reply="y"
      case "$reply" in
        n|N|no|NO) die "install rtk first: https://github.com/rtk-ai/rtk" ;;
      esac
    else
      die "rtk is not installed. Install it from https://github.com/rtk-ai/rtk first."
    fi
    brew install rtk
    RTK_BIN="$(find_rtk)" || die "rtk still not found after install"
  else
    die "rtk is not installed and Homebrew was not found. Install rtk from https://github.com/rtk-ai/rtk first."
  fi
fi

if [ -n "$RTK_BIN" ] && [ "$RTK_BIN" != "rtk" ]; then
  "$RTK_BIN" --version >/dev/null 2>&1 || warn "could not run '$RTK_BIN --version'"
fi

HOOK_COMMAND="${RTK_BIN:-rtk} hook claude"

# ------------------------------------------------------- python json helper

json_merge() {
  MODE="$1" UNINSTALL="$2" HOOK_CMD="$HOOK_COMMAND" MATCHER="$HOOK_MATCHER" \
  TIMEOUT="$HOOK_TIMEOUT" PROJECT_DIR="$PROJECT_DIR" DRY_RUN="$DRY_RUN" \
  python3 - <<'PYEOF'
import json, os, sys, shutil, datetime

mode       = os.environ["MODE"]
uninstall  = os.environ["UNINSTALL"] == "1"
dry        = os.environ["DRY_RUN"] == "1"
hook_cmd   = os.environ["HOOK_CMD"]
matcher    = os.environ["MATCHER"]
timeout    = int(os.environ["TIMEOUT"])
project    = os.environ.get("PROJECT_DIR") or os.getcwd()

def is_rtk_hook(entry):
    return any("rtk hook" in str(h.get("command", "")) for h in entry.get("hooks", []))

def strip_rtk(groups):
    out = []
    for g in groups:
        kept = [h for h in g.get("hooks", [])
                if "rtk hook" not in str(h.get("command", ""))]
        if kept:
            g = dict(g, hooks=kept)
            out.append(g)
    return out

def rtk_block():
    return {"matcher": matcher,
            "hooks": [{"type": "command", "command": hook_cmd, "timeout": timeout}]}

def ensure_rtk(groups):
    block = rtk_block()
    for g in groups:
        if g.get("matcher") == matcher and is_rtk_hook(g):
            if json.dumps(g, sort_keys=True) == json.dumps(block, sort_keys=True):
                return groups, False  # identical block already present
            g.clear(); g.update(block)  # refresh in place, keep position
            return groups, True
    return groups + [block], True

def finish(path, data, existed, changed, verb):
    if not changed:
        print(f"already {verb}: {path}")
        return
    if dry:
        print(f"--- {path} ({'update' if existed else 'create'}, dry run) ---")
        print(json.dumps(data, indent=2))
        print("--- end ---")
        return
    if existed:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        shutil.copy2(path, f"{path}.bak.{stamp}")
        print(f"backup: {path}.bak.{stamp}")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"{verb}: {path}")

try:
    if mode == "global":
        cfg_dir = os.path.expanduser("~/.config/devin")
        path = os.path.join(cfg_dir, "config.json")
        os.makedirs(cfg_dir, exist_ok=True)
        existed = os.path.exists(path)
        data = json.load(open(path)) if existed else {"version": 1}
        if not isinstance(data, dict):
            sys.exit(f"error: {path} is not a JSON object")
        hooks = data.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            sys.exit(f"error: 'hooks' in {path} is not a JSON object")
        groups = hooks.setdefault("PreToolUse", [])
        if not isinstance(groups, list):
            sys.exit(f"error: 'hooks.PreToolUse' in {path} is not a JSON array")
        verb = "uninstalled" if uninstall else "installed"
        if uninstall:
            new_groups = strip_rtk(groups)
            changed = json.dumps(new_groups) != json.dumps(groups)
            hooks["PreToolUse"] = new_groups
            if not new_groups:
                hooks.pop("PreToolUse")
            if not hooks:
                data.pop("hooks")
        else:
            new_groups, changed = ensure_rtk(groups)
            hooks["PreToolUse"] = new_groups
        finish(path, data, existed, changed, verb)
    else:
        devin_dir = os.path.join(project, ".devin")
        path = os.path.join(devin_dir, "hooks.v1.json")
        os.makedirs(devin_dir, exist_ok=True)
        existed = os.path.exists(path)
        data = json.load(open(path)) if existed else {}
        if not isinstance(data, dict):
            sys.exit(f"error: {path} is not a JSON object")
        groups = data.setdefault("PreToolUse", [])
        if not isinstance(groups, list):
            sys.exit(f"error: 'PreToolUse' in {path} is not a JSON array")
        verb = "uninstalled" if uninstall else "installed"
        remove_file = False
        if uninstall:
            new_groups = strip_rtk(groups)
            changed = json.dumps(new_groups) != json.dumps(groups)
            if new_groups:
                data["PreToolUse"] = new_groups
            else:
                data.pop("PreToolUse", None)
            remove_file = not data
        else:
            new_groups, changed = ensure_rtk(groups)
            data["PreToolUse"] = new_groups
        if remove_file and changed and not dry:
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            shutil.copy2(path, f"{path}.bak.{stamp}")
            print(f"backup: {path}.bak.{stamp}")
            os.remove(path)
            print(f"uninstalled: {path} (file removed, no hooks left)")
        elif remove_file and changed and dry:
            print(f"--- {path} (delete, dry run) --- file would be removed (no hooks left)")
        else:
            finish(path, data, existed, changed, verb)
except json.JSONDecodeError as e:
    sys.exit(f"error: invalid JSON: {e}")
PYEOF
}

# -------------------------------------------------------------------- main

if [ "$UNINSTALL" = 0 ] && [ "$DRY_RUN" = 0 ] && [ "$(uname -s)" != "Darwin" ]; then
  warn "this installer is designed and tested on macOS; continuing anyway (Devin CLI on Linux should work)"
fi

if [ "$GLOBAL" = 1 ]; then
  info "mode: global (~/.config/devin/config.json)"
else
  info "mode: project ($PROJECT_DIR/.devin/hooks.v1.json)"
fi
info "hook: matcher=$HOOK_MATCHER command='$HOOK_COMMAND'"

if [ -n "$RTK_BIN" ] && [ "$DRY_RUN" = 0 ] && [ "$UNINSTALL" = 0 ]; then
  probe='{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"git status"}}'
  out="$(printf '%s' "$probe" | "$RTK_BIN" hook claude 2>/dev/null || true)"
  case "$out" in
    *"rtk git status"*) info "hook smoke test: ok" ;;
    *) warn "hook smoke test inconclusive (rtk hook claude returned: ${out:-<empty>})" ;;
  esac
fi

json_merge "$([ "$GLOBAL" = 1 ] && echo global || echo project)" "$UNINSTALL"

if [ "$UNINSTALL" = 1 ]; then
  info "uninstall complete. Restart Devin.ai sessions to unload the hook."
else
  info "install complete."
  cat <<'EOF'

Next steps:
  1. Restart any open Devin.ai sessions (hooks load at session start).
  2. Run a command like 'git status' and watch for compact RTK output.
  3. Track savings with: rtk gain

Docs: https://github.com/morph13nd/rtk-devin
EOF
fi
