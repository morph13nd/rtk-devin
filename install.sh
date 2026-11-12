#!/usr/bin/env bash
#
# rtk-devin installer for Devin.ai (macOS first, Devin CLI elsewhere)
#
# Registers two Devin hooks on the exec tool:
#
#   PreToolUse   /opt/homebrew/bin/rtk hook claude
#                rewrites supported commands to rtk equivalents before they run
#
#   PostToolUse  /usr/bin/python3 ~/.local/share/rtk-devin/rtk-posthook.py
#                compresses command output after it runs (rtk:posthook pipeline)
#
# Usage:
#   ./install.sh                  Install the global hooks (~/.config/devin)
#   ./install.sh --project [dir]  Install project hooks (.devin/hooks.v1.json)
#   ./install.sh --uninstall      Remove the hooks (add --project for local)
#   ./install.sh --dry-run        Preview changes without writing anything
#
# Requires: rtk (https://github.com/rtk-ai/rtk), python3, Devin.ai
#
set -euo pipefail

HOOK_MATCHER='^exec$'
HOOK_TIMEOUT=10
SCRIPT_NAME='rtk-posthook.py'
SCRIPT_REPO_PATH='rtk-posthook.py'
SCRIPT_URL='https://raw.githubusercontent.com/morph13nd/rtk-devin/main/rtk-posthook.py'

DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0
GLOBAL=1
PROJECT_DIR=""
HAVE_POSTHOOK=0

usage() {
  cat <<'EOF'
rtk-devin installer for Devin.ai (macOS first, Devin CLI elsewhere)

Usage:
  ./install.sh                  Install the global hooks (~/.config/devin)
  ./install.sh --project [dir]  Install project hooks (.devin/hooks.v1.json)
  ./install.sh --uninstall      Remove the hooks (add --project for local)
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

# ------------------------------------------------------------- posthook setup

PYTHON_BIN=""
for p in /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
  if [ -n "$p" ] && [ -x "$p" ]; then PYTHON_BIN="$p"; break; fi
done
PYTHON_BIN="${PYTHON_BIN:-python3}"
INSTALL_DIR="$HOME/.local/share/rtk-devin"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
POST_HOOK_COMMAND="$PYTHON_BIN $SCRIPT_PATH"
SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$SCRIPT_REPO_PATH"

obtain_posthook_script() {
  # Locate a copy of rtk-posthook.py: sibling of this script first, then the
  # pinned raw URL. Returns 0 when a source is available.
  if [ -f "$SCRIPT_SRC" ]; then
    POSTHOOK_SOURCE="$SCRIPT_SRC"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    POSTHOOK_SOURCE="<download:$SCRIPT_URL>"
    return 0
  fi
  local tmp
  tmp="$(mktemp -t rtk-posthook.XXXXXX.py)"
  if curl -fsSL --max-time 20 -o "$tmp" "$SCRIPT_URL" 2>/dev/null \
     && [ -s "$tmp" ] && head -1 "$tmp" | grep -q '^#!/usr/bin/env python3'; then
    POSTHOOK_SOURCE="$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

install_posthook_script() {
  # Copy the posthook script into place. No-op on dry-run/uninstall.
  { [ "$DRY_RUN" = 1 ] || [ "$UNINSTALL" = 1 ]; } && return 0
  [ "$HAVE_POSTHOOK" = 1 ] || return 0
  if [ -f "$SCRIPT_PATH" ] && cmp -s "$POSTHOOK_SOURCE" "$SCRIPT_PATH" 2>/dev/null; then
    info "posthook script already up to date: $SCRIPT_PATH"
    return 0
  fi
  mkdir -p "$INSTALL_DIR"
  cp "$POSTHOOK_SOURCE" "$SCRIPT_PATH"
  chmod 755 "$SCRIPT_PATH"
  info "installed posthook script: $SCRIPT_PATH"
}

remove_posthook_script() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ -f "$SCRIPT_PATH" ] || return 0
  # The script is shared across scopes: keep it while any hook still
  # references it. Project uninstall checks the global config; global
  # uninstall cannot enumerate project hooks, so it warns instead.
  if [ "$GLOBAL" = 0 ]; then
    if [ -f "$HOME/.config/devin/config.json" ] \
       && grep -q 'rtk-posthook.py' "$HOME/.config/devin/config.json"; then
      info "keeping posthook script (global hooks still reference it): $SCRIPT_PATH"
      return 0
    fi
  else
    warn "note: project-level .devin/hooks.v1.json files may still reference $SCRIPT_PATH"
  fi
  rm -f "$SCRIPT_PATH"
  info "removed posthook script: $SCRIPT_PATH"
  rmdir "$INSTALL_DIR" 2>/dev/null || true
}

