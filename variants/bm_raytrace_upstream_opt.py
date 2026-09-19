#!/usr/bin/env python3
"""
variants/bm_raytrace_upstream_opt.py — OPTIMIZATION SLOT for the REAL
pyperformance raytrace kernel.

CURRENT STATE: **PASSTHROUGH — NO OPTIMIZATIONS APPLIED.**

This file exists so the pipeline has a complete baseline/optimized pair and can
be validated end to end on the genuine upstream workload. It deliberately runs
the unmodified upstream kernel, so a comparison against the baseline right now
must report approximately 1.00x. That is the correct and expected result: a
measurable difference here would mean the harness is biased, not that the code
is faster.

Optimizations will be added later, one at a time, each behind --kernel so its
individual contribution can be measured (see bm_nbody_upstream_opt.py's
--mode ablate for the pattern).

--------------------------------------------------------------------------
WHERE THE HEADROOM IS (from profiling the upstream kernel — NOT yet acted on)
--------------------------------------------------------------------------
Upstream raytrace carries substantially more interpreter overhead than the
custom stand-in, so the optimization ceiling should be HIGHER, not lower:

[H1] Type-check calls on every arithmetic operation.
     Vector.__add__ calls other.isPoint(); __sub__ and dot() call
     other.mustBeVector(). These are Python-level method calls that return a
     constant and compute nothing. Every vector operation therefore pays for an
     extra frame push/pop. Removing them requires collapsing the Point/Vector
     distinction, which changes the type semantics -- so it must be done
     carefully and verified against the pixel checksum.

[H2] A fresh list per ray in Scene.rayColour():
         intersections = [(o, o.intersectionTime(ray), s) for (o, s) in self.objects]
         i = firstIntersection(intersections)
     With 8 objects this allocates a list plus 8 tuples for EVERY ray, then
     scans it. Tracking the nearest hit in a running variable removes the
     allocation entirely.

[H3] intersectionTime() is called on all 8 objects even after a near hit is
     known. No early rejection, no bounding volumes.

[H4] try/finally around every rayColour() call purely to track recursion depth.
     Passing depth as a parameter removes the exception-handling setup.

[H5] Ray.__init__ calls vector.normalized(), which calls magnitude() ->
     dot() -> mustBeVector(). Shadow rays construct a Ray per light per hit, so
     this chain runs constantly.

[H6] Scene construction is INSIDE the timed loop (upstream's own structure), so
     object allocation for 8 objects + 2 lights is measured every frame.

[H7] visibleLights() builds a list per shaded point; with two lights it is
     almost always shorter to test them inline.

CORRECTNESS CONTRACT FOR FUTURE WORK
------------------------------------
The rendered image must remain BIT-IDENTICAL to the upstream baseline
(SHA-256 over canvas.bytes), checked at the measured 100x100 as well as small
and odd resolutions. This renderer contains discontinuities -- shadow-ray
hit/miss tests and a checkerboard parity test -- so a sub-ULP arithmetic change
can flip a branch and move a pixel by a large amount. That is not hypothetical:
it already happened once on the custom variant, where replacing three divisions
with a reciprocal-multiply changed one shadow-edge pixel by 118/255.
"""

import argparse
import gc
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "bench"))

import bm_raytrace_upstream as base  # noqa: E402  (shared loader + harness)

TARGET_SEC = float(os.environ.get("TARGET_SEC", "3.0"))

# Kernel registry. Only the passthrough exists today; each future optimization
# is added here so --mode ablate can attribute the speedup edit by edit.
KERNELS = {
    "upstream": None,   # None => upstream Scene, unmodified
}


def calibrate(width, height, scene_fn):
    loops = 1
    while True:
        el, _ = base.benchmark(loops, width, height, scene_fn)
        if el >= TARGET_SEC or loops >= 4096:
            return max(1, loops)
        loops *= 2


