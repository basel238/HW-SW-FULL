#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared engine for every script_<bench>.sh in this repo.
#
# DESIGN PRINCIPLE: PHASE SEPARATION.
# Profilers perturb what they measure. perf record with dwarf unwinding can add
# 10-30% wall time; cProfile adds 2-5x. So no number we quote is ever taken
# from a profiled process. Each phase runs its own fresh process:
#
#   phase 2  clean timing   -> the ONLY source of speedup claims
#   phase 3  perf stat      -> counting mode, ~1% overhead, gives IPC/cache
#   phase 4  perf record    -> sampling, high overhead, gives flame graphs
#   phase 5  cProfile       -> tracing, huge overhead, gives exact call counts
#   phase 6  pyperformance  -> independent harness, citable mean +- stdev
#
# Phases 4 and 5 write their wall time into a file literally named
# *_DO_NOT_QUOTE_timing.txt so it cannot be mistaken for a result.
# =============================================================================

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
export REPO_ROOT

# shellcheck source=../config/bench.env
source "$REPO_ROOT/config/bench.env"

# --- Output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'
  C_G=$'\033[32m';  C_Y=$'\033[33m'; C_C=$'\033[36m'; C_M=$'\033[35m'
else
  C_RST=; C_B=; C_R=; C_G=; C_Y=; C_C=; C_M=
