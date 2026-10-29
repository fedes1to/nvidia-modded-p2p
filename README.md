# nvidia-modded-p2p

Fast direct GPU-to-GPU communication for modded consumer cards.

This is a port of [barlink-pcie](https://github.com/efschu/barlink-pcie) to
the current NVIDIA open kernel driver (615.78.08). Consumer cards normally
cannot address each other's memory, so multi-GPU work bounces through
system RAM. This project opens a direct path between your GPUs inside the
memory window the cards already have. Multi-GPU transfers run up to 1.5x
faster than the path through system RAM; measured figures and conditions
in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

For modded cards (2080 Ti 22 GB, 3080 20 GB, 4080 32 GB, 4090 48 GB) and
uneven rigs (mixed models or memory). Patches and scripts only: no ReBAR
resizing, no firmware flashing, no proprietary blobs.

All credit for the mechanism goes upstream: barlink-pcie by **efschu**.
This repository adds the port to the current driver, the platform fixes,
and the card-aware installer, plus the vLLM/sglang framework patches.

## Also recommended: gpu-unlock

Pair this with [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock):
it works on all moddable cards and lifts their consumer compute caps. It
never writes the vBIOS and doesn't touch clocks, memory, or the P2P path.
It is maintained in its own repository and updated regularly — install it
directly from there.

## What you need

- Linux with NVIDIA's **open** kernel modules
- Two or more NVIDIA GPUs — the installer figures out what applies to your rig
- Root access

Build tools, supported init systems, disk space, and the driver version
the installer builds against: [docs/DETAILS.md](docs/DETAILS.md).

## Install

```bash
git clone https://git.fedesito.me/fedes1to/nvidia-modded-p2p
cd nvidia-modded-p2p
sudo bash scripts/install.sh     # detects your cards, installs what applies
sudo bash scripts/verify.sh      # must print: PASS
```

The installer targets modded cards (2080 Ti 22 GB, 3080 20 GB, 4080 32 GB,
4090 48 GB) and asks before touching an uneven rig (mixed models or
memory). A uniform stock rig is left alone; pass `--with-modded-p2p` to
force an install. The change persists across reboots; after a kernel
upgrade, re-run `install.sh`.

To undo everything:

```bash
sudo bash scripts/revert.sh
```

A plain reboot also returns you to the stock driver.

## Framework patches (vLLM, sglang)

Both frameworks send tensor-parallel collectives through NCCL, which cannot use
the direct path. `integrations/python/` makes the process group use barlink's
transport instead. vLLM additionally has its own P2P custom all-reduce, which
it disables on more than two PCIe-only GPUs; a patch in `patches/` re-enables
it on a P2P-capable driver.

### Apply the venv patches

One command patches both environments (auto-detects `~/venv-vllm` and
`~/venv-sglang`):

```bash
sudo bash scripts/patch-venvs.sh
sudo bash scripts/patch-venvs.sh ~/venv-vllm ~/venv-sglang   # explicit paths
```

It applies the four barlink patches to the barlink-pcie each venv imports, and
the vLLM custom all-reduce patch to the vLLM venv. `--check` reports without
writing.

### vLLM

vLLM requires a specific PyTorch build, so give it its own environment:

```bash
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e /path/to/nvidia-modded-p2p/integrations/python
sudo bash scripts/patch-venvs.sh ~/venv-vllm
```

Start it (root is required — the driver's P2P path asks for a permission only
root holds; the first start compiles a kernel once):

```bash
. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-vllm/bin/vllm serve <your-model> \
    --tensor-parallel-size 2 \
    --disable-custom-all-reduce
```

Each worker prints one line at startup when the direct path is active:

```
modded_p2p: process group created, resolved backend=barlink
```

Without that line the framework runs its normal path.

Some Python releases are not supported by parts of vLLM's own runtime; if the
first request hangs with `No available shared memory broadcast block`, that
issue exists independently of this project — use a Python version the
framework supports.

### sglang

sglang's binary packages are not published for every Python version; use one
its wheels exist for (see its installation docs).

```bash
python3 -m venv ~/venv-sglang
~/venv-sglang/bin/pip install sglang
~/venv-sglang/bin/pip install -e /path/to/barlink-pcie -e /path/to/nvidia-modded-p2p/integrations/python
sudo bash scripts/patch-venvs.sh ~/venv-sglang

. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-sglang/bin/python -m modded_p2p.sglang_launch \
    --model-path <your-model> --tp 2
```

The launcher is sglang's own server with the transport selection applied
first; without the two variables it behaves like plain sglang.

### Verify the direct path without a framework

```bash
. /etc/profile.d/barlink-p2p.sh
export BARLINK_TRANSPORT=bar1
sudo -E python -m torch.distributed.run --nproc_per_node=2 \
    integrations/python/tests/test_backend_allreduce.py --backend barlink
```

Expected: `all_reduce ...: OK` per rank and a transport state line reading
`requested: bar1, achieved: bar1`.

### Operational notes

- Every GPU process must see the same `BARLINK_*` variables. Mismatched values
  between processes make the job hang rather than print an error.
- Transfers below the transport's minimum size (4 KiB by default) deliberately
  use the host-staged path; larger messages are where the direct path pays.
- Tensor parallelism is covered; pipeline parallelism is not — run PP profiles
  with the plugin off. See [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).
- Native C++ engines (llama.cpp, Strata) have no `torch.distributed` interface
  and are out of scope for these integrations.

Details and limits: [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## Docs

- [docs/DETAILS.md](docs/DETAILS.md) — how it works, what the patches change, troubleshooting, FAQ
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — vLLM/sglang integration and limits
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measured numbers and conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
