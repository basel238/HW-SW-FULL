#!/usr/bin/env bash
# =============================================================================
# tools/doctor.sh — preflight check. Run this FIRST on a new VM.
#
# Distinguishes HARD failures (pipeline cannot run) from SOFT ones (a phase will
# be skipped but you still get results). Exits non-zero only on hard failures.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

HARD=0; SOFT=0

chk()  { # chk <label> <cmd> <hard|soft> <hint>
  local label="$1" cmd="$2" sev="$3" hint="${4:-}"
  if eval "$cmd" >/dev/null 2>&1; then
    printf '  %-34s %sOK%s\n' "$label" "$C_G" "$C_RST"
  elif [[ "$sev" == "hard" ]]; then
    printf '  %-34s %sFAIL%s  %s\n' "$label" "$C_R" "$C_RST" "$hint"; HARD=$((HARD+1))
  else
    printf '  %-34s %sSKIP%s  %s\n' "$label" "$C_Y" "$C_RST" "$hint"; SOFT=$((SOFT+1))
  fi
}

hdr "preflight — required"
chk "bash >= 3.2"        '[[ ${BASH_VERSINFO[0]} -gt 3 || ( ${BASH_VERSINFO[0]} -eq 3 && ${BASH_VERSINFO[1]} -ge 2 ) ]]' hard "bash 3.2+ required (Ubuntu jammy ships 5.1)"
chk "python3 ($PY_REL)"  "command -v $PY_REL"              hard "sudo ./setup/01_install_deps.sh"
chk "perf"               "command -v perf"                 hard "sudo ./setup/01_install_deps.sh"
chk "perf can count"     "perf stat -e task-clock true"     hard "sudo ./setup/03_tune_vm.sh"
chk "benchmark sources"  "[[ -f $REPO_ROOT/bench/bm_raytrace.py && -f $REPO_ROOT/bench/bm_nbody.py ]]" hard "repo is incomplete"
chk "optimized variants" "[[ -f $REPO_ROOT/variants/bm_raytrace_opt.py && -f $REPO_ROOT/variants/bm_nbody_opt.py ]]" hard "repo is incomplete"

hdr "preflight — optional (phase will be skipped if absent)"
chk "python3-dbg ($PY_DBG)" "command -v $PY_DBG" soft \
    "apt install python3-dbg -> without it perf shows no CPython internals"
chk "FlameGraph toolkit"   "[[ -x $FLAMEGRAPH_DIR/flamegraph.pl ]]" soft \
    "./setup/02_get_flamegraph.sh -> needed for flame graphs"
chk "difffolded.pl"        "[[ -x $FLAMEGRAPH_DIR/difffolded.pl ]]" soft \
    "part of FlameGraph; needed for differential flame graphs"
chk "pyperformance venv"   "[[ -f $VENV_DIR/bin/activate ]]" soft \
    "./setup/04_make_venv.sh -> needed for phase 6"
chk "py-spy"               "command -v py-spy" soft \
    "pip install py-spy -> optional cross-check profiler"
chk "taskset (CPU pinning)" "command -v taskset" soft \
    "util-linux; without it runs are noisier"
chk "hardware PMU"         "perf stat -e cycles true" soft \
    "restart QEMU with -enable-kvm -cpu host -> no IPC/cache data without it"

hdr "preflight — measurement hygiene"
P="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)"
if (( P <= 1 )); then
  printf '  %-34s %sOK%s (=%s)\n' "perf_event_paranoid" "$C_G" "$C_RST" "$P"
else
  printf '  %-34s %sWARN%s (=%s) kernel frames hidden -> sudo ./setup/03_tune_vm.sh\n' \
         "perf_event_paranoid" "$C_Y" "$C_RST" "$P"; SOFT=$((SOFT+1))
fi
NPROC="$(nproc 2>/dev/null || echo 1)"
if (( NPROC > PIN_CPU )); then
  printf '  %-34s %sOK%s (pinning to cpu %s of %s)\n' "cpu count" "$C_G" "$C_RST" "$PIN_CPU" "$NPROC"
else
  printf '  %-34s %sWARN%s only %s cpu(s); PIN_CPU=%s is invalid -> set PIN_CPU=0\n' \
         "cpu count" "$C_Y" "$C_RST" "$NPROC" "$PIN_CPU"; SOFT=$((SOFT+1))
fi
LOAD="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
if awk -v l="$LOAD" 'BEGIN{exit !(l < 0.5)}'; then
  printf '  %-34s %sOK%s (%s)\n' "system load" "$C_G" "$C_RST" "$LOAD"
else
  printf '  %-34s %sWARN%s (%s) machine is busy; results will be noisy\n' \
         "system load" "$C_Y" "$C_RST" "$LOAD"; SOFT=$((SOFT+1))
fi

hdr "functional self-test (fast)"
for pair in "bench/bm_raytrace.py:baseline raytrace" \
            "bench/bm_nbody.py:baseline nbody" \
            "variants/bm_raytrace_opt.py:optimized raytrace" \
            "variants/bm_nbody_opt.py:optimized nbody"; do
  f="${pair%%:*}"; label="${pair##*:}"
  if out="$("$PY_REL" "$REPO_ROOT/$f" --mode verify 2>&1)"; then
    printf '  %-34s %sOK%s\n' "verify $label" "$C_G" "$C_RST"
  else
    printf '  %-34s %sFAIL%s\n' "verify $label" "$C_R" "$C_RST"
    echo "$out" | tail -6 | sed 's/^/      /'
    HARD=$((HARD+1))
  fi
done

echo
if (( HARD )); then
  err "$HARD hard failure(s), $SOFT optional item(s) unavailable"
  err "the pipeline will NOT run correctly until the hard failures are fixed"
  exit 1
fi
ok "preflight passed ($SOFT optional item(s) will be skipped)"
exit 0
