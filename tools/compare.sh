#!/usr/bin/env bash
# =============================================================================
# tools/compare.sh — before/after analysis for one benchmark.
#
# Usage: ./tools/compare.sh <bench> [baseline_run_dir] [optimized_run_dir]
#        Defaults to the results/latest_<bench>_{baseline,optimized} symlinks.
#
# Produces:
#   results/comparison_<bench>_<ts>/
#     summary.txt            headline speedup + counter deltas + verdict
#     counters.txt           side-by-side perf stat comparison
#     symbols_delta.txt      which functions got cheaper/vanished
#     diff_flame.svg         DIFFERENTIAL flame graph (red = worse, blue = better)
#     diff_flame_inv.svg     reverse-direction differential
#
# The differential flame graph is the single most persuasive artifact for the
# "show your performance improvement" deliverable: it renders exactly which
# stacks lost time, rather than asking the reader to eyeball two SVGs.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

BENCH="${1:?usage: compare.sh <bench> [baseline_dir] [optimized_dir]}"
BASE_DIR="${2:-$RESULTS_DIR/latest_${BENCH}_baseline}"
OPT_DIR="${3:-$RESULTS_DIR/latest_${BENCH}_optimized}"

[[ -d "$BASE_DIR" ]] || die "no baseline run found at $BASE_DIR
Run: ./script_${BENCH}.sh --variant baseline"
[[ -d "$OPT_DIR"  ]] || die "no optimized run found at $OPT_DIR
Run: ./script_${BENCH}.sh --variant optimized"

OUT="$RESULTS_DIR/comparison_${BENCH}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
ln -sfn "$OUT" "$RESULTS_DIR/latest_comparison_${BENCH}"

hdr "comparing $BENCH: baseline vs optimized"
log "baseline : $(readlink -f "$BASE_DIR" 2>/dev/null || echo "$BASE_DIR")"
log "optimized: $(readlink -f "$OPT_DIR"  2>/dev/null || echo "$OPT_DIR")"

# -----------------------------------------------------------------------------
# 1. Headline speedup — from the UNPROFILED clean-timing CSVs only.
# -----------------------------------------------------------------------------
export CMP_OUT="$OUT"
SUMMARY="$OUT/summary.txt"
"$PY_REL" - "$BENCH" "$BASE_DIR" "$OPT_DIR" > "$SUMMARY" 2>&1 <<'PY' || warn "summary generation had problems"
import csv, os, statistics, sys

bench, base_dir, opt_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def read_loops(d):
    """
    Loop count for this run. CRITICAL: each variant is calibrated INDEPENDENTLY
    to hit TARGET_SEC, so baseline and optimized routinely run different amounts
    of work per process (observed: raytrace 16 vs 32 frames). Comparing raw
    total_sec across unequal work is meaningless.
    """
    p = os.path.join(d, "timing", "loops.txt")
    try:
        n = int(open(p).read().strip())
        return n if n > 0 else 1
    except Exception:
        return None

def load(d, variant):
    """
    Per-unit times from the clean (unprofiled) CSV: total_sec / loops.
    Returns (values, loops, raw_totals).
    """
    p = os.path.join(d, "timing", f"clean_{variant}.csv")
    if not os.path.exists(p):
        return [], None, []
    raw = []
    with open(p) as fh:
        for row in csv.DictReader(fh):
            try:
                raw.append(float(row["total_sec"]))
            except (ValueError, KeyError):
                pass
    loops = read_loops(d)
    if loops is None:
        # Refuse to guess. An unnormalized comparison is worse than none.
        return [], None, raw
    return [v / loops for v in raw], loops, raw

b, b_loops, b_raw = load(base_dir, "baseline")
o, o_loops, o_raw = load(opt_dir, "optimized")

# Hand the loop counts back to the shell so the counter section can normalize
# by the same values. Without this the counters would repeat the exact bug the
# timing section was fixed for.
with open(os.path.join(os.environ.get("CMP_OUT", "/tmp"), "loops.env"), "w") as fh:
    fh.write(f"B_LOOPS={b_loops or 0}\nO_LOOPS={o_loops or 0}\n")

