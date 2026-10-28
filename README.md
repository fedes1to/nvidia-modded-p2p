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
and the card-aware installer.

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

## Docs

- [docs/DETAILS.md](docs/DETAILS.md) — how it works, what the patches change, troubleshooting, FAQ
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measured numbers and conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
