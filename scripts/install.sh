#!/usr/bin/env bash
# nvidia-modded-p2p installer -- one command, persists across reboots.
#
#   sudo bash scripts/install.sh                 # detect the cards, then install
#   sudo bash scripts/install.sh --with-torch    # ... plus the optional Python checks
#   sudo bash scripts/install.sh --with-modded-p2p  # force the barlink driver install
#   sudo bash scripts/install.sh --no-modded-p2p    # never install the barlink driver
#   sudo bash scripts/install.sh --yes           # accept the interactive prompts
#   sudo bash scripts/install.sh --no-activate   # install for the next boot only
#
# What it does:
#   1. builds NVIDIA's open kernel modules at the pinned tag with the barlink
#      patch, plus barlink-pcie (with the platform fixes) and dmabuf_holder
#   2. installs the patched modules into
#      /lib/modules/<kernel>/updates/barlink-p2p/  (depmod prefers it over the
#      packaged module, so every boot from now on loads the patched one)
#   3. writes the load keys and runtime environment
#   4. swaps the running driver now (screen freezes for a few seconds)
#
# It targets modded cards (2080 Ti 22 GB, 3080 20 GB, 4080 32 GB, 4090 48 GB)
# and, after a confirmation prompt, uneven rigs (mixed models or memory).
# A uniform stock rig is left on the stock driver; force the install with
# --with-modded-p2p.
#
# Undo everything with:  sudo bash scripts/revert.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DRIVER_TAG="${BARLINK_DRIVER_TAG:-615.78.08}"
BASE="${BARLINK_BASE:-/opt/nvidia-modded-p2p}"
BUILD="$BASE/build"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
OVR="/lib/modules/$KVER/updates/barlink-p2p"
WITH_TORCH=0
WITH_MODDED_P2P=auto
ASSUME_YES=0
ACTIVATE=1
UPSTREAM_DRIVER="https://github.com/NVIDIA/open-gpu-kernel-modules"
UPSTREAM_BARLINK="https://github.com/efschu/barlink-pcie"

for arg in "$@"; do
  case "$arg" in
    --with-torch)       WITH_TORCH=1 ;;
    --with-modded-p2p)  WITH_MODDED_P2P=1 ;;
    --no-modded-p2p)    WITH_MODDED_P2P=0 ;;
    --yes|-y)           ASSUME_YES=1 ;;
    --no-activate)      ACTIVATE=0 ;;
    --driver-tag=*)     DRIVER_TAG="${arg#*=}" ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
confirm() {  # $1 = prompt; succeeds on yes
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then
    echo "  $1 [no TTY: no; pass --yes to accept]" >&2
    return 1
  fi
  local a
  read -r -p "  $1 [y/N] " a || return 1
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

step "prerequisites"
for c in git patch make gcc python3 depmod insmod modprobe; do
  command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
done
[ -e "$KDIR" ] || die "kernel headers missing at $KDIR (install your distro's linux-headers package)"
echo "kernel $(uname -r) | compiler $(gcc -dumpversion)"

# ---------------------------------------------------------------------------
# GPU inventory: model + memory per card (nvidia-smi), sysfs count as fallback.
# Modded-card memory thresholds: stock -> modded
#   2080 Ti 11 -> 22 GB | RTX 3080 10 -> 20 GB | RTX 4080 16 -> 32 GB | RTX 4090 24 -> 48 GB
# ---------------------------------------------------------------------------
GPU_ROWS=""
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_ROWS="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | sed 's/, /|/' || true)"
fi

GPU_COUNT=0
GPU_MODDED=0
GPU_SIGS=()
if [ -n "$GPU_ROWS" ]; then
  while IFS='|' read -r name mem; do
    [ -n "$name" ] || continue
    GPU_COUNT=$((GPU_COUNT + 1))
    sig="$name|$mem"
    seen=0
    for s in "${GPU_SIGS[@]:-}"; do
      if [ "$s" = "$sig" ]; then seen=1; break; fi
    done
    [ "$seen" = 1 ] || GPU_SIGS+=("$sig")
    case "$mem" in ''|*[!0-9]*) mem=0 ;; esac   # nvidia-smi can report [N/A]
    case "$name" in
      *"2080 Ti"*) if [ "${mem:-0}" -ge 20000 ]; then GPU_MODDED=$((GPU_MODDED + 1)); fi ;;
      *"RTX 3080"*) if [ "${mem:-0}" -ge 19000 ]; then GPU_MODDED=$((GPU_MODDED + 1)); fi ;;
      *"RTX 4080"*) if [ "${mem:-0}" -ge 30000 ]; then GPU_MODDED=$((GPU_MODDED + 1)); fi ;;
      *"RTX 4090"*) if [ "${mem:-0}" -ge 45000 ]; then GPU_MODDED=$((GPU_MODDED + 1)); fi ;;
    esac
  done <<< "$GPU_ROWS"
  printf 'NVIDIA GPUs: %s\n' "$GPU_COUNT"
  printf '%s\n' "$GPU_ROWS" | while IFS='|' read -r name mem; do printf '  %-42s %s MiB\n' "$name" "$mem"; done
