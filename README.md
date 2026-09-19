# HW/SW Co-design Project — Benchmark Optimization, Analysis & Hardware Acceleration

Course: **00460882 — HW/SW Co-design** (Technion)
Benchmarks analyzed: **`raytrace`** and **`nbody`** (from the approved `pyperformance` list)

A reproducible, VM-ready pipeline that profiles two `pyperformance` benchmarks with
`perf`, generates flame graphs, applies software optimizations, and proves the
improvement with statistically defensible before/after measurements.

---

## Measured results

All figures below come from **one identified result set**: the runs under
`results/` on the target VM (Ubuntu 22.04 guest, KVM, Xeon E5-2630 v3, 1 vCPU,
CPython 3.10.12). Numbers from any other machine or session are not mixed in.

### Custom harness (`bench/` vs `variants/`)

| Benchmark | Work/unit base → opt | Speedup | **Time reduction** | Bar | Noise |
|---|---|---|---|---|---|
| `raytrace` | 257.92 → 96.40 ms/frame | 2.6756× | **62.62 %** | ≥7 % ✅ | 0.47 % |
| `nbody` | 261.87 → 241.13 ms/sim | 1.0860× | **7.92 %** | ≥7 % ⚠️ | 0.19 % |

**Time reduction** is the metric compared against the 7 % bar. Throughput gain
is a different number (raytrace: +167.56 %) and the two must not be conflated.

Counters, normalized per unit of work:

| | raytrace | nbody |
|---|---|---|
| instructions/unit | −59.50 % | −2.51 % |
| cycles/unit | −61.93 % | −7.39 % |
| IPC | 2.80 → 2.97 | 3.06 → 3.22 |

raytrace removed a large amount of executed work. nbody removed few
instructions but more cycles, implying a cheaper mix of operations.

⚠️ **nbody's margin is thin** — 0.92 percentage points over the bar. It needs a
second measurement session before being relied upon.

### Upstream pyperformance kernels (`upstream/` + `bench/bm_*_upstream.py`)

`bench/bm_*.py` are **independently written stand-ins**, not the upstream
benchmarks. Porting the optimizations onto the real kernels changes the result
substantially. Measured ablation on the genuine upstream nbody kernel:

| kernel | speedup | time reduction |
|---|---|---|
| upstream (control) | 1.0000× | 0.00 % |
| `sqrt` — pow→sqrt only | 1.0360× | **3.47 %** |
| `hoist` — subscript hoisting only | 0.9886× | **−1.15 %** (slower) |
| `full` | 1.0247× | 2.47 % |

**Upstream nbody gets ~3.5 %, below the 7 % bar.** Upstream already
destructures coordinates at the loop head, so the flatten/hoist optimization was
largely removing work the *custom baseline itself introduced*. raytrace has not
yet been ported; upstream raytrace carries more overhead than the stand-in
(`isPoint()`/`mustBeVector()` type checks per operation, a fresh list per ray),
so its gain is expected to survive — but that is **unverified**.

### Correctness

- `raytrace` — rendered image **bit-identical** to baseline (SHA-256) at 32×32,
  **100×100 (the measured size)** and 37×23, plus five geometric edge-case rays
  agreeing on hit/miss and on bit-exact `t`
- `nbody` — full state (30 values) agrees to `2.4e-13` relative, energy to
  `9.5e-15`, total momentum conserved to `2.1e-15`, at the **measured 20 000
  steps**

## Quick start (fresh Ubuntu 22.04 / jammy VM)

```bash
# 1. dependencies: perf, python3-dbg, toolchain
sudo ./setup/01_install_deps.sh

# 2. Brendan Gregg's FlameGraph toolkit
./setup/02_get_flamegraph.sh

# 3. kernel knobs for usable measurements (perf permissions, ASLR, governor)
sudo ./setup/03_tune_vm.sh

# 4. venv with pyperformance + pyperf   (NOT as root)
./setup/04_make_venv.sh

# 5. preflight — tells you exactly what is missing and what will be skipped
./tools/doctor.sh

# 6. run everything
./run_all.sh
```

Faster paths while iterating:

```bash
./run_all.sh --quick        # ~3 min smoke test of the whole pipeline
./run_all.sh --time-only    # just the speedup numbers, zero instrumentation
./script_raytrace.sh --help # per-benchmark options
```