# ------------------------------------------------------------- pipeline.toml

rtk_user_config_dir() {
  local cfg bin=""
  if [ -n "${RTK_BIN:-}" ] && [ "$RTK_BIN" != "rtk" ]; then
    bin="$RTK_BIN"
  elif command -v rtk >/dev/null 2>&1; then
    bin="rtk"
  fi
  if [ -n "$bin" ]; then
    cfg="$("$bin" config 2>/dev/null | sed -n 's/^Config: //p' | head -1)" || true
    [ -n "$cfg" ] && { dirname "$cfg"; return 0; }
  fi
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/rtk" ;;
    *)      echo "$HOME/.config/rtk" ;;
  esac
}

pipeline_dir() {
  if [ "$GLOBAL" = 1 ]; then
    rtk_user_config_dir
  else
    echo "$PROJECT_DIR/.rtk"
  fi
}

PIPELINE_MARKER='rtk-devin'

ensure_pipeline() {
  # Make sure rtk's active pipeline extends rtk:posthook so the
  # hook.after_tool rules fire. Only manages files it created (marker).
  [ "$HAVE_POSTHOOK" = 1 ] || return 0
  local dir target
  dir="$(pipeline_dir)"
  target="$dir/pipeline.toml"

  if [ -f "$target" ]; then
    if grep -q "$PIPELINE_MARKER" "$target" 2>/dev/null; then
      if grep -q 'rtk:posthook' "$target"; then
        info "pipeline already extends rtk:posthook: $target"
        return 0
      fi
      if [ "$DRY_RUN" = 0 ]; then
        cat > "$target" <<'TOML'
# rtk-devin managed pipeline: compress exec output after it runs.
# Safe to delete this file to restore rtk defaults.
schema_version = 1

[pipeline]
name    = "rtk-devin-posthook"
extends = "rtk:posthook"
TOML
        info "updated pipeline: $target"
      else
        info "would update pipeline: $target"
      fi
      return 0
    fi
    if grep -q 'rtk:posthook\|after_tool' "$target" 2>/dev/null; then
      info "existing pipeline already has after_tool rules: $target"
    else
      warn "found existing $target without rtk:posthook rules;"
      warn "PostToolUse compression will be inactive until it extends 'rtk:posthook'."
      warn "Add to [pipeline]: extends = \"rtk:posthook\" (or merge the after_tool rules)."
    fi
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "would create pipeline: $target"
    return 0
  fi
  mkdir -p "$dir"
  cat > "$target" <<'TOML'
# rtk-devin managed pipeline: compress exec output after it runs.
# Safe to delete this file to restore rtk defaults.
schema_version = 1

[pipeline]
name    = "rtk-devin-posthook"
extends = "rtk:posthook"
TOML
  info "created pipeline: $target"
}

remove_pipeline() {
  [ "$DRY_RUN" = 1 ] && return 0
  local target
  target="$(pipeline_dir)/pipeline.toml"
  if [ -f "$target" ] && grep -q "$PIPELINE_MARKER" "$target" 2>/dev/null; then
    rm -f "$target"
    info "removed pipeline: $target"
  fi
}

# ------------------------------------------------------- python json helper

