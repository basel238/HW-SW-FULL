#!/usr/bin/env bash
# =============================================================================
# tools/gen_report.sh — assemble report_<bench>.txt from real measured data.
#
# Usage: ./tools/gen_report.sh <bench>
#
# The brief mandates report_<name_of_benchmark>.txt with six specific sections.
# This script fills in everything that can be derived mechanically from the run
# artifacts (overview, profiling data, measured comparison) and leaves clearly
# marked TODO blocks for the parts that require YOUR analysis and design work
# (the hardware proposal, the block diagram, the conclusions).
#
# Deliberate choice: it does NOT fabricate analysis prose. A report that states
# measured numbers and flags what is still missing is worth more than one that
# reads well and cannot be defended in the presentation.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

BENCH="${1:?usage: gen_report.sh <bench>}"
BASE_DIR="$RESULTS_DIR/latest_${BENCH}_baseline"
OPT_DIR="$RESULTS_DIR/latest_${BENCH}_optimized"
CMP_DIR="$RESULTS_DIR/latest_comparison_${BENCH}"
OUT="$REPO_ROOT/report_${BENCH}.txt"

# Do NOT clobber authored analysis. The generated file is evidence; once a
# student fills in the [TODO] sections it becomes their work, and run_all.sh
# regenerating it would silently destroy that.
if [[ -f "$OUT" ]]; then
  todo_left="$(grep -c '\[TODO' "$OUT" || true)"
  if [[ "${todo_left:-0}" == "0" ]]; then
    warn "$OUT has no [TODO] markers left -> it looks authored."
    warn "Refusing to overwrite. Writing to ${OUT%.txt}.generated.txt instead."
    OUT="${OUT%.txt}.generated.txt"
  fi
fi
log "assembling $OUT"

# Per-benchmark descriptive text. Kept here rather than in a data file so the
# report is self-contained and reviewable in one place.
case "$BENCH" in
  raytrace)
    PURPOSE="Recursive ray tracing: 4 spheres plus a checkerboard ground plane, Lambertian diffuse shading, hard shadows via occlusion rays, and specular reflection to a recursion depth of 3. Renders an RGB image and checksums it."
    LIBS="Standard library only: math (sqrt, floor), hashlib (correctness checksum), time (perf_counter). NO third-party dependencies, so the profile reflects CPython itself rather than a C extension."
    STRUCTS="Baseline: a Vector class with __slots__=('x','y','z') and operator overloads (__add__, __sub__, __mul__, dot, magnitude, normalize, reflect); Sphere and Plane objects held in a dict; output pixels in a flat Python list of ints.
Optimized: the Vector class is removed entirely. Coordinates are carried as separate float locals; the scene is flattened into tuples of scalars."
    ALGOS="Per pixel: construct and normalize a primary ray; for each object solve the ray-sphere quadratic (or the ray-plane linear equation) and keep the nearest positive root; shade; cast one shadow ray toward the light; recurse along the reflected direction up to MAX_DEPTH=3. Complexity is O(pixels x objects x 2^depth) in the worst case."
    ;;
  nbody)
    PURPOSE="Gravitational n-body simulation of the Sun plus the four Jovian planets (Jupiter, Saturn, Uranus, Neptune), integrated with a symplectic (velocity-Verlet family) scheme for 20000 timesteps. Reports total system energy."
    LIBS="Standard library only: math.sqrt in the optimized variant; the baseline uses the ** operator. NO third-party dependencies."
    STRUCTS="Baseline: each body is a 3-tuple (position list, velocity list, mass float); the system is a list of those tuples; body pairs are precomputed as a list of (i,j) index tuples.
Optimized: state is flattened into seven parallel flat lists (xs, ys, zs, vxs, vys, vzs, ms), and the pair list carries pre-resolved masses as (i, j, m_i, m_j)."
    STRUCTS="$STRUCTS"
    ALGOS="advance(dt): for each of the 10 unordered body pairs, compute the separation vector, its squared magnitude, and the inverse-cube-law factor dt*d2^-1.5; apply equal and opposite momentum changes to both bodies; then integrate all positions. O(n^2) per timestep with n=5. report_energy() sums kinetic and pairwise potential energy and is the conservation-based correctness oracle."
    ;;
  *) PURPOSE="(describe the benchmark)"; LIBS="(list libraries)"
     STRUCTS="(describe data structures)"; ALGOS="(describe algorithms)" ;;
