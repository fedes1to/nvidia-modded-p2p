# nvidia-modded-p2p

Port of [barlink-pcie](https://github.com/efschu/barlink-pcie) to a current
open-kernel-modules tag (615.78.08): GPU↔GPU transfers through the existing
BAR1 aperture, with no system-RAM staging in the data path. For modded cards
(2080 Ti 22 GB, 3080 20 GB, 4080 32 GB, 4090 48 GB) and uneven rigs.
**No ReBAR resizing, no firmware flashing, no proprietary blobs** — patches
and scripts only.

All credit for the mechanism goes upstream: barlink-pcie by **efschu**. This
repository adds the port to 615.78.08, the platform fixes, and the
card-aware installer.

## Related, not included

[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) — the GA102/GA104
SM issue-rate (`SS0`/`SS1`) unlock that this project used to install — is
maintained in its own repository and updated regularly there, so this
repository no longer bundles it. Install it from upstream directly if you
want the compute unlock on top of the patched driver.

## Requirements

- Linux with NVIDIA **open** kernel modules
- Kernel headers, `gcc`, `git`, `patch`, `make`
- Two or more NVIDIA GPUs — the installer selects what applies
- systemd, OpenRC or dinit
- Root (to load kernel modules)
- ~2 GB disk

The installer pins the NVIDIA source tag it was written against; see
[docs/DETAILS.md](docs/DETAILS.md).

## Install

```bash
git clone https://git.fedesito.me/fedes1to/nvidia-modded-p2p
cd nvidia-modded-p2p
sudo bash scripts/install.sh     # detect the cards, install what applies
sudo bash scripts/verify.sh      # must print: PASS
```

The installer targets modded cards (2080 Ti 22 GB, 3080 20 GB, 4080 32 GB,
4090 48 GB) and, after a confirmation prompt, uneven rigs (mixed models or
memory). A uniform stock rig is left on the stock driver; force the install
with `--with-modded-p2p`.

Non-interactive runs take the default (no) for the prompts; `--yes` accepts
them. The install persists across reboots. After a kernel upgrade, re-run
`install.sh`.

Undo everything:

```bash
sudo bash scripts/revert.sh
```

A reboot also returns to the stock driver.

## modded-p2p

Consumer cards normally cannot address each other's memory: peer access is
disabled and BAR1 is much smaller than the framebuffer, so collectives go
through system RAM. barlink-pcie exposes a direct path inside that existing
BAR1 aperture — a dma-buf on the target card, attached by a small holder
module, which the source card writes into over PCIe. BAR1 is not resized and
the firmware is not touched.

Measured at the collective level against NCCL: gains from roughly 80 KiB
message size upward, a small loss below the direct path's minimum transfer
size. Figures and conditions: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

Requirements, the pinned driver tag, the load keys and the recovery steps:
[docs/DETAILS.md](docs/DETAILS.md).

## Docs

- [docs/DETAILS.md](docs/DETAILS.md) — modded-p2p mechanism, patch ports, troubleshooting, FAQ
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measurements, conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
