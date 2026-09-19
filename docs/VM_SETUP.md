# VM Setup — QEMU guest for perf-based profiling

Follows the course guide (Step 0 / Step 1), with the additions needed to get
**hardware performance counters** working inside the guest.

---

## Step 0 — copy the prepared image

```bash
scp <your_username>@naranja10.cslcs.technion.ac.il:/scratch/ece882-001/jammy-server-cloudimg-amd64-disk-kvm.img .
```

## Step 1 — cloud-init seed (first boot only)

The cloud image has no password and no user until cloud-init configures it.

```bash
cat > user-data <<'EOF'
#cloud-config
users:
  - name: student
    plain_text_passwd: student
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: sudo
ssh_pwauth: true
EOF

echo "instance-id: hwsw-01
local-hostname: hwsw-vm" > meta-data

cloud-localds seed.img user-data meta-data   # apt install cloud-image-utils
```

Give the disk room first — the base image is small and `python3-dbg` plus the
venv need a few GB:

```bash
qemu-img resize jammy-server-cloudimg-amd64-disk-kvm.img +20G
```

---

## Step 2 — launch, **with PMU passthrough**

This is the part that matters for this project:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 4 \
  -m 4G \
  -drive file=jammy-server-cloudimg-amd64-disk-kvm.img,if=virtio,format=qcow2 \
  -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=n0 \
  -nographic
```

Then:

```bash
ssh -p 2222 student@localhost
```

### Why `-enable-kvm -cpu host` is not optional

| Flag | Effect if omitted |
|------|-------------------|
| `-enable-kvm` | Guest runs under TCG (pure emulation). 10–100× slower, and **all timing is meaningless** — you would be measuring the emulator. |
| `-cpu host` | The vCPU is a generic model with **no PMU**. `perf stat -e cycles` fails; no IPC, no cache-miss data. Flame graphs still work via the `cpu-clock` software event. |
| `-smp 4` | With 1 vCPU you cannot pin the workload away from kernel timers. The pipeline clamps `PIN_CPU` automatically, but the results are noisier. |

Verify inside the guest:

```bash
systemd-detect-virt          # -> kvm
perf stat -e cycles true     # must succeed
lscpu | grep -i 'model name' # should show your REAL host CPU
```

If `perf stat -e cycles` fails, you are running without PMU passthrough. On some
hosts you additionally need, on the **host**:

```bash
# Intel
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel enable_pmu=1
# AMD
sudo modprobe -r kvm_amd   && sudo modprobe kvm_amd
```

Nested virtualization (running the VM inside another VM) usually **cannot**
forward the PMU at all. If you are in that situation, accept software-event
profiling: flame graphs and wall-clock speedups remain perfectly valid, and the
pipeline will tell you which phases it is skipping.

---

## Step 3 — project setup inside the guest

```bash
git clone <your-repo-url> hwsw-perf-project
cd hwsw-perf-project

sudo ./setup/01_install_deps.sh    # perf, python3-dbg, toolchain
./setup/02_get_flamegraph.sh       # FlameGraph toolkit
sudo ./setup/03_tune_vm.sh         # kernel knobs (re-run after every reboot)
./setup/04_make_venv.sh            # pyperformance venv (NOT as root)
./tools/doctor.sh                  # preflight
```

`setup/03_tune_vm.sh` changes are **runtime-only** and reset on reboot. To make
them persistent:

```bash
sudo tee /etc/sysctl.d/99-perf.conf <<'EOF'
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0
kernel.randomize_va_space = 0
kernel.nmi_watchdog = 0
kernel.yama.ptrace_scope = 0
EOF
```

---

## Known issues

**`linux-tools-$(uname -r)` not found.** Cloud kernels sometimes lack a matching
package. Fall back to:

```bash
sudo apt install -y linux-tools-generic
ls /usr/lib/linux-tools/                       # find the available version
export PATH=/usr/lib/linux-tools/<version>:$PATH
```

A perf/kernel version mismatch prints a warning and may fail to resolve symbols;
`tools/doctor.sh` flags this.

**`perf record` reports lost samples.** DWARF unwinding copies a stack slice per
sample and can overrun the ring buffer:

```bash
PERF_MMAP_PAGES=64M ./script_raytrace.sh     # bigger buffer
SAMPLE_FREQ=499 ./script_raytrace.sh         # or sample less often
CALLGRAPH=fp ./script_raytrace.sh            # or cheaper unwinding
```

**Flame graph shows one giant `_PyEval_EvalFrameDefault` block.** `python3-dbg`
is missing, so there are no CPython internal symbols:
`sudo apt install -y python3-dbg`.

**High run-to-run variance.** The pipeline warns when relative stdev exceeds 5 %.
Close other work, confirm the host is idle (a VM cannot control the host's
frequency scaling), and raise `CLEAN_REPS`.

---

## Transferring results back

```bash
# from the host
scp -P 2222 -r student@localhost:~/hwsw-perf-project/results ./results
scp -P 2222 student@localhost:'~/hwsw-perf-project/report_*.txt' .
```

Flame-graph SVGs are interactive — open them in a browser, not an image viewer.
