#!/usr/bin/env bash
# =============================================================================
# setup/04_make_venv.sh — create the venv holding pyperformance + pyperf.
#
# Run as a NORMAL user (not root), so the venv is writable without sudo.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/bench.env
source "$REPO_ROOT/config/bench.env"

echo "==> creating venv at $VENV_DIR"
mkdir -p "$(dirname "$VENV_DIR")"
[[ -d "$VENV_DIR" ]] || python3 -m venv "$VENV_DIR"

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "==> installing pyperformance"
pip install --upgrade pip setuptools wheel
# pyperformance pulls in pyperf (the statistics/JSON harness) transitively.
# PINNED versions. An unpinned install makes a result set unreproducible: a
# later pyperformance release can change a benchmark's workload or harness.
# 1.14.0 is the version that produced the results in results/ (see the pyperf
# metadata in raw/pyperf_*.json).
PYPERFORMANCE_VERSION="${PYPERFORMANCE_VERSION:-1.14.0}"
pip install "pyperformance==${PYPERFORMANCE_VERSION}"
echo "  pinned pyperformance==${PYPERFORMANCE_VERSION}"
echo "  (override with PYPERFORMANCE_VERSION=x.y.z if a different one is required)"

echo
echo "==> verification"
pyperformance --version || true
python -m pyperf --version || true

echo
echo "==> available benchmarks (the project's two must appear here)"
pyperformance list 2>/dev/null | head -80 || echo "  (list unavailable)"

echo
for b in $PROJECT_BENCHES; do
  if pyperformance list 2>/dev/null | grep -qw "$b"; then
    printf '  %-16s FOUND\n' "$b"
  else
    printf '  %-16s NOT LISTED — check the name with: pyperformance list\n' "$b"
  fi
done

echo
# Record exactly what was installed, so a result set can be reproduced.
pip freeze > "$VENV_DIR/requirements.lock.txt" 2>/dev/null || true
echo "  dependency lock -> $VENV_DIR/requirements.lock.txt"

echo "venv ready. The run scripts activate it automatically."
echo "next: ./run_all.sh        (full pipeline)"
echo "  or: ./script_deepcopy.sh --help"