---

## Why the results are trustworthy: phase separation

Profilers perturb what they measure. `perf record` with DWARF unwinding adds
roughly 10–30 % wall time; `cProfile` adds 2–5×. **No number this repo quotes is
ever taken from an instrumented run.** Each phase runs in its own fresh process:

| Phase | What runs | Overhead | What it is used for |
|-------|-----------|----------|---------------------|
| 1 | `--mode verify` | none | correctness gate — **hard fail** |
| 2 | release Python, **no profiler** | **none** | ← **the only quotable timing** |
| 3 | `perf stat` (counting mode) | ~1 % | IPC, cache misses, branch misses |
| 4 | `perf record` (sampling, `python3-dbg`) | high | flame graphs — **timing discarded** |
| 5 | `cProfile` (tracing) | 2–5× | exact call counts only |
| 6 | `pyperformance` | own harness | citable mean ± stdev |

Phases 4–5 write their wall time to a file literally named
`*_DO_NOT_QUOTE_timing.txt` so it cannot be mistaken for a result.

Additional noise controls: single-CPU pinning (`taskset`), fixed
`PYTHONHASHSEED`, cyclic GC disabled inside the timed region, ASLR off,
`performance` governor where the platform exposes it. The headline statistic is
the **median of N independent processes**, and `compare.sh` refuses to endorse a
result whose improvement is smaller than 2× the measured noise.

---

## Repository layout

```
├── script_raytrace.sh        ← required deliverable (stage 2 of the brief)
├── script_nbody.sh           ← required deliverable
├── run_all.sh                   one command for everything
├── report_raytrace.txt       ← required deliverable (generated, then you finish it)
├── report_nbody.txt          ← required deliverable
├── prompt.txt                ← required deliverable (AI prompts used)
│
├── config/bench.env             every tunable knob, with rationale
├── lib/
│   ├── common.sh                measurement engine (perf wrappers, flame graphs)
│   └── pipeline.sh              the generic 6-phase pipeline + shared CLI
│
├── bench/                       BASELINE workloads
│   ├── bm_raytrace.py
│   └── bm_nbody.py
├── variants/                    OPTIMIZED workloads
│   ├── bm_raytrace_opt.py
│   └── bm_nbody_opt.py
│
├── setup/                       01 deps · 02 flamegraph · 03 vm tuning · 04 venv
├── tools/
│   ├── doctor.sh                preflight: hard vs soft failures
│   ├── compare.sh               before/after + differential flame graph
│   └── gen_report.sh            assembles report_<bench>.txt from real data
├── docs/
│   ├── VM_SETUP.md              QEMU recipe (incl. PMU passthrough)
│   ├── PERF_GUIDE.md            how to read the output; troubleshooting
│   └── HW_PROPOSAL_NOTES.md     measured data for the stage-7 hardware design
└── results/                     all generated artifacts (timestamped)
```

---

## Where each deliverable comes from

The brief asks for five things. Here is the mapping:

| Brief requirement | This repo |
|---|---|
| `report_<bench>.txt` | `tools/gen_report.sh` fills sections 1–4 from real data; sections 5–6 are marked `[TODO]` for you |
| `script_<bench>.sh` | `script_raytrace.sh`, `script_nbody.sh` |
| Flame graphs | `results/*/flame/*.svg` — plus icicle, Python-only, py-spy, and a **differential** graph |
| ≥ 7 % improvement on ≥ 2 benchmarks | 62.62 % and 7.92 % against the custom harness, both verified correct. **On the real upstream nbody kernel only ~3.5 %** — see the upstream table above. |
| AI prompts | `prompt.txt` |
| Hardware proposal | `docs/HW_PROPOSAL_NOTES.md` gives the measured motivation; the design is yours |

`gen_report.sh` deliberately **does not fabricate analysis prose.** It fills in
everything mechanically derivable and flags the rest. A report you can defend in
the presentation beats one that reads well and collapses under questioning.

---

## Output of a run