esac

# Correctness-gate prose, selected per benchmark. Built BEFORE the report
# heredoc: nesting a heredoc inside $(...) inside another heredoc makes bash
# mis-parse the inner delimiter and silently disable expansion downstream.
case "$BENCH" in
  raytrace)
    GATE_TEXT="    raytrace: the rendered 32x32 image must be BIT-IDENTICAL to the baseline
    (SHA-256 of the pixel buffer). Note the finding recorded in the variant's
    docstring: replacing three divisions with a reciprocal-multiply is ~1 ULP
    off and flipped a single shadow-edge pixel by 118/255, because the renderer
    contains discontinuities (shadow hit/miss tests). The gate caught it, and
    exact division is now the default (FAST_FP=1 opts back in, and fails the
    gate, which is a useful thing to demonstrate live). This shows concretely
    that 'safe' FP strength reduction is only safe in branch-free numeric code."
    ;;
  nbody)
    GATE_TEXT="    nbody: total system energy must match the baseline to within 1e-9
    relative (float reassociation tolerance only), and energy drift over 1000
    steps must stay below 1e-3 relative. The latter is the physically correct
    test for a symplectic integrator, whose energy error is bounded and
    oscillatory rather than zero -- an absolute 1e-6 bound was tried first and
    was simply wrong. Measured cross-check: rel_diff = 3.3e-16 (bit-level)."
    ;;
  *) GATE_TEXT="    (describe the correctness gate for this benchmark)" ;;
esac

grab() { # grab <file> <fallback-message>
  # An empty or error-only artifact must produce a clear "unavailable" note
  # rather than leaking a tool error message into the report body.
  if [[ -s "$1" ]]; then
    if grep -qiE '^(Error|Fatal|perf: |WARNING: )' "$1" && \
       [[ "$(wc -l < "$1")" -lt 5 ]]; then
      echo "  [DATA UNAVAILABLE — the profiling step failed for this run]"
      echo "  (tool output: $(head -1 "$1"))"
    else
      cat "$1"
    fi
  else
    echo "$2"
  fi
}

{
cat <<EOF
===============================================================================
 REPORT — $BENCH
 HW/SW Co-design (00460882) — Benchmark Optimization, Analysis,
                              and Hardware Acceleration
===============================================================================
 Generated : $(date -u +%FT%TZ)
 Commit    : $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'n/a')
 Host      : $(uname -srm) | $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo '?')
 Generator : tools/gen_report.sh (measured sections are auto-filled; analysis
             sections marked [TODO] require your own writing)
===============================================================================


1. OVERVIEW
-------------------------------------------------------------------------------
1.1 Purpose
$PURPOSE

1.2 Libraries used
$LIBS

1.3 Data structures
$STRUCTS

1.4 Algorithms
$ALGOS

1.5 Why this benchmark was selected
  * raytrace and nbody are both FP/compute-bound, which makes the interpreter
    overhead versus useful arithmetic ratio directly measurable with perf stat.
  * They fail in COMPLEMENTARY ways: raytrace is allocation- and
    branch-heavy (object protocol overhead, unpredictable control flow), while
    nbody is allocation-free and branch-free (pure bytecode dispatch over a
    working set that fits in L1). Optimizing both therefore exercises two
    distinct bottleneck classes rather than the same one twice.
  * Both have exact correctness oracles (image checksum / energy conservation),
    so no optimization can silently trade accuracy for speed.


