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


TAG_NAME = {0x80: "green-IBI", 0x60: "ibi+amp", 0x6E: "spo2-IBI", 0x44: "ibi(0x44)"}

# Human labels for the outer op / event tag seen in the RAW capture (superset of TAG_NAME — includes tags
# NOOP decodes but the IBI corpus doesn't carry). Anything absent here prints as "?" so unknown tags surface.
RAW_TAG_NAME = {**TAG_NAME,
    0x50: "activity/MET", 0x47: "motion", 0x46: "temp", 0x49: "sleep-summary",
    0x4E: "sleep-phase", 0x5A: "sleep-phase", 0x42: "time-anchor",
}


def find_raw(explicit):
    if explicit:
        return explicit
    diag = os.path.join(STAGING, "Diagnostics")
    hits = [os.path.join(diag, f) for f in os.listdir(diag)
            if f.startswith("oura-raw-") and f.endswith(".jsonl")] if os.path.isdir(diag) else []
    return max(hits, key=os.path.getmtime) if hits else None  # newest ring, or None


def reframe_raw(path, day=None):
    """Walk the RAW capture OFFLINE: each line's `hex` is one or more packed `op,len,body` TLV records.
    Returns (per_tag_count, per_tag_minutes, n_lines, n_records, first_iso, last_iso, malformed).
    `per_tag_minutes` keys tags to the set of UTC minutes their records arrived, for the decode-gap check.
    Ring-time isn't in the raw frame (it's inside each body, tag-specific), so we bucket by ARRIVAL utc —
    good enough to answer 'did a record of tag X arrive in this minute?' which is the drop question."""
    from collections import defaultdict
    counts, minutes = defaultdict(int), defaultdict(set)
    n_lines = n_records = malformed = 0
    first_iso = last_iso = None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            iso = rec.get("iso", "")
            if day and not iso.startswith(day):
                continue
            n_lines += 1
            first_iso = first_iso or iso
            last_iso = iso
            minute = rec["utc"] // 60
            hexs = rec.get("hex", "")
            b = bytes.fromhex(hexs) if hexs else b""
            i = 0
            while i + 2 <= len(b):
                op, ln = b[i], b[i + 1]
                if i + 2 + ln > len(b):
                    malformed += 1
                    break
                counts[op] += 1
                minutes[op].add(minute)
                n_records += 1
                i += 2 + ln
            if i != len(b) and i + 2 > len(b) and len(b) - i:
                malformed += 1
    return counts, minutes, n_lines, n_records, first_iso, last_iso, malformed


def load_ibihr(day):
    """Load the banked-IBI corpus (oura-ibihr-*.jsonl). Returns (records, filename) or ([], None)."""
    diag = os.path.join(STAGING, "Diagnostics")
    hits = [os.path.join(diag, f) for f in os.listdir(diag)
            if f.startswith("oura-ibihr-") and f.endswith(".jsonl")] if os.path.isdir(diag) else []
    if not hits:
        return [], None
    path = max(hits, key=os.path.getmtime)
    recs = []
    with open(path) as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            if day and not r["iso"].startswith(day):
                continue
            recs.append(r)
    return recs, os.path.basename(path)


