#!/usr/bin/env python3
"""
variants/bm_raytrace_opt.py — OPTIMIZED raytrace.

Pure-software, CPython-only, no third-party libraries. The rendered image must
be BIT-IDENTICAL to the baseline: the verify mode compares SHA-256 checksums,
so any change that alters a single pixel fails the gate.

WHAT WAS CHANGED AND WHY
------------------------

[O1] ELIMINATE THE Vector CLASS. Carry x,y,z as three separate local floats.
     Profile evidence (MEASURED, leaf attribution from perf + cProfile
     call counts; note that call-graph HIERARCHY was not usable until
     CALLGRAPH=dwarf was fixed, so the causal chains below are inferred
     from leaf shares and call counts, not from measured stacks):
     baseline flame graph is dominated by Vector.__add__,
     __sub__, __mul__, dot, normalize; cProfile shows millions of calls, and
     report_*_self.txt shows the interpreter's call machinery
     (_PyObject_MakeTpCall, type_call, tp_new) high in self time.
     Why it is faster: each `a + b` on Vector costs a LOAD_METHOD-ish dispatch
     to __add__, a Python frame push/pop, a tp_new heap allocation for the
     result, and later a GC/refcount decref. Replacing it with three
     scalar-local subtractions removes ALL of that: no frame, no allocation,
     no refcounting. This is the dominant win.
     SCOPE, precisely: this removes VECTOR CONTAINER objects, their
     special-method dispatch and their attribute lookups. It does NOT
     remove all allocation or all dispatch -- Python floats are still
     boxed heap objects that are allocated, refcounted and freed, and
     every arithmetic operation still goes through the interpreter.
     Trade-off, stated honestly: the code is markedly less readable. That is
     the real cost of this optimization and worth saying out loud.

[O2] HOIST math.sqrt TO A LOCAL (default argument `_sqrt=sqrt`).
     Why: `math.sqrt(x)` is LOAD_GLOBAL(math) + LOAD_ATTR(sqrt) -- two dict
     lookups per call. A default argument lives in the frame's fast locals, so
     it becomes a single LOAD_FAST.

[O3] (REVERTED — kept only behind an opt-in flag) Replacing normalize()'s three
     divisions with one reciprocal + three multiplies.
     WHAT HAPPENED: this is NOT bit-exact. `(1.0/m)*x` rounds twice (once for
     the reciprocal, once for the product) whereas `x/m` rounds once. The error
     is ~1 ULP, which is normally invisible -- but this renderer has
     DISCONTINUITIES (shadow-ray hit/miss, checkerboard parity, silhouette
     edges). At one pixel on a shadow boundary a 1-ULP change flipped the
     occlusion test, changing that pixel by 118/255.
     The verify gate caught it immediately, which is precisely why the gate
     compares checksums against the baseline rather than trusting "it looks
     fine". DEFAULT IS NOW EXACT DIVISION. Set FAST_FP=1 to opt into the
     reciprocal form and see the effect for yourself.
     LESSON FOR THE REPORT: "safe" FP strength reduction is only safe in
     branch-free numeric code. Any optimization sitting upstream of a
     comparison can change control flow.

[O4] FLATTEN THE SCENE INTO TUPLES OF SCALARS, built once outside the loop.
     Profile evidence: report_*_self.txt shows attribute loads (LOAD_ATTR on
     .center/.radius/.color) as a significant self-time cost.
     Why: instance attribute access on a __slots__ class is a descriptor
     lookup; tuple unpacking into locals is an array read.

[O5] INLINE ray-sphere intersection INTO the nearest-hit loop.
     Why: removes one Python function call per sphere per ray. At ~100x100
     pixels x 4 spheres x (1 primary + 1 shadow + 3 reflection bounces) this is
     millions of eliminated frame push/pops.

[O6] STRENGTH-REDUCE the quadratic solve: the baseline's `disc = b*b - 4*c`
     with b = 2*oc.dot(d) is algebraically `h = oc.dot(d)`, `disc = h*h - c`.
     Halving b removes two multiplies by 2.0 and one by 0.5 per test.

BIT-EXACTNESS — THE HONEST CAVEAT
---------------------------------
[O3] and [O6] change the ORDER and COUNT of floating-point operations, so they
are not guaranteed bit-identical in general. They happen to be here because the
final pixel values are quantized to 8 bits via int(x*255), which absorbs
differences far below 1/255. The verify mode asserts checksum equality, so if a
future edit breaks this the gate catches it. If you want a provably exact
variant, the exact forms are already the DEFAULT; FAST_FP=1 opts out of them.
(An earlier draft of this file documented a STRICT_FP=1 switch. That variable is
now DERIVED from FAST_FP and is not read from the environment -- documenting it
as a user-facing knob was wrong. Flagged by external review.)

NOT DONE (and why — good presentation material)
-----------------------------------------------
  * numpy vectorization per-ray: the arrays are length 3; numpy's per-call
    overhead (~1us) dwarfs 3 floats of work. Only wins if you restructure to
    trace ALL rays at once, which is a different program.
  * multiprocessing: would work (rays are independent) but the brief asks for
    single-threaded optimization, and it would make the perf comparison
    apples-to-oranges.
"""