else
  # no nvidia-smi: count PCI functions only (model/memory unknown)
  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    case "$cls:$ven" in 0x030000:0x10de|0x030200:0x10de) GPU_COUNT=$((GPU_COUNT + 1)) ;; esac
  done
  echo "NVIDIA GPUs: $GPU_COUNT (nvidia-smi unavailable: model/memory unknown)"
fi
UNEVEN=0
if [ "${#GPU_SIGS[@]}" -gt 1 ]; then UNEVEN=1; fi

# ---------------------------------------------------------------------------
# component selection
# ---------------------------------------------------------------------------
# modded-p2p (barlink) targets modded cards and, after confirmation, uneven
# rigs. A uniform stock rig is left on the stock driver unless forced.
if [ "$WITH_MODDED_P2P" = auto ]; then
  if [ "$GPU_COUNT" -eq 0 ]; then
    warn "no NVIDIA GPU detected: modded-p2p skipped (force with --with-modded-p2p)"
    WITH_MODDED_P2P=0
  elif [ "$GPU_MODDED" -eq "$GPU_COUNT" ]; then
    WITH_MODDED_P2P=1
    echo "all $GPU_COUNT GPU(s) are modded models: modded-p2p will be installed"
  elif [ "$UNEVEN" = 1 ]; then
    echo "uneven GPU set (${#GPU_SIGS[@]} distinct models)"
    if confirm "install modded-p2p (barlink) on this uneven rig?"; then
      WITH_MODDED_P2P=1
    else
      WITH_MODDED_P2P=0
    fi
  else
    echo "uniform stock rig: modded-p2p is not targeted at these cards (force with --with-modded-p2p)"
    WITH_MODDED_P2P=0
  fi
fi

if [ "$WITH_MODDED_P2P" = 1 ]; then

mkdir -p "$BASE" "$BUILD"
DRIVER_DIR="$BUILD/driver-$DRIVER_TAG"
BARLINK_DIR="$BUILD/barlink-pcie"

step "driver source @ $DRIVER_TAG"
if [ ! -d "$DRIVER_DIR" ]; then
  git clone --depth 1 --branch "$DRIVER_TAG" "$UPSTREAM_DRIVER" "$DRIVER_DIR"
else
  echo "present: $DRIVER_DIR"
fi

step "driver patch"
cd "$DRIVER_DIR"
if git diff --quiet && git diff --cached --quiet; then
  patch -p1 --fuzz=0 --batch -i "$ROOT/patches/BARLINK_PCIE-$DRIVER_TAG.patch" \
    || die "patch did not apply -- this driver tag is not supported by the shipped patch"
else
  echo "tree already patched -- skipping"
fi

step "building kernel modules (about a minute)"
make modules -j"$(nproc)"

M=$(strings kernel-open/nvidia.ko | grep -c BARLINK_PCIE || true)
echo "BARLINK_PCIE markers: $M (expected 37)"
[ "$M" = "37" ] || warn "unexpected marker count -- barlink preflight will not report 'full patch'"

step "barlink-pcie library + platform fixes"
if [ ! -d "$BARLINK_DIR" ]; then
  git clone --depth 1 "$UPSTREAM_BARLINK" "$BARLINK_DIR"
else
  echo "present: $BARLINK_DIR"
fi
cd "$BARLINK_DIR"
# Apply each patch independently and idempotently. A single combined patch
# cannot be re-checked after a partial application, and skipping on any dirty
# tree left installations missing later hunks (the inference_mode fix shipped
# after the hold-BDF hunk was already applied).
apply_patch() {
  patch_file=$1
  name=$(basename "$patch_file")
  if git apply --check "$patch_file" >/dev/null 2>&1; then
    git apply "$patch_file" || die "$name did not apply -- upstream changed; report the diff"
    echo "applied: $name"
  elif git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "already applied: $name"
  else
    die "$name did not apply and is not already applied -- upstream changed; report the diff"
  fi
}
apply_patch "$ROOT/patches/barlink-platform-fixes.patch"
apply_patch "$ROOT/patches/barlink-inference-mode.patch"
apply_patch "$ROOT/patches/barlink-capture-gate.patch"
apply_patch "$ROOT/patches/barlink-baton-marker-state.patch"

