# costline

A status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that keeps a
**per-project cost ledger which survives transcript cleanup**.

```
󰚩 Fable 5.1  │   ~/Coding/Private/weyloo  │   main  │   31%  │   $1.23 · proj $45.52  │   1h 30m
```

Claude Code prices every session itself and shows the figure in `/cost`, but it only remembers
what is still in `~/.claude/projects`, and those transcripts are deleted after 30 days
(`cleanupPeriodDays`). costline writes the figure Claude Code reports into a small JSON record per
session, so "what did this project cost me so far" has an answer months later, for every project,
with no price table to maintain.

- **No pricing logic in the hot path.** The status line stores `cost.total_cost_usd` as Claude Code
  computes it. New models work on day one.
- **Project total in the status line.** `proj $45.52` is this project across all recorded sessions,
  including the one you are in.
- **Report.** `costline report` lists every project, most expensive first.
- **Backfill.** Sessions the status line never saw (headless `claude -p`, sessions from before the
  install) are priced from their transcripts with a JSON price table: bundled defaults, the
  community table maintained by [LiteLLM](https://github.com/BerriAI/litellm), and your own overrides.
- **Dependencies:** bash, jq, python3, git. A [Nerd Font](https://www.nerdfonts.com/) for the icons,
  or `--ascii`.

The figures are API list prices. On a subscription they tell you what the usage would have cost,
not what you were billed.

## Install

```sh
git clone https://github.com/lukekania/claude-costline.git
cd claude-costline
./install.sh            # add --ascii if your terminal font has no Nerd Font glyphs
```

The installer copies the scripts to `~/.claude/costline`, backs up `~/.claude/settings.json` to
`~/.claude/backups/`, sets `statusLine` and adds a `SessionEnd` hook (see
`examples/settings.snippet.json` for what it writes), then prices the transcripts you still have.
If you already use a status line, it stops and asks you to re-run with `--force`.

Start a new Claude Code session and the line appears. `./uninstall.sh` reverts the settings and
removes the scripts, keeping your data.

## Usage

```sh
costline=~/.claude/costline/bin/costline.py
python3 $costline report              # every project
python3 $costline project             # the project in the current directory
python3 $costline backfill            # price transcripts that have no record yet
python3 $costline prices --refresh    # refresh the LiteLLM table and show effective prices
```

Data lives in `~/.claude/costs` (override with `COSTLINE_DIR`):

| Path | What |
| --- | --- |
| `sessions/<session_id>.json` | one record per session: project, cost, source (`statusline`, `transcript`, `legacy`) |
| `prices.json` | your price overrides, USD per million tokens, same shape as `prices.default.json` |
| `prices.cache.json` | the converted LiteLLM table, refreshed when older than 7 days |

A resumed session makes Claude Code restart its counter. The status line notices the drop, keeps
the previous leg's total in `closed` and continues, so nothing is double counted or lost.

Projects are keyed the way Claude Code keys them: by the directory Claude Code was started in.
A git worktree or a subdirectory is therefore its own project, exactly as in `~/.claude/projects`.

## Pricing for backfill

Only `backfill` and the `SessionEnd` hook need prices. They are layered, later wins:

1. `prices.default.json`, shipped with costline
2. the LiteLLM community table, fetched on demand and cached (`COSTLINE_OFFLINE=1` disables fetching;
   the hook never fetches)
3. `~/.claude/costs/prices.json`, yours

Models that match no entry are counted as `unpriced` on the record and listed by `report`, so a
gap is visible instead of silently zero. Add the model to `prices.json` and run
`backfill --force` to re-price.

## Development

```sh
make test          # shellcheck, py_compile, and tests/run.sh (offline, temp data dir)
make install-dev   # symlink ~/.claude/costline to this checkout
```

## Status

It depends on Claude Code internals that are not a stable API: the status line JSON, the hook
payload, the transcript format and the project folder naming. These have been stable for a while
but may change in a release; issues welcome.

## License

MIT
