#!/bin/bash
# Install costline into ~/.claude/costline and wire it into ~/.claude/settings.json.
#
#   ./install.sh [--link] [--ascii] [--force] [--no-backfill]
#
#   --link         symlink the scripts to this checkout instead of copying (development)
#   --ascii        plain labels instead of Nerd Font icons
#   --force        replace an existing status line that is not costline's
#   --no-backfill  do not price existing transcripts after installing
#
# settings.json is backed up to ~/.claude/backups/settings.json.<timestamp> before it is changed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
claude="${CLAUDE_HOME:-$HOME/.claude}"
target="$claude/costline"
settings="$claude/settings.json"
link=0 ascii=0 force=0 backfill=1
for arg in "$@"; do
  case "$arg" in
    --link) link=1 ;; --ascii) ascii=1 ;; --force) force=1 ;; --no-backfill) backfill=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
for dep in jq python3 git; do
  command -v "$dep" >/dev/null || { echo "costline needs $dep on PATH" >&2; exit 1; }
done

mkdir -p "$target" "$claude/backups"
if [ "$link" = 1 ]; then
  ln -sfn "$here/bin" "$target/bin"
  ln -sfn "$here/prices.default.json" "$target/prices.default.json"
else
  rm -rf "${target:?}/bin"; cp -R "$here/bin" "$target/bin"
  cp "$here/prices.default.json" "$target/prices.default.json"
fi

# shellcheck disable=SC2088,SC2016  # literal strings written into settings.json; Claude Code expands them
statusline_cmd='~/.claude/costline/bin/statusline.sh'
[ "$ascii" = 1 ] && statusline_cmd="COSTLINE_ASCII=1 $statusline_cmd"
# shellcheck disable=SC2016
hook_cmd='python3 -I "$HOME/.claude/costline/bin/costline.py" hook'

[ -f "$settings" ] || echo '{}' > "$settings"
current=$(jq -r '.statusLine.command // ""' "$settings")
if [ -n "$current" ] && [[ "$current" != *costline* ]] && [ "$force" != 1 ]; then
  echo "settings.json already has a status line: $current" >&2
  echo "re-run with --force to replace it (a backup is kept)" >&2
  exit 1
fi
cp "$settings" "$claude/backups/settings.json.$(date +%Y%m%d-%H%M%S)"
tmp=$(mktemp)
jq --arg sl "$statusline_cmd" --arg hook "$hook_cmd" '
  .statusLine = {type: "command", command: $sl, padding: 0}
  | .hooks.SessionEnd = (
      ((.hooks.SessionEnd // []) | map(select(((.hooks // []) | any(.command | test("costline.py"))) | not)))
      + [{hooks: [{type: "command", command: $hook, timeout: 15}]}])' "$settings" > "$tmp"
mv "$tmp" "$settings"

tool="python3 -I $target/bin/costline.py"
[ -d "${COSTLINE_DIR:-$claude/costs}/ledger" ] && $tool migrate
[ "$backfill" = 1 ] && $tool backfill
echo "installed: status line -> $statusline_cmd"
echo "           SessionEnd hook -> $hook_cmd"
echo "Restart Claude Code (or start a new session) to see the status line. Report: $tool report"
