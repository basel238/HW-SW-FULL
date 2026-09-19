# FIXES — what changed in this version and why

Every entry was found either by an external code review or by running the code
on the target VM. Each states the defect, the mechanism, and the evidence.

---

## Measurement-validity fixes

### M1 — `compare.sh` compared unequal work  [CRITICAL]

`tools/compare.sh` divided raw `total_sec` medians while each variant had been
**independently calibrated** to hit `TARGET_SEC`. Baseline raytrace ran 16
frames per process; optimized ran 32. The script contained *zero* references to
`loops.txt`.

```
reported : 4.126748 / 3.084778           = 1.3378x  (25.25%)
correct  : (4.126748/16) / (3.084778/32) = 2.6756x  (62.62%)
```

**Fix:** `load()` now divides by `loops.txt` and reports per-unit figures. If
`loops.txt` is missing the comparison **refuses to report a speedup** rather
than silently comparing unequal work. Raw medians are still shown, explicitly
labelled *NOT comparable directly*.

Also now separates **time reduction** (62.62%) from **throughput gain**
(167.56%) — different metrics, easily conflated — and prints margin-to-bar in
units of measured noise.

### M2 — `perf record` captured zero samples, silently

On the target VM (Xeon E5-2630 v3 guest, KVM, partial PMU), `perf record -F 999`
captured **0 samples** while exiting 0. Every downstream artifact was empty:

| artifact | expected | actual |
|---|---|---|
| `baseline.data` | MBs | 24 KB (headers only) |
| `baseline_script.txt` | MBs | 0 bytes |
| `report_baseline.txt` | thousands of lines | 85 bytes |
| `*.folded`, `*.svg` | present | never created |

The cache-miss pass, which used `-c 10000` (fixed **period**), worked fine and
produced 23 KB of real symbols. Frequency-based sampling depends on a timer the
emulated PMU does not drive reliably.

**Fix:** `PERF_RECORD_MODE=period` is now the default, with `SAMPLE_PERIOD` and
`PERF_RECORD_EVENT` exposed. Confirmed: `-c 2000000` → 2058 samples, 0 lost.

### M3 — sample count misparsed as 3 instead of 3000

`perf report` prints `# Samples: 3K`. The regex `[0-9]+` captured the `3` and
dropped the `K`, so a healthy run logged "3 samples".

**Fix:** suffix-aware parsing (K/M/G), anchored on `^# Samples:` so it cannot
match the `# Total Lost Samples:` line that precedes it.

### M4 — no minimum-sample gate, and no silent substitution

**Fix:** profiles below `MIN_SAMPLES` (default 200) fail **loudly** and name the
knob to change. There is deliberately **no automatic fallback to another event**:
a flame graph built from a different event than requested is worse than no flame
graph, because nothing in the output records the substitution.

### M5 — `CALLGRAPH=fp` truncated every stack

CPython is compiled `-fomit-frame-pointer`, so the frame-pointer walker gets one
or two links and stops. Measured on the target VM:

| unwind | avg stack depth |
|---|---|
| `fp` | **2.5** |
| `dwarf` | **71.2** |

93% of `fp` stacks were 2–3 frames with `python3-dbg` as the only root. Leaf
percentages remained valid (they need only the innermost frame), but the
*hierarchy* was fiction — a flat profile drawn as a flame graph.

**Fix:** `CALLGRAPH=dwarf` is the default, with the reason documented inline.
`make_reports` now measures average stack depth and warns below 5.
`DWARF_STACK_BYTES` reduced 16384 → 8192: `perf script` costs ~0.6 s/sample at
16 KB (unwinding is deferred to post-processing), and 8 KB is still far deeper
than CPython's C stack requires.

---

## Correctness fixes

### C1 — rounded radius-squared changed rendering

`variants/bm_raytrace_opt.py` stored `0.16`, but the baseline computes `0.4*0.4`
which is `0.16000000000000003`. The literal shrinks the sphere by ~3e-17.

Tangent ray, origin `(1.0,-0.4,-3.6)` direction `(0,0,1)`:

```
baseline  : HIT  t = 0.09999999705489952
optimized : MISS disc = -1.9e-17      <- silently wrong
with r*r  : HIT  t = 0.09999999705489952   (bit-identical)
```

**Fix:** all four spheres compute `r2` as `r*r`. Verified bit-identical.

### C2 — plane boundary predicate differed

Baseline: `if abs(direction.y) < 1e-6: return None` — accepts `|dy| == 1e-6`.
Optimized: `if dy < -1e-6 or dy > 1e-6` — **excludes** it.

**Fix:** `if not (-1e-6 <= dy <= 1e-6)`, mirroring the baseline exactly.

### C3 — `STRICT_FP` documented but dead

The docstring advertised `STRICT_FP=1`; the code derived `STRICT_FP` from
`FAST_FP` and never read it from the environment. Introduced by a later patch
that changed the code and left the docstring stale.

**Fix:** documentation corrected. Exact division is the default; `FAST_FP=1`
opts into the ~1-ULP reciprocal form and **deliberately fails the gate** — kept
as a demonstration.

### C4 — verify gates tested the wrong problem size

raytrace verified only 32×32 while rendering 100×100. nbody verified 1000 steps
while simulating 20000. A defect at the measured size could pass.

**Fix — raytrace:** now checks 32×32, **100×100 (measured)**, and 37×23 (odd
dimensions), plus five geometric edge cases (tangent, near-parallel,
straight-down, through-centre, miss). The optimized variant must agree on
hit/miss **and** on bit-exact `t` — a `t` difference means the quadratic solve
changed, not just the shading.

