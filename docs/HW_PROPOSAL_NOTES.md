# Hardware Acceleration — measured motivation for the stage-7 proposal

This file collects the **measured evidence** that should drive your accelerator
design, plus the numbers to quote. The design itself (RTL, block diagram,
interface, trade-offs) is yours to write — this is the input data, not the answer.

Fill the `<measured>` placeholders from your own run:

```bash
grep -E 'instructions|cycles|insn per cycle' results/latest_raytrace_baseline/perf/stat_baseline.txt
sed -n '1,25p' results/latest_raytrace_baseline/perf/report_baseline_self.txt
```

---

## 1. Why these two benchmarks point at the same accelerator

Both reduce to the **same primitive**: a 3-element dot product followed by an
inverse magnitude.

**raytrace**, per ray–sphere test:
```
oc = origin - center          3 subtractions
h  = oc · d                   3 mul + 2 add   <-- dot product (MAC)
c  = oc · oc - r²             3 mul + 2 add   <-- dot product (MAC)
disc = h*h - c                1 mul + 1 sub
sqrt(disc)                    1 sqrt
normalize()                   1 dot + 1 sqrt + 3 div
```

**nbody**, per body pair:
```
d  = p_i - p_j                3 subtractions
d2 = d · d                    3 mul + 2 add   <-- dot product (MAC)
mag = dt / (d2 * sqrt(d2))    1 sqrt, 1 mul, 1 div
v_i -= d * m_j * mag          3 MACs
v_j += d * m_i * mag          3 MACs
```

This is exactly the pattern the brief names as a good target: *"Extend ISA with
instructions [that] can accelerate workloads but are not too workload-specific
(e.g., multiple-accumulate)."* A 3-lane MAC + reciprocal-sqrt unit serves both
benchmarks — it is **not** a raytrace accelerator or an nbody accelerator.

---

## 2. The real bottleneck is dispatch, not arithmetic

This is the central argument, and the software optimization already proves it:

| Evidence | What it shows |
|---|---|
| Deleting the `Vector` class alone gave **~60 %** | The arithmetic was never the cost; the *object protocol around it* was |
| `nbody` gained **~17 %** from `pow()` → `sqrt()` + subscript hoisting | Even in a tight numeric loop, interpreter overhead dominates |
| IPC = `<measured>` | Low IPC with few cache misses ⇒ dependency/dispatch stalls, not memory |
| `instructions` count vs estimated useful FLOPs | The ratio is the *interpreter tax* — quote this number |

Compute the tax explicitly:

```
useful FLOPs (nbody) ≈ steps × 10 pairs × 30 ops
instructions retired  = <measured from perf stat>
→ instructions per useful FLOP = <compute>      ← this is your headline number
```

A ratio of ~50–100× is typical for CPython. **That gap, not the FP arithmetic, is
what the accelerator must attack** — which has an important design consequence:
a bare MAC unit reachable only through normal interpreter dispatch will deliver
almost nothing. The interface matters more than the datapath.

---

## 3. Amdahl bound — do this before designing anything

From `report_baseline_self.txt`, sum the self-overhead of the frames doing
vector arithmetic. Call it *f*.

```
max speedup = 1 / ((1 - f) + f/S)      S = accelerator speedup on that fraction

f = 0.40, S → ∞  ⇒  1.67× ceiling
f = 0.70, S → ∞  ⇒  3.33× ceiling
f = 0.70, S = 10 ⇒  2.70×
```

State *f* from your own profile and be honest about the ceiling. An accelerator
that is infinitely fast on 40 % of the runtime still cannot beat 1.67×.

---

## 4. Design sketch (starting point — refine it yourself)

**Unit:** 3-lane fused multiply-accumulate with an optional reciprocal-sqrt stage.

- **Inputs:** two 3×FP64 vectors (192 b each), opcode (dot / MAC / scale), and for
  nbody an accumulate-target select.
- **Outputs:** 1×FP64 scalar (dot product) or 3×FP64 vector (scaled MAC), plus a
  valid/ready pair.
- **Datapath:** 3 parallel FP64 multipliers → 3:1 adder tree (2 levels) →
  accumulator; a separate Newton-Raphson reciprocal-sqrt block (2 iterations from
  a lookup-table seed) for the normalize / inverse-cube-law path.
- **Pipeline:** ~4 stages for the dot product, ~8 for rsqrt. Target 1 GHz in the
  guest's notional process; state your assumption.
- **Throughput:** 1 dot product per cycle once the pipeline is full.

### Interface — the part that decides whether this is worth anything

Recall the course rules: *do not expect end users to change their code*, and
*never break user code*. Three options, in increasing intrusiveness:

1. **Memory-mapped registers + polling.** Simplest RTL. But an MMIO round trip
   costs far more than the ~5 ns of arithmetic you are accelerating — this
   **loses** at this granularity. Say so explicitly; the analysis is the point.
2. **New ISA instruction (`VDOT3`, `VMAC3`).** No MMIO cost, but requires
   CPython to emit it — realistically via a C extension or a patched
   `float_*` slot in the interpreter. Users recompile; their source is unchanged.
3. **Batch/DMA interface.** Hand the accelerator *many* pair-interactions at
   once (all 10 nbody pairs, or a tile of rays) so setup cost amortizes. This is
   the only variant where an MMIO/DMA design wins, and it maps directly onto the
   systolic-array and CGRA patterns from lecture 4.

Option 3 is the strongest answer, and it lets you connect explicitly to the TPU
case study: weights preloaded, data streamed, control amortized over many
operations.

### Trade-offs to discuss

| Axis | Consideration |
|---|---|
| Area | 3 FP64 multipliers ≈ 3× a scalar FPU; the rsqrt LUT dominates SRAM |
| Power | 3 lanes switching every cycle; gate idle lanes when the opcode is scalar |
| Frequency | The adder tree is the critical path; deeper pipelining buys clock at the cost of latency, which hurts the *latency-bound* MMIO variant |
| Complexity | FP64 is ~4× the area of FP32 — is FP64 actually required? nbody needs it for energy conservation; raytrace does **not** (output is quantized to 8 bits). A mixed-precision unit is a defensible design choice, and you can prove the raytrace half with the existing checksum gate. |

---

## 5. Where the bottleneck moves afterwards

Say this in the conclusion — it demonstrates systems thinking. Once vector
arithmetic is free, the remaining time is interpreter dispatch: `LOAD_FAST`,
refcounting, frame management. The next bottleneck is **CPython itself**, which
is why the honest end state of this analysis is either a JIT, or an accelerator
with a *batch* interface that escapes per-operation dispatch entirely.

That conclusion is also a neat callback to the course's framing: the problem and
the constraints are co-dependent moving targets. Accelerating the arithmetic
simply relocates the bottleneck to the abstraction layer above it.
