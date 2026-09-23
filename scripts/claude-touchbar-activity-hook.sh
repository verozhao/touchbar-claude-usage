#!/bin/bash
# Claude Code activity hooks → Claude Touch Bar.
# Records what each session is doing in ~/.claude/touchbar/activity/<session_id>.json
# so the Touch Bar can say "still working", "waiting for you" or "finished".
#
# Wired as:  bash claude-touchbar-activity-hook.sh <state>
#   working  UserPromptSubmit  (a turn started)
#   waiting  Notification      (Claude needs something mid-turn: permission, a question)
#   done     Stop              (the turn finished; stays "working" while subagents run on)
#   agent+   PreToolUse:Task   (a subagent was launched)
#   agent-   SubagentStop      (a subagent finished)
# Same shape as the status line writer: no python, no network, always exit 0.
set -u
umask 077
STATE="${1:-working}"
DIR="${CLAUDE_TOUCHBAR_DIR:-$HOME/.claude/touchbar}"
ACT_DIR="$DIR/activity"

input="$(cat)"
[ -d "$ACT_DIR" ] || mkdir -p "$ACT_DIR" 2>/dev/null

sid=""
if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then sid=${BASH_REMATCH[1]}; fi
sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-80)
[ -n "$sid" ] || sid="pid-$PPID"

cwd=""
if [[ $input =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then cwd=${BASH_REMATCH[1]}; fi
# Notification hooks carry the text Claude Code would have shown in a system notification.
msg=""
if [[ $input =~ \"message\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then msg=${BASH_REMATCH[1]}; fi
msg=${msg//\\/}
msg=$(printf '%s' "$msg" | tr -d '"' | cut -c1-120)

COUNT="$ACT_DIR/$sid.agents"

# Subagents outlive the turn that started them: Stop fires while they are still working, and the
# session is not really finished until they are. Count them so "done" can wait for the last one.
read_count() { c=$(cat "$COUNT" 2>/dev/null); case $c in ''|*[!0-9]*) echo 0 ;; *) echo "$c" ;; esac; }
case $STATE in
  agent+)
    printf '%s\n' "$(( $(read_count) + 1 ))" > "$COUNT" 2>/dev/null
    STATE=working ;;
  agent-)
    n=$(( $(read_count) - 1 )); [ "$n" -lt 0 ] && n=0
    printf '%s\n' "$n" > "$COUNT" 2>/dev/null
    # The last subagent finishing is the moment a turn that already stopped becomes "done".
    if [ "$n" -gt 0 ]; then STATE=working
    elif grep -q '"state":"working"' "$ACT_DIR/$sid.json" 2>/dev/null && [ -f "$ACT_DIR/$sid.stopped" ]; then STATE=done
    else exit 0
    fi ;;
  working)
    rm -f "$COUNT" "$ACT_DIR/$sid.stopped" 2>/dev/null ;;   # a fresh prompt starts a fresh count
  done)
    # Remember that the turn itself ended, then stay blue while subagents are still running.
    : > "$ACT_DIR/$sid.stopped" 2>/dev/null
    [ "$(read_count)" -gt 0 ] && STATE=working ;;
esac

# Claude Code sends Notification for two different things: a real mid-turn ask (permission,
# a question) and a "waiting for your input" nudge ~60s after a turn already finished. Only the
# first deserves amber, so a nudge that arrives once the turn is done leaves the state alone.
if [ "$STATE" = "waiting" ] && [ -f "$ACT_DIR/$sid.json" ]; then
  prev=$(cat "$ACT_DIR/$sid.json" 2>/dev/null)
  case $prev in
    *'"state":"working"'*) : ;;
    *) exit 0 ;;
  esac
fi

tmp="$ACT_DIR/.$sid.tmp"
if printf '{"session_id":"%s","state":"%s","cwd":"%s","message":"%s","agents":%s,"ts":%s}\n' \
    "$sid" "$STATE" "$cwd" "$msg" "$(read_count)" "$(date +%s)" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$ACT_DIR/$sid.json" 2>/dev/null || rm -f "$tmp"
fi
exit 0
