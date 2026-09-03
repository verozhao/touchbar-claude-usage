#!/bin/bash
# Claude Code statusLine wrapper → Claude Touch Bar.
# Saves each status payload to ~/.claude/touchbar/status/<session_id>.json for the
# Touch Bar app (context window %, model, cost, rate limits), then hands the same
# payload to the user's original status line command so the terminal is unchanged.
# Kept dependency-free and fast: Claude Code cancels status line scripts that are
# still running when the next update (300 ms debounce) arrives.
set -u
umask 077
DIR="${CLAUDE_TOUCHBAR_DIR:-$HOME/.claude/touchbar}"
STATUS_DIR="$DIR/status"
PASSTHROUGH_FILE="$DIR/statusline-passthrough"

input="$(cat)"
[ -d "$STATUS_DIR" ] || mkdir -p "$STATUS_DIR" 2>/dev/null

# Session id straight from the JSON (bash regex, no python startup cost).
sid=""
if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then sid=${BASH_REMATCH[1]}; fi
sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-80)
[ -n "$sid" ] || sid="pid-$PPID"
tmp="$STATUS_DIR/.$sid.tmp"
if printf '%s\n' "$input" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$STATUS_DIR/$sid.json" 2>/dev/null || rm -f "$tmp"
fi

# Pass through to the original status line command, if any (whole file, same shell Claude Code uses).
if [ -s "$PASSTHROUGH_FILE" ]; then
  cmd="$(cat "$PASSTHROUGH_FILE")"
  if [ -n "$cmd" ]; then
    printf '%s\n' "$input" | /bin/sh -c "$cmd"
    exit $?
  fi
fi
# Default minimal status line when there is nothing to pass through to.
model="Claude"; ctx=""
if [[ $input =~ \"display_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then model=${BASH_REMATCH[1]}; fi
if [[ $input =~ \"used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then ctx=${BASH_REMATCH[1]}; fi
if [ -n "$ctx" ]; then printf '%s  ctx %s%%\n' "$model" "$ctx"; else printf '%s\n' "$model"; fi
