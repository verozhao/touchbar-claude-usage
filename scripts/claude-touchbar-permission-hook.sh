#!/bin/bash
# Claude Code PermissionRequest hook → Claude Touch Bar.
# Reads the hook JSON on stdin, drops a request file for the Touch Bar app,
# waits for the user's tap, and prints the decision JSON Claude Code expects.
# If the app is not running (or its heartbeat is stale: lid closed, display asleep),
# the session is remote, the tool is a dialog, the user taps "Terminal", or the wait
# times out, it prints nothing and Claude Code shows its normal terminal prompt.
set -u
umask 077
DIR="${CLAUDE_TOUCHBAR_DIR:-$HOME/.claude/touchbar}"
REQ_DIR="$DIR/requests"
RES_DIR="$DIR/responses"
PIDFILE="$DIR/app.pid"
CONFIG="$DIR/config.json"

trace() { [ -n "${CLAUDE_TOUCHBAR_TRACE:-}" ] && printf '%s pid=%s %s\n' "$(date '+%H:%M:%S')" "$$" "$*" >> "$CLAUDE_TOUCHBAR_TRACE" 2>/dev/null; return 0; }

# Nobody can reach this Mac's Touch Bar from an SSH session.
if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && [ "${CLAUDE_TOUCHBAR_OVER_SSH:-0}" != "1" ]; then
  trace "ssh session, skipping"; exit 0
fi

input="$(cat)"
trace "entered, ${#input} bytes"
[ -n "$input" ] || exit 0

# The app is alive only while it keeps refreshing app.pid (every 15 s). A fresh heartbeat plus
# either a successful kill -0 or an EPERM (sandboxed hook) counts; "No such process" does not.
app_alive() {
  [ -f "$PIDFILE" ] || return 1
  pid=$(tr -cd '0-9' < "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  now=$(date +%s); mtime=$(stat -f %m "$PIDFILE" 2>/dev/null || echo 0)
  [ $((now - mtime)) -lt 60 ] || return 1
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  case "$(kill -0 "$pid" 2>&1)" in *"No such process"*) return 1 ;; *) return 0 ;; esac
}
if ! app_alive; then
  trace "app not running (pidfile $PIDFILE)"
  exit 0
fi

wait_seconds=60
if [ -f "$CONFIG" ]; then
  w=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("wait_seconds", 60)))' "$CONFIG" 2>/dev/null || true)
  case "$w" in ''|*[!0-9]*) ;; *) wait_seconds=$w ;; esac
fi
# Stay under the hook timeout Claude Code enforces (install.sh sets it to wait_seconds + 30).
if [ -n "${CLAUDE_TOUCHBAR_HOOK_TIMEOUT:-}" ] && [ "$wait_seconds" -gt $((CLAUDE_TOUCHBAR_HOOK_TIMEOUT - 5)) ]; then
  wait_seconds=$((CLAUDE_TOUCHBAR_HOOK_TIMEOUT - 5))
fi

mkdir -p "$REQ_DIR" "$RES_DIR"

# Build the request file (python does the JSON work; no jq dependency).
# The payload goes through a temp file: "python3 -" already uses stdin for the program.
tmpin=$(mktemp "$DIR/.hookin.XXXXXX") || exit 0
printf '%s' "$input" > "$tmpin"
req_path=$(python3 - "$REQ_DIR" "$$" "$tmpin" "$CONFIG" <<'PY'
import json, os, sys, time
req_dir, hook_pid, in_path, config_path = sys.argv[1:5]
try:
    with open(in_path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
tool = d.get("tool_name") or "Tool"
# Dialog-style tools need the terminal UI; two buttons cannot answer them.
passthrough = {"AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "EnterWorktree", "ExitWorktree"}
try:
    extra = json.load(open(config_path)).get("passthrough_tools", [])
    if isinstance(extra, list):
        passthrough.update(str(x) for x in extra)
except Exception:
    pass
if tool in passthrough:
    sys.exit(3)
ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    ti = {}
# One-line human summary of what is being asked.
if tool == "Bash":
    summary = ti.get("command") or ti.get("description") or ""
elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit", "Read"):
    summary = ti.get("file_path") or ti.get("notebook_path") or ""
elif tool in ("WebFetch", "WebSearch"):
    summary = ti.get("url") or ti.get("query") or ""
elif tool in ("Grep", "Glob"):
    summary = ti.get("pattern") or ""
else:
    summary = ti.get("description") or ti.get("command") or ti.get("prompt") or ""
    if not summary:
        try:
            summary = json.dumps(ti, ensure_ascii=False)
        except Exception:
            summary = ""
summary = " ".join(str(summary).split())[:400]
tid = d.get("tool_use_id") or ""
tid = "".join(c if c.isalnum() or c in "-_" else "_" for c in str(tid))[:100]
tid = f"{tid or 'req'}-{int(time.time()*1000)}-{hook_pid}"   # unique across sessions and retries
req = {
    "id": tid,
    "created_at": time.time(),
    "hook_pid": int(hook_pid),
    "session_id": d.get("session_id"),
    "cwd": d.get("cwd"),
    "tool_name": tool,
    "summary": summary,
    "description": (ti.get("description") if isinstance(ti.get("description"), str) else None),
    "permission_mode": d.get("permission_mode"),
}
tmp = os.path.join(req_dir, f".{tid}.tmp")
path = os.path.join(req_dir, f"{tid}.json")
with open(tmp, "w") as f:
    json.dump(req, f)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(path)
PY
)
rc=$?
rm -f "$tmpin"
trace "request rc=$rc path=$req_path"
[ $rc -eq 0 ] || exit 0
[ -n "$req_path" ] || exit 0

req_id=$(basename "$req_path" .json)
res_path="$RES_DIR/$req_id.json"
cleanup() { rm -f "$req_path" "$res_path"; }
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 143' TERM
trap 'cleanup; trap - EXIT; exit 129' HUP
trap 'cleanup; trap - EXIT; exit 130' INT

# Poll for the app's answer.
deadline=$(( $(date +%s) + wait_seconds ))
decision=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$res_path" ]; then
    decision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("decision",""))' "$res_path" 2>/dev/null || true)
    [ -n "$decision" ] && break
  fi
  # Stop waiting if the app died (or the display went to sleep) mid-wait.
  app_alive || exit 0
  sleep 0.25
done

trace "decision='$decision'"
case "$decision" in
  allow)
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n' ;;
  deny)
    # interrupt: like answering "No" in the terminal, Claude stops and waits for you.
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this from the Touch Bar. Stop and wait for further instructions.","interrupt":true}}}\n' ;;
  *) ;;  # "pass", empty, or timeout → fall through to the normal terminal prompt
esac
exit 0
