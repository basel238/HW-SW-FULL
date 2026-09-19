#!/usr/bin/env bash
# =============================================================================
# tools/ab_timing.sh — INTERLEAVED A/B timing, the statistically sound way to
# establish a speedup.
#
# WHY THIS EXISTS
# ---------------
# The main pipeline measures baseline fully, then optimized fully, minutes later.
# An external review correctly noted that sequential blocks cannot separate the
# code change from host drift, thermal effects, or any other slow-moving
# systematic difference — and that "improvement > 2 x stdev" is a rule of thumb,
# not a confidence interval.
#
# This tool addresses both:
#   * ALTERNATES baseline/optimized process by process (A B A B ...), optionally
#     randomizing the order within each round, so drift affects both arms
#     equally instead of loading onto one.
#   * Reports a bootstrap confidence interval for the speedup, not just a
#     point estimate and a heuristic.
#
# Usage:
#   ./tools/ab_timing.sh raytrace [rounds]
#   ./tools/ab_timing.sh nbody 15
#   ./tools/ab_timing.sh raytrace 11 --shuffle
#
# Output: results/abtiming_<bench>_<ts>/{summary.txt,samples.csv}
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

BENCH="${1:?usage: ab_timing.sh <raytrace|nbody> [rounds] [--shuffle]}"
ROUNDS="${2:-11}"
case "${3:-}" in --shuffle) SHUFFLE=1 ;; *) SHUFFLE=0 ;; esac

case "$BENCH" in
  raytrace|nbody) ;;
  *) die "unknown benchmark '$BENCH' (expected raytrace or nbody)" ;;
esac
# Same workload selection as the deliverable scripts.
if [[ "${USE_UPSTREAM:-1}" == "1" ]]; then
  BASE="$REPO_ROOT/bench/bm_${BENCH}_upstream.py"
  OPT="$REPO_ROOT/variants/bm_${BENCH}_upstream_opt.py"
  log "workload: UPSTREAM pyperformance kernel"
else
  BASE="$REPO_ROOT/bench/bm_${BENCH}.py"
  OPT="$REPO_ROOT/variants/bm_${BENCH}_opt.py"
  log "workload: custom stand-in"
fi
[[ -f "$BASE" && -f "$OPT" ]] || die "benchmark sources missing"

OUT="$RESULTS_DIR/abtiming_${BENCH}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
( cd "$RESULTS_DIR" && ln -sfn "$(basename "$OUT")" "latest_abtiming_${BENCH}" )

hdr "interleaved A/B timing — $BENCH"
log "rounds=$ROUNDS  shuffle=$SHUFFLE  (2 processes per round)"

# CRITICAL: both arms must do IDENTICAL work. Calibrate ONCE on the baseline and
# force that loop count on both, rather than letting each self-calibrate to a
# different value.
py_env
LOOPS_FIXED="${LOOPS:-}"
if [[ -z "$LOOPS_FIXED" ]]; then
  log "calibrating once on the baseline (both arms will use this value)"
  LOOPS_FIXED="$("$PY_REL" "$BASE" --mode calibrate 2>/dev/null | tail -1 | tr -dc '0-9')"
  [[ -n "$LOOPS_FIXED" && "$LOOPS_FIXED" -gt 0 ]] 2>/dev/null || LOOPS_FIXED=16
fi
ok "fixed loops = $LOOPS_FIXED for BOTH variants (equal work by construction)"

build_pin
CSV="$OUT/samples.csv"
echo "round,order,variant,total_sec" > "$CSV"

run_one() { # run_one <variant> <script> <round> <order>
  local variant="$1" script="$2" round="$3" order="$4" out t
  local args=("$script" --mode raw --loops "$LOOPS_FIXED")
  [[ "$DISABLE_GC" == "1" ]] && args+=(--no-gc)
  out="$(${PIN[@]+"${PIN[@]}"} "$PY_REL" "${args[@]}" 2>&1)" || {
    warn "round $round $variant failed"; return 0; }
  t="$(printf '%s' "$out" | grep -oE 'total_sec=[0-9.]+' | head -1 | cut -d= -f2)"
  [[ -n "$t" ]] && echo "$round,$order,$variant,$t" >> "$CSV"
  printf '%s' "$t"
}

for (( r=1; r<=ROUNDS; r++ )); do
  # Alternate which arm goes first. With --shuffle the order is random; without
  # it, it strictly alternates by round parity. Either way neither variant
  # systematically occupies the "first" (cold) or "second" (warm) slot.
  if (( SHUFFLE )); then
    (( RANDOM % 2 )) && first=base || first=opt
  else
    (( r % 2 )) && first=base || first=opt
  fi

  if [[ "$first" == "base" ]]; then
    tb="$(run_one baseline  "$BASE" "$r" 1)"
    to="$(run_one optimized "$OPT"  "$r" 2)"
  else
    to="$(run_one optimized "$OPT"  "$r" 1)"
    tb="$(run_one baseline  "$BASE" "$r" 2)"
  fi
  printf '  round %2d (%s first): base=%-10s opt=%-10s\n' "$r" "$first" "${tb:-fail}" "${to:-fail}"