W = 74
print("=" * W)
print(f" PERFORMANCE COMPARISON — {bench}".center(W))
print("=" * W)
print()
print("Source: clean-timing phase only (no profiler attached).")
print("Statistic: MEDIAN of independent processes — robust to host hiccups.")
print()

if not b or not o:
    print("!! CANNOT PRODUCE A VALID COMPARISON")
    print(f"   baseline  usable samples: {len(b)}  (raw rows: {len(b_raw)}, loops: {b_loops})")
    print(f"   optimized usable samples: {len(o)}  (raw rows: {len(o_raw)}, loops: {o_loops})")
    if (b_raw and b_loops is None) or (o_raw and o_loops is None):
        print()
        print("   Timing data exists but timing/loops.txt is missing, so the work")
        print("   per process is unknown. Comparing raw totals across independently")
        print("   calibrated runs would be invalid, so no speedup is reported.")
        print("   Re-run the affected variant, or set LOOPS=N to fix work explicitly.")
    raise SystemExit(0)

print(f"Work per process : baseline {b_loops} unit(s), optimized {o_loops} unit(s)")
if b_loops != o_loops:
    print(f"  NOTE: loop counts DIFFER ({b_loops} vs {o_loops}) because each variant")
    print( "  was calibrated independently. All figures below are PER UNIT OF WORK")
    print( "  (total_sec / loops), which is the only valid basis for comparison.")
else:
    print("  Loop counts match; figures below are per unit of work.")
print(f"Raw process medians: baseline {statistics.median(b_raw):.6f} s, "
      f"optimized {statistics.median(o_raw):.6f} s  <- NOT comparable directly")
print()

def stats(v):
    m = statistics.mean(v)
    sd = statistics.stdev(v) if len(v) > 1 else 0.0
    return {
        "n": len(v), "min": min(v), "median": statistics.median(v),
        "mean": m, "max": max(v), "sd": sd, "rel_sd": (sd / m * 100 if m else 0.0),
    }

sb, so = stats(b), stats(o)
print(f"{'metric':<14}{'baseline':>16}{'optimized':>16}{'delta':>16}")
print("-" * W)
for k, label, unit in (("n", "samples", ""), ("min", "min/unit", " s"),
                       ("median", "median/unit", " s"), ("mean", "mean/unit", " s"),
                       ("max", "max/unit", " s"), ("sd", "stdev", " s"),
                       ("rel_sd", "rel stdev", " %")):
    vb, vo = sb[k], so[k]
    if k == "n":
        print(f"{label:<14}{vb:>16d}{vo:>16d}{'':>16}")
    elif k == "rel_sd":
        print(f"{label:<14}{vb:>15.2f}%{vo:>15.2f}%{'':>16}")
    else:
        d = vo - vb
        print(f"{label:<14}{vb:>14.6f}{unit}{vo:>14.6f}{unit}{d:>+14.6f}{unit}")

print()
print("=" * W)
mb, mo = sb["median"], so["median"]
speedup = mb / mo if mo else float("inf")
improvement = (1 - mo / mb) * 100 if mb else 0.0
noise = max(sb["rel_sd"], so["rel_sd"])
solid = improvement >= 2 * noise
print(f"  SPEEDUP        : {speedup:.4f}x   (throughput ratio)")
print(f"  TIME REDUCTION : {improvement:.2f} %   <- compared against the 7% bar")
print(f"  THROUGHPUT GAIN: {(speedup - 1) * 100:.2f} %   (different metric; do not conflate)")
print(f"  PROJECT BAR    : 7.00 % time reduction")
if improvement < 7:
    verdict = "BELOW BAR"
elif not solid:
    verdict = "PASS (but NOT statistically solid -- see caution below)"
else:
    verdict = "PASS"
print(f"  VERDICT        : {verdict}")
print("=" * W)
print()

# Honesty check: if run-to-run noise is comparable to the claimed gain, the
# gain is not established. This guards against over-claiming.
if not solid:
    print(f"!! CAUTION: improvement ({improvement:.2f}%) is less than 2x the")
    print(f"   run-to-run noise ({noise:.2f}%). This result is NOT statistically")
    print( "   solid. Raise CLEAN_REPS, quiet the machine, and re-measure.")
else:
    print(f"Signal check: improvement ({improvement:.2f}%) exceeds 2x noise "
          f"({noise:.2f}%). OK.")