fi
log()   { printf '%s[%s]%s %s\n' "$C_C" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
err()   { printf '%s[fail]%s %s\n' "$C_R" "$C_RST" "$*" >&2; }
hdr()   { printf '\n%s%s>>> %s%s\n' "$C_B" "$C_M" "$*" "$C_RST"; }
phase() { printf '\n%s%s=== PHASE %s ===%s\n' "$C_B" "$C_C" "$*" "$C_RST"; }
die()   { err "$*"; exit 1; }
trap 'err "aborted at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"' ERR
have()  { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# Run directory
# =============================================================================
init_run() {
  local bench="$1" variant="${2:-baseline}"
  RUN_TAG="${bench}_${variant}_$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="$RESULTS_DIR/$RUN_TAG"
  mkdir -p "$RUN_DIR"/{perf,flame,logs,raw,timing}
  export RUN_DIR RUN_TAG BENCH="$bench" VARIANT="$variant"
  # Relative target: absolute /root/... symlinks break the moment the
  # results tree is copied off the VM.
  ( cd "$RESULTS_DIR" && ln -sfn "$RUN_TAG" "latest_${bench}_${variant}" )
  log "run dir: $RUN_DIR"
}

capture_env() {
  local f="$RUN_DIR/manifest.txt"
  {
    echo "=============================================================="
    echo " run tag    : $RUN_TAG"
    echo " benchmark  : $BENCH        variant: $VARIANT"
    echo " date (UTC) : $(date -u +%FT%TZ)"
    echo " git commit : $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'not-a-git-repo')"
    echo " git dirty  : $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
    echo "=============================================================="
    echo; echo "--- host ---"
    echo "uname      : $(uname -a)"
    echo "distro     : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
    echo "nproc      : $(nproc 2>/dev/null || echo '?')"
    echo "virt       : $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo "hypervisor : $(grep -qm1 hypervisor /proc/cpuinfo 2>/dev/null && echo yes || echo no)"
    echo; echo "--- cpu ---"
    lscpu 2>/dev/null | sed -n '1,22p' || grep -m6 -E 'model name' /proc/cpuinfo || true
    echo; echo "--- memory ---"
    free -h 2>/dev/null || head -3 /proc/meminfo || true
    echo; echo "--- toolchain ---"
    echo "perf       : $(perf --version 2>/dev/null || echo MISSING)"
    echo "PY_REL     : $PY_REL -> $($PY_REL -VV 2>&1 | tr '\n' ' ' || echo MISSING)"
    echo "PY_DBG     : $PY_DBG -> $($PY_DBG -VV 2>&1 | tr '\n' ' ' || echo MISSING)"
    echo "py-spy     : $(py-spy --version 2>/dev/null || echo 'not installed')"
    echo "FlameGraph : $FLAMEGRAPH_DIR $( [[ -d $FLAMEGRAPH_DIR ]] && echo present || echo MISSING)"
    echo; echo "--- kernel knobs affecting measurement ---"
    for k in kernel.perf_event_paranoid kernel.kptr_restrict \
             kernel.randomize_va_space kernel.nmi_watchdog; do
      echo "$k = $(sysctl -n "$k" 2>/dev/null || echo '?')"
    done
    echo "governor   : $(cat /sys/devices/system/cpu/cpu${PIN_CPU}/cpufreq/scaling_governor 2>/dev/null || echo 'n/a (virtualized)')"
    echo "THP        : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
    echo "PMU        : ${PMU_OK:-unprobed}"
    echo; echo "--- measurement config ---"
    echo "SAMPLE_FREQ=$SAMPLE_FREQ  CALLGRAPH=$CALLGRAPH  TARGET_SEC=$TARGET_SEC"
    echo "CLEAN_REPS=$CLEAN_REPS  REPS=$REPS  LOOPS=${LOOPS:-auto}"
    # Record both requested and effective values: build_pin() clamps PIN_CPU to
    # an existing CPU, so the requested value alone can misdescribe the run.
    echo "PIN_CPU requested=$PIN_CPU  effective=$( \
        n=$(nproc 2>/dev/null || echo 1); \
        if [[ "$USE_TASKSET" == "1" ]] && command -v taskset >/dev/null 2>&1; then \
          if (( PIN_CPU >= n )); then echo "$((n-1)) (clamped from $PIN_CPU)"; \
          else echo "$PIN_CPU"; fi; \
        else echo "none (taskset disabled or absent)"; fi)"
    echo "USE_TASKSET=$USE_TASKSET  nproc=$(nproc 2>/dev/null || echo '?')"
    echo "sampling: PERF_RECORD_MODE=${PERF_RECORD_MODE:-?} "\
         "SAMPLE_PERIOD=${SAMPLE_PERIOD:-?} EVENT=${PERF_RECORD_EVENT:-auto}"
    echo "unwind:   CALLGRAPH=$CALLGRAPH DWARF_STACK_BYTES=${DWARF_STACK_BYTES:-n/a}"
    echo "PYTHONHASHSEED=$PYTHONHASHSEED_VALUE  DISABLE_GC=$DISABLE_GC"
    echo
    echo "TIMING POLICY: quote only phase2_clean (results/timing/clean_*.txt)."
    echo "Files named *DO_NOT_QUOTE* come from profiled runs and are"
    echo "inflated by profiler overhead; they exist only for cross-checking."
  } > "$f" 2>&1
  ok "environment captured -> manifest.txt"
}

# =============================================================================
# Preconditions
# =============================================================================
require_perf() {
  have perf || die "perf not found. Run: sudo ./setup/01_install_deps.sh"
  local p; p="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)"
  (( p > 1 )) && {
    warn "perf_event_paranoid=$p -> kernel frames hidden."
    warn "fix: sudo ./setup/03_tune_vm.sh"
  }
  return 0
}

require_python_dbg() {
  if ! have "$PY_DBG"; then
    warn "$PY_DBG missing -> perf will show one opaque _PyEval_EvalFrameDefault"
    warn "block with nothing below it. Install: sudo apt install -y python3-dbg"
    warn "Falling back to $PY_REL for the sampling phase."
    PY_DBG="$PY_REL"
  fi
  export PY_DBG
}

# Probe events one at a time: perf stat aborts the whole run on a single
# unsupported event, and a QEMU guest without -cpu host has no PMU at all.
filter_supported_events() {
  local want="$1" supported="" e arr
  IFS=',' read -ra arr <<< "$want"
  for e in "${arr[@]}"; do
    [[ -n "$e" ]] || continue
    if perf stat -e "$e" -x, true >/dev/null 2>&1; then
      # Build a plain string, not an array. Under `set -u`, "${arr[*]}" on an
      # EMPTY array is an unbound-variable error in bash 3.2 -- and the empty
      # case is the normal one on a QEMU guest with no PMU, which is exactly
      # the configuration this function exists to handle.
      [[ -n "$supported" ]] && supported="$supported,$e" || supported="$e"
    fi
  done
  printf '%s' "$supported"
}

probe_pmu() {
  hdr "probing available perf events"
  local sw hw mem fp
  sw="$(filter_supported_events "$PERF_EVENTS_SW")"
  hw="$(filter_supported_events "$PERF_EVENTS_HW")"
  mem="$(filter_supported_events "$PERF_EVENTS_MEM")"
  fp="$(filter_supported_events "$PERF_EVENTS_FP")"

  if [[ -n "$hw" ]]; then
    PMU_OK=1; ok "hardware PMU present"
  else
    PMU_OK=0
    warn "NO hardware PMU events available."
    warn "You are in a QEMU guest without PMU passthrough."
    warn "Flame graphs still work (perf uses the cpu-clock software event),"
    warn "but cycles/IPC/cache counters will be missing."
    warn "Fix: restart QEMU with  -enable-kvm -cpu host   (see docs/VM_SETUP.md)"
  fi

  PERF_EVENTS="$(printf '%s,%s,%s,%s' "$sw" "$hw" "$mem" "$fp" \
                 | sed 's/,\{2,\}/,/g; s/^,//; s/,$//')"
  export PMU_OK PERF_EVENTS
  printf '%s\n' "$PERF_EVENTS" | tr ',' '\n' > "$RUN_DIR/perf/events_used.txt"
  ok "events: $PERF_EVENTS"
}

# =============================================================================
# Command helpers
# =============================================================================
# Emits taskset words into the global array PIN[] (avoids unquoted expansion).
build_pin() {
  PIN=()
  [[ "$USE_TASKSET" == "1" ]] || return 0
  have taskset || return 0
  # Clamp PIN_CPU to a CPU that actually exists. A 1-vCPU guest would otherwise
  # make every taskset invocation fail, silently killing all measurements.
  local n; n="$(nproc 2>/dev/null || echo 1)"
  if (( PIN_CPU >= n )); then
    warn "PIN_CPU=$PIN_CPU but only $n cpu(s) present -> clamping to $((n - 1))"
    PIN_CPU=$((n - 1)); export PIN_CPU
  fi
  PIN=(taskset -c "$PIN_CPU")
}

py_env() {
  # TARGET_SEC must be exported: the Python calibrators read it from the
  # environment. Without this the config knob has no effect.
  export TARGET_SEC
  export PYTHONHASHSEED="$PYTHONHASHSEED_VALUE"
  export PYTHONDONTWRITEBYTECODE=1   # no .pyc writes mid-measurement
  export PYTHONUNBUFFERED=1
}

# Workload argv for a given script + mode. GC flag applied centrally.
workload_args() {
  local script="$1"; shift
  WL=("$script" "$@")
  # NOTE the explicit if/fi. Written as `[[ ... ]] && WL+=(...)` the function
  # returns 1 whenever DISABLE_GC != 1, and under `set -e` that aborts the whole
  # run -- i.e. the documented DISABLE_GC=0 option was fatal. Found by review.
  if [[ "$DISABLE_GC" == "1" ]]; then
    WL+=(--no-gc)
  fi
  return 0
}

# =============================================================================
# PHASE 1 — correctness gate
# =============================================================================
run_verify() {
  local script="$1"
  [[ "$ENABLE_VERIFY" == "1" ]] || return 0
  phase "1  correctness verification"
  py_env
  if "$PY_REL" "$script" --mode verify 2>&1 | tee "$RUN_DIR/logs/verify.log"; then
    ok "correctness gate passed"
  else
    die "VERIFY FAILED — refusing to benchmark incorrect code. See logs/verify.log"
  fi
}

# =============================================================================
# PHASE 2 — clean timing (ZERO instrumentation). The only quotable numbers.
# =============================================================================
run_clean_timing() {
  local script="$1" loops="$2"
  [[ "$ENABLE_CLEAN_TIMING" == "1" ]] || return 0
  phase "2  clean timing — NO profiler attached (quote these numbers)"

  build_pin; py_env
  workload_args "$script" --mode raw --loops "$loops"
  local out="$RUN_DIR/timing/clean_${VARIANT}.txt"
  local csv="$RUN_DIR/timing/clean_${VARIANT}.csv"
  : > "$out"; echo "rep,total_sec" > "$csv"

  log "running $CLEAN_REPS independent processes, loops=$loops"
  local i t
  for (( i=1; i<=CLEAN_REPS; i++ )); do
    # Fresh process every rep: no warm caches carried across reps, no profiler,
    # no perf, no tracing. This is as close to the true cost as we can get.
    ${PIN[@]+"${PIN[@]}"} "$PY_REL" ${WL[@]+"${WL[@]}"} > "$RUN_DIR/timing/.rep$i" 2>&1 || {
      warn "rep $i failed"; cat "$RUN_DIR/timing/.rep$i" >&2; continue; }
    cat "$RUN_DIR/timing/.rep$i" >> "$out"
    t="$(grep -oE 'total_sec=[0-9.]+' "$RUN_DIR/timing/.rep$i" | head -1 | cut -d= -f2)"
    [[ -n "$t" ]] && { echo "$i,$t" >> "$csv"; printf '  rep %d: %s s\n' "$i" "$t"; }
    rm -f "$RUN_DIR/timing/.rep$i"
  done

  # Median is the headline statistic, not mean: it is robust to the occasional
  # outlier from a host-side hiccup, which is unavoidable in a VM.
  "$PY_REL" - "$csv" <<'PY' | tee "$RUN_DIR/timing/clean_${VARIANT}_summary.txt"
import csv, statistics, sys
vals = []
with open(sys.argv[1]) as fh:
    for row in csv.DictReader(fh):
        try: vals.append(float(row["total_sec"]))
        except (ValueError, KeyError): pass
if not vals:
    print("no samples collected"); sys.exit(0)
vals.sort()
mean = statistics.mean(vals)
sd   = statistics.stdev(vals) if len(vals) > 1 else 0.0
print(f"n        = {len(vals)}")
print(f"min      = {min(vals):.6f} s")
print(f"median   = {statistics.median(vals):.6f} s   <-- headline")
print(f"mean     = {mean:.6f} s")
print(f"max      = {max(vals):.6f} s")
print(f"stdev    = {sd:.6f} s")
print(f"rel_sd   = {(sd/mean*100 if mean else 0):.2f} %")
if mean and sd/mean > 0.05:
    print("WARNING: rel_sd > 5% -- environment is noisy; results are not")
    print("         trustworthy. Close other work, re-run setup/03_tune_vm.sh,")
    print("         or raise CLEAN_REPS.")
PY
  ok "clean timing -> timing/clean_${VARIANT}_summary.txt"
}

# =============================================================================
# PHASE 3 — perf stat (counting mode: near-zero overhead)
# =============================================================================
run_perf_stat() {
  local script="$1" loops="$2"
  [[ "$ENABLE_PERF_STAT" == "1" ]] || return 0
  phase "3  perf stat — hardware counters (counting mode, ~1% overhead)"

  build_pin; py_env
  workload_args "$script" --mode raw --loops "$loops"
  local base="$RUN_DIR/perf/stat_${VARIANT}"
  local ev=(); [[ -n "$PERF_EVENTS" ]] && ev=(-e "$PERF_EVENTS")

  # NOTE: counting mode only. No -g, no -F. perf programs the counters once and
  # reads them at exit, so the workload runs at essentially full speed. This is
  # why IPC/cache-miss ratios from here are valid even though wall time from
  # phase 4 is not.
  log "perf stat -r $REPS (mean +- stddev over $REPS runs)"
  perf stat ${ev[@]+"${ev[@]}"} -r "$REPS" -o "$base.txt" \
      -- ${PIN[@]+"${PIN[@]}"} "$PY_REL" ${WL[@]+"${WL[@]}"} \
      > "$base.workload.log" 2>&1 || warn "perf stat returned non-zero"
  # Machine-readable copy for tools/compare.sh
  perf stat ${ev[@]+"${ev[@]}"} -r "$REPS" -x, -o "$base.csv" \
      -- ${PIN[@]+"${PIN[@]}"} "$PY_REL" ${WL[@]+"${WL[@]}"} \
      > /dev/null 2>&1 || true

  [[ -f "$base.txt" ]] && { ok "-> perf/stat_${VARIANT}.txt"; sed -n '1,45p' "$base.txt"; }

  # Topdown / CPI-stack breakdown: attributes stalls to frontend vs backend vs
  # bad speculation (lecture 3, and the tutorial's "backend bound" discussion).
  if [[ "$ENABLE_TOPDOWN" == "1" && "${PMU_OK:-0}" == "1" ]]; then
    log "attempting topdown breakdown"
    perf stat --topdown -a -o "$base.topdown.txt" \
        -- ${PIN[@]+"${PIN[@]}"} "$PY_REL" ${WL[@]+"${WL[@]}"} >/dev/null 2>&1 \
      && ok "-> perf/stat_${VARIANT}.topdown.txt" \
      || log "topdown unsupported on this CPU/PMU, skipped"
  fi
}

# =============================================================================
# PHASE 4 — perf record (sampling; HIGH overhead, timing NOT quotable)
# =============================================================================
run_perf_record() {
  local script="$1" loops="$2" tag="${3:-$VARIANT}"
  [[ "$ENABLE_PERF_RECORD" == "1" ]] || return 0
  phase "4  perf record — call-graph sampling for flame graphs"
  warn "this phase uses $PY_DBG and dwarf unwinding: wall time here is"
  warn "inflated on purpose and is NOT a performance result."

  build_pin; py_env
  # Debug interpreter is slower, so scale the loop count down to keep the pass
  # around TARGET_SEC. Sample COUNT is what matters for a flame graph, not
  # wall time, so this costs us nothing analytically.
  local rloops=$(( loops / 3 )); (( rloops < 1 )) && rloops=1
  workload_args "$script" --mode raw --loops "$rloops"

  local data="$RUN_DIR/perf/${tag}.data"
  local cg=(--call-graph "$CALLGRAPH")
  [[ "$CALLGRAPH" == "dwarf" ]] && cg=(--call-graph "dwarf,$DWARF_STACK_BYTES")

  # Sampling selector. On the target VM's partially-emulated PMU, frequency
  # mode (-F) captured ZERO samples while perf exited 0; fixed period (-c) works.
  local samp=() sev=()
  if [[ "${PERF_RECORD_MODE:-period}" == "period" ]]; then
    samp=(-c "${SAMPLE_PERIOD:-5000000}")
  else
    samp=(-F "$SAMPLE_FREQ")
  fi
  [[ -n "${PERF_RECORD_EVENT:-}" ]] && sev=(-e "$PERF_RECORD_EVENT")

  log "perf record ${sev[*]-} ${samp[*]} --call-graph $CALLGRAPH (loops=$rloops, $PY_DBG)"
  if ! perf record ${sev[@]+"${sev[@]}"} ${samp[@]+"${samp[@]}"} ${cg[@]+"${cg[@]}"} -m "$PERF_MMAP_PAGES" \
        --output="$data" -- ${PIN[@]+"${PIN[@]}"} "$PY_DBG" ${WL[@]+"${WL[@]}"} \
        > "$RUN_DIR/logs/${tag}_record.log" 2>&1; then
    warn "perf record failed:"; tail -20 "$RUN_DIR/logs/${tag}_record.log" >&2; return 0
  fi

  # Quarantine the inflated timing so it can never be mistaken for a result.
  grep -E 'RESULT|elapsed|total_sec' "$RUN_DIR/logs/${tag}_record.log" 2>/dev/null \
      > "$RUN_DIR/timing/${tag}_DO_NOT_QUOTE_timing.txt" || true

  # Lost samples silently invalidate every downstream conclusion.
  if grep -qiE 'lost [0-9]+|truncated' "$RUN_DIR/logs/${tag}_record.log"; then
    warn "LOST SAMPLES detected -> flame graph may be skewed."
    warn "raise PERF_MMAP_PAGES (now $PERF_MMAP_PAGES) or lower SAMPLE_FREQ."
  fi
  # perf prints "# Samples: 3K" -- the K/M/G suffix MUST be normalized or a
  # healthy run reports "3 samples". Anchor on '^# Samples:' so we do not match
  # the '# Total Lost Samples:' line that precedes it.
  local raw nsamp
  raw="$(perf report -i "$data" --stdio 2>/dev/null \
         | grep -m1 -oE '^# Samples: [0-9.]+[KMG]?' | sed 's/^# Samples: //')"
  case "$raw" in
    *K) nsamp=$(awk -v v="${raw%K}" 'BEGIN{printf "%d", v*1000}') ;;
    *M) nsamp=$(awk -v v="${raw%M}" 'BEGIN{printf "%d", v*1000000}') ;;
    *G) nsamp=$(awk -v v="${raw%G}" 'BEGIN{printf "%d", v*1000000000}') ;;
    "") nsamp=0 ;;
    *)  nsamp="${raw%%.*}" ;;
  esac

  # NO automatic event substitution. A flame graph silently built from a
  # different event than requested is worse than no flame graph, so this fails
  # loudly and tells you exactly which knob to change.
  if (( nsamp < ${MIN_SAMPLES:-200} )); then
    err "perf record captured only ${nsamp} samples (minimum ${MIN_SAMPLES:-200})."
    err "NOT substituting another event. Fix the configuration instead:"
    err "    PERF_RECORD_MODE=period       # if currently freq"
    err "    SAMPLE_PERIOD=<smaller>       # currently ${SAMPLE_PERIOD:-?}"
    err "    PERF_RECORD_EVENT=cpu-clock   # only if the PMU cannot sample"
    err "Flame graph SKIPPED for ${tag}."
    return 0
  fi
  ok "$(du -h "$data" 2>/dev/null | cut -f1) perf.data, $nsamp samples"

  make_reports "$tag" "$data"
  make_flamegraph "$tag" "$data"
}

