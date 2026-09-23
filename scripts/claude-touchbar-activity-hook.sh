#!/bin/bash
# Claude Code activity hooks → Claude Touch Bar.
# Records what each session is doing in ~/.claude/touchbar/activity/<session_id>.json
# so the Touch Bar can say "still working", "waiting for you" or "finished".
#
# Wired as:  bash claude-touchbar-activity-hook.sh <state>
#   working  UserPromptSubmit  (a turn started)
#   waiting  Notification      (Claude needs something mid-turn: permission, a question)
#   done     Stop              (the turn finished, output is ready to read)
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
if printf '{"session_id":"%s","state":"%s","cwd":"%s","message":"%s","ts":%s}\n' \
    "$sid" "$STATE" "$cwd" "$msg" "$(date +%s)" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$ACT_DIR/$sid.json" 2>/dev/null || rm -f "$tmp"
fi
exit 0