done

hdr "analysis"
"$PY_REL" - "$CSV" "$LOOPS_FIXED" "$BENCH" <<'PYEOF' | tee "$OUT/summary.txt"
import csv, random, statistics, sys

path, loops, bench = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = list(csv.DictReader(open(path)))
b = [float(r["total_sec"]) / loops for r in rows if r["variant"] == "baseline"]
o = [float(r["total_sec"]) / loops for r in rows if r["variant"] == "optimized"]

W = 72
print("=" * W)
print(f" INTERLEAVED A/B TIMING — {bench}".center(W))
print("=" * W)
print()
print(f"Design: processes alternated A/B/A/B, {loops} unit(s) of work each,")
print("        identical loop count for both arms, no profiler attached.")
print("        This separates the code change from monotonic host drift, which")
print("        sequential baseline-then-optimized blocks cannot do.")
print()

if len(b) < 3 or len(o) < 3:
    print(f"!! too few samples (baseline {len(b)}, optimized {len(o)})")
    raise SystemExit(0)

def st(v):
    m = statistics.mean(v); sd = statistics.stdev(v) if len(v) > 1 else 0.0
    return m, statistics.median(v), sd, (sd / m * 100 if m else 0.0)

mb, medb, sdb, rsb = st(b)
mo, medo, sdo, rso = st(o)
print(f"{'':<14}{'n':>5}{'median/unit':>15}{'mean/unit':>13}{'rel sd':>10}")
print("-" * W)
print(f"{'baseline':<14}{len(b):>5}{medb:>15.6f}{mb:>13.6f}{rsb:>9.2f}%")
print(f"{'optimized':<14}{len(o):>5}{medo:>15.6f}{mo:>13.6f}{rso:>9.2f}%")
print()

speedup = medb / medo
timered = (1 - medo / medb) * 100

# Bootstrap CI: resample both arms with replacement and recompute. This makes no
# normality assumption, which matters because timing distributions are
# right-skewed (a run can be slowed by interference, never sped up).
random.seed(12345)
boots = []
for _ in range(20000):
    rb = statistics.median(random.choices(b, k=len(b)))
    ro = statistics.median(random.choices(o, k=len(o)))
    if rb and ro:
        boots.append((1 - ro / rb) * 100)
boots.sort()
lo = boots[int(0.025 * len(boots))]
hi = boots[int(0.975 * len(boots))]

print("=" * W)
print(f"  SPEEDUP        : {speedup:.4f}x")
print(f"  TIME REDUCTION : {timered:.2f} %")
print(f"  95% CI (boot)  : [{lo:.2f} %, {hi:.2f} %]   (20000 resamples)")
print(f"  PROJECT BAR    : 7.00 % time reduction")
print()

# The decision rule: the ENTIRE interval must clear the bar. A point estimate
# above 7% with a CI straddling it does not establish the result.
if lo >= 7.0:
    print("  VERDICT        : PASS — the whole 95% CI is above the 7% bar.")
elif timered >= 7.0:
    print("  VERDICT        : INCONCLUSIVE — point estimate clears the bar but")
    print("                   the CI straddles it. Collect more rounds.")
else:
    print("  VERDICT        : BELOW BAR.")
print("=" * W)
print()

# Paired analysis: within a round both arms saw the same machine state, so the
# per-round difference cancels drift more effectively than comparing pooled
# medians.
rounds = {}
for r in rows:
    rounds.setdefault(r["round"], {})[r["variant"]] = float(r["total_sec"]) / loops
paired = [(v["baseline"] - v["optimized"]) / v["baseline"] * 100
          for v in rounds.values() if "baseline" in v and "optimized" in v]
if len(paired) >= 3:
    pm = statistics.mean(paired); psd = statistics.stdev(paired)
    print(f"Paired within-round analysis (n={len(paired)}):")
    print(f"  mean time reduction = {pm:.2f} %  (sd {psd:.2f})")
    print(f"  per-round range     = [{min(paired):.2f} %, {max(paired):.2f} %]")
    print("  All rounds agree in sign."
          if all(p > 0 for p in paired) else
          "  WARNING: some rounds show the optimized variant SLOWER.")
PYEOF

ok "output: $OUT"
printf '  %-18s %s\n' "summary:" "$OUT/summary.txt"
printf '  %-18s %s\n' "raw samples:" "$OUT/samples.csv"
