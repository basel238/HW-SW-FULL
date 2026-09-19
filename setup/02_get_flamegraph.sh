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
  # --depth 1 tracks a MOVING target: the tool version is not recorded, so a
  # result set cannot be reproduced exactly. Clone fully and record the commit.
  git clone https://github.com/brendangregg/FlameGraph "$FLAMEGRAPH_DIR"
  if [[ -n "${FLAMEGRAPH_COMMIT:-}" ]]; then
    git -C "$FLAMEGRAPH_DIR" checkout -q "$FLAMEGRAPH_COMMIT" \
      && echo "  pinned to $FLAMEGRAPH_COMMIT"
  fi
fi

chmod +x "$FLAMEGRAPH_DIR"/*.pl 2>/dev/null || true

# Record the exact tool version used, for the report's reproducibility section.
FG_COMMIT="$(git -C "$FLAMEGRAPH_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "$FG_COMMIT" > "$FLAMEGRAPH_DIR/.pinned-commit" 2>/dev/null || true
echo "  FlameGraph commit: $FG_COMMIT"
echo "  (pin it for future clones with: export FLAMEGRAPH_COMMIT=$FG_COMMIT)"

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
