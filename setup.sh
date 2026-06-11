#!/usr/bin/env bash
# setup.sh — make the Surface Go (gen 1) cameras usable under Linux.
#
# What this does (all in user space, no sudo, nothing destructive):
#   1. Sanity-checks that the kernel already sees the IPU3 sensors.
#   2. Installs the snap-photo.sh helper to ~/.local/bin.
#   3. Installs uncalibrated IPU3 tuning aliases (ov5693/ov8865/ov7251) so
#      libcamera stops erroring on missing per-sensor tuning.
#   4. Points libcamera at them via ~/.config/environment.d (persistent).
#   5. Installs+enables a user service that bounces WirePlumber after boot so
#      the cameras reliably show up in PipeWire (browsers, video calls).
#   6. Applies everything to the running session and verifies.
#
# Run from the repo root:  ./setup.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }

say "1/6  Checking the kernel sees the IPU3 sensors…"
if ! ls /dev/v4l-subdev0 >/dev/null 2>&1; then
  warn "No /dev/v4l-subdev* — the camera sensors aren't bound."
  warn "You need a linux-surface kernel (https://github.com/linux-surface/linux-surface)."
  warn "Verify with:  media-ctl -d /dev/media0 -p | grep -E 'ov5693|ov8865'"
  exit 1
fi
echo "    OK: $(ls /dev/v4l-subdev* | wc -l) subdev nodes present."

say "2/6  Installing helper scripts → ~/.local/bin"
mkdir -p "$HOME/.local/bin"
install -m 0755 "$REPO/snap-photo.sh" "$HOME/.local/bin/snap-photo.sh"
install -m 0755 "$REPO/front-camera-loopback.sh" "$HOME/.local/bin/front-camera-loopback.sh"

say "3/6  Installing IPU3 tuning aliases → ~/.local/share/libcamera/ipa/ipu3"
mkdir -p "$HOME/.local/share/libcamera/ipa/ipu3"
install -m 0644 "$REPO"/ipa/ipu3/*.yaml "$HOME/.local/share/libcamera/ipa/ipu3/"

say "4/6  Pointing libcamera at them (~/.config/environment.d)"
mkdir -p "$HOME/.config/environment.d"
install -m 0644 "$REPO/config/90-libcamera.conf" "$HOME/.config/environment.d/90-libcamera.conf"
systemctl --user set-environment "LIBCAMERA_IPA_CONFIG_PATH=$HOME/.local/share/libcamera/ipa" 2>/dev/null || true

say "5/6  Installing the WirePlumber re-scan user service"
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$REPO/systemd/wireplumber-camera-fix.service" "$HOME/.config/systemd/user/wireplumber-camera-fix.service"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable wireplumber-camera-fix.service 2>/dev/null || true

say "6/6  Applying now (restarting WirePlumber) and verifying…"
systemctl --user restart wireplumber 2>/dev/null || true
sleep 4
if wpctl status 2>/dev/null | grep -qiE "ov5693|ov8865"; then
  echo
  say "SUCCESS — cameras are live in PipeWire:"
  wpctl status 2>/dev/null | sed -n '/Video/,/Sinks/p' | grep -iE "ov5693|ov8865" || true
  echo
  echo "Try:   qcam                 # GUI preview"
  echo "       snap-photo.sh both   # save stills to ~/Downloads"
  echo "       libcamerify cheese   # use in a V4L2 app"
  echo "Browsers/Zoom see them via the PipeWire camera portal."
else
  warn "Cameras not visible yet. Check 'cam --list' works, then re-run, or reboot."
fi
