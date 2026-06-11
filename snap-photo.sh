#!/usr/bin/env bash
# snap-photo.sh — grab a still (or short clip) from the Surface Go cameras via libcamera.
#
# Usage:
#   snap-photo.sh                 # photo from BOTH cameras -> ~/Downloads
#   snap-photo.sh front           # photo from front camera only
#   snap-photo.sh back            # photo from back camera only
#   snap-photo.sh both ~/Pictures # photo from both, custom output dir
#   snap-photo.sh front --video   # ~5 s mp4 clip from the front camera
#
# The Surface Go IPU3 cameras only work through libcamera; this uses the `cam`
# tool (raw NV12 frames) + ffmpeg to assemble a viewable file. The first frames
# are dark while auto-exposure settles, so we grab a burst and keep the last.

set -euo pipefail
export LIBCAMERA_LOG_LEVELS="*:ERROR"
export LIBCAMERA_IPA_CONFIG_PATH="${LIBCAMERA_IPA_CONFIG_PATH:-$HOME/.local/share/libcamera/ipa}"

WHICH="${1:-both}"; shift || true
VIDEO=0; OUTDIR="$HOME/Downloads"
for a in "$@"; do case "$a" in --video) VIDEO=1;; *) OUTDIR="$a";; esac; done
mkdir -p "$OUTDIR"

W=1280; H=720; FMT=nv12
# cam camera indices: 1 = back, 2 = front  (see `cam --list`)
declare -A IDX=( [front]=2 [back]=1 )
targets=(); case "$WHICH" in front) targets=(front);; back) targets=(back);; both) targets=(front back);; *) echo "usage: snap-photo.sh [front|back|both] [outdir] [--video]"; exit 1;; esac

stamp() { date +%Y%m%d_%H%M%S; }   # fine: not inside the sandboxed workflow runtime

grab() {
  local name="$1" idx="${IDX[$1]}" tmp; tmp="$(mktemp -d)"
  local nframes=$([ "$VIDEO" = 1 ] && echo 150 || echo 20)
  echo "capturing $name camera ($nframes frames)..."
  timeout 40 cam -c"$idx" --capture="$nframes" --stream "pixelformat=${FMT},width=${W},height=${H}" \
      --file="$tmp/f_#.raw" >/dev/null 2>&1 || true
  local frames=( "$tmp"/f_*.raw ); [ -e "${frames[0]}" ] || { echo "  ! no frames from $name camera"; rm -rf "$tmp"; return 1; }
  local out
  if [ "$VIDEO" = 1 ]; then
    out="$OUTDIR/surface_${name}_$(stamp).mp4"
    cat "$tmp"/f_*.raw | ffmpeg -y -hide_banner -loglevel error \
        -f rawvideo -pix_fmt "$FMT" -s "${W}x${H}" -framerate 25 -i - \
        -vf "format=yuv420p" -movflags +faststart "$out"
  else
    out="$OUTDIR/surface_${name}_$(stamp).png"
    ffmpeg -y -hide_banner -loglevel error -f rawvideo -pix_fmt "$FMT" -s "${W}x${H}" \
        -i "${frames[-1]}" -frames:v 1 "$out"
  fi
  rm -rf "$tmp"; echo "  -> $out"
}

for t in "${targets[@]}"; do grab "$t" || true; done
