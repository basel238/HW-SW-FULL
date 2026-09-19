# Reading the output — a practical guide

## The one rule

**Quote timing only from `timing/clean_*_summary.txt`.** Everything in `perf/`,
`raw/cprofile_*` and any file containing `DO_NOT_QUOTE` comes from an
instrumented run and is inflated by profiler overhead. Counters and *ratios* from
`perf stat` are valid (counting mode costs ~1 %); wall time from `perf record`
and `cProfile` is not.

---

## `perf stat` — why it is slow

```
      4,000,000,000      cycles
      6,000,000,000      instructions   #  1.50  insn per cycle
         50,000,000      cache-misses   #  2.5 % of all cache refs
        120,000,000      branch-misses  #  1.2 % of all branches
```

Read it in this order:

1. **IPC** (`insn per cycle`). Modern x86 retires up to ~4. Below ~1.0 means the
   pipeline is stalling.
2. **If IPC is low, find out why.** High `cache-misses` ⇒ memory-bound. Low cache
   misses but still low IPC ⇒ dependency chains or dispatch overhead. For these
   two benchmarks it is the latter: the working set is tiny (nbody's 5 bodies are
   ~280 B and live in L1), so any stall is *not* memory.
3. **`instructions` between variants.** A drop means you removed work. IPC rising
   at constant instruction count means you removed *stalls*. These are different
   claims and `tools/compare.sh` reports both.

`--topdown` (when the PMU supports it) splits stalls into frontend-bound,
backend-bound, bad-speculation and retiring — the CPI-stack methodology from
lecture 3.

---

## Flame graphs

- **x-axis is NOT time.** It is alphabetically sorted stacks; width = fraction of
  samples. Nothing about left-to-right implies ordering.
- **y-axis is stack depth.** Each box is a frame; the box above is its callee.
- **Width is what matters.** A wide box near the top is a hot leaf; a wide box
  with a narrow tower above it is doing the work itself.

Four variants are generated:

| File | Use it for |
|---|---|
| `<variant>.svg` | the main view |
| `<variant>_icicle.svg` | top-down; makes recursion depth obvious (raytrace reflections) |
| `<variant>_python.svg` | C/kernel frames stripped — maps onto editable source |
| `<variant>_pyspy.svg` | independent cross-check; if it disagrees with perf, suspect the DWARF unwind |

They are **interactive**: click to zoom, Ctrl-F to search. Open in a browser.

**Differential** (`comparison_*/diff_flame.svg`): red = more time in optimized,
blue = less. Sample counts are normalized so the two runs are comparable despite
different loop counts. This is the single most persuasive artifact for the
"show your improvement" deliverable.

---

## perf reports

| File | Question it answers |
|---|---|
| `report_<v>.txt` | the brief's `perf report --stdio` output |
| `report_<v>_self.txt` | which single function burns the most cycles *itself* |
| `report_<v>_callers.txt` | who is responsible for calling the hot leaf |
| `report_<v>_dso.txt` | interpreter vs libm vs kernel split |
| `report_<v>_symbols.csv` | machine-readable, used by `compare.sh` |

Start with `_self.txt`: it names the function to optimize. Then `_callers.txt` to
find out who is driving it.

---

## cProfile

Use it for **call counts**, never timing. The useful column is `ncalls`: if a
function is called 8 million times, the fix is usually *calling it less*, not
making it faster. This is how the `Vector.__add__` problem in raytrace becomes
obvious — the count, not the per-call cost, is the story.

---

## Judging whether a result is real

`compare.sh` prints a signal check:

```
Signal check: improvement (16.95%) exceeds 2x noise (0.62%). OK.
```

If it instead prints `CAUTION`, the claimed gain is within noise and is **not
established**. Fixes, in order: quiet the machine, raise `CLEAN_REPS`, re-run
`setup/03_tune_vm.sh`, increase `TARGET_SEC`.

Relative stdev above ~5 % means the environment is unusable for measurement.
Inside a VM you cannot control the host's frequency scaling, so always collect
baseline and optimized numbers **in the same session**.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| One giant `_PyEval_EvalFrameDefault` box | `python3-dbg` missing → `sudo apt install python3-dbg` |
| `perf stat -e cycles` fails | no PMU → restart QEMU with `-enable-kvm -cpu host` |
| Kernel frames show as `[unknown]` | `sudo ./setup/03_tune_vm.sh` (`perf_event_paranoid`) |
| "lost N chunks" | raise `PERF_MMAP_PAGES=64M`, lower `SAMPLE_FREQ`, or `CALLGRAPH=fp` |
| Truncated / shallow stacks | `CALLGRAPH=dwarf` (default); `fp` fails on stock CPython |
| py-spy permission denied | `sudo sysctl -w kernel.yama.ptrace_scope=0` |
| Huge `perf.data` | expected with DWARF; lower `DWARF_STACK_BYTES` or `SAMPLE_FREQ` |
| `pyperformance: command not found` | `./setup/04_make_venv.sh` |

---

## Useful invocations

```bash
./script_raytrace.sh --time-only         # fastest defensible speedup
./script_raytrace.sh --profile-only      # flame graphs only
./script_raytrace.sh --quick             # smoke test
CALLGRAPH=fp ./script_nbody.sh           # cheaper unwinding
SAMPLE_FREQ=4999 ./script_nbody.sh       # finer sampling (short runs)
CLEAN_REPS=15 ./script_nbody.sh          # tighter confidence
DISABLE_GC=0 ./script_nbody.sh           # include GC cost in the measurement
LOOPS=100 ./script_nbody.sh              # skip calibration, fix the work
```

Manual perf, matching the course guide exactly:

```bash
perf record -F 999 -g -- python3-dbg -m pyperformance run --bench nbody
perf report --stdio > perf_report.txt
```

Note this profiles the *whole pyperformance harness* (subprocess spawning,
calibration, JSON writing), which is why this repo also provides standalone
single-process workloads in `bench/` — their flame graphs are almost entirely the
benchmark itself.