step "dmabuf_holder module"
make -C "$KDIR" M="$BARLINK_DIR/dmabuf_holder" modules

step "installing the patched modules for every boot"
mkdir -p "$OVR"
for m in nvidia nvidia-uvm nvidia-drm nvidia-modeset nvidia-peermem; do
  f="$DRIVER_DIR/kernel-open/$m.ko"
  [ -f "$f" ] && install -m 644 "$f" "$OVR/$m.ko"
done
install -m 644 "$BARLINK_DIR/dmabuf_holder/dmabuf_holder.ko" "$OVR/dmabuf_holder.ko"
depmod -a "$KVER"
RESOLVED="$(modinfo -n nvidia 2>/dev/null || true)"
[ "$RESOLVED" = "$OVR/nvidia.ko" ] || warn "modinfo resolves nvidia to '$RESOLVED' (expected $OVR/nvidia.ko)"

step "load keys + runtime environment"
cat > /etc/modprobe.d/barlink-p2p.conf <<'EOF'
# nvidia-modded-p2p: keys consumed by the patched module. Unknown keys are
# ignored by the stock module, so a kernel update cannot make the machine
# unbootable.
options nvidia NVreg_RegistryDwords="BarlinkPeerBar1=1;RMPcieP2PType=1"
EOF
# load the holder module at boot, whatever the init is
if [ -d /etc/dinit.d ]; then
  cat > /etc/dinit.d/barlink-holder <<'EOF'
type = scripted
command = /usr/bin/modprobe dmabuf_holder
restart = false
EOF
  ln -sf ../barlink-holder /etc/dinit.d/boot.d/barlink-holder
else
  mkdir -p /etc/modules-load.d 2>/dev/null || true
  [ -d /etc/modules-load.d ] && echo dmabuf_holder > /etc/modules-load.d/barlink-p2p.conf
fi
if command -v rc-update >/dev/null 2>&1; then          # OpenRC / Gentoo
  touch /etc/conf.d/modules
  grep -q dmabuf_holder /etc/conf.d/modules || echo 'modules="$modules dmabuf_holder"' >> /etc/conf.d/modules
  rc-update add modules boot >/dev/null 2>&1 || true
fi
if [ -f /etc/modules ] && ! grep -q '^dmabuf_holder' /etc/modules; then
  echo dmabuf_holder >> /etc/modules                    # inits that read it directly
fi