make_reports() {
  local tag="$1" data="$2" rp="$RUN_DIR/perf"
  log "generating perf reports"
  # The exact command from the project brief:
  perf report --stdio -i "$data"                    > "$rp/report_${tag}.txt"          2>/dev/null || true
  # Flat/self profile: which single function burns the most cycles itself.
  perf report --stdio --no-children -i "$data"      > "$rp/report_${tag}_self.txt"     2>/dev/null || true
  # Inverted call graph: who is responsible for calling the hot leaf.
  perf report --stdio -g graph,0.5,caller -i "$data" > "$rp/report_${tag}_callers.txt" 2>/dev/null || true
  # Per-DSO: separates interpreter time from libm / kernel time.
  perf report --stdio --sort dso -i "$data"         > "$rp/report_${tag}_dso.txt"      2>/dev/null || true
  # Symbol CSV -> consumed by tools/compare.sh for before/after diffing.
  perf report --stdio --no-children -i "$data" -F overhead,dso,symbol -t, 2>/dev/null \
      | grep -v '^#' | sed '/^$/d' > "$rp/report_${tag}_symbols.csv" || true
  # Raw samples -> input to stackcollapse. THIS IS THE SLOW STEP: DWARF
  # unwinding is deferred to post-processing, measured at ~0.6 s/sample with a
  # 16 KB stack slice on the target VM (halved by DWARF_STACK_BYTES=8192).
  local est; est=$(awk -v n="${nsamp:-0}" 'BEGIN{printf "%d", n*0.3}')
  log "perf script (DWARF unwind of ${nsamp:-?} samples, est. ~${est}s -- be patient)"
  perf script -i "$data" > "$rp/${tag}_script.txt" 2>/dev/null || true
  local avg
  avg=$(awk '/^$/{if(d){s+=d;n++;d=0};next} /^\t/{d++} END{if(n)printf "%.1f", s/n}' \
        "$rp/${tag}_script.txt" 2>/dev/null)
  if [[ -n "$avg" ]]; then
    log "average stack depth: $avg"
    # A mean depth this shallow means unwinding failed and the "flame graph"
    # would be a flat profile in disguise. Measured: fp=2.5, dwarf=71.2.
    awk -v a="$avg" 'BEGIN{exit !(a < 5)}' && {
      warn "stack depth $avg is implausibly shallow -> unwinding is failing."
      warn "Set CALLGRAPH=dwarf (CPython has no frame pointers)."; }
  fi
  ok "reports: report_${tag}{,_self,_callers,_dso}.txt + symbols.csv"
}

