#!/usr/bin/env bash
# front-camera-loopback.sh — feed the Surface Go FRONT camera into a v4l2loopback
# device so V4L2-only apps (Zoom, Teams, OBS, Skype…) can use it.
#
# Why: those apps don't speak libcamera or the PipeWire camera portal, so they
# never see the IPU3 cameras directly. This pipes the front camera through
# GStreamer into a virtual /dev/video* that they CAN see.
#
# Prereq (one time, needs sudo — see README):
#   sudo apt install -y v4l2loopback-dkms
#   sudo modprobe v4l2loopback video_nr=20 card_label="Surface Front Camera" exclusive_caps=1
#
# Usage:  front-camera-loopback.sh [/dev/videoN]   (auto-detects if omitted)
set -euo pipefail
export LIBCAMERA_LOG_LEVELS="*:ERROR"
export LIBCAMERA_IPA_CONFIG_PATH="${LIBCAMERA_IPA_CONFIG_PATH:-$HOME/.local/share/libcamera/ipa}"

# Surface Go gen1 front camera (ov5693) ACPI path; gst-launch needs the backslash doubled.
FRONT_NAME='\\_SB_.PCI0.LNK1'
WIDTH=1280; HEIGHT=720; FPS=30

# Find the v4l2loopback sink device (the one labelled for us), unless given.
DEV="${1:-}"
if [ -z "$DEV" ]; then
  for v in /sys/devices/virtual/video4linux/video*; do
    [ -e "$v/name" ] || continue
    if grep -qiE "Surface Front|Dummy|loopback" "$v/name" 2>/dev/null; then
      DEV="/dev/$(basename "$v")"; break
    fi
  done
fi
if [ -z "$DEV" ] || [ ! -e "$DEV" ]; then
  echo "No v4l2loopback device found. Load it first:" >&2
  echo "  sudo modprobe v4l2loopback video_nr=20 card_label=\"Surface Front Camera\" exclusive_caps=1" >&2
  exit 1
fi

echo "Bridging front camera -> $DEV  (${WIDTH}x${HEIGHT}@${FPS}, YUY2). Ctrl-C to stop."
exec gst-launch-1.0 -e \
  libcamerasrc camera-name="$FRONT_NAME" \
  ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
  ! videoconvert ! "video/x-raw,format=YUY2" \
  ! v4l2sink device="$DEV" sync=false
