#!/usr/bin/env python3
"""
bench/bm_raytrace.py — standalone raytracer workload (baseline, faithful to
the pyperformance `raytrace` benchmark's structure).

WHY A STANDALONE COPY
---------------------
`perf record -- pyperformance run --bench raytrace` profiles the whole harness:
subprocess spawning, setuptools imports, calibration, JSON writing. Under dwarf
unwinding that machinery can dominate the flame graph. This file runs ONLY the
kernel under test in a single process, so the flame graph is the benchmark.

We keep pyperformance in the pipeline (phase 6) for the citable statistics; this
file exists for clean profiling and clean timing.

WHAT IT STRESSES
----------------
A recursive ray tracer over spheres with a checkerboard plane:
  * Vector arithmetic via a Python class with __add__/__mul__/dot/magnitude
    -> every 3-component operation costs several interpreter dispatches plus a
       heap allocation for the result object.
  * Ray-sphere intersection: a quadratic solve per ray per object (sqrt, dot).
  * Recursive reflection rays up to a depth limit.

This is the classic "the interpreter is the bottleneck, not the math" workload,
which is exactly the setup for a MAC/FMA-style hardware proposal.

Modes: raw | calibrate | verify
"""

import argparse
import gc
import os
import hashlib
import math
import sys
import time

# Calibration target. Read from the environment so config/bench.env
# TARGET_SEC actually controls it; previously this was hardcoded and the
# documented shell knob silently did nothing. Found by external review.
TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))
DEFAULT_W = 100
DEFAULT_H = 100
MAX_DEPTH = 3


# ---------------------------------------------------------------------------
# Vector: the hot data type. Deliberately a plain Python class -- this IS the
# bottleneck we later attack.
# ---------------------------------------------------------------------------
class Vector:
    # __slots__ avoids a per-instance __dict__. Even so, every operation below
    # allocates a NEW Vector, which is the dominant cost.
    __slots__ = ("x", "y", "z")

    def __init__(self, x, y, z):
        self.x = x; self.y = y; self.z = z

    def __add__(self, o):
        return Vector(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o):
        return Vector(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s):
        return Vector(self.x * s, self.y * s, self.z * s)

    def dot(self, o):
        # 3 multiplies + 2 adds -- a textbook multiply-accumulate, buried under
        # ~5 bytecode dispatches and 6 attribute loads.
        return self.x * o.x + self.y * o.y + self.z * o.z

    def magnitude(self):
        return math.sqrt(self.dot(self))

    def normalize(self):
        m = self.magnitude()
        if m == 0.0:
            return Vector(0.0, 0.0, 0.0)
        return Vector(self.x / m, self.y / m, self.z / m)

    def reflect(self, n):
        d = self.dot(n) * 2.0
        return self - n * d


# ---------------------------------------------------------------------------
# Scene primitives
# ---------------------------------------------------------------------------
class Sphere:
    __slots__ = ("center", "radius", "color", "reflect")

    def __init__(self, center, radius, color, reflect=0.5):
        self.center = center; self.radius = radius
        self.color = color;   self.reflect = reflect

    def intersect(self, origin, direction):
        """Returns distance along `direction`, or None. Quadratic solve."""
        oc = origin - self.center
        b = 2.0 * oc.dot(direction)
        c = oc.dot(oc) - self.radius * self.radius
        disc = b * b - 4.0 * c
        if disc < 0.0:
            return None
        sq = math.sqrt(disc)
        t1 = (-b - sq) * 0.5
        if t1 > 1e-6:
            return t1
        t2 = (-b + sq) * 0.5
        if t2 > 1e-6:
            return t2
        return None

    def normal_at(self, point):
        return (point - self.center).normalize()


