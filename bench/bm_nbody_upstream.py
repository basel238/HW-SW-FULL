#!/usr/bin/env python3
"""
bench/bm_nbody_upstream.py — BASELINE wrapper around the REAL pyperformance
nbody kernel.

WHY THIS FILE EXISTS
--------------------
An external review correctly identified that bench/bm_nbody.py is an
independently written stand-in, not the upstream benchmark. Replacing the
workload changes the experiment. This wrapper instead imports
`upstream/bm_nbody_upstream.py` COMPLETELY UNMODIFIED (extracted verbatim from
the installed pyperformance package; see upstream/PROVENANCE.txt for version and
sha256) and only adds the raw/calibrate/verify CLI the pipeline needs.

WHAT IS AND IS NOT CHANGED
--------------------------
  NOT changed: advance(), report_energy(), offset_momentum(), BODIES, SYSTEM,
               PAIRS, combinations(), DEFAULT_ITERATIONS -- every line of the
               measured kernel is upstream's.
  Added here : a pyperf stub (so the file imports without the venv, using
               time.perf_counter, which is exactly what pyperf.perf_counter is),
               and the harness/CLI.

The timed region mirrors upstream `bench_nbody` exactly:
    offset_momentum(BODIES[reference])       # once, before timing
    loop: report_energy(); advance(0.01, iterations); report_energy()

IMPORTANT — UPSTREAM MUTATES MODULE-LEVEL STATE
-----------------------------------------------
SYSTEM/PAIRS alias the lists inside BODIES, and advance() mutates them in place.
State therefore accumulates across loops. That is upstream's own behaviour and
is preserved. Reproducibility is obtained by loading a FRESH copy of the module
for every measurement, so each process starts from pristine initial conditions.
"""

import argparse
import gc
import importlib.util
import os
import sys
import time
import types

TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))
HERE = os.path.dirname(os.path.abspath(__file__))
UPSTREAM = os.path.join(HERE, "..", "upstream", "bm_nbody_upstream.py")


def load_upstream():
    """
    Import the upstream kernel with a fresh module namespace.

    A minimal pyperf stub is injected because upstream does `import pyperf` for
    perf_counter only; stubbing it keeps the upstream file byte-identical while
    letting phases 2/3/5 run under the system interpreter (no venv needed).
    """
    if "pyperf" not in sys.modules:
        stub = types.ModuleType("pyperf")
        stub.perf_counter = time.perf_counter

        class _Runner:  # present only so `import pyperf` cannot fail
            def __init__(self, *a, **k):
                raise RuntimeError("pyperf.Runner is not available in this harness")
        stub.Runner = _Runner
        sys.modules["pyperf"] = stub

    if not os.path.exists(UPSTREAM):
        sys.exit(f"missing upstream kernel: {UPSTREAM}\n"
                 f"Extract it from the installed pyperformance package first.")

    # A unique module name per call guarantees a pristine BODIES/SYSTEM/PAIRS.
    name = f"_upstream_nbody_{load_upstream.counter}"
    load_upstream.counter += 1
    spec = importlib.util.spec_from_file_location(name, UPSTREAM)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


load_upstream.counter = 0


# ---------------------------------------------------------------------------
# Harness — mirrors upstream bench_nbody()
# ---------------------------------------------------------------------------
def benchmark(loops, iterations, advance=None):
    """
    `advance` lets the optimized variant substitute ONLY the hot kernel while
    reusing upstream's data layout, offset_momentum and report_energy. That
    makes the before/after an isolated, auditable one-function swap.
    """
    up = load_upstream()
    adv = advance if advance is not None else up.advance

    up.offset_momentum(up.BODIES[up.DEFAULT_REFERENCE])

    t0 = time.perf_counter()
    for _ in range(loops):
        up.report_energy()
        adv(0.01, iterations, up.SYSTEM, up.PAIRS)
        up.report_energy()
    elapsed = time.perf_counter() - t0

    return elapsed, up.report_energy(), up


def snapshot(up):
    """Full state: positions and velocities of every body, plus energy."""
    state = []
    for (r, v, m) in up.SYSTEM:
        state.extend([r[0], r[1], r[2], v[0], v[1], v[2]])
    return state


def calibrate(iterations):
    loops = 1
    while True:
        el, _, _ = benchmark(loops, iterations)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(description="upstream pyperformance nbody (baseline)")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0, help="0 => auto-calibrate")
    p.add_argument("--iterations", type=int, default=0,
                   help="advance() steps per loop; 0 => upstream default (20000)")
    p.add_argument("--no-gc", action="store_true")
    a = p.parse_args()

    probe = load_upstream()
    iters = a.iterations or probe.DEFAULT_ITERATIONS

    if a.mode == "calibrate":
        print(calibrate(iters)); return 0

    if a.mode == "verify":
        # Determinism at the MEASURED problem size, not a reduced one.
        e1, s1 = (lambda r: (r[1], snapshot(r[2])))(benchmark(1, iters))
        e2, s2 = (lambda r: (r[1], snapshot(r[2])))(benchmark(1, iters))
        assert e1 == e2, f"upstream nbody not deterministic: {e1!r} vs {e2!r}"
        assert s1 == s2, "upstream nbody state not deterministic"
        # Energy must be conserved to the level a symplectic integrator allows:
        # its error is BOUNDED and oscillatory, so a relative test is correct.
        up0 = load_upstream()
        up0.offset_momentum(up0.BODIES[up0.DEFAULT_REFERENCE])
        e0 = up0.report_energy()
        rel = abs(e1 - e0) / abs(e0)
        assert rel < 1e-3, f"energy not conserved: e0={e0!r} e1={e1!r} rel={rel:.3e}"
        print(f"verify: OK  iterations={iters}  energy={e1!r}")
        print(f"  deterministic over full state ({len(s1)} values)")
        print(f"  relative energy drift = {rel:.3e}")
        return 0

    loops = a.loops or calibrate(iters)
    if a.no_gc:
        gc.disable()

    elapsed, energy, up = benchmark(loops, iters)
    total_steps = loops * iters
    npairs = len(up.PAIRS)

    print(f"UPSTREAM pyperformance nbody kernel (unmodified)")
    print(f"bodies={len(up.SYSTEM)} pairs={npairs} iterations={iters} loops={loops}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/loop")
    print(f"energy={energy!r}")
    print(f"step_rate={total_steps / elapsed / 1e3:.2f} ksteps/s")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_loop={elapsed / loops * 1e3:.4f} energy={energy!r} "
          f"iterations={iters}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
