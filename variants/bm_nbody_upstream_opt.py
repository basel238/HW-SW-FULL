#!/usr/bin/env python3
"""
variants/bm_nbody_upstream_opt.py — OPTIMIZED, ported onto the REAL upstream
pyperformance nbody kernel.

HONEST STARTING POINT
---------------------
An external review predicted that most of the gain measured against my custom
baseline would evaporate here, and reading the upstream source confirms the
mechanism. Upstream's inner loop already destructures coordinates in the `for`
target:

    for (([x1, y1, z1], v1, m1), ([x2, y2, z2], v2, m2)) in pairs:

so the coordinates are ALREADY locals and the masses are ALREADY bound from the
pair tuple. My custom baseline had added `bodies[i]` / `p1[0]` subscripting that
upstream never had, which means optimization [O2] (flatten + hoist subscripts)
was largely removing work I had introduced myself.

WHAT IS GENUINELY LEFT TO OPTIMIZE
----------------------------------
[U1] `** (-1.5)` -> `1.0 / (d2 * sqrt(d2))`
     Upstream computes `mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))`.
     The `**` operator on a float with a non-integral exponent calls CPython's
     float_pow, which calls libm pow(): a generic polynomial/exponential
     evaluation (tens of cycles). sqrt() compiles to a single hardware
     instruction (SQRTSD). Mathematically identical for d2 > 0, which always
     holds here because two bodies never coincide.

[U2] Bind `sqrt` into the function's fast locals via a default argument.
     A bare `sqrt(...)` resolved from module scope is LOAD_GLOBAL (a dict
     lookup, with a builtins fallback on miss). A default argument lives in the
     frame's fast-locals array, so the same call becomes LOAD_FAST.

[U3] Hoist the velocity lists' element access.
     Upstream does `v1[0] -= dx*b2m` etc. -- six subscript load/store pairs per
     pair. Reading the three components into locals, updating them, and writing
     back replaces the in-place subscript arithmetic. This is NOT obviously a
     win (the store count is unchanged), so it is included as a separately
     measurable ablation rather than assumed to help.

NOT APPLIED, AND WHY
--------------------
  * Flattening to parallel scalar lists: upstream's layout is already
    destructured at the loop head; rewriting it would change the data structure
    the assignment asks us to analyse, for no measured benefit.
  * numpy: 5 bodies / 10 pairs. Per-call overhead (~1 us) exceeds the whole
    inner loop. Only a batched rewrite could win, which is a different program.
  * Barnes-Hut: an approximation; would invalidate the energy oracle. n=5.
  * threading: the GIL serialises pure-Python float arithmetic.

CORRECTNESS CONTRACT
--------------------
[U1] changes the rounding of ONE operation, so results are not required to be
bit-identical. The gate therefore checks:
  * relative energy agreement with upstream to < 1e-9, and
  * full state (all positions and velocities) agreement to < 1e-9 relative.
Both are verified at the MEASURED iteration count (20000), not a reduced one.

ABLATION SUPPORT
----------------
--kernel selects which variant is timed, so each edit can be attributed:
    upstream   upstream advance(), unmodified          (control)
    sqrt       [U1] + [U2] only
    hoist      [U3] only
    full       [U1] + [U2] + [U3]
"""

import argparse
import gc
import os
import sys
from math import sqrt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "bench"))

import bm_nbody_upstream as base  # noqa: E402  (shared loader + harness)

TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))


# ---------------------------------------------------------------------------
# [U1] + [U2] — replace pow() with sqrt(), bind sqrt as a fast local.
# Signature matches upstream advance(dt, n, bodies, pairs) exactly.
# ---------------------------------------------------------------------------
def advance_sqrt(dt, n, bodies, pairs, _sqrt=sqrt):
    for _ in range(n):
        for (([x1, y1, z1], v1, m1),
             ([x2, y2, z2], v2, m2)) in pairs:
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            d2 = dx * dx + dy * dy + dz * dz
            # [U1] d2 ** -1.5  ==  1 / (d2 * sqrt(d2)), via hardware SQRTSD
            mag = dt / (d2 * _sqrt(d2))
            b1m = m1 * mag
            b2m = m2 * mag
            v1[0] -= dx * b2m
            v1[1] -= dy * b2m
            v1[2] -= dz * b2m
            v2[0] += dx * b1m
            v2[1] += dy * b1m
            v2[2] += dz * b1m
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx
            r[1] += dt * vy
            r[2] += dt * vz


# ---------------------------------------------------------------------------
# [U3] only — velocity component hoisting, keeping upstream's pow().
# Isolated so the ablation can show whether it helps at all.
# ---------------------------------------------------------------------------
def advance_hoist(dt, n, bodies, pairs):
    for _ in range(n):
        for (([x1, y1, z1], v1, m1),
             ([x2, y2, z2], v2, m2)) in pairs:
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))
            b1m = m1 * mag
            b2m = m2 * mag
            a0 = v1[0]; a1 = v1[1]; a2 = v1[2]
            c0 = v2[0]; c1 = v2[1]; c2 = v2[2]
            v1[0] = a0 - dx * b2m
            v1[1] = a1 - dy * b2m
            v1[2] = a2 - dz * b2m
            v2[0] = c0 + dx * b1m
            v2[1] = c1 + dy * b1m
            v2[2] = c2 + dz * b1m
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx
            r[1] += dt * vy
            r[2] += dt * vz