2. INITIAL ANALYSIS (BASELINE)
-------------------------------------------------------------------------------
2.1 Measurement methodology

  Profilers perturb what they measure, so this project separates phases and
  never quotes a number taken from an instrumented run:

    phase 1  verify         correctness gate (hard fail)
    phase 2  clean timing   NO profiler attached      <-- QUOTED NUMBERS
    phase 3  perf stat      counting mode, ~1% ovh    IPC / cache / branches
    phase 4  perf record    sampling, high ovh        flame graphs only
    phase 5  cProfile       tracing, 2-5x ovh         exact call counts only
    phase 6  pyperformance  upstream harness          citable mean +- stdev

  Noise control: single-CPU pinning via taskset, PYTHONHASHSEED fixed,
  cyclic GC disabled during the timed region, ASLR disabled, CPU governor set
  to performance where the platform exposes it. Reported statistic is the
  MEDIAN over $CLEAN_REPS independent processes, with relative standard
  deviation reported so the reader can judge whether the result is solid.

  Sampling frequency is $SAMPLE_FREQ Hz (deliberately not a round 1000 Hz, to
  avoid lock-stepping with periodic kernel timers and with the benchmark's own
  loop boundaries). Call graphs use $CALLGRAPH unwinding because stock CPython
  is compiled with -fomit-frame-pointer, so frame-pointer unwinding yields
  truncated stacks.

2.2 Environment
$(grab "$BASE_DIR/manifest.txt" "  [no baseline manifest — run ./script_${BENCH}.sh --variant baseline]" | sed -n '1,60p' | sed 's/^/  /')

2.3 Hardware counters (baseline)
$(grab "$BASE_DIR/perf/stat_baseline.txt" "  [no perf stat data]" | sed 's/^/  /')

2.4 perf report — hottest symbols, self time (baseline)
$(grab "$BASE_DIR/perf/report_baseline_self.txt" "  [no perf report data]" | grep -v '^#' | sed -n '1,35p' | sed 's/^/  /')

2.5 Time by shared object (baseline)
$(grab "$BASE_DIR/perf/report_baseline_dso.txt" "  [no DSO breakdown]" | grep -v '^#' | sed -n '1,18p' | sed 's/^/  /')

2.6 Hottest call stacks (baseline, folded)
$(grab "$BASE_DIR/flame/baseline_top30_stacks.txt" "  [no folded stacks]" | sed -n '1,18p' | sed 's/^/  /')

2.7 Exact call counts (cProfile, baseline)
$(grab "$BASE_DIR/raw/cprofile_baseline.txt" "  [no cProfile data]" | sed -n '1,42p' | sed 's/^/  /')

2.8 Flame graphs
  Baseline SVGs (open in a browser; they are interactive):
    $BASE_DIR/flame/baseline.svg              (CPU flame graph)
    $BASE_DIR/flame/baseline_icicle.svg       (top-down; shows recursion depth)
    $BASE_DIR/flame/baseline_python.svg       (Python frames only)
    $BASE_DIR/flame/baseline_pyspy.svg        (py-spy cross-check)

2.9 [TODO] Bottleneck interpretation
  Write 1-2 paragraphs answering:
    - Which frames dominate, and are they YOUR code, the interpreter, or libm?
    - Is the limiter instruction count, stalls, or branch mispredictions?
      (compare IPC in 2.3; low IPC with few cache misses points to dispatch
      or dependency stalls rather than memory)
    - For raytrace: quantify the object-allocation cost. For nbody: quantify
      the pow() cost versus the multiply-accumulate cost.


3. OPTIMIZATIONS
-------------------------------------------------------------------------------
3.1 Changes applied
  See the module docstring of the optimized variant for the full rationale,
  with each change tied to the profile observation that motivated it:
    $( [[ "$BENCH" == "raytrace" ]] && echo "variants/bm_raytrace_opt.py" || echo "variants/bm_nbody_opt.py" )

3.2 Correctness gate
  Every optimization is cross-checked against the baseline implementation:
${GATE_TEXT}

3.3 Optimizations considered and REJECTED
  numpy       : both benchmarks operate on 3-element vectors. numpy's
                per-call overhead (~1 us) exceeds the cost of 3 float ops, so
                it is slower at this granularity. It would only win after
                restructuring to batch all rays/bodies, which is a different
                program.
  threading   : the GIL serializes pure-Python float arithmetic.
  algorithmic : for nbody, Barnes-Hut reduces O(n^2) to O(n log n) but is an
                APPROXIMATION and would invalidate the energy oracle; with n=5
                it is also slower. Out of scope for a like-for-like comparison.