json_merge() {
  MODE="$1" UNINSTALL="$2" PRE_CMD="$HOOK_COMMAND" POST_CMD="$POST_HOOK_COMMAND" \
  HAVE_POSTHOOK="$HAVE_POSTHOOK" MATCHER="$HOOK_MATCHER" TIMEOUT="$HOOK_TIMEOUT" \
  PROJECT_DIR="$PROJECT_DIR" DRY_RUN="$DRY_RUN" \
  python3 - <<'PYEOF'
import json, os, sys, shutil, datetime

mode          = os.environ["MODE"]
uninstall     = os.environ["UNINSTALL"] == "1"
dry          = os.environ["DRY_RUN"] == "1"
pre_cmd       = os.environ["PRE_CMD"]
post_cmd      = os.environ["POST_CMD"]
have_posthook = os.environ["HAVE_POSTHOOK"] == "1"
matcher       = os.environ["MATCHER"]
timeout       = int(os.environ["TIMEOUT"])
project       = os.environ.get("PROJECT_DIR") or os.getcwd()

def is_ours(cmd):
    cmd = str(cmd)
    return "rtk-posthook.py" in cmd or "rtk hook claude" in cmd

def strip_ours(groups):
    out = []
    for g in groups:
        kept = [h for h in g.get("hooks", []) if not is_ours(h.get("command", ""))]
        if kept:
            g = dict(g, hooks=kept)
            out.append(g)
    return out

def block_for(event):
    cmd = post_cmd if (event == "PostToolUse" and have_posthook) else pre_cmd
    if event == "PostToolUse" and not have_posthook:
        return None
    return {"matcher": matcher,
            "hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}

def ensure(groups, event):
    block = block_for(event)
    if block is None:
        return groups, False
    for g in groups:
        if g.get("matcher") == matcher and any(is_ours(h.get("command", "")) for h in g.get("hooks", [])):
            if json.dumps(g, sort_keys=True) == json.dumps(block, sort_keys=True):
                return groups, False
            g.clear(); g.update(block)
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

EVENTS = ["PreToolUse", "PostToolUse"]

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
        verb = "uninstalled" if uninstall else "installed"
        changed = False
        for ev in EVENTS:
            groups = hooks.setdefault(ev, [])
            if not isinstance(groups, list):
                sys.exit(f"error: 'hooks.{ev}' in {path} is not a JSON array")
            if uninstall:
                new_groups = strip_ours(groups)
                if json.dumps(new_groups) != json.dumps(groups):
                    changed = True
                if new_groups:
                    hooks[ev] = new_groups
                else:
                    hooks.pop(ev, None)
            else:
                new_groups, ch = ensure(groups, ev)
                hooks[ev] = new_groups
                changed = changed or ch
        if uninstall:
            if not hooks:
                data.pop("hooks")
        finish(path, data, existed, changed, verb)
    else:
        devin_dir = os.path.join(project, ".devin")
        path = os.path.join(devin_dir, "hooks.v1.json")
        os.makedirs(devin_dir, exist_ok=True)
        existed = os.path.exists(path)
        data = json.load(open(path)) if existed else {}
        if not isinstance(data, dict):
            sys.exit(f"error: {path} is not a JSON object")
        verb = "uninstalled" if uninstall else "installed"
        changed = False
        remove_file = False
        for ev in EVENTS:
            groups = data.setdefault(ev, [])
            if not isinstance(groups, list):
                sys.exit(f"error: '{ev}' in {path} is not a JSON array")
            if uninstall:
                new_groups = strip_ours(groups)
                if json.dumps(new_groups) != json.dumps(groups):
                    changed = True
                if new_groups:
                    data[ev] = new_groups
                else:
                    data.pop(ev, None)
            else:
                new_groups, ch = ensure(groups, ev)
                data[ev] = new_groups
                changed = changed or ch
        if uninstall:
            remove_file = not data
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
info "pretool hook:  matcher=$HOOK_MATCHER command='$HOOK_COMMAND'"

# Decide whether the PostToolUse layer can be installed.
if [ "$UNINSTALL" = 0 ] && obtain_posthook_script; then
  HAVE_POSTHOOK=1
  info "posthook script: $POST_HOOK_COMMAND"
elif [ "$UNINSTALL" = 0 ]; then
  warn "could not obtain $SCRIPT_NAME; installing PreToolUse hook only"
fi

if [ -n "$RTK_BIN" ] && [ "$DRY_RUN" = 0 ] && [ "$UNINSTALL" = 0 ]; then
  probe='{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"git status"}}'
  out="$(printf '%s' "$probe" | "$RTK_BIN" hook claude 2>/dev/null || true)"
  case "$out" in
    *"rtk git status"*) info "hook smoke test: ok" ;;
    *) warn "hook smoke test inconclusive (rtk hook claude returned: ${out:-<empty>})" ;;
  esac
fi

if [ "$UNINSTALL" = 1 ]; then
  remove_posthook_script
  remove_pipeline
else
  install_posthook_script
  ensure_pipeline
fi

json_merge "$([ "$GLOBAL" = 1 ] && echo global || echo project)" "$UNINSTALL"

if [ "$UNINSTALL" = 1 ]; then
  info "uninstall complete. Restart Devin.ai sessions to unload the hooks."
else
  info "install complete."
  cat <<'EOF'

Next steps:
  1. Restart any open Devin.ai sessions (hooks load at session start).
  2. Run a command like 'git status' and watch for compact RTK output.
  3. Run something verbose (build, test suite) to see PostToolUse compression.
  4. Track savings with: rtk gain

Docs: https://github.com/morph13nd/rtk-devin
EOF
fi