make_flamegraph() {
  local tag="$1" data="$2"
  [[ "$ENABLE_FLAMEGRAPH" == "1" ]] || return 0
  local sc="$FLAMEGRAPH_DIR/stackcollapse-perf.pl" fg="$FLAMEGRAPH_DIR/flamegraph.pl"
  [[ -x "$sc" && -x "$fg" ]] || {
    warn "FlameGraph missing in $FLAMEGRAPH_DIR -> run ./setup/02_get_flamegraph.sh"; return 0; }

  hdr "flame graphs — $tag"
  local script="$RUN_DIR/perf/${tag}_script.txt"
  [[ -s "$script" ]] || { warn "empty perf script output"; return 0; }

  local folded="$RUN_DIR/flame/${tag}.folded"
  "$sc" "$script" > "$folded" 2>/dev/null || { warn "stackcollapse failed"; return 0; }
  [[ -s "$folded" ]] || { warn "no stacks folded"; return 0; }

  local subtitle="$(date -u +%FT%TZ) | F=$SAMPLE_FREQ | $CALLGRAPH | $(basename "$PY_DBG")"
  "$fg" --title "$BENCH/$VARIANT — CPU flame graph" --subtitle "$subtitle" \
        --width 1800 --colors java "$folded" > "$RUN_DIR/flame/${tag}.svg" 2>/dev/null \
    || { warn "flamegraph.pl failed"; return 0; }

  # Icicle (top-down): makes recursion depth obvious — the whole story for
  # raytrace's recursive ray bounces.
  "$fg" --inverted --reverse --title "$BENCH/$VARIANT — icicle (top-down)" \
        --width 1800 "$folded" > "$RUN_DIR/flame/${tag}_icicle.svg" 2>/dev/null || true

  # Python-frames-only view: drops C/kernel frames so the graph maps onto
  # source lines the student can actually edit.
  grep -E '\.py|Py[A-Z_]|_PyEval' "$folded" > "$RUN_DIR/flame/${tag}_python.folded" 2>/dev/null || true
  [[ -s "$RUN_DIR/flame/${tag}_python.folded" ]] && \
    "$fg" --title "$BENCH/$VARIANT — Python frames only" --width 1800 \
          "$RUN_DIR/flame/${tag}_python.folded" \
          > "$RUN_DIR/flame/${tag}_python.svg" 2>/dev/null || true

  ok "flame/${tag}.svg (+ _icicle, _python)"
  sort -k2 -nr "$folded" | head -30 > "$RUN_DIR/flame/${tag}_top30_stacks.txt" || true
}