**Fix — nbody:** now runs the **measured 20000 steps**, compares the **full
state** (all 30 positions and velocities) rather than the energy scalar alone —
different configurations can share an energy value — and adds **momentum
conservation** as an independent invariant.

Measured results:

```
raytrace  bit-identical at all three sizes; all 5 edge cases AGREE
nbody     state max_rel = 2.391e-13   |total momentum| = 2.051e-15
          energy rel_diff vs baseline = 9.521e-15
```

---

## Infrastructure fixes

### I1 — `DISABLE_GC=0` aborted the run

`[[ "$DISABLE_GC" == "1" ]] && WL+=(--no-gc)` returns 1 when false. Under
`set -e` that killed the pipeline, so the documented option was fatal.

**Fix:** explicit `if`/`fi` plus `return 0`.

### I2 — `TARGET_SEC` was inert

Documented in `config/bench.env`, hardcoded to `3.0` in the Python calibrators.

**Fix:** read via `os.environ.get("TARGET_SEC", "3.0")` and exported by
`py_env()`. Verified: `TARGET_SEC=0.3` → 64 loops, default → 1024.

### I3 — `--time-only` still required perf

Contradicted its own purpose.

**Fix:** perf preconditions and the PMU probe run only when a perf-using phase
is enabled.

### I4 — `latest_*` symlinks were absolute

They pointed at `/root/HW-SW-FULL/...` and broke the moment results were copied
off the VM.

**Fix:** relative symlink targets.

### I5 — report generator could destroy authored work

`run_all.sh` regenerated `report_<bench>.txt`, overwriting sections the student
had filled in.

**Fix:** if no `[TODO]` markers remain the file is treated as authored and the
generator writes `report_<bench>.generated.txt` instead.

### I6 — tool errors leaked into reports, warnings were truncated

`grab()` pasted error text into the report body, and pyperf statistics were cut
at 25 lines — dropping the instability warning that appears below.

**Fix:** error-only artifacts produce a clear `[DATA UNAVAILABLE]` note;
pyperf warnings are extracted and preserved.

### I7 — `PIN_CPU` could be invalid

`PIN_CPU=1` on a single-vCPU guest makes every `taskset` call fail.

**Fix:** `build_pin()` clamps to an existing CPU and warns. Default is now 0 for
the target VM.

### I8 — `doctor.sh` could not detect either sampling failure

It inferred PMU health from `perf stat` alone, so a host that counted perfectly
but could not sample passed preflight and produced empty flame graphs.

**Fix:** two new probes — a **sampling** probe (records and counts real samples,
hard-fails at zero) and an **unwind-depth** probe (warns below depth 5). Plus an
explicit warning if `CALLGRAPH=fp` is set.

### I9 — `bash >= 4` falsely required

`doctor.sh` demanded bash 4 "for associative arrays". None are used.

**Fix:** requirement corrected to 3.2.

### I10 — empty-array expansion under `set -u`

`"${EMPTY[@]}"` raises *unbound variable* in bash 3.2. The affected arrays
(`PIN` with no taskset, `ev` with no supported events) are empty in exactly the
**normal no-PMU case** the code exists to handle.

**Fix:** all 19 expansions guarded as `${ARR[@]+"${ARR[@]}"}`.

---

## Documentation corrections

| Was | Now |
|---|---|
| "velocity-Verlet-style" integration | **symplectic Euler (kick-then-drift)** |
| raytrace complexity `O(... × 2^depth)` | **linear in depth** — one reflection ray per hit |
| "removes all allocation and dispatch" | removes **container objects, method dispatch, subscripts**; Python floats remain boxed heap objects |
| "flatten to parallel arrays" | Python **lists of boxed floats** — no SIMD, no unboxing |
| flame-graph causal chains asserted | labelled as **inferred from leaf shares and call counts**, since hierarchy was unusable until M5 |
| py-spy presented as peer of perf | **optional cross-check only**, `ENABLE_PYSPY=0` by default |

---

## Validated defaults for the target VM

```
PERF_RECORD_MODE=period      # -F captures 0 samples on this PMU
PERF_RECORD_EVENT=cycles
SAMPLE_PERIOD=5000000        # ~600-900 samples/pass
MIN_SAMPLES=200              # below this: loud failure
CALLGRAPH=dwarf              # fp truncates at depth 2.5
DWARF_STACK_BYTES=8192       # halves perf script cost
PIN_CPU=0                    # single-vCPU guest
CLEAN_REPS=11                # more reps to offset 1-vCPU noise
ENABLE_PYSPY=0               # perf is the deliverable
```

---

## Still outstanding

1. **Upstream workload question.** `bench/bm_*.py` are independently written
   stand-ins, not the upstream pyperformance kernels. `upstream/` and
   `bench/bm_nbody_upstream.py` begin the port. The measured ablation on the
   real upstream nbody kernel gives only **~3.5%** time reduction (below the 7%
   bar), because upstream already destructures coordinates at the loop head —
   so part of the gain measured against the custom baseline was removing work
   the custom baseline itself introduced. raytrace has not yet been ported.

2. **Report sections 5–6** (hardware proposal, conclusions) remain `[TODO]`.

3. **Shadow rays are unbounded by light distance** in both raytracers — an
   object beyond the light can occlude it. Shared by baseline and optimized, so
   it does not affect the comparison, but it is a model limitation.
