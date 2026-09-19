#!/usr/bin/env python3
"""
bench/bm_raytrace_upstream.py — BASELINE wrapper around the REAL pyperformance
raytrace kernel.

WHY THIS FILE EXISTS
--------------------
An external review correctly identified that bench/bm_raytrace.py is an
independently written stand-in, not the upstream benchmark. Replacing the
workload changes the experiment. This wrapper imports
`upstream/bm_raytrace_upstream.py` COMPLETELY UNMODIFIED (extracted verbatim
from the installed pyperformance package; see upstream/PROVENANCE.txt for
version and sha256) and only adds the raw/calibrate/verify CLI the pipeline
needs.

WHAT IS AND IS NOT CHANGED
--------------------------
  NOT changed: Vector, Point, Sphere, Halfspace, Ray, Canvas, Scene,
               SimpleSurface, CheckerboardSurface, firstIntersection, and the
               scene constructed by bench_raytrace() -- every line of the
               measured kernel is upstream's.
  Added here : a pyperf stub (so the file imports without the venv;
               pyperf.perf_counter IS time.perf_counter), and the harness/CLI.

HOW THE UPSTREAM SCENE DIFFERS FROM THE CUSTOM STAND-IN
-------------------------------------------------------
This matters because it is why the optimization headroom is different:
  * 7 spheres (one large + six small) vs 4, plus a Halfspace ground plane.
  * TWO light sources, so every shaded point casts two shadow rays.
  * A Point/Vector type split where isPoint() / mustBeVector() are called on
    essentially every arithmetic operation -- pure interpreter overhead with no
    numerical content.
  * rayColour() builds a FRESH list of (object, t, surface) tuples for every
    ray, then scans it, instead of tracking the nearest hit in-place.
  * Recursion depth is tracked with a try/finally around each ray.
  * Reflection is unconditional (specularCoefficient defaults to 0.2), so every
    hit spawns a reflection ray up to depth 3.

The timed region mirrors upstream bench_raytrace() exactly: scene construction
is INSIDE the loop, as upstream has it, so the measurement includes building
the scene each iteration.

DETERMINISM
-----------
Upstream keeps no module-level mutable state across iterations (the Scene and
Canvas are rebuilt per loop), so a fresh module import per measurement is not
required for correctness. One import is used and reused.
"""

import argparse
import gc
import hashlib
import importlib.util
import os
import sys
import time
import types

TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))
HERE = os.path.dirname(os.path.abspath(__file__))
UPSTREAM = os.path.join(HERE, "..", "upstream", "bm_raytrace_upstream.py")

_MOD = None


def load_upstream():
    """
    Import the upstream kernel.

    A minimal pyperf stub is injected because upstream does `import pyperf` for
    perf_counter only; stubbing it keeps the upstream file byte-identical while
    letting phases 2/3/5 run under the system interpreter with no venv.
    """
    global _MOD
    if _MOD is not None:
        return _MOD

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
                 f"Run ./setup/05_get_upstream.sh to extract it from the "
                 f"installed pyperformance package.")

    spec = importlib.util.spec_from_file_location("_upstream_raytrace", UPSTREAM)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _MOD = mod
    return mod


# ---------------------------------------------------------------------------
# Harness — mirrors upstream bench_raytrace()
# ---------------------------------------------------------------------------
def render_once(up, width, height, scene_fn=None, ray_colour=None):
    """
    One frame, constructed exactly as upstream bench_raytrace() does.

    `scene_fn` / `ray_colour` are hooks the optimized variant uses to substitute
    ONLY the parts it changes, so the before/after remains an auditable swap
    rather than a rewrite.
    """
    canvas = up.Canvas(width, height)
    s = (scene_fn or up.Scene)()
    s.addLight(up.Point(30, 30, 10))
    s.addLight(up.Point(-10, 100, 30))
    s.lookAt(up.Point(0, 3, 0))
    s.addObject(up.Sphere(up.Point(1, 3, -10), 2),
                up.SimpleSurface(baseColour=(1, 1, 0)))
    for y in range(6):
        s.addObject(up.Sphere(up.Point(-3 - y * 0.4, 2.3, -5), 0.4),
                    up.SimpleSurface(baseColour=(y / 6.0, 1 - y / 6.0, 0.5)))
    s.addObject(up.Halfspace(up.Point(0, 0, 0), up.Vector.UP),
                up.CheckerboardSurface())
    s.render(canvas)
    return canvas


def benchmark(loops, width, height, scene_fn=None):
    up = load_upstream()
    t0 = time.perf_counter()
    for _ in range(loops):
        canvas = render_once(up, width, height, scene_fn)
    elapsed = time.perf_counter() - t0
    return elapsed, canvas


def checksum(canvas):
    """SHA-256 of the rendered pixel buffer: the exact correctness oracle."""
    return hashlib.sha256(canvas.bytes.tobytes()).hexdigest()


def calibrate(width, height):
    loops = 1
    while True:
        el, _ = benchmark(loops, width, height)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    up = load_upstream()
    p = argparse.ArgumentParser(
        description="upstream pyperformance raytrace (baseline)")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify"), default="raw")
    p.add_argument("--loops", type=int, default=0, help="0 => auto-calibrate")
    p.add_argument("--width", type=int, default=up.DEFAULT_WIDTH)
    p.add_argument("--height", type=int, default=up.DEFAULT_HEIGHT)
    p.add_argument("--no-gc", action="store_true")
    p.add_argument("--checksum", action="store_true")
    a = p.parse_args()

    if a.mode == "calibrate":
        print(calibrate(a.width, a.height)); return 0

    if a.mode == "verify":
        # Determinism at the MEASURED resolution as well as small and odd sizes.
        for (w, h) in [(24, 24), (a.width, a.height), (37, 23)]:
            _, c1 = benchmark(1, w, h)
            _, c2 = benchmark(1, w, h)
            s1, s2 = checksum(c1), checksum(c2)
            assert s1 == s2, f"upstream raytrace not deterministic at {w}x{h}"
            assert len(c1.bytes) == w * h * 3, f"pixel count wrong at {w}x{h}"
            assert any(c1.bytes), f"image entirely black at {w}x{h}"
            print(f"  {w}x{h:<4} sha={s1[:16]} pixels={len(c1.bytes)}")
        print("verify: OK  (upstream kernel, unmodified)")
        return 0

    loops = a.loops or calibrate(a.width, a.height)
    if a.no_gc:
        # The cyclic GC fires on allocation counts. Upstream allocates a Vector
        # or Point per arithmetic operation, so collector pauses would land
        # inside the timed region and appear in the profile as collect().
        gc.disable()

    elapsed, canvas = benchmark(loops, a.width, a.height)
    rays = loops * a.width * a.height

    print("UPSTREAM pyperformance raytrace kernel (unmodified)")
    print(f"resolution={a.width}x{a.height} loops={loops}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/frame")
    print(f"primary_rays={rays}  {rays / elapsed / 1000.0:.2f} kray/s")
    if a.checksum:
        print(f"checksum={checksum(canvas)}")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_frame={elapsed / loops * 1e3:.4f} "
          f"krays_per_sec={rays / elapsed / 1000.0:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