# Sampling keyed on cache-misses rather than time: answers "where do the misses
# come from", which time-based sampling structurally cannot.
run_cache_profile() {
  local script="$1" loops="$2" tag="${3:-$VARIANT}"
  [[ "$ENABLE_CACHE_PROFILE" == "1" && "${PMU_OK:-0}" == "1" ]] || {
    log "cache profiling needs a real PMU, skipped"; return 0; }
  hdr "cache-miss attribution — $tag"
  build_pin; py_env
  local rloops=$(( loops / 3 )); (( rloops < 1 )) && rloops=1
  workload_args "$script" --mode raw --loops "$rloops"
  local data="$RUN_DIR/perf/${tag}_cachemiss.data"
  # -c 10000: sample every 10k misses (period, not frequency) to bound overhead.
  if perf record -e cache-misses -c 10000 --call-graph "$CALLGRAPH" \
       --output="$data" -- ${PIN[@]+"${PIN[@]}"} "$PY_DBG" ${WL[@]+"${WL[@]}"} \
       > "$RUN_DIR/logs/${tag}_cache.log" 2>&1; then
    perf report --stdio --no-children -i "$data" \
       > "$RUN_DIR/perf/report_${tag}_cachemiss.txt" 2>/dev/null || true
    ok "-> perf/report_${tag}_cachemiss.txt"
  else
    log "cache-miss sampling unavailable (event likely emulated), skipped"
  fi
}

