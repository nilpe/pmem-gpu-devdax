# GPU-usable PMem via `cudaHostRegister()` on DEVDAX

How much persistent memory (PMem, exposed as a `devdax` character device) can an
NVIDIA GPU actually pin and DMA to via `cudaHostRegister()`, and what limits it?

This repo reproduces a staged measurement: starting from the stock driver and
adding the kernel/userspace patches from [`PATCH.md`](PATCH.md) one at a time,
probing the maximum registrable size at each stage, and finally **breaking the
hard ceiling** with a split-registration trick.

## Test environment

| | |
|---|---|
| Node | `nova01` |
| GPU | Tesla V100-PCIE-32GB (compute capability 7.0 / Volta `sm_70`) |
| NVIDIA driver | `nvidia-srv` **580.159.03** (Ubuntu `nvidia-kernel-source-580-server`) |
| Kernel | `6.8.0-106-generic` (Ubuntu/Canonical build) |
| PMem | `/dev/dax0.1` = **737.25 GiB**, `devdax` mode, 2 MiB aligned |
| CUDA toolkit | 13.0 |

> `/dev/dax0.0` on this node is in `system-ram` mode (~20 GiB) — the devdax target is `dax0.1`.

## Results

```
 0  stock (no patch)                    203.47 GiB  27.6%
 1  +sysinfo hook (userspace)           207.16 GiB  28.1%
 2  +nv-dma get_num_physpages           512.00 GiB  69.4%
 3  +os-mlock page-array vmalloc        512.00 GiB  69.4%
 4  +nv.c pte-array vmalloc (ALL)       512.00 GiB  69.4%
 5  split: 2x<512G + ALL patches        737.25 GiB 100.0%   <-- DMA-verified
```

(see [`results/SUMMARY.txt`](results/SUMMARY.txt) and `results/stage*.slide.txt`)

## Key findings

1. **The 512 GiB ceiling is `INT_MAX`, not a tunable.** A single
   `cudaHostRegister()` makes `nv.c:nvos_create_alloc()` allocate a
   `nvidia_pte_t[]` page table (16 B/page). At 512 GiB that array is exactly
   **2 GiB = 2³¹**, so the allocation fails (`kvmalloc`/`__vmalloc` reject
   `size > INT_MAX`). The measured OK/FAIL boundary matches the 2³¹ crossing to
   the page. `PATCH.md` patch 4 (`kvzalloc`→`__vmalloc`) does **not** lift it —
   it's a size cap, not a GFP-flag problem.
2. **The os-mlock patch (patch 3) is a no-op on this node** — stages 2, 3 and 4
   are all 512.00 GiB; the binding allocation is the one in `nv.c`.
3. **Split registration breaks the ceiling.** `dax_pin_split.cu` `mmap`s the
   whole device as one contiguous VA, then registers it in **N chunks each
   < 512 GiB** (so each chunk's page table stays < 2 GiB). The full **737.25 GiB**
   becomes contiguous and GPU-DMA accessible — verified at the start, the chunk
   boundary, and the end (write + read).
4. **THP gotcha.** Faulting a `devdax` (2 MiB) mapping needs THP. If the process
   inherits `PR_SET_THP_DISABLE` (some launchers set it), the first access
   SIGBUSes — easy to misread as "PMem is broken." The probes call
   `prctl(PR_SET_THP_DISABLE, 0)` at startup. See
   [`diagnostics/thp_sigbus_probe.cu`](diagnostics/thp_sigbus_probe.cu).
5. **CUDA 13 dropped Volta (`sm_70`).** Compute kernels won't run on the V100
   ("no kernel image available"), but the **DMA path (`cudaMemcpy`) works**, so
   data is verified via DMA. See
   [`diagnostics/kernel_arch_probe.cu`](diagnostics/kernel_arch_probe.cu) and
   [`diagnostics/dma_path_probe.cu`](diagnostics/dma_path_probe.cu).

## Repo layout

```
patches/    nvidia-srv-580.159.03-devdax.patch   combined patches 2-4 (kernel glue)
src/        dax_pin_bisect.cu   max-registrable-size probe (bisection)
            dax_pin_split.cu    split registration + DMA verification
            sysinfo_hook.c      patch 1: LD_PRELOAD totalram hook (userspace)
            pmem_register_slide.c, stage_slide.c   result panels
scripts/    apply_patch.sh, rebuild_reload.sh, run_stage.sh, summary.sh
diagnostics/ thp_sigbus_probe.cu, kernel_arch_probe.cu, dma_path_probe.cu
results/    per-stage panels + raw bisection/split logs
PATCH.md    original patch guide (the 4 limits and fixes)
```

## Reproduce

> ⚠️ This rebuilds and reloads the **system-wide NVIDIA driver**. Do it on a node
> you own with no other GPU users. Keep a way to restore the stock driver
> (re-`apt install --reinstall nvidia-kernel-source-580-server`, or back up the
> three `.c` files first). Adjust paths/versions to your node.

```bash
# 0. Build the tools (needs nvcc + cc)
make

# 1. Baseline (Stage 0): no patches, no hook
./dax_pin_bisect /dev/dax0.1

# 1b. Stage 1: userspace totalram hook only
LD_PRELOAD=$PWD/libsysinfo_hook.so ./dax_pin_bisect /dev/dax0.1

# 2. Apply kernel patches, rebuild DKMS, reload modules (Stages 2-4 share this)
sudo ./scripts/apply_patch.sh /usr/src/nvidia-srv-580.159.03/nvidia
sudo ./scripts/rebuild_reload.sh
LD_PRELOAD=$PWD/libsysinfo_hook.so ./dax_pin_bisect /dev/dax0.1   # -> 512 GiB

# 3. Break the 512 GiB wall: split into <512 GiB chunks of one mmap
LD_PRELOAD=$PWD/libsysinfo_hook.so ./dax_pin_split /dev/dax0.1 384  # -> 737.25 GiB, DMA verified
```

`scripts/run_stage.sh` wraps a probe run into a labelled result panel;
`scripts/summary.sh` renders the combined progression bar.

## Caveat on the numbers

Stages 0–4 measure whether `cudaHostRegister()` **succeeds** (the pin/page-table
path). Stage 5 additionally **verifies real GPU↔PMem DMA** (write + read) across
the whole span. The `512 → 737 GiB` jump is the headline: the documented patches
top out at the `INT_MAX` page-table ceiling, and splitting one contiguous mapping
into sub-`INT_MAX` registrations gets you the full device.
