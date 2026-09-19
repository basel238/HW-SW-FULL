#!/usr/bin/env bash
# =============================================================================
# run_all.sh — one command to produce every artifact the project requires.
#
# Usage:
#   ./run_all.sh              full run (both benchmarks, both variants)
#   ./run_all.sh --quick      ~3 min smoke test, verifies the whole pipeline
#   ./run_all.sh --time-only  just the speedup numbers
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

PASSTHRU=("$@")

hdr "HWSW PROJECT — full pipeline"
log "benchmarks: $PROJECT_BENCHES"
log "passing through to per-benchmark scripts: ${PASSTHRU[*]:-<none>}"

# Preflight: catching a missing dependency now beats failing 20 minutes in.
"$HERE/tools/doctor.sh" || die "preflight failed — fix the issues above first"

START=$(date +%s)
FAILED=()

for b in $PROJECT_BENCHES; do
  s="$HERE/script_${b}.sh"
  if [[ ! -x "$s" ]]; then
    warn "missing or non-executable: $s"; FAILED+=("$b"); continue
  fi
  hdr "=== benchmark: $b ==="
  if ! "$s" "${PASSTHRU[@]}"; then
    err "script_${b}.sh failed"; FAILED+=("$b")
  fi
done

# Generate the report skeletons required by the brief.
hdr "generating report_<bench>.txt deliverables"
for b in $PROJECT_BENCHES; do
  "$HERE/tools/gen_report.sh" "$b" || warn "report generation failed for $b"
done

ELAPSED=$(( $(date +%s) - START ))
hdr "ALL DONE in $((ELAPSED / 60))m $((ELAPSED % 60))s"

if (( ${#FAILED[@]} )); then
  err "failed benchmarks: ${FAILED[*]}"
else
  ok "every benchmark completed"
fi

echo
echo "DELIVERABLES"
for b in $PROJECT_BENCHES; do
  printf '  %-28s %s\n' "report_${b}.txt" \
    "$( [[ -f "$HERE/report_${b}.txt" ]] && echo 'generated' || echo 'MISSING')"
  printf '  %-28s %s\n' "script_${b}.sh" \
    "$( [[ -f "$HERE/script_${b}.sh" ]] && echo 'present' || echo 'MISSING')"
done
echo
echo "Comparison summaries:"
for b in $PROJECT_BENCHES; do
  f="$RESULTS_DIR/latest_comparison_${b}/summary.txt"
  [[ -f "$f" ]] && { echo "--- $b ---"; grep -E 'SPEEDUP|IMPROVEMENT|VERDICT' "$f" || true; }
done
echo
log "flame graphs: find results -name '*.svg'"
(( ${#FAILED[@]} )) && exit 1 || exit 0
