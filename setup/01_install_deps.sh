#!/usr/bin/env bash
# =============================================================================
# setup/01_install_deps.sh — install everything needed on a fresh Ubuntu 22.04
# (jammy) guest, matching the cloud image from the course guide.
#
# Run with sudo:  sudo ./setup/01_install_deps.sh
# Idempotent: safe to re-run.
# =============================================================================
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

echo "==> apt update"
apt-get update -y

# --- Why each package -------------------------------------------------------
#  linux-tools-common / -generic / -$(uname -r) : the perf binary. perf is
#      version-locked to the running kernel; installing only -common gives you
#      a stub that refuses to run.
#  python3-dbg  : debug build with DWARF symbols for CPython internals. Without
#      it perf shows one giant opaque _PyEval_EvalFrameDefault block.
#  python3-dev  : headers, needed to build C extensions in the venv.
#  linux-tools-generic pulls in the right perf for HWE kernels.
echo "==> installing perf + build toolchain"
apt-get install -y --no-install-recommends \
  linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic \
  build-essential git curl wget ca-certificates pkg-config \
  python3 python3-dev python3-venv python3-pip python3-dbg \
  binutils elfutils libdw-dev libunwind-dev \
  bzip2 zlib1g-dev \
  util-linux procps time bc jq \
  || {
    echo "!! some packages failed. If linux-tools-$(uname -r) is unavailable"
    echo "!! (common on cloud kernels), try:  apt-get install -y linux-tools-generic"
    echo "!! and then use /usr/lib/linux-tools/*/perf directly."
  }

# Optional but genuinely useful: a Python-native sampling profiler that needs
# no debug build, as an independent cross-check on perf's attribution.
echo "==> installing py-spy (optional)"
python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
python3 -m pip install py-spy 2>/dev/null || echo "   (py-spy install skipped)"

echo
echo "==> verification"
for t in perf git python3 python3-dbg; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  %-12s OK  %s\n' "$t" "$(command -v "$t")"
  else
    printf '  %-12s MISSING\n' "$t"
  fi
done

if command -v perf >/dev/null 2>&1; then
  echo
  perf --version || true
  # A mismatched perf prints a loud warning here instead of failing later.
  perf stat -e task-clock true >/dev/null 2>&1 \
    && echo "  perf can count events: OK" \
    || echo "  !! perf cannot count events yet -> run setup/03_tune_vm.sh"
fi

echo
echo "next: ./setup/02_get_flamegraph.sh"
