#!/usr/bin/env bash
# fix-v4l2loopback-kernel6.18.sh — make Ubuntu's v4l2loopback-dkms build on Linux >= 6.18.
#
# Kernel 6.18 changed the V4L2 API: v4l2_fh_add()/v4l2_fh_del() gained a
# `struct file *` argument. v4l2loopback 0.12.7 (Ubuntu 24.04) still calls them
# the old way, so its DKMS build fails. This patches the two call sites (guarded
# by a kernel-version check so older kernels still build), rebuilds via DKMS, and
# loads the module. Run as root:  sudo ./fix-v4l2loopback-kernel6.18.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root:  sudo $0"; exit 1; }

# locate the installed v4l2loopback dkms source
SRCDIR=$(ls -d /usr/src/v4l2loopback-* 2>/dev/null | sort -V | tail -1)
[ -n "${SRCDIR:-}" ] || { echo "v4l2loopback-dkms not installed (apt install v4l2loopback-dkms)"; exit 1; }
VER=$(basename "$SRCDIR" | sed 's/v4l2loopback-//')
SRC="$SRCDIR/v4l2loopback.c"
echo "Patching v4l2loopback $VER at $SRC"

if grep -q 'v4l2_fh_add(&opener->fh, file)' "$SRC"; then
  echo "  already patched."
else
  cp -n "$SRC" "$SRC.orig"
  sed -i \
   -e 's@^\(\s*\)v4l2_fh_add(&opener->fh);@#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n\1v4l2_fh_add(\&opener->fh, file);\n#else\n\1v4l2_fh_add(\&opener->fh);\n#endif@' \
   -e 's@^\(\s*\)v4l2_fh_del(&opener->fh);@#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n\1v4l2_fh_del(\&opener->fh, file);\n#else\n\1v4l2_fh_del(\&opener->fh);\n#endif@' \
   "$SRC"
  echo "  patched (backup at $SRC.orig)."
fi

echo "Rebuilding via DKMS for $(uname -r)..."
dkms remove -m v4l2loopback -v "$VER" --all >/dev/null 2>&1 || true
dkms install --force -m v4l2loopback -v "$VER"

echo "Clearing any half-configured package state..."
dpkg --configure -a || true

echo "Loading the module..."
modprobe v4l2loopback video_nr=20 card_label="Surface Front Camera" exclusive_caps=1

echo
echo "Done. Loopback device:"
ls -l /dev/video20 2>/dev/null && echo "  -> /dev/video20 ready" || echo "  (check: lsmod | grep v4l2loopback)"
echo
echo "Make it persist across reboots (optional):"
echo "  echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf"
echo "  printf 'options v4l2loopback video_nr=20 card_label=\"Surface Front Camera\" exclusive_caps=1\\n' | sudo tee /etc/modprobe.d/v4l2loopback.conf"