class Plane:
    """Checkerboard ground plane at y = height."""
    __slots__ = ("height", "c1", "c2", "reflect")

    def __init__(self, height, c1, c2, reflect=0.2):
        self.height = height; self.c1 = c1; self.c2 = c2; self.reflect = reflect

    def intersect(self, origin, direction):
        if abs(direction.y) < 1e-6:
            return None
        t = (self.height - origin.y) / direction.y
        return t if t > 1e-6 else None

    def normal_at(self, point):
        return Vector(0.0, 1.0, 0.0)

    def color_at(self, point):
        return self.c1 if (int(math.floor(point.x) + math.floor(point.z)) & 1) else self.c2


def build_scene():
    return {
        "spheres": [
            Sphere(Vector(0.0, 0.0, -5.0), 1.0, Vector(1.0, 0.2, 0.2), 0.4),
            Sphere(Vector(2.0, 0.5, -7.0), 1.2, Vector(0.2, 1.0, 0.3), 0.6),
            Sphere(Vector(-2.2, 0.2, -6.0), 0.9, Vector(0.2, 0.3, 1.0), 0.5),
            Sphere(Vector(0.6, -0.4, -3.5), 0.4, Vector(1.0, 1.0, 0.2), 0.3),
        ],
        "plane": Plane(-1.2, Vector(0.9, 0.9, 0.9), Vector(0.15, 0.15, 0.15)),
        "light": Vector(-4.0, 6.0, 1.0),
    }


# ---------------------------------------------------------------------------
# Tracing kernel
# ---------------------------------------------------------------------------
def nearest_hit(scene, origin, direction):
    best_t = float("inf"); best = None
    for s in scene["spheres"]:
        t = s.intersect(origin, direction)
        if t is not None and t < best_t:
            best_t = t; best = s
    t = scene["plane"].intersect(origin, direction)
    if t is not None and t < best_t:
        best_t = t; best = scene["plane"]
    return best, best_t


def trace(scene, origin, direction, depth=0):
    """Recursive: shading + one reflection ray per bounce, up to MAX_DEPTH."""
    obj, t = nearest_hit(scene, origin, direction)
    if obj is None:
        return Vector(0.05, 0.05, 0.12)          # background

    point = origin + direction * t
    normal = obj.normal_at(point)
    base = obj.color_at(point) if isinstance(obj, Plane) else obj.color

    # Lambertian diffuse term.
    to_light = (scene["light"] - point).normalize()
    lam = to_light.dot(normal)
    if lam < 0.0:
        lam = 0.0

    # Hard shadow: one occlusion ray toward the light.
    shadow_obj, _ = nearest_hit(scene, point + normal * 1e-4, to_light)
    if shadow_obj is not None:
        lam *= 0.25

    col = base * (0.12 + 0.88 * lam)

    # Reflection: the recursion that makes the flame graph deep.
    if depth < MAX_DEPTH and obj.reflect > 0.0:
        rdir = direction.reflect(normal).normalize()
        rcol = trace(scene, point + normal * 1e-4, rdir, depth + 1)
        col = col * (1.0 - obj.reflect) + rcol * obj.reflect
    return col


def render(width, height, scene):
    """Returns a flat list of ints; the checksum makes correctness verifiable."""
    pixels = []
    eye = Vector(0.0, 0.0, 1.0)
    inv_w = 1.0 / width
    inv_h = 1.0 / height
    aspect = width / height
    for j in range(height):
        y = (0.5 - (j + 0.5) * inv_h) * 2.0
        for i in range(width):
            x = ((i + 0.5) * inv_w - 0.5) * 2.0 * aspect
            d = Vector(x, y, -1.0).normalize()
            c = trace(scene, eye, d)
            # Clamp + quantize to 8-bit.
            pixels.append(int(min(1.0, max(0.0, c.x)) * 255.0))
            pixels.append(int(min(1.0, max(0.0, c.y)) * 255.0))
            pixels.append(int(min(1.0, max(0.0, c.z)) * 255.0))
    return pixels


