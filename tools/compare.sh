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
SUMMARY="$OUT/summary.txt"
"$PY_REL" - "$BENCH" "$BASE_DIR" "$OPT_DIR" > "$SUMMARY" 2>&1 <<'PY' || warn "summary generation had problems"
import csv, os, statistics, sys

bench, base_dir, opt_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def load(d, variant):
    """Read the clean (unprofiled) timing CSV. These are the only quotable numbers."""
    p = os.path.join(d, "timing", f"clean_{variant}.csv")
    if not os.path.exists(p):
        return []
    vals = []
    with open(p) as fh:
        for row in csv.DictReader(fh):
            try:
                vals.append(float(row["total_sec"]))
            except (ValueError, KeyError):
                pass
    return vals

b = load(base_dir, "baseline")
o = load(opt_dir, "optimized")

W = 74
print("=" * W)
print(f" PERFORMANCE COMPARISON — {bench}".center(W))
print("=" * W)
print()
print("Source: clean-timing phase only (no profiler attached).")
print("Statistic: MEDIAN of independent processes — robust to host hiccups.")
print()

if not b or not o:
    print("!! MISSING TIMING DATA")
    print(f"   baseline samples : {len(b)}")
    print(f"   optimized samples: {len(o)}")
    print("   Re-run both variants with clean timing enabled.")
    raise SystemExit(0)

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
for k, label, unit in (("n", "samples", ""), ("min", "min", " s"),
                       ("median", "median", " s"), ("mean", "mean", " s"),
                       ("max", "max", " s"), ("sd", "stdev", " s"),
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
print(f"  SPEEDUP     : {speedup:.4f}x")
print(f"  IMPROVEMENT : {improvement:.2f} %   (time reduction)")
print(f"  PROJECT BAR : 7.00 %")
print(f"  VERDICT     : {'PASS' if improvement >= 7 else 'BELOW BAR'}")
print("=" * W)
print()

# Honesty check: if run-to-run noise is comparable to the claimed gain, the
# gain is not established. This guards against over-claiming.
noise = max(sb["rel_sd"], so["rel_sd"])
if improvement < 2 * noise:
    print(f"!! CAUTION: improvement ({improvement:.2f}%) is less than 2x the")
    print(f"   run-to-run noise ({noise:.2f}%). This result is NOT statistically")
    print( "   solid. Raise CLEAN_REPS, quiet the machine, and re-measure.")
else:
    print(f"Signal check: improvement ({improvement:.2f}%) exceeds 2x noise "
          f"({noise:.2f}%). OK.")

# Best-case comparison too: min-vs-min is less noise-sensitive than median.
if sb["min"] and so["min"]:
    print(f"Min-vs-min speedup (least-noise estimate): "
          f"{sb['min'] / so['min']:.4f}x "
          f"({(1 - so['min'] / sb['min']) * 100:.2f}% improvement)")
PY

cat "$SUMMARY"

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
  for v in baseline optimized; do
    d="$BASE_DIR"; [[ "$v" == "optimized" ]] && d="$OPT_DIR"
    f="$d/perf/stat_${v}.txt"
    echo "--------------------------------------------------------------"
    echo " $v"
    echo "--------------------------------------------------------------"
    if [[ -f "$f" ]]; then
      grep -E '[0-9]' "$f" | grep -vE '^\s*$' | head -30
    else
      echo " (no perf stat data — was ENABLE_PERF_STAT=0, or no PMU?)"
    fi
    echo
  done
  # Derived ratios are the interesting part: fewer instructions at similar IPC
  # means we removed work; same instructions at higher IPC means we improved
  # locality or reduced stalls. The distinction matters for the HW proposal.
  echo "--------------------------------------------------------------"
  echo " derived ratios (insn, IPC, miss rates)"
  echo "--------------------------------------------------------------"
  for v in baseline optimized; do
    d="$BASE_DIR"; [[ "$v" == "optimized" ]] && d="$OPT_DIR"
    f="$d/perf/stat_${v}.txt"
    [[ -f "$f" ]] || continue
    ins="$(grep -oE '^\s*[0-9,]+\s+instructions' "$f" | head -1 | tr -dc '0-9' || true)"
    cyc="$(grep -oE '^\s*[0-9,]+\s+cycles' "$f" | head -1 | tr -dc '0-9' || true)"
    printf ' %-10s instructions=%-16s cycles=%-16s' "$v" "${ins:-n/a}" "${cyc:-n/a}"
    if [[ -n "${ins:-}" && -n "${cyc:-}" && "${cyc:-0}" != "0" ]]; then
      awk -v i="$ins" -v c="$cyc" 'BEGIN{printf " IPC=%.4f", i/c}'
    fi
    echo
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