# =============================================================================
# PHASE 5 — cProfile (exact call counts; 2-5x overhead, timing NOT quotable)
# =============================================================================
run_cprofile() {
  local script="$1" loops="$2"
  [[ "$ENABLE_CPROFILE" == "1" ]] || return 0
  phase "5  cProfile — exact call counts (deterministic tracing)"
  warn "cProfile adds 2-5x overhead; use it for CALL COUNTS, never for timing."

  build_pin; py_env
  # Far fewer loops: we want counts and the call tree, not a long run.
  # cProfile runs FEWER loops than the timed phases (tracing is 2-5x slower).
  # That means its call counts and totals are NOT comparable to another
  # variant's unless divided by this number, so record it next to the output.
  local cloops=$(( loops / 10 )); (( cloops < 1 )) && cloops=1
  echo "$cloops" > "$RUN_DIR/raw/cprofile_${VARIANT}_loops.txt"
  workload_args "$script" --mode raw --loops "$cloops"
  local pstats="$RUN_DIR/raw/cprofile_${VARIANT}.pstats"

  if ${PIN[@]+"${PIN[@]}"} "$PY_REL" -m cProfile -o "$pstats" ${WL[@]+"${WL[@]}"} \
       > "$RUN_DIR/logs/cprofile.log" 2>&1; then
    # Note the UNQUOTED heredoc delimiter is avoided; we pass the path as argv
    # so no shell expansion happens inside the Python source.
    "$PY_REL" - "$pstats" > "$RUN_DIR/raw/cprofile_${VARIANT}.txt" 2>&1 <<'PY' || true
import pstats, sys
st = pstats.Stats(sys.argv[1])
print("=" * 70); print("TOP 40 BY TOTTIME (self time, excludes subcalls)"); print("=" * 70)
st.sort_stats("tottime").print_stats(40)
print("=" * 70); print("TOP 25 BY CUMTIME (includes subcalls)"); print("=" * 70)
st.sort_stats("cumtime").print_stats(25)
print("=" * 70); print("CALLEES OF THE 15 HOTTEST FUNCTIONS"); print("=" * 70)
st.sort_stats("tottime").print_callees(15)
PY
    # Prepend the normalization header: an earlier version left readers to
    # compare raw totals from runs with different loop counts.
    { echo "# cProfile for $BENCH/$VARIANT"
      echo "# LOOPS IN THIS PROFILE: $cloops"
      echo "#"
      echo "# Divide ncalls and tottime by $cloops for per-unit figures."
      echo "# Comparing raw totals against another variant is INVALID unless"
      echo "# both were profiled with the same loop count."
      echo "#"
      echo "# cProfile TIMING is inflated 2-5x by tracing overhead. Use this"
      echo "# file for CALL COUNTS only; quote timing from timing/clean_*."
      echo
      cat "$RUN_DIR/raw/cprofile_${VARIANT}.txt"
    } > "$RUN_DIR/raw/.cp.tmp" && mv "$RUN_DIR/raw/.cp.tmp" "$RUN_DIR/raw/cprofile_${VARIANT}.txt"
    ok "-> raw/cprofile_${VARIANT}.txt (loops=$cloops, normalize before comparing)"
    grep -A12 'TOP 40 BY TOTTIME' "$RUN_DIR/raw/cprofile_${VARIANT}.txt" 2>/dev/null | head -20 || true
  else
    warn "cProfile failed; see logs/cprofile.log"
  fi
}

