#!/bin/bash
# Removes the LaunchAgent, the app, the Claude Code hook/statusLine wiring, and restores the
# Touch Bar mode. Keeps ~/.claude/touchbar (config + logs) unless you pass --purge.
set -uo pipefail
DATA="$HOME/.claude/touchbar"
SETTINGS="$HOME/.claude/settings.json"
LABEL="com.verozhao.claude-touchbar"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
pkill -x ClaudeTouchBar >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeTouchBar.app"
python3 - "$SETTINGS" "$DATA" <<'PY'
import json, os, sys
settings_path, data = os.path.realpath(sys.argv[1]), sys.argv[2]
if not os.path.exists(settings_path): sys.exit(0)
s = json.load(open(settings_path))
mode = os.stat(settings_path).st_mode & 0o777
hooks = s.get("hooks", {})
for event, marker in (("PermissionRequest", "claude-touchbar-permission-hook"), ("SessionEnd", "claude-touchbar-session-end"),
                      ("UserPromptSubmit", "claude-touchbar-activity-hook"), ("Notification", "claude-touchbar-activity-hook"),
                      ("Stop", "claude-touchbar-activity-hook"), ("SubagentStop", "claude-touchbar-activity-hook"),
                      ("PreToolUse", "claude-touchbar-activity-hook")):
    if event not in hooks: continue
    kept = []
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", []) if marker not in h.get("command", "")]
        if g["hooks"]: kept.append(g)
    if kept: hooks[event] = kept
    else: del hooks[event]
if not hooks: s.pop("hooks", None)
sl = s.get("statusLine")
if isinstance(sl, dict) and "claude-touchbar-statusline" in sl.get("command", ""):
    original = os.path.join(data, "statusline-original.json")
    passthrough = os.path.join(data, "statusline-passthrough")
    prev = None
    if os.path.exists(original):
        try: prev = json.load(open(original))
        except Exception: prev = None
    if prev is None and os.path.exists(passthrough):
        cmd = open(passthrough).read().strip()
        if cmd: prev = dict(sl); prev["command"] = cmd
    if prev: s["statusLine"] = prev
    else: s.pop("statusLine", None)
    for p in (original, passthrough):
        if os.path.exists(p): os.remove(p)
tmp = settings_path + ".tmp"
json.dump(s, open(tmp, "w"), indent=2); open(tmp, "a").write("\n")
os.chmod(tmp, mode)
os.replace(tmp, settings_path)
print("  settings restored")
PY
if [ -f "$DATA/previous-touchbar-mode" ]; then
  prev=$(cat "$DATA/previous-touchbar-mode")
  if [ "$prev" = "unset" ] || [ -z "$prev" ]; then defaults delete com.apple.touchbar.agent PresentationModeGlobal >/dev/null 2>&1 || true
  else defaults write com.apple.touchbar.agent PresentationModeGlobal -string "$prev"; fi
  killall ControlStrip >/dev/null 2>&1 || true
  rm -f "$DATA/previous-touchbar-mode"
  echo "  Touch Bar mode restored to '$prev'"
fi
rm -rf "$DATA/bin"
if [ "${1:-}" = "--purge" ]; then rm -rf "$DATA"; echo "  data folder removed"; fi
echo "Uninstalled."