def checksum(pixels):
    return hashlib.sha256(bytes(p & 0xFF for p in pixels)).hexdigest()


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
def benchmark(loops, width, height):
    scene = build_scene()
    t0 = time.perf_counter()
    for _ in range(loops):
        pixels = render(width, height, scene)
    elapsed = time.perf_counter() - t0
    return elapsed, pixels


def calibrate(width, height):
    loops = 1
    while True:
        el, _ = benchmark(loops, width, height)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    p = argparse.ArgumentParser(description="standalone raytrace workload")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0, help="0 => auto-calibrate")
    p.add_argument("--width", type=int, default=DEFAULT_W)
    p.add_argument("--height", type=int, default=DEFAULT_H)
    p.add_argument("--no-gc", action="store_true",
                   help="disable cyclic GC during measurement")
    p.add_argument("--checksum", action="store_true", help="print output checksum")
    a = p.parse_args()

    if a.mode == "calibrate":
        print(calibrate(a.width, a.height)); return 0

    if a.mode == "verify":
        # Determinism gate. Tested at the MEASURED resolution as well as small
        # sizes: an earlier version checked only 32x32 while the benchmark runs
        # at 100x100, so a defect at the measured size could have slipped by.
        sizes = [(32, 32), (a.width, a.height), (37, 23)]
        for (w, h) in sizes:
            _, q1 = benchmark(1, w, h)
            _, q2 = benchmark(1, w, h)
            c1, c2 = checksum(q1), checksum(q2)
            assert c1 == c2, f"raytrace not deterministic at {w}x{h}"
            assert len(q1) == w * h * 3, f"pixel count wrong at {w}x{h}"
            assert any(v > 0 for v in q1), f"image entirely black at {w}x{h}"
            print(f"  {w}x{h:<4} checksum={c1[:16]} pixels={len(q1)}")

        # Geometric edge cases. These are the rays where a 1-ULP difference can
        # flip a hit/miss decision and change a pixel by a large amount, so the
        # baseline's behaviour on them is part of the numerical contract that any
        # optimized variant must reproduce.
        scene = build_scene()
        probes = [
            ("tangent-to-small-sphere", Vector(1.0, -0.4, -3.6), Vector(0.0, 0.0, 1.0)),
            ("near-parallel-to-plane",  Vector(0.0, 0.0, 1.0),   Vector(1.0, -1e-6, 0.0)),
            ("straight-down-at-plane",  Vector(0.0, 2.0, 0.0),   Vector(0.0, -1.0, 0.0)),
            ("through-sphere-centre",   Vector(0.0, 0.0, 1.0),   Vector(0.0, 0.0, -1.0)),
            ("away-from-scene",         Vector(0.0, 0.0, 1.0),   Vector(0.0, 1.0, 0.0)),
        ]
        print("  edge-case rays (nearest hit):")
        for name, o, d in probes:
            obj, t = nearest_hit(scene, o, d.normalize())
            kind = "miss" if obj is None else type(obj).__name__
            print(f"    {name:<26} {kind:<8} t={t if obj is not None else '-'}")
        print("verify: OK")
        return 0

    loops = a.loops or calibrate(a.width, a.height)
    if a.no_gc:
        # The cyclic GC triggers on allocation counts. This workload allocates a
        # Vector per arithmetic op, so GC pauses land inside the timed region
        # and appear in the flame graph as collect(). Disabling isolates the
        # raytracing cost; the manifest records that we did so.
        gc.disable()

    elapsed, pixels = benchmark(loops, a.width, a.height)
    rays = loops * a.width * a.height

    print(f"resolution={a.width}x{a.height} loops={loops} max_depth={MAX_DEPTH}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/frame")
    print(f"primary_rays={rays}  {rays / elapsed / 1000.0:.2f} kray/s")
    if a.checksum:
        print(f"checksum={checksum(pixels)}")
    # Machine-readable line consumed by lib/common.sh and tools/compare.sh.
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_frame={elapsed / loops * 1e3:.4f} krays_per_sec={rays / elapsed / 1000.0:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