margin = improvement - 7.0
print(f"Margin over the 7% bar: {margin:+.2f} percentage points "
      f"({margin / noise:.1f}x the measured noise)" if noise else
      f"Margin over the 7% bar: {margin:+.2f} percentage points")
if 0 <= margin < 2:
    print("  CAUTION: this margin is thin. Re-run in a second session before")
    print("           relying on it, and keep the individual observations.")
print()

# Best-case comparison too: min-vs-min is less noise-sensitive than median.
if sb["min"] and so["min"]:
    print(f"Min-vs-min speedup (least-noise estimate): "
          f"{sb['min'] / so['min']:.4f}x "
          f"({(1 - so['min'] / sb['min']) * 100:.2f}% improvement)")
PY

cat "$SUMMARY"

# Pick up loop counts recorded by the summary step.
B_LOOPS=0; O_LOOPS=0
[[ -f "$OUT/loops.env" ]] && source "$OUT/loops.env"
export B_LOOPS O_LOOPS

# -----------------------------------------------------------------------------
# 2. Counter comparison — IPC, cache, branches. Explains WHY it got faster.
# -----------------------------------------------------------------------------
{
  echo "==============================================================="
  echo " PERF STAT COMPARISON — $BENCH"
  echo "==============================================================="
  echo
  echo "Counters come from perf stat COUNTING mode (~1% overhead), so the"
  echo "ratios below are valid even though absolute wall time in profiled"
  echo "phases is inflated."
  echo
  echo "CRITICAL — PER-WORK NORMALIZATION:"
  echo "  Each variant is calibrated INDEPENDENTLY, so the two runs may execute"
  echo "  different amounts of work per process. Raw counter totals are"
  echo "  therefore NOT comparable, for exactly the same reason raw total_sec"
  echo "  is not. Every derived figure below is divided by the loop count."
  echo "    baseline  loops = ${B_LOOPS:-unknown}"
  echo "    optimized loops = ${O_LOOPS:-unknown}"
  echo
  for v in baseline optimized; do
    d="$BASE_DIR"; [[ "$v" == "optimized" ]] && d="$OPT_DIR"
    f="$d/perf/stat_${v}.txt"
    echo "--------------------------------------------------------------"
    echo " $v  (RAW totals as perf reported them — not comparable)"
    echo "--------------------------------------------------------------"
    if [[ -f "$f" ]]; then
      grep -E '[0-9]' "$f" | grep -vE '^\s*$' | head -30
    else
      echo " (no perf stat data — was ENABLE_PERF_STAT=0, or no PMU?)"
    fi
    echo
  done

  echo "--------------------------------------------------------------"
  echo " PER-WORK counters and derived ratios"
  echo "--------------------------------------------------------------"
  "$PY_REL" - "$BASE_DIR/perf/stat_baseline.txt" "$OPT_DIR/perf/stat_optimized.txt" \
            "${B_LOOPS:-0}" "${O_LOOPS:-0}" <<'PYSTAT'
import re, sys, os

bf, of, bl, ol = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

def parse(path):
    """
    Extract event counts from `perf stat` text output.

    perf has ALREADY scaled these values to account for multiplexing, so they
    must NOT be scaled again by the running percentage. The (NN.NN%) field is
    captured separately purely as a confidence indicator: a low percentage means
    the event was only counted for part of the run and the value is a
    statistical estimate, not an exact count.
    """
    if not os.path.exists(path):
        return {}, {}
    vals, pcts = {}, {}
    for line in open(path):
        m = re.match(r'\s*([0-9][0-9,.]*)\s+([A-Za-z0-9_.\-]+)', line)
        if not m:
            continue
        raw, ev = m.group(1).replace(',', ''), m.group(2)
        try:
            vals[ev] = float(raw)
        except ValueError:
            continue
        mp = re.search(r'\(\s*([0-9.]+)%\)', line)
        if mp:
            pcts[ev] = float(mp.group(1))
    return vals, pcts

b, bp = parse(bf)
o, op = parse(of)

if not b or not o:
    print("  [no comparable perf stat data]")
    raise SystemExit(0)
if bl <= 0 or ol <= 0:
    print("  [loop counts unknown -> refusing to report per-work counters,")
    print("   because raw totals across independently calibrated runs are not")
    print("   comparable]")
    raise SystemExit(0)

interesting = [
    ("instructions",           "instructions"),
    ("cycles",                 "cycles"),
    ("branches",               "branches"),
    ("branch-misses",          "branch misses"),
    ("cache-references",       "cache refs"),
    ("cache-misses",           "cache misses"),
    ("L1-dcache-loads",        "L1-d loads"),
    ("L1-dcache-load-misses",  "L1-d misses"),
    ("dTLB-loads",             "dTLB loads"),
    ("dTLB-load-misses",       "dTLB misses"),
    ("page-faults",            "page faults"),
    ("context-switches",       "ctx switches"),
]

print(f"  {'event':<22}{'base/unit':>16}{'opt/unit':>16}{'change':>11}  conf")
print("  " + "-" * 70)
for ev, label in interesting:
    if ev not in b or ev not in o:
        continue
    pb, po = b[ev] / bl, o[ev] / ol
    chg = ((po - pb) / pb * 100) if pb else float("nan")
    # Lowest multiplexing percentage of the two runs, as a confidence flag.
    conf = min(bp.get(ev, 100.0), op.get(ev, 100.0))
    flag = "" if conf >= 80 else ("  <- LOW" if conf >= 40 else "  <- VERY LOW")
    print(f"  {label:<22}{pb:>16,.0f}{po:>16,.0f}{chg:>+10.2f}%  {conf:5.1f}%{flag}")

print()
# IPC is a ratio of two counters from the SAME run, so it needs no loop
# normalization -- it is already work-independent.
for name, d in (("baseline", b), ("optimized", o)):
    if "instructions" in d and "cycles" in d and d["cycles"]:
        print(f"  IPC {name:<10} = {d['instructions'] / d['cycles']:.4f}")

print()
print("  Interpretation:")
print("    instructions/unit down  -> work was REMOVED")
print("    instructions/unit flat but IPC up -> STALLS were removed")
print("  These are different claims and the counters distinguish them.")
print()
print("  MISS-RATE CAVEAT (course Tutorial 2): a miss PERCENTAGE can rise while")
print("  misses PER UNIT OF WORK fall, because the denominator shrank. Always")
print("  quote the per-unit absolute counts above, not just the percentage.")

low = [ev for ev, _ in interesting
       if min(bp.get(ev, 100.0), op.get(ev, 100.0)) < 40 and ev in b and ev in o]
if low:
    print()
    print("  WARNING: these events ran for <40% of the measurement period and")
    print("  are statistical estimates, not exact counts. Do not build a precise")
    print("  causal argument on them:")
    for ev in low:
        print(f"    - {ev}")
PYSTAT

  # Topdown output is rejected rather than interpreted when it is internally
  # inconsistent. Observed on the target VM: "bad speculation -73.0%", which is
  # arithmetically impossible and indicates the PMU counters are unreliable.
  echo
  echo "--------------------------------------------------------------"
  echo " topdown breakdown (validity-checked)"
  echo "--------------------------------------------------------------"
  for v in baseline optimized; do
    d="$BASE_DIR"; [[ "$v" == "optimized" ]] && d="$OPT_DIR"
    tf="$d/perf/stat_${v}.topdown.txt"
    if [[ -f "$tf" ]]; then
      if grep -qE '\-[0-9]+\.[0-9]+%' "$tf"; then
        echo " $v: REJECTED — contains negative percentages, so the counters"
        echo "   are internally inconsistent (a share cannot be negative)."
        echo "   Do NOT assign a bottleneck interpretation to this output."
        grep -oE '\-[0-9]+\.[0-9]+%[^ ]*' "$tf" | head -4 | sed 's/^/     /'
      else
        echo " $v:"; grep -E '[0-9]' "$tf" | head -8 | sed 's/^/   /'
      fi
    else
      echo " $v: (no topdown data)"
    fi
  done
} > "$OUT/counters.txt" 2>&1
ok "counters -> counters.txt"