def ibihr_per_min(recs, tags=None):
    """{utc_minute: [bpm,...]} from records, HR = 60000/ibiMs gated to 30-220 bpm. Optional tag filter."""
    from collections import defaultdict
    per = defaultdict(list)
    for r in recs:
        if tags is not None and r.get("tag") not in tags:
            continue
        for ibi in r.get("ibiMs", []):
            if ibi <= 0:
                continue
            bpm = round(60000 / ibi)
            if 30 <= bpm <= 220:
                per[int(r["utc"] // 60)].append(bpm)
    return per


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


def suunto_hr_per_min(path):
    """{utc_minute: mean HR bpm} from a Suunto DeviceLog JSON (HR stored in Hz on some exports → ×60)."""
    from collections import defaultdict
    d = json.load(open(path))["DeviceLog"]
    per = defaultdict(list)
    for s in d["Samples"]:
        if not isinstance(s, dict) or "TimeISO8601" not in s or s.get("HR") is None:
            continue
        hr = s["HR"]
        per[int(datetime.fromisoformat(s["TimeISO8601"]).timestamp() // 60)].append(hr * 60 if hr < 10 else hr)
    return {m: sum(v) / len(v) for m, v in per.items()}


def suunto_profile(samples, path):
    """Oura MET vs a Suunto ground-truth profile, per minute, over the recorded session.

    Turns the single mean/p50 into a WITHIN-session tracking check: does MET rise and fall WITH the
    watch's speed? `samples` = the Oura MET (utc, met, state) list; `path` = a Suunto DeviceLog JSON.
    Suunto stores HR in Hz on some exports (< 10) — converted to bpm for display; the correlation is
    MET-vs-speed and does not depend on that. Prints one row per minute + Pearson r over the overlap.
    """
    from collections import defaultdict
    d = json.load(open(path))["DeviceLog"]
    hdr = d["Header"]

    def ep(iso):  # ISO8601 with offset (e.g. +02:00) → UTC epoch
        return datetime.fromisoformat(iso).timestamp()

    su = defaultdict(lambda: {"hr": [], "spd": []})
    for s in d["Samples"]:
        if not isinstance(s, dict) or "TimeISO8601" not in s:
            continue
        m = int(ep(s["TimeISO8601"]) // 60)
        hr = s.get("HR")
        if hr is not None:
            su[m]["hr"].append(hr * 60 if hr < 10 else hr)
        if s.get("Speed") is not None:
            su[m]["spd"].append(s["Speed"])

    met = defaultdict(list)
    for (t, mv, _s) in samples:
        met[int(t // 60)].append(mv)

    start = int(ep(hdr["DateTime"]) // 60)
    dur = int((hdr.get("Duration") or 0) // 60)
    act = {12: "Walking"}.get(hdr.get("ActivityType"), f"activity {hdr.get('ActivityType')}")
    kcal = round((hdr.get("Energy") or 0) / 4184)
    print(f"\n== Oura MET vs Suunto profile — {act}, {hdr.get('StepCount')} steps, "
          f"{hdr.get('Distance')} m, {kcal} kcal ==")
    print("  min(UTC)     | Suunto HR  km/h | Oura MET")
    xs, ys = [], []
    for m in range(start, start + dur + 2):
        s_, o_ = su.get(m), met.get(m)
        hr = f"{sum(s_['hr'])/len(s_['hr']):.0f}" if s_ and s_["hr"] else "-"
        spd = f"{3.6*sum(s_['spd'])/len(s_['spd']):.1f}" if s_ and s_["spd"] else "-"
        mt = f"{sum(o_)/len(o_):.2f}" if o_ else "-"
        print(f"  {u(m*60)}  |   {hr:>3}    {spd:>4} |  {mt}")
        if s_ and s_["spd"] and o_:
            xs.append(sum(s_["spd"]) / len(s_["spd"])); ys.append(sum(o_) / len(o_))
    if len(xs) > 2:
        n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
        cov = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
        vx = sum((a - mx) ** 2 for a in xs) ** .5
        vy = sum((b - my) ** 2 for b in ys) ** .5
        r = cov / (vx * vy) if vx and vy else float("nan")
        print(f"\n  MET vs Suunto-speed per-minute correlation r = {r:.2f}  (n={n} min)")
    else:
        print("  (not enough overlapping minutes for a correlation)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jsonl", help="MET corpus JSONL (default: newest in staging Diagnostics)")
    ap.add_argument("--db", help="app SQLite (default: staging whoop.sqlite)")
    ap.add_argument("--day", help="restrict to one UTC day, e.g. 2026-07-14 (default: whole corpus)")
    ap.add_argument("--suunto", help="a Suunto DeviceLog JSON export (a .fit-source walk/run/ride): "
                                     "prints Oura MET vs its per-minute speed/HR profile + correlation r")
    ap.add_argument("--raw", nargs="?", const="auto", help="reframe the RAW capture (oura-raw-<id>.jsonl): "
                    "TLV tag histogram + decode-drop cross-check. Bare flag = newest in staging Diagnostics")
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

    print("\n== Oura IBI-derived HR (reconstructed from banked IBIs, HR = 60000/ibi) ==")
    ibirecs, hrfile = load_ibihr(a.day)
    hrmin = ibihr_per_min(ibirecs)
    if not hrmin:
        print("  (no IBI-HR corpus yet — run the combined-branch build and re-sync to populate it)")
    else:
        def med(xs):
            xs = sorted(xs); return xs[len(xs) // 2]
        allb = [b for v in hrmin.values() for b in v]
        print(f"  corpus: {hrfile}  {len(hrmin)} min with beats, {len(allb)} beats"
              + (f", day={a.day}" if a.day else ""))
        # Per-tag breakdown — WHICH history stream is clean vs noisy (the point of the tag label).
        from collections import defaultdict
        tag_beats, tag_arts = defaultdict(int), defaultdict(int)
        for r in ibirecs:
            for ibi in r.get("ibiMs", []):
                t = r.get("tag")
                tag_beats[t] += 1
                if ibi <= 0 or not (30 <= round(60000 / ibi) <= 220):
                    tag_arts[t] += 1
        print("  by source tag:")
        for t in sorted(tag_beats, key=lambda x: (x is None, x)):
            per_t = ibihr_per_min(ibirecs, tags={t})
            kept = [b for v in per_t.values() for b in v]
            art = 100 * tag_arts[t] / tag_beats[t] if tag_beats[t] else 0
            label = "0x%02X %-10s" % (t, TAG_NAME.get(t, "?")) if isinstance(t, int) else "untagged(old)   "
            mstr = f"median HR={med(kept)}" if kept else "no valid HR"
            print(f"    {label}: {tag_beats[t]:4d} beats, {art:2.0f}% artifact, {len(per_t)} min, {mstr}")
        for sport, source, s, e, strain, avg, mx, kcal in wk:
            mins = [m for m in hrmin if s // 60 <= m < (e + 59) // 60]
            bpms = [b for m in mins for b in hrmin[m]]
            if bpms:
                extra = f"  (watch avgHR={avg})" if avg else ""
                print(f"  {sport:9s} {u(s)}-{u(e)}: Oura-IBI HR median={med(bpms)} "
                      f"n={len(bpms)} beats / {len(mins)} min{extra}")
            else:
                print(f"  {sport:9s} {u(s)}-{u(e)}: no IBI beats in window (motion gap?)")
        if a.suunto:
            sh = suunto_hr_per_min(a.suunto)
            pairs = [(sum(hrmin[m]) / len(hrmin[m]), sh[m]) for m in hrmin if m in sh]
            if len(pairs) > 2:
                xs = [p[0] for p in pairs]; ys = [p[1] for p in pairs]
                n = len(xs); mx_ = sum(xs) / n; my = sum(ys) / n
                cov = sum((x - mx_) * (y - my) for x, y in pairs)
                vx = sum((x - mx_) ** 2 for x in xs) ** .5
                vy = sum((y - my) ** 2 for y in ys) ** .5
                r = cov / (vx * vy) if vx and vy else float("nan")
                print(f"  Oura-IBI HR vs Suunto HR per-minute r = {r:.2f} (n={n} min) "
                      f"— the real test: does ring HR match the watch?")

    print("\n== dynamic range: sleep floor vs active (tracks a VARYING input?) ==")
    for dev, s, e in sleep_windows(db, lo, hi):
        tag = "oura" if dev.startswith("oura-") and dev != "oura-import" else dev.split("-")[0]
        print(f"  sleep[{tag:11s}] {u(s)}-{u(e)}: {band(samples, s, e)}")

    if a.suunto:
        suunto_profile(samples, a.suunto)

    if a.raw is not None:
        raw = None if a.raw == "auto" else a.raw
        raw = find_raw(raw)
        print("\n== RAW capture: TLV tags actually received (decode-drop vs ring-side) ==")
        if not raw or not os.path.exists(raw):
            print("  (no raw capture yet — run the combined-branch build and re-sync to populate it)")
        else:
            counts, rawmin, nl, nr, f_iso, l_iso, bad = reframe_raw(raw, a.day)
            print(f"  corpus: {os.path.basename(raw)}  {nl} notifications, {nr} TLV records"
                  + (f", day={a.day}" if a.day else ""))
            if f_iso:
                print(f"        span: {f_iso} → {l_iso}" + (f"   malformed frames: {bad}" if bad else ""))
            # MET (0x50) minutes present in RAW but absent from the DECODED MET corpus = a decode drop we
            # can now name; both absent = the ring genuinely didn't send them. This is the whole point.
            met_min_decoded = {s[0] // 60 for s in samples}
            met_raw = rawmin.get(0x50, set())
            drop = sorted(m for m in met_raw if m not in met_min_decoded)
            for op in sorted(counts):
                label = "0x%02X %-13s" % (op, RAW_TAG_NAME.get(op, "?"))
                print(f"    {label}: {counts[op]:5d} records, {len(rawmin[op])} min")
            if met_raw:
                print(f"  MET decode-drop check: {len(met_raw)} raw-MET minutes, "
                      f"{len(drop)} present in RAW but MISSING from decoded corpus"
                      + (f" (e.g. {u(drop[0]*60)}…)" if drop else " — no drops, holes are ring-side"))

    print("\n== coverage / gaps (uncovered minutes = undercount in any daily total) ==")
    coverage(recs)
    print("\nNote: MET reads near-rest during swims/water (ring PPG+motion degraded) — exclude those windows.")


if __name__ == "__main__":
    main()
