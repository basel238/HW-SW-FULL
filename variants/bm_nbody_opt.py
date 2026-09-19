#!/usr/bin/env python3
"""
variants/bm_nbody_opt.py — OPTIMIZED nbody.

All optimizations are pure software, CPython-only, no third-party libraries and
no change to the physics. The correctness oracle is unchanged: total energy must
match the baseline to within floating-point reassociation error.

WHAT WAS CHANGED AND WHY (each traced to a specific profile observation)
-----------------------------------------------------------------------

[O1] Replace `d2 ** -1.5` with `1/(d2*sqrt(d2))`.
     Profile evidence: baseline flame graph shows float_pow / pow() as a
     top-3 self-time leaf inside advance().
     Why it is faster: `** -1.5` calls the generic CPython float_pow, which
     goes through libm pow() -- a polynomial approximation costing ~40-60
     cycles. sqrt() is a single hardware instruction (SQRTSD, ~15 cycles
     latency, pipelined) plus one multiply and one divide. Mathematically
     identical for d2 > 0, which always holds here (bodies never coincide).

[O2] Flatten the body representation into parallel lists of scalars.
     NOTE, precisely: these are Python LISTS of BOXED floats, not unboxed
     hardware arrays. This does not produce SIMD, does not eliminate
     allocation, and does not remove every subscript -- it reduces the
     NUMBER of subscript operations and of tuple unpacks. Claims beyond
     that would not be supported by the measurements., and unpack pair state into LOCAL
     variables before the arithmetic.
     Profile evidence: report_*_self.txt attributes heavy self time to
     list subscript (BINARY_SUBSCR) and to the tuple-unpacking of
     `(p1, v1, m1) = bodies[i]`.
     Why it is faster: CPython resolves a local variable with LOAD_FAST (an
     array index into the frame), whereas `p1[0]` is a BINARY_SUBSCR that
     must type-check the container and bounds-check the index every time.
     The baseline re-subscripts the same element up to 4x per pair.

[O3] Precompute the pair list WITH the masses already resolved, so the inner
     loop never touches `bodies[i][2]`.
     Why: mass is loop-invariant. Hoisting it removes 2 subscripts per pair
     per step -- classic loop-invariant code motion, done by hand because
     CPython has no optimizing compiler to do it for us.

[O4] Bind `sqrt` to a local name.
     Why: a bare `sqrt(...)` on a module-level import is a LOAD_GLOBAL, which
     is a dict lookup in the module namespace (plus a builtins fallback on
     miss). Binding it as a default argument / local makes it LOAD_FAST.
     This is the single most cost-effective CPython idiom.

[O5] Fuse the position-update loop into a flat scalar loop over the same
     flat arrays, avoiding the tuple unpack per body.

NOT DONE (deliberately, and worth saying in the presentation)
------------------------------------------------------------
  * numpy: for n=5 bodies the array-setup overhead exceeds the arithmetic;
    numpy wins only for large n. Measured, and it was SLOWER here.
  * Barnes-Hut / octree: changes the ALGORITHM from O(n^2) to O(n log n) but
    also changes the RESULT (it is an approximation). That would invalidate
    the energy oracle, so it is out of scope for a like-for-like comparison.
  * Multithreading: the GIL serializes pure-Python float work, so it cannot help.

A NOTE ON WHAT SCALARIZATION DOES *NOT* DO
------------------------------------------
Python scalar floats remain boxed heap objects, and arithmetic still goes
through the interpreter with allocation and reference counting. These
optimizations remove CONTAINER objects, METHOD dispatch and SUBSCRIPT
operations. They do not make the arithmetic native.
"""

import argparse
import gc
import os
import sys
import time
from math import sqrt

# Calibration target. Read from the environment so config/bench.env
# TARGET_SEC actually controls it; previously this was hardcoded and the
# documented shell knob silently did nothing. Found by external review.
TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))
DEFAULT_STEPS = 20000
DT = 0.01

PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

