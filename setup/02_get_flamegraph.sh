#!/usr/bin/env bash
# =============================================================================
# setup/02_get_flamegraph.sh — fetch Brendan Gregg's FlameGraph toolkit.
#
# We shallow-clone into $FLAMEGRAPH_DIR (default ~/FlameGraph) rather than
# vendoring it, to keep this repo's history clean and the licence intact.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/bench.env
source "$REPO_ROOT/config/bench.env"

if [[ -d "$FLAMEGRAPH_DIR/.git" ]]; then
  echo "==> FlameGraph already present at $FLAMEGRAPH_DIR — updating"
  git -C "$FLAMEGRAPH_DIR" pull --ff-only || echo "   (pull failed, using existing copy)"
else
  echo "==> cloning FlameGraph into $FLAMEGRAPH_DIR"
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FLAMEGRAPH_DIR"
fi

chmod +x "$FLAMEGRAPH_DIR"/*.pl 2>/dev/null || true

echo
echo "==> verification"
for s in stackcollapse-perf.pl flamegraph.pl difffolded.pl; do
  if [[ -x "$FLAMEGRAPH_DIR/$s" ]]; then
    printf '  %-26s OK\n' "$s"
  else
    printf '  %-26s MISSING\n' "$s"
  fi
done

# difffolded.pl is what produces the red/blue differential flame graph used in
# tools/compare.sh — worth calling out since it is the most persuasive single
# image for the "show your improvement" deliverable.
echo
echo "note: difffolded.pl enables differential (before/after) flame graphs."
echo "next: ./setup/03_tune_vm.sh   (needs sudo)"
