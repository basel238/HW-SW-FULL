#!/usr/bin/env python3
"""
bench/bm_nbody.py — standalone n-body gravitational simulation (baseline,
faithful to the pyperformance `nbody` benchmark).

WHAT IT IS
----------
Symplectic (velocity-Verlet-style) integration of the Jovian planets plus the
Sun, as in the classic Computer Language Benchmarks Game n-body:

  advance(dt):
      for each unordered pair (i, j):
          dx = x_i - x_j                       # 3 subtractions
          mag = dt / (dx.dx)^1.5               # 1 dot, 1 sqrt, 1 divide
          v_i -= dx * m_j * mag                # 3 multiply-accumulates
          v_j += dx * m_i * mag                # 3 multiply-accumulates
      for each body:
          x += v * dt                          # 3 multiply-accumulates

WHY IT IS A GOOD PROJECT BENCHMARK
----------------------------------
  * O(n^2) pairwise inner loop -> a tight, perfectly regular MAC pattern. This
    is the single clearest case in the approved list for a multiply-accumulate
    / FMA hardware proposal ("Extend ISA with instructions... e.g.
    multiple-accumulate" from the brief).
  * Pure float arithmetic on small tuples/lists -> the ratio of useful FLOPs to
    interpreter overhead is dismal, and `perf stat` can quantify it exactly
    (instructions vs fp_arith_inst_retired).
  * Deterministic: energy is a conserved quantity, giving a precise correctness
    oracle for any optimization.

Modes: raw | calibrate | verify
"""

import argparse
import gc
import sys
import time

TARGET_SEC = 3.0
DEFAULT_STEPS = 20000
DT = 0.01

PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

# Body layout: [x, y, z], [vx, vy, vz], mass
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


def fresh_system():
    """Deep copy of the initial conditions: every run starts identically."""
    return [([x[:] for x in (pos, vel)] + [mass])
            for pos, vel, mass in (BODIES_INIT[k] for k in SYSTEM_ORDER)]


def pairs(n):
    """All unordered pairs — precomputed to keep it out of the hot loop."""
    return [(i, j) for i in range(n) for j in range(i + 1, n)]


def advance(dt, n, bodies, pair_list):
    """
    The hot kernel. Written in the straightforward style of the upstream
    benchmark: indexed list access, explicit per-component arithmetic.

    Every line here is a multiply-accumulate expressed as a sequence of
    interpreter operations. Note the `** 0.5` -- a full pow() call.
    """
    for _ in range(n):
        for i, j in pair_list:
            (p1, v1, m1) = bodies[i]
            (p2, v2, m2) = bodies[j]
            dx = p1[0] - p2[0]
            dy = p1[1] - p2[1]
            dz = p1[2] - p2[2]
            # dot product -> inverse-cube-law magnitude
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt * (d2 ** -1.5)
            b1m = m1 * mag
            b2m = m2 * mag
            v1[0] -= dx * b2m
            v1[1] -= dy * b2m
            v1[2] -= dz * b2m
            v2[0] += dx * b1m
            v2[1] += dy * b1m
            v2[2] += dz * b1m
        for (p, v, m) in bodies:
            p[0] += dt * v[0]
            p[1] += dt * v[1]
            p[2] += dt * v[2]


def report_energy(bodies, pair_list):
    """
    Total energy = kinetic + potential. This is a CONSERVED quantity, so it is
    the correctness oracle: any optimization must preserve it to ~1e-9.
    """
    e = 0.0
    for i, j in pair_list:
        (p1, v1, m1) = bodies[i]
        (p2, v2, m2) = bodies[j]
        dx = p1[0] - p2[0]; dy = p1[1] - p2[1]; dz = p1[2] - p2[2]
        e -= (m1 * m2) / ((dx * dx + dy * dy + dz * dz) ** 0.5)
    for (p, v, m) in bodies:
        e += m * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) / 2.0
    return e


def offset_momentum(bodies, ref_mass):
    """Zero the net momentum so the system does not drift."""
    px = py = pz = 0.0
    for (p, v, m) in bodies:
        px -= v[0] * m; py -= v[1] * m; pz -= v[2] * m
    p, v, m = bodies[0]
    v[0] = px / ref_mass; v[1] = py / ref_mass; v[2] = pz / ref_mass


def benchmark(loops, steps):
    """Each loop is a full, independent simulation from identical conditions."""
    pl = pairs(len(SYSTEM_ORDER))
    t0 = time.perf_counter()
    for _ in range(loops):
        bodies = fresh_system()
        offset_momentum(bodies, SOLAR_MASS)
        advance(DT, steps, bodies, pl)
    elapsed = time.perf_counter() - t0
    return elapsed, report_energy(bodies, pl)


def calibrate(steps):
    loops = 1
    while True:
        el, _ = benchmark(loops, steps)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(description="standalone nbody workload")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0, help="0 => auto-calibrate")
    p.add_argument("--steps", type=int, default=DEFAULT_STEPS,
                   help="integration steps per simulation")
    p.add_argument("--no-gc", action="store_true")
    a = p.parse_args()

    if a.mode == "calibrate":
        print(calibrate(a.steps)); return 0

    if a.mode == "verify":
        pl = pairs(len(SYSTEM_ORDER))
        b = fresh_system(); offset_momentum(b, SOLAR_MASS)
        e0 = report_energy(b, pl)
        advance(DT, 1000, b, pl)
        e1 = report_energy(b, pl)
        # Energy drift is the physics correctness check. This integrator is
        # symplectic, so energy error is BOUNDED and oscillatory rather than
        # zero -- a relative tolerance is the physically correct test. At
        # dt=0.01 over 1000 steps the expected relative drift is ~1e-4.
        drift = abs(e1 - e0)
        rel = drift / abs(e0) if e0 else drift
        assert rel < 1e-3, (f"energy not conserved: e0={e0:.9f} e1={e1:.9f} "
                            f"abs={drift:.3e} rel={rel:.3e}")
        # Determinism check: bit-identical energy from identical inputs.
        b2 = fresh_system(); offset_momentum(b2, SOLAR_MASS)
        advance(DT, 1000, b2, pl)
        assert report_energy(b2, pl) == e1, "nbody is not deterministic!"
        print(f"verify: OK  e_initial={e0:.9f} e_final={e1:.9f} "
              f"abs_drift={drift:.3e} rel_drift={rel:.3e}")
        return 0

    loops = a.loops or calibrate(a.steps)
    if a.no_gc:
        gc.disable()

    elapsed, energy = benchmark(loops, a.steps)
    npairs = len(pairs(len(SYSTEM_ORDER)))
    total_steps = loops * a.steps
    # 30 useful float ops per pair-interaction (counting the divide/sqrt as one
    # each) -- a deliberately conservative FLOP estimate for the HW proposal.
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