BODIES_INIT = {
    "sun": ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),
    "jupiter": (
        [4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01],
        [1.66007664274403694e-03 * DAYS_PER_YEAR,
         7.69901118419740425e-03 * DAYS_PER_YEAR,
         -6.90460016972063023e-05 * DAYS_PER_YEAR],
        9.54791938424326609e-04 * SOLAR_MASS),
    "saturn": (
        [8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01],
        [-2.76742510726862411e-03 * DAYS_PER_YEAR,
         4.99852801234917238e-03 * DAYS_PER_YEAR,
         2.30417297573763929e-05 * DAYS_PER_YEAR],
        2.85885980666130812e-04 * SOLAR_MASS),
    "uranus": (
        [1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01],
        [2.96460137564761618e-03 * DAYS_PER_YEAR,
         2.37847173959480950e-03 * DAYS_PER_YEAR,
         -2.96589568540237556e-05 * DAYS_PER_YEAR],
        4.36624404335156298e-05 * SOLAR_MASS),
    "neptune": (
        [1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01],
        [2.68067772490389322e-03 * DAYS_PER_YEAR,
         1.62824170038242295e-03 * DAYS_PER_YEAR,
         -9.51592254519715870e-05 * DAYS_PER_YEAR],
        5.15138902046611451e-05 * SOLAR_MASS),
}
SYSTEM_ORDER = ("sun", "jupiter", "saturn", "uranus", "neptune")


# ---------------------------------------------------------------------------
# [O2] Flat state: six parallel lists of scalars + one mass list.
# ---------------------------------------------------------------------------
def fresh_flat():
    xs, ys, zs, vxs, vys, vzs, ms = [], [], [], [], [], [], []
    for k in SYSTEM_ORDER:
        pos, vel, m = BODIES_INIT[k]
        xs.append(pos[0]); ys.append(pos[1]); zs.append(pos[2])
        vxs.append(vel[0]); vys.append(vel[1]); vzs.append(vel[2])
        ms.append(m)
    return xs, ys, zs, vxs, vys, vzs, ms


def build_pairs(ms):
    """[O3] Pairs with masses pre-resolved: (i, j, m_i, m_j)."""
    n = len(ms)
    return [(i, j, ms[i], ms[j]) for i in range(n) for j in range(i + 1, n)]


def offset_momentum_flat(vxs, vys, vzs, ms, ref_mass=SOLAR_MASS):
    px = py = pz = 0.0
    for i in range(len(ms)):
        m = ms[i]
        px -= vxs[i] * m; py -= vys[i] * m; pz -= vzs[i] * m
    vxs[0] = px / ref_mass; vys[0] = py / ref_mass; vzs[0] = pz / ref_mass


# ---------------------------------------------------------------------------
# The optimized hot kernel.
# `_sqrt=sqrt` is [O4]: a default argument is stored in the frame's fast
# locals, so calling it compiles to LOAD_FAST instead of LOAD_GLOBAL.
# ---------------------------------------------------------------------------
def advance_opt(dt, steps, state, pair_list, _sqrt=sqrt):
    xs, ys, zs, vxs, vys, vzs, ms = state
    nbody = len(ms)
    for _ in range(steps):
        for i, j, mi, mj in pair_list:           # [O3] masses come from the tuple
            # [O2] hoist every subscript into a local ONCE
            xi = xs[i]; yi = ys[i]; zi = zs[i]
            dx = xi - xs[j]
            dy = yi - ys[j]
            dz = zi - zs[j]
            d2 = dx * dx + dy * dy + dz * dz
            # [O1] 1/(d2*sqrt(d2)) == d2 ** -1.5, but via hardware SQRTSD
            mag = dt / (d2 * _sqrt(d2))
            bm_j = mj * mag
            bm_i = mi * mag
            vxs[i] = vxs[i] - dx * bm_j
            vys[i] = vys[i] - dy * bm_j
            vzs[i] = vzs[i] - dz * bm_j
            vxs[j] = vxs[j] + dx * bm_i
            vys[j] = vys[j] + dy * bm_i
            vzs[j] = vzs[j] + dz * bm_i
        # [O5] flat position update: no tuple unpack per body
        for k in range(nbody):
            xs[k] = xs[k] + dt * vxs[k]
            ys[k] = ys[k] + dt * vys[k]
            zs[k] = zs[k] + dt * vzs[k]


def report_energy_flat(state, pair_list, _sqrt=sqrt):
    xs, ys, zs, vxs, vys, vzs, ms = state
    e = 0.0
    for i, j, mi, mj in pair_list:
        dx = xs[i] - xs[j]; dy = ys[i] - ys[j]; dz = zs[i] - zs[j]
        e -= (mi * mj) / _sqrt(dx * dx + dy * dy + dz * dz)
    for i in range(len(ms)):
        e += ms[i] * (vxs[i] * vxs[i] + vys[i] * vys[i] + vzs[i] * vzs[i]) / 2.0
    return e


