#!/usr/bin/env python3
"""costline: per-project Claude Code costs that survive transcript cleanup.

The status line script records the cost Claude Code reports for every session in
$COSTLINE_DIR/sessions/<session_id>.json. This tool reads those records and fills the gaps:

  costline.py report [--json]          every project, most expensive first (default command)
  costline.py project [PATH] [--json]  one project (default: current directory)
  costline.py hook                     SessionEnd hook: prices the ended session from its
                                       transcript if the status line never saw it
  costline.py backfill [--project PATH] [--force]
                                       price transcripts still on disk that have no record
  costline.py prices [--refresh]       show where prices come from and the known models
  costline.py migrate                  import ledgers written by the pre-release version

Pricing is only needed for the transcript based commands (hook, backfill). Prices are USD per
million tokens, layered: bundled prices.default.json < cached LiteLLM community table
< $COSTLINE_DIR/prices.json (your overrides). Set COSTLINE_OFFLINE=1 to never fetch.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
DATA = Path(os.environ.get("COSTLINE_DIR", HOME / ".claude" / "costs"))
SESSIONS = DATA / "sessions"
LEGACY_LEDGER = DATA / "ledger"
PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS_DIR", HOME / ".claude" / "projects"))
PRICES_DEFAULT = Path(__file__).resolve().parent.parent / "prices.default.json"
PRICES_CACHE = DATA / "prices.cache.json"
PRICES_OVERRIDE = DATA / "prices.json"
LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
CACHE_MAX_AGE = 7 * 86400
IGNORED_MODELS = {"<synthetic>"}
FIELDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")


def encode(path):
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    tmp.replace(path)


def warn(msg):
    print(f"costline: {msg}", file=sys.stderr)


# ---------------------------------------------------------------- prices

def litellm_to_prices(table):
    """Convert LiteLLM's per-token table to costline's per-million-token shape."""
    out = {}
    for name, m in table.items():
        if not isinstance(m, dict) or m.get("litellm_provider") != "anthropic":
            continue
        inp = m.get("input_cost_per_token")
        outp = m.get("output_cost_per_token")
        if inp is None or outp is None:
            continue
        key = name.split("/", 1)[1] if name.startswith("anthropic/") else name
        p = {"input": inp * 1e6, "output": outp * 1e6}
        w5 = m.get("cache_creation_input_token_cost")
        w1 = m.get("cache_creation_input_token_cost_above_1hr")
        rd = m.get("cache_read_input_token_cost")
        p["cache_write_5m"] = w5 * 1e6 if w5 is not None else p["input"] * 1.25
        p["cache_write_1h"] = w1 * 1e6 if w1 is not None else p["input"] * 2
        p["cache_read"] = rd * 1e6 if rd is not None else p["input"] * 0.1
        above = m.get("input_cost_per_token_above_200k_tokens")
        if above and inp:
            p["long_context_threshold"] = 200_000
            p["long_context_multiplier"] = above / inp
        out[key] = p
    return out


def fetch_litellm():
    with urllib.request.urlopen(LITELLM_URL, timeout=15) as r:  # noqa: S310 - fixed https URL
        return litellm_to_prices(json.load(r))


def models_only(table):
    """Drop comment keys and anything that is not a price entry."""
    return {k: v for k, v in (table or {}).items() if isinstance(v, dict) and not k.startswith("_")}


def load_prices(refresh=False):
    """Return (prices, sources). Network is used only when the cache is missing or stale."""
    prices, sources = {}, []
    bundled = models_only(read_json(PRICES_DEFAULT))
    if bundled:
        prices.update(bundled)
        sources.append(f"bundled {PRICES_DEFAULT.name}")
    cache = read_json(PRICES_CACHE)
    stale = cache is None or time.time() - PRICES_CACHE.stat().st_mtime > CACHE_MAX_AGE
    if (refresh or stale) and os.environ.get("COSTLINE_OFFLINE") != "1":
        try:
            cache = fetch_litellm()
            write_json(PRICES_CACHE, cache)
        except Exception as e:  # network trouble must never break a hook
            warn(f"could not refresh prices from LiteLLM: {e}")
    if cache:
        prices.update(cache)
        age = int((time.time() - PRICES_CACHE.stat().st_mtime) / 86400) if PRICES_CACHE.exists() else 0
        sources.append(f"LiteLLM community table (cached {age}d ago)")
    override = models_only(read_json(PRICES_OVERRIDE))
    if override:
        prices.update(override)
        sources.append(f"overrides {PRICES_OVERRIDE}")
    return prices, sources


def find_price(prices, model):
    if model in prices:
        return prices[model]
    bare = re.sub(r"-\d{8}$", "", model)          # claude-x-20260101 -> claude-x
    if bare in prices:
        return prices[bare]
    for k in sorted(prices, key=len, reverse=True):  # longest known name that prefixes the model
        if model.startswith(k):
            return prices[k]
    return None


def price_usage(p, usage):
    inp = usage.get("input_tokens") or 0
    cc = usage.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens") or 0
    if w5 is None:  # older transcripts only have the total
        w5 = usage.get("cache_creation_input_tokens") or 0
    rd = usage.get("cache_read_input_tokens") or 0
    out = usage.get("output_tokens") or 0
    mult = 1
    thr = p.get("long_context_threshold")
    if thr and inp + w5 + w1 + rd > thr:
        mult = p.get("long_context_multiplier", 1)
    return (inp * p["input"] + w5 * p["cache_write_5m"] + w1 * p["cache_write_1h"]
            + rd * p["cache_read"] + out * p["output"]) * mult / 1e6


# ---------------------------------------------------------------- transcripts

def price_transcript(path, prices):
    """Price one transcript. Returns dict(usd, unpriced, cwd, model) or None if it has no usage."""
    seen, cwd = {}, None  # message id -> (model, usage); streamed messages repeat, keep the last
    with open(path, errors="replace") as fh:
        for line in fh:
            if cwd is None and '"cwd"' in line:
                try:
                    cwd = json.loads(line).get("cwd")
                except json.JSONDecodeError:
                    pass
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if d.get("type") != "assistant" or not u or m.get("model") in IGNORED_MODELS:
                continue
            seen[m.get("id") or d.get("uuid")] = (m.get("model") or "?", u)
    if not seen:
        return None
    total, unpriced, model = 0.0, {}, None
    for model, u in seen.values():
        p = find_price(prices, model)
        if p is None:
            unpriced[model] = unpriced.get(model, 0) + 1
        else:
            total += price_usage(p, u)
    return {"usd": round(total, 4), "unpriced": unpriced, "cwd": cwd, "model": model}


# ---------------------------------------------------------------- session records

def session_path(sid):
    return SESSIONS / f"{sid}.json"


def load_sessions():
    out = []
    for f in sorted(SESSIONS.glob("*.json")) if SESSIONS.is_dir() else []:
        s = read_json(f)
        if isinstance(s, dict) and s.get("session_id"):
            out.append(s)
    return out


def record_from_transcript(sid, transcript, prices, project_key=None, force=False):
    """Write a session record priced from a transcript. Never replaces a status line record."""
    existing = read_json(session_path(sid))
    if existing and not force:
        return None
    if existing and existing.get("source") == "statusline":
        return None
    r = price_transcript(transcript, prices)
    if r is None:
        return None
    rec = {"session_id": sid, "project": project_key or encode(r["cwd"] or ""),
           "project_dir": r["cwd"] or "", "model": r["model"], "leg": r["usd"], "closed": 0,
           "source": "transcript", "unpriced": r["unpriced"], "updated": int(time.time())}
    write_json(session_path(sid), rec)
    return rec


def summarize(sessions):
    """Group session records by project -> {project_dir, usd, sessions, unpriced}."""
    proj = {}
    for s in sessions:
        p = proj.setdefault(s["project"], {"project_dir": s.get("project_dir") or s["project"],
                                           "usd": 0.0, "sessions": 0, "unpriced": {}})
        p["usd"] += (s.get("leg") or 0) + (s.get("closed") or 0)
        p["sessions"] += 1
        if s.get("project_dir"):
            p["project_dir"] = s["project_dir"]
        for m, n in (s.get("unpriced") or {}).items():
            p["unpriced"][m] = p["unpriced"].get(m, 0) + n
    for p in proj.values():
        p["usd"] = round(p["usd"], 4)
    return proj


def print_table(proj):
    rows = sorted(proj.values(), key=lambda r: -r["usd"])
    print(f"{'USD':>10}  {'sessions':>8}  project")
    for r in rows:
        flag = "  (unpriced: " + ", ".join(sorted(r["unpriced"])) + ")" if r["unpriced"] else ""
        print(f"{r['usd']:>10.2f}  {r['sessions']:>8}  {r['project_dir'].replace(str(HOME), '~')}{flag}")
    print(f"{sum(r['usd'] for r in rows):>10.2f}  {sum(r['sessions'] for r in rows):>8}  total")


# ---------------------------------------------------------------- commands

def cmd_report(a):
    proj = summarize(load_sessions())
    if a.json:
        print(json.dumps(proj, indent=2, sort_keys=True))
    else:
        print_table(proj)


def cmd_project(a):
    path = os.path.abspath(a.path or os.getcwd())
    key = encode(path)
    proj = summarize([s for s in load_sessions() if s["project"] == key])
    r = proj.get(key, {"project_dir": path, "usd": 0.0, "sessions": 0, "unpriced": {}})
    if a.json:
        print(json.dumps(r, indent=2, sort_keys=True))
    else:
        print(f"{r['usd']:.2f} USD over {r['sessions']} session(s) in {r['project_dir']}")


def cmd_hook(a):
    hook = json.load(sys.stdin)
    sid = hook.get("session_id")
    transcript = hook.get("transcript_path")
    if not sid or not transcript or not Path(transcript).exists():
        return
    if read_json(session_path(sid)):
        return  # the status line already recorded it
    os.environ["COSTLINE_OFFLINE"] = "1"  # hooks have a short timeout: use prices on disk, never fetch
    prices, _ = load_prices()
    record_from_transcript(sid, transcript, prices, encode(hook.get("cwd") or ""))


def cmd_backfill(a):
    prices, sources = load_prices()
    folders = [PROJECTS / encode(os.path.abspath(a.project))] if a.project else \
        [f for f in sorted(PROJECTS.iterdir()) if f.is_dir()] if PROJECTS.is_dir() else []
    written, skipped, unpriced = 0, 0, {}
    for folder in folders:
        for t in sorted(folder.glob("*.jsonl")):
            rec = record_from_transcript(t.stem, t, prices, folder.name, a.force)
            if rec is None:
                skipped += 1
                continue
            written += 1
            for m, n in rec["unpriced"].items():
                unpriced[m] = unpriced.get(m, 0) + n
    print(f"backfilled {written} session(s), skipped {skipped} already recorded or empty")
    print("prices: " + ", ".join(sources))
    if unpriced:
        print("unpriced models (add them to %s): %s" % (PRICES_OVERRIDE, ", ".join(sorted(unpriced))))


def cmd_prices(a):
    prices, sources = load_prices(refresh=a.refresh)
    print("sources (later overrides earlier): " + "; ".join(sources))
    print(f"{'model':<40} {'input':>8} {'w5m':>8} {'w1h':>8} {'read':>8} {'output':>8}")
    for m in sorted(prices):
        p = prices[m]
        print(f"{m:<40} " + " ".join(f"{p.get(f, 0):>8.3f}" for f in FIELDS))


def cmd_migrate(a):
    """Import the pre-release ledger format (one file per project, usd per session)."""
    if not LEGACY_LEDGER.is_dir():
        print(f"nothing to migrate: {LEGACY_LEDGER} does not exist")
        return
    n = 0
    for lp in sorted(LEGACY_LEDGER.glob("*.json")):
        led = read_json(lp) or {}
        pdir = led.get("project_dir", "")
        for sid, v in (led.get("sessions") or {}).items():
            if read_json(session_path(sid)):
                continue
            write_json(session_path(sid), {
                "session_id": sid, "project": encode(pdir), "project_dir": pdir, "model": None,
                "leg": v.get("usd", 0), "closed": 0, "source": "legacy",
                "unpriced": v.get("unpriced") or {}, "updated": v.get("updated") or int(time.time())})
            n += 1
    print(f"migrated {n} session(s) from {LEGACY_LEDGER}; the old ledger can be deleted")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="costline", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("report", help="every project, most expensive first")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("project", help="one project (default: current directory)")
    p.add_argument("path", nargs="?")
    p.add_argument("--json", action="store_true")
    sub.add_parser("hook", help="SessionEnd hook (reads hook JSON on stdin)")
    p = sub.add_parser("backfill", help="price transcripts that have no record yet")
    p.add_argument("--project")
    p.add_argument("--force", action="store_true", help="re-price transcript based records too")
    p = sub.add_parser("prices", help="show price sources and known models")
    p.add_argument("--refresh", action="store_true", help="fetch the LiteLLM table now")
    sub.add_parser("migrate", help="import pre-release ledgers")
    a = ap.parse_args(argv)
    {"report": cmd_report, "project": cmd_project, "hook": cmd_hook, "backfill": cmd_backfill,
     "prices": cmd_prices, "migrate": cmd_migrate, None: cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
