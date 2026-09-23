#!/bin/bash
# Claude Code SessionEnd hook → forget the session's status file so the Touch Bar
# stops showing its context window right away.
set -u
DIR="${CLAUDE_TOUCHBAR_DIR:-$HOME/.claude/touchbar}"
input="$(cat)"
if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  sid=$(printf '%s' "${BASH_REMATCH[1]}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-80)
  [ -n "$sid" ] && rm -f "$DIR/status/$sid.json" "$DIR/activity/$sid.json" \
      "$DIR/activity/$sid.agents" "$DIR/activity/$sid.stopped"
fi
exit 0