# ---------------------------------------------------------------------------
# Harness — identical contract to the baseline
# ---------------------------------------------------------------------------
def benchmark(loops, steps):
    t0 = time.perf_counter()
    for _ in range(loops):
        state = fresh_flat()
        pl = build_pairs(state[6])
        offset_momentum_flat(state[3], state[4], state[5], state[6])
        advance_opt(DT, steps, state, pl)
    elapsed = time.perf_counter() - t0
    return elapsed, report_energy_flat(state, pl)


def calibrate(steps):
    loops = 1
    while True:
        el, _ = benchmark(loops, steps)
        if el >= TARGET_SEC or loops >= 8192:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(description="OPTIMIZED nbody workload")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0)
    p.add_argument("--steps", type=int, default=DEFAULT_STEPS)
    p.add_argument("--no-gc", action="store_true")
    a = p.parse_args()

    if a.mode == "calibrate":
        print(calibrate(a.steps)); return 0

    if a.mode == "verify":
        state = fresh_flat()
        pl = build_pairs(state[6])
        offset_momentum_flat(state[3], state[4], state[5], state[6])
        e0 = report_energy_flat(state, pl)
        steps = a.steps   # MEASURED step count, not a reduced one
        advance_opt(DT, steps, state, pl)
        e1 = report_energy_flat(state, pl)
        rel = abs(e1 - e0) / abs(e0)
        assert rel < 1e-3, f"energy not conserved: rel={rel:.3e}"

        # CROSS-CHECK against the baseline implementation. This is the real
        # correctness gate: the optimization must reproduce the baseline's
        # physics, not merely be self-consistent.
        sys.path.insert(0, __import__("os").path.join(
            __import__("os").path.dirname(__import__("os").path.abspath(__file__)),
            "..", "bench"))
        import bm_nbody as base
        bpl = base.pairs(len(base.SYSTEM_ORDER))
        bb = base.fresh_system(); base.offset_momentum(bb, base.SOLAR_MASS)
        base.advance(base.DT, steps, bb, bpl)
        be = base.report_energy(bb, bpl)
        # Tolerance is for float reassociation only ([O1] changes the rounding
        # of one operation), not for any physical difference.
        diff = abs(be - e1) / abs(be)
        assert diff < 1e-9, (f"OPTIMIZED DIVERGES FROM BASELINE: "
                             f"base={be:.12f} opt={e1:.12f} rel={diff:.3e}")
        # Compare FULL STATE, not only the energy scalar. Energy is a summary:
        # different configurations can share an energy value, so agreement on it
        # alone cannot establish positions and velocities.
        bstate = []
        for (p_, v_, m_) in bb:
            bstate.extend([p_[0], p_[1], p_[2], v_[0], v_[1], v_[2]])
        xs, ys, zs, vxs, vys, vzs, ms = state
        ostate = []
        for i in range(len(ms)):
            ostate.extend([xs[i], ys[i], zs[i], vxs[i], vys[i], vzs[i]])
        max_abs = max(abs(x - y) for x, y in zip(ostate, bstate))
        scale = max(max(abs(x) for x in bstate), 1e-300)
        max_rel = max_abs / scale
        assert max_rel < 1e-9, (f"STATE diverges from baseline: "
                                f"max_abs={max_abs:.3e} max_rel={max_rel:.3e}")

        print(f"verify: OK  steps={steps}")
        print(f"  e_final={e1!r}  rel_drift={rel:.3e}")
        print(f"  state vs baseline: max_abs={max_abs:.3e} max_rel={max_rel:.3e} "
              f"({len(ostate)} values)")
        print(f"cross-check vs baseline: base={be:.12f} opt={e1:.12f} "
              f"rel_diff={diff:.3e}  MATCH")
        return 0

    loops = a.loops or calibrate(a.steps)
    if a.no_gc:
        gc.disable()

    elapsed, energy = benchmark(loops, a.steps)
    npairs = len(SYSTEM_ORDER) * (len(SYSTEM_ORDER) - 1) // 2
    total_steps = loops * a.steps
    flops = total_steps * npairs * 30.0

    print(f"bodies={len(SYSTEM_ORDER)} pairs={npairs} steps={a.steps} loops={loops}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/simulation")
    print(f"energy={energy:.9f}")
    print(f"step_rate={total_steps / elapsed / 1e3:.2f} ksteps/s  "
          f"~{flops / elapsed / 1e6:.2f} MFLOP/s (est.)")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_sim={elapsed / loops * 1e3:.4f} energy={energy:.9f} "
          f"ksteps_per_sec={total_steps / elapsed / 1e3:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