4. PERFORMANCE COMPARISON
-------------------------------------------------------------------------------
$(grab "$CMP_DIR/summary.txt" "  [no comparison yet — run ./tools/compare.sh $BENCH]" | sed 's/^/  /')

4.1 Counter comparison
$(grab "$CMP_DIR/counters.txt" "  [no counter comparison]" | sed -n '1,60p' | sed 's/^/  /')

4.2 Symbol-level delta
$(grab "$CMP_DIR/symbols_delta.txt" "  [no symbol delta]" | sed -n '1,45p' | sed 's/^/  /')

4.3 Differential flame graph
    $CMP_DIR/diff_flame.svg
  Red = more time in the optimized build, blue = less. Sample counts are
  normalized (difffolded.pl -n) so the two profiles are comparable despite
  different loop counts.

4.4 pyperformance (independent harness)
$(grab "$BASE_DIR/raw/pyperf_baseline_stats.txt" "  [no pyperformance data]" | sed -n '1,25p' | sed 's/^/  /')
$( [[ -f "$BASE_DIR/raw/pyperf_baseline_stats.txt" ]] &&    grep -iE 'unstable|warning|WARNING|inconsistent|outlier'         "$BASE_DIR/raw/pyperf_baseline_stats.txt" 2>/dev/null    | sed 's/^/  !! /' || true )

4.5 [TODO] Interpretation
  Explain WHY it got faster using 4.1: did instruction count fall (work
  removed), or did IPC rise (stalls removed)? Those are different claims and
  the counters distinguish them.


5. HARDWARE ACCELERATION PROPOSAL
-------------------------------------------------------------------------------
  [TODO — this section is yours to design. The brief requires ALL of:]

  5.1 Hardware description
      RTL in Verilog / SystemVerilog / PyXHDL. Complete and logically
      consistent; it does NOT need to be synthesizable or tape-out ready.
      Suggested starting point given these two benchmarks: a 3-lane
      multiply-accumulate / dot-product unit with an optional reciprocal-sqrt
      stage, since both benchmarks reduce to dot products plus an inverse
      magnitude. See docs/HW_PROPOSAL_NOTES.md for the measured data that
      motivates the design and for the numbers to quote.

  5.2 Inputs and outputs
      Data widths, interfaces, expected operating frequency.

  5.3 Hardware architecture
      Main datapath plus control logic; pipeline depth and latency.

  5.4 Hardware/software interface
      How CPython reaches it: memory-mapped registers, a new instruction, a
      DMA path? Which software layer changes — the interpreter's float ops, a
      C extension, or an ISA intrinsic? Recall the course rule: do not expect
      end users to change their code, and never break it.

  5.5 Acceleration justification
      Use YOUR measured numbers from sections 2 and 4: the fraction of time in
      the target operation bounds the achievable speedup (Amdahl). State your
      assumptions explicitly.

  5.6 Block diagram
      Accelerator, its interfaces, and its place in the overall system.

  5.7 Performance / area / power trade-offs


6. CONCLUSION
-------------------------------------------------------------------------------
  [TODO] Summarize: what the profiling revealed, what the software
  optimization achieved and at what cost in readability, what the proposed
  hardware would add on top, and where the remaining bottleneck would move to
  afterwards (it always moves — say where).


===============================================================================
 ARTIFACT INDEX
===============================================================================
 baseline run   : $BASE_DIR
 optimized run  : $OPT_DIR
 comparison     : $CMP_DIR
 run scripts    : script_${BENCH}.sh, run_all.sh
 sources        : bench/bm_${BENCH}.py, variants/bm_${BENCH}_opt.py
===============================================================================
EOF
} > "$OUT" 2>&1

ok "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
n_todo="$(grep -c '\[TODO' "$OUT" || true)"
echo "  ${n_todo:-0} section(s) still need your analysis — search for [TODO]"