import argparse
import gc
import hashlib
import os
import sys
import time
from math import floor, sqrt

# Calibration target. Read from the environment so config/bench.env
# TARGET_SEC actually controls it; previously this was hardcoded and the
# documented shell knob silently did nothing. Found by external review.
TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))
DEFAULT_W = 100
DEFAULT_H = 100
MAX_DEPTH = 3
# Exact FP is the DEFAULT. FAST_FP=1 opts into the reciprocal-multiply form
# ([O3]), which is ~1 ULP off and is known to flip a shadow-edge pixel.
FAST_FP = os.environ.get("FAST_FP", "0") == "1"
STRICT_FP = not FAST_FP


# ---------------------------------------------------------------------------
# [O4] Flat scene: tuples of scalars, no objects in the hot path.
# spheres: (cx, cy, cz, radius, r, g, b, reflect, radius_squared)
# ---------------------------------------------------------------------------
def build_scene_flat():
    spheres = (
        (0.0, 0.0, -5.0, 1.0, 1.0, 0.2, 0.2, 0.4, 1.0 * 1.0),
        (2.0, 0.5, -7.0, 1.2, 0.2, 1.0, 0.3, 0.6, 1.2 * 1.2),
        (-2.2, 0.2, -6.0, 0.9, 0.2, 0.3, 1.0, 0.5, 0.9 * 0.9),
        # r2 MUST be computed as r*r, not written as a decimal literal:
        # 0.4*0.4 == 0.16000000000000003, which is NOT equal to 0.16. The
        # literal shrinks the sphere by ~3e-17, and a tangent ray at
        # origin (1.0,-0.4,-3.6) dir (0,0,1) that HITS in the baseline
        # (t=0.09999999705) MISSES here. Found by external review.
        (0.6, -0.4, -3.5, 0.4, 1.0, 1.0, 0.2, 0.3, 0.4 * 0.4),
    )
    plane = (-1.2, 0.9, 0.9, 0.9, 0.15, 0.15, 0.15, 0.2)  # height, c1 rgb, c2 rgb, reflect
    light = (-4.0, 6.0, 1.0)
    return spheres, plane, light


# ---------------------------------------------------------------------------
# [O5] Fully inlined nearest-hit. Returns (kind, index, t) with
# kind: 0 = miss, 1 = sphere, 2 = plane.
# ---------------------------------------------------------------------------
def nearest_hit_flat(ox, oy, oz, dx, dy, dz, spheres, plane, _sqrt=sqrt):
    best_t = 1e30
    best_kind = 0
    best_idx = -1

    idx = 0
    for s in spheres:
        # [O4] one tuple unpack, then pure locals
        cx = s[0]; cy = s[1]; cz = s[2]; r2 = s[8]
        ocx = ox - cx; ocy = oy - cy; ocz = oz - cz
        # [O6] half-b form: h = oc.d, disc = h*h - (oc.oc - r^2)
        h = ocx * dx + ocy * dy + ocz * dz
        c = ocx * ocx + ocy * ocy + ocz * ocz - r2
        disc = h * h - c
        if disc >= 0.0:
            sq = _sqrt(disc)
            t = -h - sq
            if t <= 1e-6:
                t = -h + sq
            if 1e-6 < t < best_t:
                best_t = t; best_kind = 1; best_idx = idx
        idx += 1

    # plane
    # Must mirror the baseline EXACTLY: `if abs(direction.y) < 1e-6: return None`
    # rejects only |dy| strictly below the epsilon, so |dy| == 1e-6 is ACCEPTED.
    # The previous form (dy < -1e-6 or dy > 1e-6) excluded that boundary.
    if not (-1e-6 <= dy <= 1e-6):
        t = (plane[0] - oy) / dy
        if 1e-6 < t < best_t:
            best_t = t; best_kind = 2; best_idx = 0

    return best_kind, best_idx, best_t


