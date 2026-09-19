#!/usr/bin/env bash
# =============================================================================
# lib/pipeline.sh — the generic 6-phase pipeline shared by every script_*.sh.
#
# Sourced AFTER lib/common.sh. Keeps script_raytrace.sh / script_nbody.sh thin
# and declarative so a reader can see the benchmark-specific facts immediately
# without wading through plumbing.
# =============================================================================

# run_variant <bench> <variant> <script> <extra_args...>
# Executes all enabled phases for ONE variant, in strict order.
run_variant() {
  local bench="$1" variant="$2" script="$3"; shift 3
  local extra=("$@")

  init_run "$bench" "$variant"
  require_perf
  require_python_dbg
  probe_pmu
  capture_env

  # --- Phase 1: correctness BEFORE performance -------------------------------
  # Benchmarking incorrect code is worse than not benchmarking at all, so this
  # gate is hard-fail (die) rather than a warning.
  run_verify "$script"

  # --- Calibration (once, on the release interpreter) -----------------------
  # Every phase reuses this loop count so all phases do identical work and the
  # numbers are mutually comparable.
  local loops
  loops="$(calibrate_loops "$script")"
  log "calibrated loops=$loops (target ~${TARGET_SEC}s per pass)"
  echo "$loops" > "$RUN_DIR/timing/loops.txt"

  # --- Phases 2-6 -----------------------------------------------------------
  run_clean_timing  "$script" "$loops"        # QUOTABLE numbers
  run_perf_stat     "$script" "$loops"        # counters, ~1% overhead
  run_perf_record   "$script" "$loops" "$variant"
  run_cache_profile "$script" "$loops" "$variant"
  run_cprofile      "$script" "$loops"        # call counts only
  run_pyspy         "$script" "$loops"

  # Only the upstream benchmark name is meaningful to pyperformance, and only
  # for the baseline: our optimized variant is not an upstream benchmark.
  if [[ "$variant" == "baseline" ]]; then
    run_pyperformance "$bench" "$variant"
  else
    log "skipping pyperformance for '$variant' (not an upstream benchmark)"
  fi

  finish_run
}

# Standard CLI shared by all script_*.sh files.
pipeline_usage() {
  local bench="$1"
  cat <<EOF
Usage: ./script_${bench}.sh [OPTIONS]

Runs the full profiling pipeline for the '${bench}' benchmark.

OPTIONS
  --variant V     baseline | optimized | both     (default: both)
  --quick         fast smoke test: fewer reps, no cProfile/py-spy/pyperformance
  --profile-only  skip clean timing; only collect perf data + flame graphs
  --time-only     only clean timing (no profilers at all) — fastest path to a
                  defensible speedup number
  --loops N       force the loop count instead of auto-calibrating
  --list-phases   print the phase plan and exit
  -h, --help      this message

PHASE PLAN (see config/bench.env for the rationale)
  1  verify          correctness gate           hard-fail on mismatch
  2  clean timing    NO profiler                <-- the only quotable numbers
  3  perf stat       counting mode, ~1% ovh     IPC, cache, branch misses
  4  perf record     sampling, high ovh         flame graphs  (timing discarded)
  5  cProfile        tracing, 2-5x ovh          exact call counts
  6  pyperformance   upstream harness           citable mean +- stdev

EXAMPLES
  ./script_${bench}.sh                     # everything, both variants
  ./script_${bench}.sh --quick             # ~1 min smoke test
  ./script_${bench}.sh --variant baseline  # baseline only
  ./script_${bench}.sh --time-only         # just the speedup number
  SAMPLE_FREQ=499 CALLGRAPH=fp ./script_${bench}.sh   # cheaper sampling
EOF
}

# Parses the shared flags. Sets VARIANT_SEL and mutates the ENABLE_* toggles.
pipeline_parse_args() {
  VARIANT_SEL="both"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)      VARIANT_SEL="${2:?--variant needs a value}"; shift 2 ;;
      --loops)        LOOPS="${2:?--loops needs a value}"; export LOOPS; shift 2 ;;
      --quick)
        # Smoke test: keep the cheap, high-signal phases; drop the slow ones.
        CLEAN_REPS=3; REPS=2; TARGET_SEC=1.0
        ENABLE_CPROFILE=0; ENABLE_PYSPY=0; ENABLE_PYPERFORMANCE=0
        ENABLE_CACHE_PROFILE=0
        export CLEAN_REPS REPS TARGET_SEC ENABLE_CPROFILE ENABLE_PYSPY \
               ENABLE_PYPERFORMANCE ENABLE_CACHE_PROFILE
        log "--quick: 3 reps, no cProfile/py-spy/pyperformance"; shift ;;
      --profile-only)
        ENABLE_CLEAN_TIMING=0; ENABLE_PYPERFORMANCE=0
        export ENABLE_CLEAN_TIMING ENABLE_PYPERFORMANCE
        log "--profile-only: skipping clean timing"; shift ;;
      --time-only)
        ENABLE_PERF_STAT=0; ENABLE_PERF_RECORD=0; ENABLE_FLAMEGRAPH=0
        ENABLE_CPROFILE=0; ENABLE_PYSPY=0; ENABLE_CACHE_PROFILE=0
        ENABLE_PYPERFORMANCE=0
        export ENABLE_PERF_STAT ENABLE_PERF_RECORD ENABLE_FLAMEGRAPH \
               ENABLE_CPROFILE ENABLE_PYSPY ENABLE_CACHE_PROFILE ENABLE_PYPERFORMANCE
        log "--time-only: clean timing only, zero instrumentation"; shift ;;
      --list-phases)  PIPELINE_LIST_ONLY=1; shift ;;
      -h|--help)      PIPELINE_HELP=1; shift ;;
      *)              err "unknown option: $1"; return 2 ;;
    esac
  done
  case "$VARIANT_SEL" in
    baseline|optimized|both) ;;
    *) err "--variant must be baseline, optimized, or both"; return 2 ;;
  esac
  export VARIANT_SEL
}