# ---------------------------------------------------------------------------
# full — [U1] + [U2] + [U3]
# ---------------------------------------------------------------------------
def advance_full(dt, n, bodies, pairs, _sqrt=sqrt):
    for _ in range(n):
        for (([x1, y1, z1], v1, m1),
             ([x2, y2, z2], v2, m2)) in pairs:
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * _sqrt(d2))
            b1m = m1 * mag
            b2m = m2 * mag
            a0 = v1[0]; a1 = v1[1]; a2 = v1[2]
            c0 = v2[0]; c1 = v2[1]; c2 = v2[2]
            v1[0] = a0 - dx * b2m
            v1[1] = a1 - dy * b2m
            v1[2] = a2 - dz * b2m
            v2[0] = c0 + dx * b1m
            v2[1] = c1 + dy * b1m
            v2[2] = c2 + dz * b1m
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx
            r[1] += dt * vy
            r[2] += dt * vz


KERNELS = {
    "upstream": None,               # None => use upstream's own advance()
    "sqrt":     advance_sqrt,
    "hoist":    advance_hoist,
    "full":     advance_full,
}


def calibrate(iterations, kernel):
    loops = 1
    while True:
        el, _, _ = base.benchmark(loops, iterations, advance=kernel)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(
        description="OPTIMIZED upstream pyperformance nbody")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify", "ablate"),
                   default="raw")
    p.add_argument("--loops", type=int, default=0)
    p.add_argument("--iterations", type=int, default=0,
                   help="0 => upstream default (20000)")
    p.add_argument("--kernel", choices=tuple(KERNELS), default="full")
    p.add_argument("--no-gc", action="store_true")
    a = p.parse_args()

    probe = base.load_upstream()
    iters = a.iterations or probe.DEFAULT_ITERATIONS
    kernel = KERNELS[a.kernel]

    if a.mode == "calibrate":
        print(calibrate(iters, kernel)); return 0

    if a.mode == "verify":
        # Cross-check EVERY kernel against upstream at the MEASURED size.
        _, e_ref, up_ref = base.benchmark(1, iters, advance=None)
        s_ref = base.snapshot(up_ref)
        print(f"reference (upstream advance), iterations={iters}")
        print(f"  energy = {e_ref!r}")

        all_ok = True
        for name, fn in KERNELS.items():
            if fn is None:
                continue
            _, e, up = base.benchmark(1, iters, advance=fn)
            s = base.snapshot(up)
            rel_e = abs(e - e_ref) / abs(e_ref)
            max_abs = max(abs(x - y) for x, y in zip(s, s_ref))
            denom = max(max(abs(x) for x in s_ref), 1e-300)
            max_rel = max_abs / denom
            # [U1] reassociates one operation, so exact equality is not
            # required; 1e-9 relative is far tighter than any physical effect.
            ok_e = rel_e < 1e-9
            ok_s = max_rel < 1e-9
            all_ok = all_ok and ok_e and ok_s
            print(f"  {name:<9} energy rel_diff={rel_e:.3e} "
                  f"{'OK' if ok_e else 'FAIL'}"
                  f" | state max_abs={max_abs:.3e} rel={max_rel:.3e} "
                  f"{'OK' if ok_s else 'FAIL'}")
        assert all_ok, "a kernel diverged from upstream beyond tolerance"
        print("verify: OK  all kernels agree with upstream within 1e-9 relative")
        return 0

    if a.mode == "ablate":
        # Attribute the speedup to individual edits. Median of several runs each,
        # interleaved to blunt any monotonic host drift.
        import statistics
        loops = a.loops or calibrate(iters, KERNELS["upstream"])
        reps = 5
        samples = dict((k, []) for k in KERNELS)
        for _ in range(reps):
            for name, fn in KERNELS.items():
                el, _, _ = base.benchmark(loops, iters, advance=fn)
                samples[name].append(el)
        ref = statistics.median(samples["upstream"])
        print(f"ABLATION  loops={loops} iterations={iters} reps={reps}")
        print(f"{'kernel':<10}{'median s':>12}{'speedup':>10}{'time red.':>11}")
        print("-" * 43)
        for name in KERNELS:
            m = statistics.median(samples[name])
            print(f"{name:<10}{m:>12.6f}{ref / m:>9.4f}x"
                  f"{(1 - m / ref) * 100:>10.2f}%")
        print()
        print("Interpretation: any kernel whose speedup is ~1.00x contributes")
        print("nothing on the real upstream layout and must not be claimed.")
        return 0

    loops = a.loops or calibrate(iters, kernel)
    if a.no_gc:
        gc.disable()

    elapsed, energy, up = base.benchmark(loops, iters, advance=kernel)
    total_steps = loops * iters

    print(f"OPTIMIZED upstream nbody — kernel={a.kernel}")
    print(f"bodies={len(up.SYSTEM)} pairs={len(up.PAIRS)} "
          f"iterations={iters} loops={loops}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/loop")
    print(f"energy={energy!r}")
    print(f"step_rate={total_steps / elapsed / 1e3:.2f} ksteps/s")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_loop={elapsed / loops * 1e3:.4f} energy={energy!r} "
          f"iterations={iters} kernel={a.kernel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