# a non-GPU PCI device the dma-bufs are attached as (615-class drivers refuse
# a GPU as the attaching device)
HOLD_BDF=""
for d in /sys/bus/pci/devices/*; do
  cls="$(cat "$d/class" 2>/dev/null)" || continue
  ven="$(cat "$d/vendor" 2>/dev/null)" || continue
  [ "$ven" = "0x10de" ] && continue
  case "$cls" in 0x03*) continue ;; esac
  case "$cls" in 0x020000|0x010802) HOLD_BDF="$(basename "$d")"; break ;; esac
done
if [ -z "$HOLD_BDF" ]; then
  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    [ "$ven" = "0x10de" ] && continue
    case "$cls" in 0x03*) continue ;; esac
    HOLD_BDF="$(basename "$d")"; break
  done
fi
echo "$HOLD_BDF" > /etc/barlink-p2p.hold-bdf
echo "attach device: ${HOLD_BDF:-<none found>}"

cat > /etc/profile.d/barlink-p2p.sh <<EOF
# nvidia-modded-p2p runtime environment (barlink-pcie direct path)
export BARLINK_BUILD_DIR="$BUILD"
export BARLINK_BAR1_NV_SOURCE="$BUILD/driver-$DRIVER_TAG"
export BARLINK_NVIDIA_KO="$BUILD/driver-$DRIVER_TAG/kernel-open/nvidia.ko"
[ -r /etc/barlink-p2p.hold-bdf ] && export BARLINK_BAR1_HOLD_BDF="\$(cat /etc/barlink-p2p.hold-bdf)"
[ -z "\${CUDA_HOME:-}" ] && [ -d /opt/cuda ] && export CUDA_HOME=/opt/cuda
true
EOF
chmod 644 /etc/profile.d/barlink-p2p.sh

cat > "$BASE/env" <<EOF
BASE=$BASE
BUILD=$BUILD
DRIVER_TAG=$DRIVER_TAG
DRIVER_DIR=$DRIVER_DIR
BARLINK_DIR=$BARLINK_DIR
OVERRIDE_DIR=$OVR
HOLD_BDF=$HOLD_BDF
EOF

if [ "$WITH_TORCH" = 1 ]; then
  step "Python environment for the optional checks (torch)"
  [ -x "$BARLINK_DIR/.venv/bin/python" ] || python3 -m venv "$BARLINK_DIR/.venv"
  "$BARLINK_DIR/.venv/bin/pip" install -q -e "$BARLINK_DIR"
  "$BARLINK_DIR/.venv/bin/pip" install -q nvidia-ml-py numpy
fi

# ---------------------------------------------------------------------------
# live activation
# ---------------------------------------------------------------------------
if [ "$ACTIVATE" = 1 ]; then
  step "activating now (display freezes for a few seconds)"
  stopped=""
  svc_active() {   # $1 = service name -> echoes the init that has it running
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$1" 2>/dev/null; then echo systemd; return; fi
    if command -v dinitctl  >/dev/null 2>&1 && dinitctl status "$1" 2>/dev/null | grep -q started; then echo dinit; return; fi
    if command -v rc-service >/dev/null 2>&1 && rc-service "$1" status >/dev/null 2>&1; then echo openrc; return; fi
  }
  svc_stop() {     # $1 = service name
    local who; who="$(svc_active "$1")"; [ -n "$who" ] || return 1
    case "$who" in
      systemd) systemctl stop "$1" ;;
      dinit)   dinitctl stop "$1" >/dev/null ;;
      openrc)  rc-service "$1" stop ;;
    esac
    stopped="$stopped $who:$1"
  }
  for s in gdm sddm lightdm greetd ly ly@tty1 display-manager nvidia-persistenced; do svc_stop "$s" || true; done
  pkill -TERM -f 'Hyprland|sway|kwin_wayland|gnome-shell|Xorg|startplasma|plasmashell' 2>/dev/null || true
  pkill -TERM -f nvidia-persistenced 2>/dev/null || true
  sleep 2

  for m in dmabuf_holder nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    rmmod "$m" 2>/dev/null && echo "rmmod $m ok"
  done
  sleep 1
  if lsmod | grep -qE '^nvidia'; then
    lsmod | grep nvidia
    die "modules still loaded -- a process holds /dev/nvidia*; close it and re-run, or reboot"
  fi

  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    case "$cls:$ven" in
      0x030000:0x10de|0x030200:0x10de) echo 1 > "$d/reset" 2>/dev/null || true ;;
    esac
  done
  sleep 2

  modprobe nvidia || { dmesg | tail -15; die "nvidia load failed"; }
  modprobe nvidia-uvm 2>/dev/null || warn "nvidia-uvm failed"
  modprobe dmabuf_holder 2>/dev/null || warn "dmabuf_holder failed"
  sleep 2

  loaded="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
  built="$(modinfo "$DRIVER_DIR/kernel-open/nvidia.ko" | awk '/^srcversion:/{print $2}')"
  echo "srcversion loaded=$loaded built=$built"
  [ "$loaded" = "$built" ] && echo "patched module is loaded" || warn "srcversion mismatch"
  grep -i '^RegistryDwords' /proc/driver/nvidia/params 2>/dev/null || warn "RegistryDwords empty"
  dmesg | grep BARLINK_PCIE | tail -4 || true

  # restart what was stopped
  for s in $stopped; do
    case "$s" in
      systemd:*) systemctl start "${s#systemd:}" 2>/dev/null || true ;;
      dinit:*)   dinitctl start "${s#dinit:}" 2>/dev/null || true ;;
      openrc:*)  rc-service "${s#openrc:}" start 2>/dev/null || true ;;
    esac
  done
fi

else
  step "modded-p2p"
  echo "skipped: not a modded or confirmed uneven rig (force with --with-modded-p2p)"
fi

if [ "$WITH_MODDED_P2P" = 1 ]; then
  step "installed"
  cat <<EOF
Persistent: every boot now loads the patched module from
  $OVR
  (stock module stays at /lib/modules/$KVER/kernel/..., untouched)
Verify now:     sudo bash $ROOT/scripts/verify.sh
Revert to stock: sudo bash $ROOT/scripts/revert.sh   (a reboot also does it)
After a kernel  upgrade: re-run this installer for the new kernel; until then
the machine boots the stock driver (safe).
EOF
else
  step "installed (modded-p2p skipped)"
  echo "  The barlink driver was not installed. Re-run with --with-modded-p2p to install it."
fi
