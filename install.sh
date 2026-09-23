#!/bin/bash
# Builds the app, installs it to ~/Applications, wires the Claude Code hooks + status line,
# switches the Touch Bar to "App Controls with Control Strip" so the gauges and the system
# Control Strip share the bar, and registers a LaunchAgent so it starts at login. Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"
DATA="$HOME/.claude/touchbar"
SETTINGS="$HOME/.claude/settings.json"
APP_DST="$HOME/Applications/ClaudeTouchBar.app"
LABEL="com.verozhao.claude-touchbar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

umask 077
mkdir -p "$HOME/Applications" "$DATA/bin" "$DATA/requests" "$DATA/responses" "$DATA/status" "$DATA/activity" "$HOME/Library/LaunchAgents"
chmod 700 "$DATA" "$DATA/requests" "$DATA/responses" "$DATA/status" "$DATA/activity"
chmod 600 "$DATA"/*.json "$DATA"/statusline-passthrough 2>/dev/null || true
# Scripts live in the data dir so the clone can move or go away without breaking Claude Code.
cp scripts/claude-touchbar-permission-hook.sh scripts/claude-touchbar-statusline.sh scripts/claude-touchbar-session-end.sh scripts/claude-touchbar-activity-hook.sh "$DATA/bin/"
chmod 700 "$DATA/bin"/*.sh

# Stop a running copy before replacing the binary.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
pkill -x ClaudeTouchBar >/dev/null 2>&1 || true
rm -rf "$APP_DST"
cp -R build/ClaudeTouchBar.app "$APP_DST"

# Default config (only if missing).
[ -f "$DATA/config.json" ] || cat > "$DATA/config.json" <<JSON
{
  "wait_seconds": 60,
  "refresh_seconds": 180,
  "keep_control_strip": true,
  "auto_present": true,
  "sound": false,
  "show_tray": true,
  "passthrough_tools": []
}
JSON

# Wire Claude Code: PermissionRequest + SessionEnd hooks, statusLine wrapper (keeps your existing status line).
python3 - "$SETTINGS" "$DATA" <<'PY'
import json, os, sys, time, shutil, shlex
settings_path, data = os.path.realpath(sys.argv[1]), sys.argv[2]
try:
    wait = int(json.load(open(os.path.join(data, "config.json"))).get("wait_seconds", 60))
except Exception:
    wait = 60
timeout = wait + 30
hook_cmd = f"CLAUDE_TOUCHBAR_HOOK_TIMEOUT={timeout} bash {shlex.quote(os.path.join(data, 'bin', 'claude-touchbar-permission-hook.sh'))}"
end_cmd = f"bash {shlex.quote(os.path.join(data, 'bin', 'claude-touchbar-session-end.sh'))}"
act = shlex.quote(os.path.join(data, "bin", "claude-touchbar-activity-hook.sh"))
wrap_cmd = f"bash {shlex.quote(os.path.join(data, 'bin', 'claude-touchbar-statusline.sh'))}"
s = {}
mode = 0o600
if os.path.exists(settings_path):
    with open(settings_path) as f:
        s = json.load(f)
    mode = os.stat(settings_path).st_mode & 0o777
    shutil.copy(settings_path, f"{settings_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")

hooks = s.setdefault("hooks", {})
def upsert(event, marker, entry):
    entries = hooks.setdefault(event, [])
    found = False
    for group in entries:
        for h in group.get("hooks", []):
            if marker in h.get("command", ""):
                h.clear(); h.update(entry); found = True
    if not found:
        entries.append({"hooks": [entry]})
upsert("PermissionRequest", "claude-touchbar-permission-hook", {
    "type": "command", "command": hook_cmd, "timeout": timeout,
    "statusMessage": f"Approve or deny on the Touch Bar (terminal prompt in {wait}s; Esc cancels the turn)"})
upsert("SessionEnd", "claude-touchbar-session-end", {"type": "command", "command": end_cmd, "timeout": 10})
# Activity: working / needs you / done, shown as a pill on the Touch Bar.
for event, state in (("UserPromptSubmit", "working"), ("Notification", "waiting"), ("Stop", "done")):
    upsert(event, "claude-touchbar-activity-hook",
           {"type": "command", "command": f"bash {act} {state}", "timeout": 5})

# Status line: remember the user's own command verbatim and run it after ours.
sl = s.get("statusLine")
passthrough = os.path.join(data, "statusline-passthrough")
original = os.path.join(data, "statusline-original.json")
if isinstance(sl, dict) and sl.get("type") == "command" and sl.get("command") and "claude-touchbar-statusline" not in sl["command"]:
    with open(passthrough, "w") as f:
        f.write(sl["command"])
    with open(original, "w") as f:
        json.dump(sl, f)
    print(f"  status line: kept your existing command as passthrough → {passthrough}")
elif not (isinstance(sl, dict) and "claude-touchbar-statusline" in str(sl.get("command", ""))):
    open(passthrough, "w").close()
    if os.path.exists(original): os.remove(original)
new_sl = dict(sl) if isinstance(sl, dict) else {}
new_sl.update({"type": "command", "command": wrap_cmd})
s["statusLine"] = new_sl

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, settings_path)
print(f"  settings: hooks + statusLine written to {settings_path} (backup saved next to it)")
PY

# Touch Bar mode: only "App Controls with Control Strip" lets a modal bar and the system
# Control Strip (brightness, volume, mute, Siri) share the panel. Remembered for uninstall.
mode=$(defaults read com.apple.touchbar.agent PresentationModeGlobal 2>/dev/null || echo "")
if [ "$mode" != "appWithControlStrip" ]; then
  [ -f "$DATA/previous-touchbar-mode" ] || printf '%s\n' "${mode:-unset}" > "$DATA/previous-touchbar-mode"
  defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip
  killall ControlStrip >/dev/null 2>&1 || true
  sleep 1
  echo "  Touch Bar: switched 'Touch Bar shows' from '${mode:-unset}' to App Controls with Control Strip (uninstall.sh restores it)"
fi

# LaunchAgent (start at login, restart on crash). Fresh log each install.
: > "$DATA/app.log"
sed -e "s|__APP_BINARY__|$APP_DST/Contents/MacOS/ClaudeTouchBar|g" -e "s|__HOME__|$HOME|g" \
  LaunchAgents/$LABEL.plist > "$AGENT"
launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
if ! launchctl bootstrap "gui/$(id -u)" "$AGENT"; then
  echo "  launchctl bootstrap failed; starting the app directly. To retry: launchctl bootstrap gui/$(id -u) $AGENT"
  open -a "$APP_DST"
fi

cat <<MSG

Installed.
  • App:        $APP_DST  (menu bar item "C …", Touch Bar shows 5h / Week / Fable / Context)
  • Hook:       PermissionRequest → Approve / Deny / Terminal on the Touch Bar (waits ${wait:-60}s, then the terminal prompt)
  • Scripts:    $DATA/bin  (referenced from ~/.claude/settings.json)
  • Data:       $DATA  (config.json, app.log)
  • First run:  if macOS asks to let "security" read "Claude Code-credentials", click Always Allow.
  • Note:       Claude Code sessions started before this install pick up the hook after a restart.
MSG
