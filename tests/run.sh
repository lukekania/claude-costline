#!/bin/bash
# End-to-end tests for costline: status line rendering and recording, backfill, hook, migrate.
# Runs offline against a temporary data directory.
# shellcheck disable=SC2016  # single-quoted patterns are intentional
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp="$root/tests/tmp"; rm -rf "$tmp"; mkdir -p "$tmp/costs"
export LC_ALL=C COSTLINE_DIR="$tmp/costs" COSTLINE_OFFLINE=1 CLAUDE_PROJECTS_DIR="$root/tests/fixtures/projects" HOME="$tmp/home"
mkdir -p "$HOME"
cp "$root/tests/fixtures/prices.json" "$COSTLINE_DIR/prices.json"
sl="$root/bin/statusline.sh"; py="python3 -I $root/bin/costline.py"
fails=0
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi
}
payload() { # payload <sid> <project_dir> <cost> [model]
  jq -nc --arg sid "$1" --arg dir "$2" --argjson cost "$3" --arg model "${4:-Test}" \
    '{session_id:$sid, cwd:$dir, model:{display_name:$model}, workspace:{current_dir:$dir, project_dir:$dir},
      context_window:{used_percentage:42}, cost:{total_cost_usd:$cost, total_duration_ms:125000}}'
}
strip() { sed $'s/\x1b\\[[0-9;]*m//g'; }  # ANSI-C quoting: BSD sed has no \x escapes

out=$(payload s1 /p/a 0.4 | "$sl" | strip)
check "renders model, dir, context, cost, duration" grep -q 'Test.*/p/a.*42%.*\$0.40.*2m' <<<"$out"
check "no project total for a lone session" bash -c '! grep -q proj <<<"$1"' _ "$out"
check "session record written" test -f "$COSTLINE_DIR/sessions/s1.json"
check "record holds leg 0.4" test "$(jq .leg "$COSTLINE_DIR/sessions/s1.json")" = 0.4

out=$(payload s1 /p/a 0.1 | "$sl" | strip)
check "counter restart closes the leg" test "$(jq -c '[.leg,.closed]' "$COSTLINE_DIR/sessions/s1.json")" = "[0.1,0.4]"
check "shows Claude Code's current figure" grep -q '\$0.10' <<<"$out"

out=$(payload s2 /p/a 1.0 | "$sl" | strip)
check "project total = other sessions + mine" grep -q 'proj \$1.50' <<<"$out"
out=$(payload s9 /p/b 0.2 | "$sl" | strip)
check "other project has no total" bash -c '! grep -q proj <<<"$1"' _ "$out"
before=$(date -r "$COSTLINE_DIR/sessions/s2.json" +%s)
sleep 1; payload s2 /p/a 1.0 | "$sl" >/dev/null
after=$(date -r "$COSTLINE_DIR/sessions/s2.json" +%s)
check "unchanged cost does not rewrite the record" test "$before" = "$after"
out=$(payload s1 /p/a 0.1 | COSTLINE_ASCII=1 "$sl" | strip)
check "ascii mode emits only ascii" bash -c '[ -z "$(printf %s "$1" | LC_ALL=C tr -d "[:print:]")" ]' _ "$out"
check "ascii mode still renders cost" grep -q '\$0.10' <<<"$out"
out=$(echo '{}' | "$sl" | strip)
check "empty payload still renders" grep -q '\$0.00' <<<"$out"

out=$($py backfill 2>&1)
check "backfill prices the fixture transcript" grep -q 'backfilled 1 session' <<<"$out"
check "backfill cost: dedupes streamed ids, ignores synthetic, matches dated model" \
  test "$(jq .leg "$COSTLINE_DIR/sessions/s3.json")" = 0.022
check "backfill record uses the transcript folder as project" test "$(jq -r .project "$COSTLINE_DIR/sessions/s3.json")" = "-p-a"
out=$($py backfill 2>&1)
check "second backfill skips recorded sessions" grep -q 'backfilled 0 session' <<<"$out"

echo '{"session_id":"s1","cwd":"/p/a","transcript_path":"'"$root"'/tests/fixtures/projects/-p-a/s3.jsonl"}' | $py hook
check "hook never overwrites a status line record" test "$(jq -r .source "$COSTLINE_DIR/sessions/s1.json")" = statusline
cp "$root/tests/fixtures/projects/-p-a/s3.jsonl" "$tmp/s4.jsonl"
echo '{"session_id":"s4","cwd":"/p/a","transcript_path":"'"$tmp"'/s4.jsonl"}' | $py hook
check "hook records a session the status line never saw" test "$(jq -r .source "$COSTLINE_DIR/sessions/s4.json")" = transcript

mkdir -p "$COSTLINE_DIR/ledger"; cp "$root/tests/fixtures/ledger/-p-legacy.json" "$COSTLINE_DIR/ledger/"
out=$($py migrate)
check "migrate imports legacy ledger" grep -q 'migrated 1 session' <<<"$out"
check "legacy record has the old amount" test "$(jq .leg "$COSTLINE_DIR/sessions/old1.json")" = 1.5

out=$($py report)
check "report lists /p/a with four sessions" grep -qE '^ +1\.54 +4 +/p/a' <<<"$out"
check "report lists /p/legacy" grep -q '/p/legacy' <<<"$out"
check "report total" grep -qE '^ +3\.24 +6 +total' <<<"$out"
out=$($py project /p/a)
check "project command" grep -q '1.54 USD over 4 session' <<<"$out"
out=$($py prices 2>&1)
check "prices lists override and bundled sources" grep -q 'bundled prices.default.json.*overrides' <<<"$out"
check "prices resolves test-model" grep -q '^test-model ' <<<"$out"

rm -rf "$tmp"
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