```
results/<bench>_<variant>_<timestamp>/
├── manifest.txt                  full environment capture (CPU, kernel knobs, versions)
├── timing/
│   ├── clean_<variant>.csv           per-rep raw timings
│   └── clean_<variant>_summary.txt  ← median/stdev/noise warning  ★ QUOTE THIS
├── perf/
│   ├── stat_<variant>.txt            counters (IPC, cache, branches)
│   ├── report_<variant>.txt          `perf report --stdio` (the brief's command)
│   ├── report_<variant>_self.txt     flat profile — hottest single functions
│   ├── report_<variant>_callers.txt  inverted call graph
│   ├── report_<variant>_dso.txt      time split by shared object
│   └── report_<variant>_symbols.csv  machine-readable, for diffing
├── flame/
│   ├── <variant>.svg                 CPU flame graph
│   ├── <variant>_icicle.svg          top-down (shows recursion depth)
│   ├── <variant>_python.svg          Python frames only
│   └── <variant>_top30_stacks.txt    quotable text form
└── raw/
    ├── cprofile_<variant>.txt        exact call counts
    └── pyperf_<variant>_stats.txt    pyperformance mean ± stdev
```

And from `tools/compare.sh`:

```
results/comparison_<bench>_<timestamp>/
├── summary.txt          speedup, improvement %, noise check, PASS/FAIL
├── counters.txt         side-by-side perf stat + derived IPC
├── symbols_delta.txt    which functions got cheaper or vanished entirely
└── diff_flame.svg       differential flame graph (red = worse, blue = better)
```

---

## The optimizations

Full rationale lives in each variant's module docstring, with every change tied
to the profile observation that motivated it.

**`raytrace` (62.62 %)** — the dominant win is deleting the `Vector` class. Each
`a + b` cost a method dispatch, a Python frame, a heap allocation for the result,
and later refcount/GC work. Carrying `x, y, z` as scalar locals removes all of
it. Also: scene flattened to tuples, intersection inlined, `sqrt` bound to a
local, quadratic solve strength-reduced to the half-`b` form.

**`nbody` (7.92 % on the custom baseline, ~3.5 % on real upstream)** — replaced `d2 ** -1.5` (a `libm pow()` call) with
`1/(d2*sqrt(d2))` (hardware `SQRTSD`); flattened body state into parallel scalar
lists to turn `BINARY_SUBSCR` into `LOAD_FAST`; hoisted loop-invariant masses
into the precomputed pair list.

### A finding worth presenting

The `raytrace` correctness gate **caught a real bug**. Replacing three divisions
with one reciprocal-multiply is ~1 ULP off — normally invisible. But this
renderer contains *discontinuities* (shadow hit/miss tests), and at one pixel on
a shadow boundary that 1 ULP flipped the occlusion test, changing the pixel by
**118/255**. Exact division is now the default; `FAST_FP=1` opts back in and
fails the gate on demand:

```bash
FAST_FP=1 python3 variants/bm_raytrace_opt.py --mode verify   # fails, by design
```

**Lesson:** "safe" floating-point strength reduction is only safe in
*branch-free* numeric code. Any optimization upstream of a comparison can change
control flow. This is why the gate compares checksums against the baseline
instead of trusting that the output "looks fine".

### Rejected optimizations (and why)

- **numpy** — both benchmarks work on 3-element vectors, where numpy's
  per-call overhead (~1 µs) is expected to exceed the cost of 3 float ops.
  **No benchmark for this is retained in the repository**, so this is stated
  as reasoning, not as a measurement. A batched rewrite (all rays/bodies at
  once) is a genuinely different and potentially winning design.
- **threading** — the GIL serializes pure-Python float arithmetic.
- **Barnes-Hut for nbody** — reduces O(n²) to O(n log n) but is an
  *approximation*, so it would invalidate the energy oracle. With n=5 it is also
  slower.

---

## If you have no hardware PMU

A QEMU guest started without PMU passthrough exposes **no** hardware counters.
Flame graphs still work (perf falls back to the `cpu-clock` software event), but
`cycles`, IPC and cache statistics will be missing. The pipeline detects this and
degrades gracefully rather than failing.

To get real counters, start the VM with KVM and the host CPU model:

```bash
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G ...
```

See `docs/VM_SETUP.md` for the full recipe.

---

## Reproducing a single number

```bash
# fastest defensible speedup measurement, no profilers involved
./script_nbody.sh --time-only
cat results/latest_comparison_nbody/summary.txt
```

Every run records its git commit, full environment, and the exact event set used,
so any figure in a report can be traced back to the run that produced it.