# py-spy: independent sampling profiler, no debug build needed. Good sanity
# check that perf's attribution is not an artifact of dwarf unwinding.
run_pyspy() {
  local script="$1" loops="$2"
  [[ "$ENABLE_PYSPY" == "1" ]] || return 0
  have py-spy || { log "py-spy not installed, skipped"; return 0; }
  hdr "py-spy — native Python flame graph (cross-check)"
  build_pin; py_env
  workload_args "$script" --mode raw --loops "$loops"
  py-spy record --rate 999 --subprocesses --format flamegraph \
      --output "$RUN_DIR/flame/${VARIANT}_pyspy.svg" \
      -- "$PY_REL" ${WL[@]+"${WL[@]}"} > "$RUN_DIR/logs/pyspy.log" 2>&1 \
    && ok "-> flame/${VARIANT}_pyspy.svg" \
    || warn "py-spy failed (may need: sudo sysctl -w kernel.yama.ptrace_scope=0)"
}

# =============================================================================
# PHASE 6 — pyperformance (the citable number)
# =============================================================================
activate_venv() {
  [[ -f "$VENV_DIR/bin/activate" ]] || die "venv missing at $VENV_DIR — run ./setup/04_make_venv.sh"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
}

run_pyperformance() {
  local bench="$1" tag="${2:-$VARIANT}"
  [[ "$ENABLE_PYPERFORMANCE" == "1" ]] || return 0
  phase "6  pyperformance — upstream harness (calibration + warmups + stdev)"
  activate_venv; py_env; build_pin

  local json="$RUN_DIR/raw/pyperf_${tag}.json"
  if ${PIN[@]+"${PIN[@]}"} pyperformance run --benchmarks "$bench" \
        --output "$json" > "$RUN_DIR/logs/pyperformance_${tag}.log" 2>&1; then
    ok "-> raw/pyperf_${tag}.json"
    python -m pyperf stats "$json" > "$RUN_DIR/raw/pyperf_${tag}_stats.txt" 2>/dev/null || true
    # Distribution, not just the mean — cf. the Histogram/PDF/CDF lecture.
    python -m pyperf hist "$json"  > "$RUN_DIR/raw/pyperf_${tag}_hist.txt"  2>/dev/null || true
    python -m pyperf dump "$json"  > "$RUN_DIR/raw/pyperf_${tag}_dump.txt"  2>/dev/null || true
    grep -E 'Mean|Median|Minimum|Maximum|stdev|MAD' \
        "$RUN_DIR/raw/pyperf_${tag}_stats.txt" 2>/dev/null | head -12 || true
  else
    warn "pyperformance failed; tail of log:"
    tail -25 "$RUN_DIR/logs/pyperformance_${tag}.log" >&2
  fi
  deactivate 2>/dev/null || true
}