def trace_flat(ox, oy, oz, dx, dy, dz, spheres, plane, light, depth=0, _sqrt=sqrt):
    """[O1] Everything is scalar locals. No Vector objects are ever created."""
    kind, idx, t = nearest_hit_flat(ox, oy, oz, dx, dy, dz, spheres, plane, _sqrt)
    if kind == 0:
        return 0.05, 0.05, 0.12                      # background

    # hit point
    px = ox + dx * t; py = oy + dy * t; pz = oz + dz * t

    if kind == 1:
        s = spheres[idx]
        nx = px - s[0]; ny = py - s[1]; nz = pz - s[2]
        m = _sqrt(nx * nx + ny * ny + nz * nz)
        if m != 0.0:
            if STRICT_FP:
                nx = nx / m; ny = ny / m; nz = nz / m
            else:
                inv = 1.0 / m                        # [O3] one divide, three muls
                nx *= inv; ny *= inv; nz *= inv
        br = s[4]; bg = s[5]; bb = s[6]; refl = s[7]
    else:
        nx = 0.0; ny = 1.0; nz = 0.0
        # checkerboard
        if int(floor(px) + floor(pz)) & 1:
            br = plane[1]; bg = plane[2]; bb = plane[3]
        else:
            br = plane[4]; bg = plane[5]; bb = plane[6]
        refl = plane[7]

    # light direction (normalized)
    lx = light[0] - px; ly = light[1] - py; lz = light[2] - pz
    lm = _sqrt(lx * lx + ly * ly + lz * lz)
    if lm != 0.0:
        if STRICT_FP:
            lx = lx / lm; ly = ly / lm; lz = lz / lm
        else:
            linv = 1.0 / lm
            lx *= linv; ly *= linv; lz *= linv

    lam = lx * nx + ly * ny + lz * nz
    if lam < 0.0:
        lam = 0.0

    # shadow ray, offset along the normal to avoid self-intersection
    sk, _, _ = nearest_hit_flat(px + nx * 1e-4, py + ny * 1e-4, pz + nz * 1e-4,
                                lx, ly, lz, spheres, plane, _sqrt)
    if sk != 0:
        lam *= 0.25

    shade = 0.12 + 0.88 * lam
    cr = br * shade; cg = bg * shade; cb = bb * shade

    # reflection recursion
    if depth < MAX_DEPTH and refl > 0.0:
        d2n = (dx * nx + dy * ny + dz * nz) * 2.0
        rx = dx - nx * d2n; ry = dy - ny * d2n; rz = dz - nz * d2n
        rm = _sqrt(rx * rx + ry * ry + rz * rz)
        if rm != 0.0:
            if STRICT_FP:
                rx = rx / rm; ry = ry / rm; rz = rz / rm
            else:
                rinv = 1.0 / rm
                rx *= rinv; ry *= rinv; rz *= rinv
        rr, rg, rb = trace_flat(px + nx * 1e-4, py + ny * 1e-4, pz + nz * 1e-4,
                                rx, ry, rz, spheres, plane, light, depth + 1, _sqrt)
        inv_refl = 1.0 - refl
        cr = cr * inv_refl + rr * refl
        cg = cg * inv_refl + rg * refl
        cb = cb * inv_refl + rb * refl

    return cr, cg, cb


def render_flat(width, height, scene, _sqrt=sqrt):
    spheres, plane, light = scene
    pixels = []
    append = pixels.append                  # bind the method once, not per pixel
    inv_w = 1.0 / width
    inv_h = 1.0 / height
    aspect = width / height
    for j in range(height):
        y = (0.5 - (j + 0.5) * inv_h) * 2.0
        for i in range(width):
            x = ((i + 0.5) * inv_w - 0.5) * 2.0 * aspect
            # normalize the primary ray direction
            m = _sqrt(x * x + y * y + 1.0)
            if STRICT_FP:
                dx = x / m; dy = y / m; dz = -1.0 / m
            else:
                inv = 1.0 / m
                dx = x * inv; dy = y * inv; dz = -1.0 * inv
            cr, cg, cb = trace_flat(0.0, 0.0, 1.0, dx, dy, dz,
                                    spheres, plane, light, 0, _sqrt)
            if cr < 0.0: cr = 0.0
            elif cr > 1.0: cr = 1.0
            if cg < 0.0: cg = 0.0
            elif cg > 1.0: cg = 1.0
            if cb < 0.0: cb = 0.0
            elif cb > 1.0: cb = 1.0
            append(int(cr * 255.0)); append(int(cg * 255.0)); append(int(cb * 255.0))
    return pixels


def checksum(pixels):
    return hashlib.sha256(bytes(p & 0xFF for p in pixels)).hexdigest()


def benchmark(loops, width, height):
    scene = build_scene_flat()
    t0 = time.perf_counter()
    for _ in range(loops):
        pixels = render_flat(width, height, scene)
    return time.perf_counter() - t0, pixels


