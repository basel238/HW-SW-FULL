#!/usr/bin/env bash
# =============================================================================
# script_nbody.sh — full analysis pipeline for the `nbody` benchmark.
#
# Deliverable for the HWSW project (file name mandated by the brief:
# "script_<name_of_benchmark>.sh").
#
# WHAT THIS BENCHMARK IS
#   Symplectic integration of the Sun + 4 Jovian planets (the classic Computer
#   Language Benchmarks Game n-body). O(n^2) pairwise gravitational force
#   accumulation, 20000 timesteps per simulation.
#
# WHY IT WAS CHOSEN
#   * The inner loop is a textbook multiply-accumulate over 3-vectors, repeated
#     for all 10 body pairs every timestep. That maps DIRECTLY onto the brief's
#     own suggestion: "Extend ISA with instructions [that] can accelerate
#     workloads but are not too workload-specific (e.g., multiple-accumulate)".
#   * Perfectly regular control flow and a tiny working set (5 bodies = 280 B,
#     fits in L1) -> this is a PURE compute/dispatch bottleneck with no memory
#     confound, which makes the accelerator argument clean.
#   * Total energy is a conserved physical quantity -> an exact correctness
#     oracle. The optimized variant is cross-checked against the baseline's
#     energy to 1e-9 relative.
#
# COMPLEMENTARITY WITH raytrace
#   raytrace is branch-heavy and allocation-heavy (object churn); nbody is
#   branch-free and allocation-free. Together they isolate the two distinct
#   CPython overheads — object protocol vs bytecode dispatch — which is a much
#   stronger story than two benchmarks that fail the same way.
#
# WHAT IT PRODUCES / MEASUREMENT INTEGRITY
#   Identical to script_raytrace.sh; see that file's header and --help.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/pipeline.sh
source "$HERE/lib/pipeline.sh"

BENCH_NAME="nbody"
BASELINE="$HERE/bench/bm_nbody.py"
OPTIMIZED="$HERE/variants/bm_nbody_opt.py"

pipeline_parse_args "$@" || { pipeline_usage "$BENCH_NAME"; exit 2; }
[[ "${PIPELINE_HELP:-0}" == "1" ]] && { pipeline_usage "$BENCH_NAME"; exit 0; }

if [[ "${PIPELINE_LIST_ONLY:-0}" == "1" ]]; then
  pipeline_usage "$BENCH_NAME"; exit 0
fi

[[ -f "$BASELINE"  ]] || die "missing baseline: $BASELINE"
[[ -f "$OPTIMIZED" ]] || die "missing optimized variant: $OPTIMIZED"
mkdir -p "$RESULTS_DIR"

hdr "nbody — HWSW benchmark analysis pipeline"
log "variant selection : $VARIANT_SEL"
log "baseline          : bench/bm_nbody.py"
log "optimized         : variants/bm_nbody_opt.py"

if [[ "$VARIANT_SEL" == "baseline" || "$VARIANT_SEL" == "both" ]]; then
  run_variant "$BENCH_NAME" "baseline" "$BASELINE"
fi

if [[ "$VARIANT_SEL" == "optimized" || "$VARIANT_SEL" == "both" ]]; then
  run_variant "$BENCH_NAME" "optimized" "$OPTIMIZED"
fi

if [[ "$VARIANT_SEL" == "both" ]]; then
  hdr "before/after comparison"
  "$HERE/tools/compare.sh" "$BENCH_NAME" || warn "compare.sh reported a problem"
fi

ok "nbody pipeline complete"