# =============================================================================
# Calibration + wrap-up
# =============================================================================
# Determine a loop count on the RELEASE interpreter, once, then reuse it across
# all phases so every phase does identical work.
calibrate_loops() {
  local script="$1"
  if [[ -n "$LOOPS" ]]; then echo "$LOOPS"; return; fi
  py_env
  local n; n="$("$PY_REL" "$script" --mode calibrate 2>/dev/null | tail -1 | tr -dc '0-9')"
  [[ -n "$n" && "$n" -gt 0 ]] 2>/dev/null || n=64
  echo "$n"
}

finish_run() {
  hdr "run complete"
  { echo; echo "--- artifacts ---"
    find "$RUN_DIR" -type f | sed "s|$RUN_DIR/||" | sort; } >> "$RUN_DIR/manifest.txt"
  ok "artifacts: $RUN_DIR"
  printf '  %-22s %s\n' "QUOTABLE timing:" "timing/clean_${VARIANT}_summary.txt"
  printf '  %-22s %s\n' "counters:"        "perf/stat_${VARIANT}.txt"
  printf '  %-22s %s\n' "flame graphs:"    "flame/*.svg"
  printf '  %-22s %s\n' "perf reports:"    "perf/report_*.txt"
  printf '  %-22s %s\n' "manifest:"        "manifest.txt"
  echo
  log "next: ./tools/compare.sh $BENCH   (once baseline + optimized both exist)"
}