def main():
    up = base.load_upstream()
    p = argparse.ArgumentParser(
        description="OPTIMIZED upstream raytrace (currently a passthrough)")
    p.add_argument("--mode", choices=("raw", "calibrate", "verify", "ablate"),
                   default="raw")
    p.add_argument("--loops", type=int, default=0)
    p.add_argument("--width", type=int, default=up.DEFAULT_WIDTH)
    p.add_argument("--height", type=int, default=up.DEFAULT_HEIGHT)
    p.add_argument("--kernel", choices=tuple(KERNELS), default="upstream")
    p.add_argument("--no-gc", action="store_true")
    p.add_argument("--checksum", action="store_true")
    a = p.parse_args()

    scene_fn = KERNELS[a.kernel]

    if a.mode == "calibrate":
        print(calibrate(a.width, a.height, scene_fn)); return 0

    if a.mode == "verify":
        # Must be pixel-identical to the upstream baseline at every size. With
        # no optimizations applied this is trivially true; keeping the gate in
        # place now means it is already wired when edits begin.
        for (w, h) in [(24, 24), (a.width, a.height), (37, 23)]:
            _, c1 = base.benchmark(1, w, h, scene_fn)
            _, c2 = base.benchmark(1, w, h, scene_fn)
            s1 = base.checksum(c1)
            assert s1 == base.checksum(c2), f"not deterministic at {w}x{h}"
            _, cb = base.benchmark(1, w, h, None)     # upstream reference
            sb = base.checksum(cb)
            if s1 != sb:
                diff = sum(1 for x, y in zip(c1.bytes, cb.bytes) if x != y)
                worst = max((abs(x - y) for x, y in zip(c1.bytes, cb.bytes)),
                            default=0)
                raise AssertionError(
                    f"IMAGE DIFFERS FROM UPSTREAM at {w}x{h}\n"
                    f"  upstream sha={sb[:16]} optimized sha={s1[:16]}\n"
                    f"  {diff}/{len(cb.bytes)} channels differ, worst={worst}")
            print(f"  {w}x{h:<4} sha={s1[:16]} BIT-IDENTICAL to upstream")
        print(f"verify: OK  kernel={a.kernel}")
        print("NOTE: this variant is currently a PASSTHROUGH -- no optimizations")
        print("      are applied, so ~1.00x against the baseline is expected.")
        return 0

    if a.mode == "ablate":
        import statistics
        loops = a.loops or calibrate(a.width, a.height, None)
        reps = 5
        samples = dict((k, []) for k in KERNELS)
        for _ in range(reps):
            for name, fn in KERNELS.items():
                el, _ = base.benchmark(loops, a.width, a.height, fn)
                samples[name].append(el)
        ref = statistics.median(samples["upstream"])
        print(f"ABLATION  loops={loops} {a.width}x{a.height} reps={reps}")
        print(f"{'kernel':<12}{'median s':>12}{'speedup':>10}{'time red.':>11}")
        print("-" * 45)
        for name in KERNELS:
            m = statistics.median(samples[name])
            print(f"{name:<12}{m:>12.6f}{ref / m:>9.4f}x"
                  f"{(1 - m / ref) * 100:>10.2f}%")
        if len(KERNELS) == 1:
            print("\nOnly the passthrough kernel exists so far -- nothing to compare.")
        return 0

    loops = a.loops or calibrate(a.width, a.height, scene_fn)
    if a.no_gc:
        gc.disable()

    elapsed, canvas = base.benchmark(loops, a.width, a.height, scene_fn)
    rays = loops * a.width * a.height

    print(f"UPSTREAM raytrace — kernel={a.kernel} (PASSTHROUGH, no optimizations)")
    print(f"resolution={a.width}x{a.height} loops={loops}")
    print(f"elapsed={elapsed:.6f} s  {elapsed / loops * 1e3:.3f} ms/frame")
    print(f"primary_rays={rays}  {rays / elapsed / 1000.0:.2f} kray/s")
    if a.checksum:
        print(f"checksum={base.checksum(canvas)}")
    print(f"RESULT total_sec={elapsed:.6f} loops={loops} "
          f"ms_per_frame={elapsed / loops * 1e3:.4f} "
          f"krays_per_sec={rays / elapsed / 1000.0:.4f} kernel={a.kernel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