# -----------------------------------------------------------------------------
# 3. Symbol-level delta — which functions disappeared.
# -----------------------------------------------------------------------------
BS="$BASE_DIR/perf/report_baseline_symbols.csv"
OS_="$OPT_DIR/perf/report_optimized_symbols.csv"
if [[ -f "$BS" && -f "$OS_" ]]; then
  "$PY_REL" - "$BS" "$OS_" > "$OUT/symbols_delta.txt" 2>&1 <<'PY' || true
import csv, sys

def load(p):
    out = {}
    with open(p) as fh:
        for row in csv.reader(fh):
            if len(row) < 3:
                continue
            try:
                pct = float(row[0].strip().rstrip("%"))
            except ValueError:
                continue
            out[row[2].strip()] = out.get(row[2].strip(), 0.0) + pct
    return out

b, o = load(sys.argv[1]), load(sys.argv[2])
print("=" * 78)
print(" SYMBOL-LEVEL DELTA (self overhead %, sampled profile)")
print("=" * 78)
print("Note: percentages are shares of each profile, so they sum to ~100 in")
print("both columns. A symbol dropping to 0.00 means it was eliminated.")
print()
print(f"{'symbol':<46}{'base%':>9}{'opt%':>9}{'delta':>10}")
print("-" * 78)
for sym in sorted(set(b) | set(o), key=lambda s: -(b.get(s, 0) + o.get(s, 0)))[:40]:
    vb, vo = b.get(sym, 0.0), o.get(sym, 0.0)
    print(f"{sym[:45]:<46}{vb:>9.2f}{vo:>9.2f}{vo - vb:>+10.2f}")