def calibrate(width, height):
    loops = 1
    while True:
        el, _ = benchmark(loops, width, height)
        if el >= TARGET_SEC or loops >= 8192:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(description="OPTIMIZED raytrace workload")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0)
    p.add_argument("--width", type=int, default=DEFAULT_W)
    p.add_argument("--height", type=int, default=DEFAULT_H)
    p.add_argument("--no-gc", action="store_true")
    p.add_argument("--checksum", action="store_true")
    a = p.parse_args()

    if a.mode == "calibrate":
        print(calibrate(a.width, a.height)); return 0

    if a.mode == "verify":
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "bench"))
        import bm_raytrace as base

        # Checked at the MEASURED resolution as well as small and odd sizes.
        # An earlier version verified only 32x32 while the benchmark renders
        # 100x100, so a defect at the measured size could have slipped through.
        for (w, h) in [(32, 32), (a.width, a.height), (37, 23)]:
            _, q1 = benchmark(1, w, h)
            _, q2 = benchmark(1, w, h)
            c1 = checksum(q1)
            assert c1 == checksum(q2), f"optimized not deterministic at {w}x{h}"

            # THE REAL GATE: pixel-identical to the baseline renderer.
            _, bp = base.benchmark(1, w, h)
            bc = base.checksum(bp)
            if bc != c1:
                diffs = [abs(x - y) for x, y in zip(bp, q1)]
                worst = max(diffs) if diffs else 0
                nbad = sum(1 for d in diffs if d)
                raise AssertionError(
                    f"OPTIMIZED IMAGE DIFFERS FROM BASELINE at {w}x{h}\n"
                    f"  baseline sha={bc[:16]} optimized sha={c1[:16]}\n"
                    f"  {nbad}/{len(diffs)} channels differ, worst delta={worst}\n"
                    f"  unset FAST_FP to use the exact-division form.")
            print(f"  {w}x{h:<4} sha={c1[:16]} BIT-IDENTICAL to baseline")

        # Geometric edge cases: rays where a 1-ULP difference can flip a
        # hit/miss decision. The optimized nearest-hit must agree with the
        # baseline on every one of them, not merely on the average image.
        bscene = base.build_scene()
        oscene = build_scene_flat()
        probes = [
            ("tangent-to-small-sphere", (1.0, -0.4, -3.6), (0.0, 0.0, 1.0)),
            ("near-parallel-to-plane",  (0.0, 0.0, 1.0),   (1.0, -1e-6, 0.0)),
            ("straight-down-at-plane",  (0.0, 2.0, 0.0),   (0.0, -1.0, 0.0)),
            ("through-sphere-centre",   (0.0, 0.0, 1.0),   (0.0, 0.0, -1.0)),
            ("away-from-scene",         (0.0, 0.0, 1.0),   (0.0, 1.0, 0.0)),
        ]
        print("  edge-case rays:")
        for name, (ox, oy, oz), (dx0, dy0, dz0) in probes:
            bd = base.Vector(dx0, dy0, dz0).normalize()
            bobj, bt = base.nearest_hit(bscene, base.Vector(ox, oy, oz), bd)
            k, _i, t = nearest_hit_flat(ox, oy, oz, bd.x, bd.y, bd.z,
                                        oscene[0], oscene[1])
            bhit = bobj is not None
            ohit = k != 0
            status = "AGREE" if bhit == ohit else "*** DIVERGENT ***"
            assert bhit == ohit, (
                f"{name}: baseline {'HIT' if bhit else 'MISS'} but "
                f"optimized {'HIT' if ohit else 'MISS'}")
            # When both hit, t must match bit-for-bit: any difference here means
            # the quadratic solve was altered, not just the shading.
            if bhit:
                assert bt == t, f"{name}: t differs {bt!r} vs {t!r}"
            print(f"    {name:<26} {'HIT' if bhit else 'MISS':<5} {status}")

        print("verify: OK")
        print(f"fp_mode={'FAST_FP (reciprocal, ~1ULP)' if FAST_FP else 'exact division (bit-identical)'}")
        return 0

    loops = a.loops or calibrate(a.width, a.height)
    if a.no_gc:
        gc.disable()

    elapsed, pixels = benchmark(loops, a.width, a.height)
    rays = loops * a.width * a.height
    print(f"resolution={a.width}x{a.height} loops={loops} max_depth={MAX_DEPTH}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/frame")
    print(f"primary_rays={rays}  {rays / elapsed / 1000.0:.2f} kray/s")
    if a.checksum:
        print(f"checksum={checksum(pixels)}")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_frame={elapsed / loops * 1e3:.4f} krays_per_sec={rays / elapsed / 1000.0:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
