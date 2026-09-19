#!/usr/bin/env bash
# =============================================================================
# setup/03_tune_vm.sh — make the guest a usable measurement environment.
#
# Run with sudo. These settings are intentionally permissive; this is a
# throwaway benchmarking VM, NOT a production host.
#
# Every knob here exists because leaving it at its default silently degrades
# either correctness (missing symbols) or precision (noise).
# =============================================================================
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

set_sysctl() {
  local key="$1" val="$2" cur
  cur="$(sysctl -n "$key" 2>/dev/null || echo '<unset>')"
  if sysctl -w "$key=$val" >/dev/null 2>&1; then
    printf '  %-34s %s -> %s\n' "$key" "$cur" "$val"
  else
    printf '  %-34s FAILED (not supported here)\n' "$key"
  fi
}

echo "==> perf permissions"
# -1 = allow sampling kernel addresses too. Without this, kernel frames in the
# flame graph collapse into a useless [unknown] block, and you cannot see
# syscall / page-fault / memory-management cost -- which is exactly where the
# interesting HW/SW boundary effects live.
set_sysctl kernel.perf_event_paranoid -1
# 0 = expose kernel pointers so perf can resolve kernel symbol names.
set_sysctl kernel.kptr_restrict 0
# py-spy and any other attach-based profiler need this.
set_sysctl kernel.yama.ptrace_scope 0

echo
echo "==> noise reduction"
# ASLR shifts library load addresses between runs, which fragments symbol
# attribution and makes two runs harder to diff. Disable for measurement.
set_sysctl kernel.randomize_va_space 0
# The NMI watchdog itself consumes a performance counter. Freeing it can be the
# difference between getting cycles+instructions and getting neither.
set_sysctl kernel.nmi_watchdog 0
# Stop dirty-page writeback storms from landing mid-measurement.
set_sysctl vm.swappiness 10

echo
echo "==> CPU frequency governor"
# Frequency scaling is the single biggest source of run-to-run variance on bare
# metal: the first iterations run at a low clock, later ones boost. In a VM
# this usually does not exist, hence the graceful message.
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$g" 2>/dev/null || true
  done
  echo "  governor set to 'performance' on all CPUs"
  # Intel turbo makes clock a function of thermals/duration -> nondeterministic.
  if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null \
      && echo "  intel turbo disabled (more repeatable clocks)"
  fi
else
  echo "  no cpufreq interface — normal inside a VM (host controls the clock)."
  echo "  Consequence: you cannot pin the guest clock, so always compare"
  echo "  baseline and optimized runs from the SAME session."
fi

echo
echo "==> transparent huge pages"
# THP changes TLB behaviour and page-fault counts between runs. For workloads
# that allocate heavily (deepcopy, pickle) this perturbs minor-faults and dTLB
# counters. 'madvise' is the reproducible middle ground.
if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo "  THP = $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
else
  echo "  THP interface not present"
fi

echo
echo "==> current state"
printf '  perf_event_paranoid : %s\n' "$(cat /proc/sys/kernel/perf_event_paranoid)"
printf '  kptr_restrict       : %s\n' "$(cat /proc/sys/kernel/kptr_restrict)"
printf '  randomize_va_space  : %s\n' "$(cat /proc/sys/kernel/randomize_va_space)"
printf '  nproc               : %s\n' "$(nproc)"
printf '  virtualization      : %s\n' "$(systemd-detect-virt 2>/dev/null || echo unknown)"

echo
echo "==> PMU availability check"
if perf stat -e cycles true >/dev/null 2>&1; then
  echo "  hardware PMU: AVAILABLE — you will get cycles, IPC, cache stats."
else
  cat <<'EOF'
  hardware PMU: NOT AVAILABLE.
  This is the default for QEMU unless the vCPU model forwards the host PMU.
  Flame graphs still work (perf falls back to the cpu-clock software event),
  but cycles / IPC / cache-miss counters will be absent.

  To fix, start the VM with KVM + host CPU model, e.g.:

    qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
      -drive file=jammy-server-cloudimg-amd64-disk-kvm.img,if=virtio \
      -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net,netdev=n0 \
      -nographic

  See docs/VM_SETUP.md for the full recipe.
EOF
fi

echo
echo "NOTE: sysctl changes are runtime-only and reset on reboot. Re-run after"
echo "      every VM boot, or append them to /etc/sysctl.d/99-perf.conf."
echo
echo "next: ./setup/04_make_venv.sh   (as a normal user, NOT root)"