print()
gone = sorted((s for s in b if b[s] >= 1.0 and s not in o), key=lambda s: -b[s])
if gone:
    print("ELIMINATED (>=1% in baseline, absent from optimized):")
    for s in gone[:20]:
        print(f"  {b[s]:6.2f}%  {s}")
PY
  ok "symbol delta -> symbols_delta.txt"
else
  warn "symbol CSVs missing; skipping symbol delta (need perf record for both variants)"
fi

# -----------------------------------------------------------------------------
# 4. Differential flame graph.
# -----------------------------------------------------------------------------
DF="$FLAMEGRAPH_DIR/difffolded.pl"
FG="$FLAMEGRAPH_DIR/flamegraph.pl"
BF="$BASE_DIR/flame/baseline.folded"
OF="$OPT_DIR/flame/optimized.folded"
if [[ -x "$DF" && -x "$FG" && -s "$BF" && -s "$OF" ]]; then
  # -n normalizes sample counts so the two profiles are comparable even though
  # they ran different loop counts; without it the diff is meaningless.
  "$DF" -n "$BF" "$OF" > "$OUT/diff.folded" 2>/dev/null || true
  if [[ -s "$OUT/diff.folded" ]]; then
    "$FG" --title "$BENCH — differential (red = more time in optimized, blue = less)" \
          --subtitle "baseline -> optimized | normalized" --width 1800 \
          "$OUT/diff.folded" > "$OUT/diff_flame.svg" 2>/dev/null || true
    ok "differential flame graph -> diff_flame.svg"
  fi
  # Reverse direction: highlights what the baseline spent time on that is gone.
  "$DF" -n "$OF" "$BF" > "$OUT/diff_rev.folded" 2>/dev/null || true
  [[ -s "$OUT/diff_rev.folded" ]] && \
    "$FG" --title "$BENCH — differential reversed (red = baseline-only cost)" \
          --width 1800 "$OUT/diff_rev.folded" > "$OUT/diff_flame_inv.svg" 2>/dev/null || true
else
  warn "differential flame graph skipped (need difffolded.pl + both .folded files)"
fi

# -----------------------------------------------------------------------------
# 5. pyperformance cross-check, if present.
# -----------------------------------------------------------------------------
BJ="$BASE_DIR/raw/pyperf_baseline.json"
if [[ -f "$BJ" ]] && have python; then
  activate_venv 2>/dev/null || true
  python -m pyperf stats "$BJ" > "$OUT/pyperformance_baseline_stats.txt" 2>/dev/null || true
  deactivate 2>/dev/null || true
fi

hdr "comparison complete"
ok "output: $OUT"
printf '  %-26s %s\n' "headline verdict:"  "summary.txt"
printf '  %-26s %s\n' "counter deltas:"    "counters.txt"
printf '  %-26s %s\n' "symbol deltas:"     "symbols_delta.txt"
printf '  %-26s %s\n' "differential flame:" "diff_flame.svg"
