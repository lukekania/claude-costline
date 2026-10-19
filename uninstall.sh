#!/bin/bash
# Remove costline from ~/.claude/settings.json and delete ~/.claude/costline. Keeps the data in
# ~/.claude/costs (delete it yourself if you want the cost history gone).
set -euo pipefail
claude="${CLAUDE_HOME:-$HOME/.claude}"
settings="$claude/settings.json"
if [ -f "$settings" ]; then
  mkdir -p "$claude/backups"
  cp "$settings" "$claude/backups/settings.json.$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  jq '
    (if (.statusLine.command // "") | test("costline") then del(.statusLine) else . end)
    | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | map(select(((.hooks // []) | any(.command | test("costline.py"))) | not)))
    | (if .hooks.SessionEnd == [] then del(.hooks.SessionEnd) else . end)
    | (if .hooks == {} then del(.hooks) else . end)' "$settings" > "$tmp"
  mv "$tmp" "$settings"
fi
rm -rf "$claude/costline"
echo "costline removed; data kept in ${COSTLINE_DIR:-$claude/costs}"
