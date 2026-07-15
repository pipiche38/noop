#!/usr/bin/env python3
"""Cross-check the Oura Tier-B MET research corpus against NOOP's stored workouts.

WHAT IT READS (not the strap text log — the two files the app already writes):
  1. the JSONL MET corpus  `.../OpenWhoop/Diagnostics/oura-activity-<deviceId>.jsonl`
     (one anchored 0x50 record per line: {schema,deviceId,ringTs,utc,iso,state,secPerSample,met[]})
  2. the app SQLite         `.../OpenWhoop/whoop.sqlite`   (its `workout` + `sleepSession` tables)

Both are inside the staging app's container; the defaults below point there. Override with
--jsonl / --db for a different install (e.g. the release container or a copy you AirDropped off a phone).

WHY: the MET stream is Tier-B instrumentation with no slot in NOOP's HR/strain workout model, so it is
never scored. This script is how we judge it OFFLINE — does MET elevate during the HR-scored workouts NOOP
DID record, and how gappy is the corpus (day totals undercount by exactly the uncovered minutes)?

USAGE
  python3 diagnostics/oura_met_crosscheck.py                 # auto-locate staging corpus + db, all dates
  python3 diagnostics/oura_met_crosscheck.py --day 2026-07-14
  python3 diagnostics/oura_met_crosscheck.py --jsonl a.jsonl --db whoop.sqlite

All times printed in UTC (the corpus `iso` and the DB epochs are both UTC).
"""
import argparse, json, os, sqlite3, sys
from datetime import datetime, timezone, date

STAGING = os.path.expanduser(
    "~/Library/Containers/com.noopapp.noop.staging/Data/Library/Application Support/OpenWhoop")


def u(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%m-%d %H:%M")


def find_jsonl(explicit):
    if explicit:
        return explicit
    diag = os.path.join(STAGING, "Diagnostics")
    hits = [os.path.join(diag, f) for f in os.listdir(diag)
            if f.startswith("oura-activity-") and f.endswith(".jsonl")] if os.path.isdir(diag) else []
    if not hits:
        sys.exit(f"no MET corpus found under {diag} — pass --jsonl")
    return max(hits, key=os.path.getmtime)  # newest ring


def load_samples(path, day):
    """Return (samples, records). samples = sorted [(utc, met, state)]; one entry per MET value,
    sample i of a record placed at record.utc + i*secPerSample (utc is the window START)."""
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if day and not r["iso"].startswith(day):
                continue
            recs.append(r)
    samples = []
    for r in recs:
        sps = r["secPerSample"]
        for i, m in enumerate(r["met"]):
            samples.append((r["utc"] + i * sps, m, r["state"]))
    samples.sort()
    return samples, recs


def met_in(samples, lo, hi):
    return [m for (t, m, _s) in samples if lo <= t < hi]


def band(samples, lo, hi):
    xs = met_in(samples, lo, hi)
    if not xs:
        return "n=0 (no MET coverage)"
    xs2 = sorted(xs)
    return (f"n={len(xs):3d} mean={sum(xs)/len(xs):.2f} max={max(xs):.1f} "
            f"p50={xs2[len(xs2)//2]:.1f}  ≥ 3MET={sum(1 for m in xs if m >= 3)}min")


def coverage(recs):
    """Print contiguous coverage segments (gap > 5 min starts a new one) and the overall %."""
    if not recs:
        print("  (empty corpus)"); return
    segs, seg_start, prev_end = [], None, None
    for r in recs:
        start = r["utc"]; end = r["utc"] + len(r["met"]) * r["secPerSample"]
        if prev_end is None:
            seg_start = start
        elif start - prev_end > 300:
            segs.append((seg_start, prev_end, start - prev_end))
            seg_start = start
        prev_end = end
    segs.append((seg_start, prev_end, 0))
    covered = sum(len(r["met"]) * r["secPerSample"] for r in recs)
    span = recs[-1]["utc"] + len(recs[-1]["met"]) * recs[-1]["secPerSample"] - recs[0]["utc"]
    for s, e, gap in segs:
        tail = f"   [then GAP {gap//60} min]" if gap else ""
        print(f"  {u(s)} → {u(e)}  ({(e-s)//60:4d} min){tail}")
    print(f"\n  covered {covered//60} min over a {span//60}-min span "
          f"→ {100*covered/span:.0f}% coverage (remainder = ring cadence / connection gaps)")


def workouts(db, lo, hi):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT sport, source, startTs, endTs, strain, avgHr, maxHr, energyKcal "
        "FROM workout WHERE endTs>=? AND startTs<? ORDER BY startTs", (lo, hi)).fetchall()
    con.close()
    # Dedup to one window per (sport, rounded-start): prefer the HR-bearing source over apple-health.
    best = {}
    for sport, source, s, e, strain, avg, mx, kcal in rows:
        key = (sport, s // 60)
        pri = 0 if source in ("whoop", "activity-file") else 1
        if key not in best or pri < best[key][0]:
            best[key] = (pri, sport, source, s, e, strain, avg, mx, kcal)
    return [v[1:] for v in sorted(best.values(), key=lambda v: v[3])]


def sleep_windows(db, lo, hi):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT deviceId, startTs, endTs FROM sleepSession WHERE endTs>=? AND startTs<? "
        "ORDER BY startTs", (lo, hi)).fetchall()
    con.close()
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jsonl", help="MET corpus JSONL (default: newest in staging Diagnostics)")
    ap.add_argument("--db", help="app SQLite (default: staging whoop.sqlite)")
    ap.add_argument("--day", help="restrict to one UTC day, e.g. 2026-07-14 (default: whole corpus)")
    a = ap.parse_args()

    jsonl = find_jsonl(a.jsonl)
    db = a.db or os.path.join(STAGING, "whoop.sqlite")
    for p in (jsonl, db):
        if not os.path.exists(p):
            sys.exit(f"missing: {p}")

    samples, recs = load_samples(jsonl, a.day)
    print(f"corpus: {os.path.basename(jsonl)}")
    print(f"        {len(recs)} records, {len(samples)} MET-minutes"
          + (f", day={a.day}" if a.day else "") )
    if not samples:
        sys.exit("no samples (wrong --day?)")
    ring = {r["ringTs"] for r in recs}
    print(f"        dup ringTs: {len(recs)-len(ring)}   span: {recs[0]['iso']} → {recs[-1]['iso']}")

    lo, hi = samples[0][0] - 3600, samples[-1][0] + 3600

    print("\n== MET during NOOP-recorded workouts (exact DB epochs) ==")
    wk = workouts(db, lo, hi)
    if not wk:
        print("  (no workouts in range)")
    for sport, source, s, e, strain, avg, mx, kcal in wk:
        sc = f"strain={strain:.1f} " if strain else ""
        hr = f"avgHR={avg} " if avg else ""
        print(f"  {sport:9s}[{source:13s}] {u(s)}-{u(e)}  {sc}{hr}\n"
              f"     Oura MET: {band(samples, s, e)}")

    print("\n== dynamic range: sleep floor vs active (tracks a VARYING input?) ==")
    for dev, s, e in sleep_windows(db, lo, hi):
        tag = "oura" if dev.startswith("oura-") and dev != "oura-import" else dev.split("-")[0]
        print(f"  sleep[{tag:11s}] {u(s)}-{u(e)}: {band(samples, s, e)}")

    print("\n== coverage / gaps (uncovered minutes = undercount in any daily total) ==")
    coverage(recs)
    print("\nNote: MET reads near-rest during swims/water (ring PPG+motion degraded) — exclude those windows.")


if __name__ == "__main__":
    main()
