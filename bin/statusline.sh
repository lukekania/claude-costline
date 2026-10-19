#!/bin/bash
# costline: Claude Code status line with a per-project cost ledger.
#
# Reads the status line JSON Claude Code pipes in, prints one styled line and records the session
# cost Claude Code itself reports (cost.total_cost_usd) in $COSTLINE_DIR/sessions/<session_id>.json.
# Those records are what make project totals survive Claude Code's transcript cleanup.
#
# Line: model | directory | git branch (+worktree) | context used | session cost (+ project total) | duration
#
# Environment:
#   COSTLINE_DIR    data directory, default ~/.claude/costs
#   COSTLINE_ASCII  set to 1 for plain labels instead of Nerd Font icons
export LC_ALL=C   # dot decimal separator for printf regardless of the user locale
data="${COSTLINE_DIR:-$HOME/.claude/costs}"
sessions="$data/sessions"
input=$(cat)

IFS=$'\x1f' read -r model dir projdir wt pct cost ms sid < <(printf '%s' "$input" | jq -r '[
  (.model.display_name // "?"),
  (.workspace.current_dir // .cwd // ""),
  (.workspace.project_dir // .cwd // .workspace.current_dir // ""),
  (.workspace.git_worktree // ""),
  (.context_window.used_percentage // 0 | floor),
  (.cost.total_cost_usd // 0),
  (.cost.total_duration_ms // 0),
  (.session_id // "")
] | map(tostring) | join("\u001f")')
projkey=$(printf '%s' "$projdir" | sed 's/[^A-Za-z0-9]/-/g')

# Record this session's cost. Claude Code restarts its counter when a session is resumed, so a
# figure lower than the last one closes the previous "leg" and keeps its total.
record_cost() {
  [ -n "$sid" ] && mkdir -p "$sessions" 2>/dev/null || return 0
  local file="$sessions/$sid.json" old=null new
  [ -r "$file" ] && old=$(cat "$file" 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$old" || old=null
  new=$(jq -nc --argjson old "$old" --argjson cost "$cost" --arg sid "$sid" --arg project "$projkey" \
           --arg project_dir "$projdir" --arg model "$model" '
    ($old.leg // 0) as $leg | ($old.closed // 0) as $closed
    | {session_id: $sid, project: $project, project_dir: $project_dir, model: $model,
       leg: $cost,
       closed: (if $cost < $leg - 0.00001 then $closed + $leg else $closed end),
       source: "statusline", updated: (now | floor),
       changed: ($old == null or $old.leg != $cost)}' 2>/dev/null) || return 0
  [ "$(jq -r .changed <<<"$new")" = true ] || return 0
  jq 'del(.changed)' <<<"$new" > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file"
}
record_cost

# Total of the other recorded sessions of this project: "<count>\x1f<usd>"
others="0"$'\x1f'"0"
if [ -n "$sid" ] && [ -d "$sessions" ]; then
  files=("$sessions"/*.json)
  if [ -e "${files[0]}" ]; then
    others=$(jq -rs --arg p "$projkey" --arg s "$sid" '
      [.[] | select(.project == $p and .session_id != $s) | (.leg // 0) + (.closed // 0)]
      | [length, (add // 0)] | map(tostring) | join("\u001f")' "${files[@]}" 2>/dev/null) || others="0"$'\x1f'"0"
  fi
fi
IFS=$'\x1f' read -r ocount ototal <<<"$others"
mine=$(jq -n --argjson c "$cost" --argjson f "$(cat "$sessions/$sid.json" 2>/dev/null || echo null)" '$c + ($f.closed // 0)')

if [ "${COSTLINE_ASCII:-0}" = 1 ]; then
  i_model="AI" i_dir="dir" i_git="git" i_ctx="ctx" i_cost="cost" i_time="t" bar="|" dot="/"
else
  i_model="󰚩" i_dir="" i_git="" i_ctx="" i_cost="" i_time="" bar="│" dot="·"
fi
c() { printf '\033[38;2;%sm' "$1"; }   # 24-bit colour from "r;g;b" (GitHub Dark palette)
blue=$(c "88;166;255"); purple=$(c "188;140;255"); green=$(c "63;185;80")
amber=$(c "210;153;34"); red=$(c "248;81;73"); text=$(c "201;209;217"); dim=$(c "139;148;158")
reset=$'\033[0m'; sep="  ${dim}${bar}${reset}  "

branch=""
if [ -n "$dir" ] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
fi
short="${dir/#$HOME/~}"

if   [ "$pct" -ge 80 ]; then ctxcol=$red
elif [ "$pct" -ge 50 ]; then ctxcol=$amber
else ctxcol=$green; fi

mins=$(( ms / 60000 ))
if [ "$mins" -ge 60 ]; then dur="$(( mins / 60 ))h $(( mins % 60 ))m"; else dur="${mins}m"; fi
costfmt=$(printf '$%.2f' "$cost")
projfmt=""
if [ "${ocount:-0}" -gt 0 ]; then
  projfmt=$(printf '$%.2f' "$(jq -n --argjson a "$ototal" --argjson b "$mine" '$a + $b')")
fi

out="${blue}${i_model} ${model}${reset}"
out="$out${sep}${text}${i_dir} ${short}${reset}"
[ -n "$branch" ] && out="$out${sep}${purple}${i_git} ${branch}${reset}"
[ -n "$wt" ] && out="$out ${dim}(wt:${wt})${reset}"
out="$out${sep}${ctxcol}${i_ctx} ${pct}%${reset}"
out="$out${sep}${green}${i_cost} ${costfmt}${reset}"
[ -n "$projfmt" ] && out="$out ${dim}${dot} proj ${projfmt}${reset}"
out="$out${sep}${dim}${i_time} ${dur}${reset}"
printf '%s' "$out"
