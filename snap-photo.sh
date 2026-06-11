#!/usr/bin/env bash
# snap-photo.sh — grab a still (or short clip) from the Surface Go cameras via libcamera.
#
# Usage:
#   snap-photo.sh                 # photo from BOTH cameras -> ~/Downloads
#   snap-photo.sh front           # photo from front camera only
#   snap-photo.sh back            # photo from back camera only
#   snap-photo.sh both ~/Pictures # photo from both, custom output dir
#   snap-photo.sh front --video   # ~6 s mp4 clip from the front camera
#
# Notes on the Surface Go cameras:
#  * They only work through libcamera; this uses `cam` (raw NV12) + ffmpeg.
#  * The first frames are dark while auto-exposure settles, so we grab a burst
#    and keep the last frame.
#  * The REAR camera (ov8865) stalls after one frame in low-res modes (a kernel
#    CSI-2 payload-length bug), so we drive it at its native binned mode, which
#    streams reliably. See the README for details.
#  * The IPU3 aligns the output width down to a multiple of 64 (e.g. 1632 -> 1600),
#    so we derive the true geometry from the captured frame size rather than
#    trusting the requested size.

set -euo pipefail
export LIBCAMERA_LOG_LEVELS="*:ERROR"
export LIBCAMERA_IPA_CONFIG_PATH="${LIBCAMERA_IPA_CONFIG_PATH:-$HOME/.local/share/libcamera/ipa}"

WHICH="${1:-both}"; shift || true
VIDEO=0; OUTDIR="$HOME/Downloads"
for a in "$@"; do case "$a" in --video) VIDEO=1;; *) OUTDIR="$a";; esac; done
mkdir -p "$OUTDIR"

# cam camera indices: 1 = back, 2 = front  (see `cam --list`)
# Per-camera REQUESTED capture size. Front 720p is fine; the rear must use its
# native binned mode (~1632x1224) or it stalls.
declare -A IDX=( [front]=2 [back]=1 )
declare -A REQW=( [front]=1280 [back]=1632 )
declare -A REQH=( [front]=720  [back]=1224 )

targets=(); case "$WHICH" in
  front) targets=(front);; back) targets=(back);; both) targets=(front back);;
  *) echo "usage: snap-photo.sh [front|back|both] [outdir] [--video]"; exit 1;;
esac

stamp() { date +%Y%m%d_%H%M%S; }

# derive true geometry from an NV12 file size, given the requested width
geom() { # $1=file $2=reqw  -> echoes "WxH"
  local fsize y w h; fsize=$(stat -c%s "$1"); y=$(( fsize * 2 / 3 ))
  w=$(( ($2 / 64) * 64 )); [ "$w" -eq 0 ] && w=$2
  if [ $(( y % w )) -ne 0 ]; then w=$2; fi
  h=$(( y / w )); echo "${w}x${h}"
}

grab() {
  local name="$1" idx="${IDX[$1]}" rw="${REQW[$1]}" rh="${REQH[$1]}" tmp; tmp="$(mktemp -d)"
  local nframes; nframes=$([ "$VIDEO" = 1 ] && echo 150 || echo 20)
  echo "capturing $name camera (${rw}x${rh} request, $nframes frames)..."
  timeout 45 cam -c"$idx" --capture="$nframes" --stream "pixelformat=NV12,width=${rw},height=${rh}" \
      --file="$tmp/f_#.raw" >/dev/null 2>&1 || true
  local frames=( "$tmp"/f_*.raw )
  if [ ! -e "${frames[0]}" ]; then echo "  ! no frames from $name camera"; rm -rf "$tmp"; return 1; fi
  if [ "${#frames[@]}" -lt 3 ]; then
    echo "  ! $name camera stalled after ${#frames[@]} frame(s) — known rear-camera kernel bug if this is 'back'"
  fi
  local sz; sz=$(geom "${frames[-1]}" "$rw")
  local out
  if [ "$VIDEO" = 1 ]; then
    out="$OUTDIR/surface_${name}_$(stamp).mp4"
    cat "$tmp"/f_*.raw | ffmpeg -y -hide_banner -loglevel error \
        -f rawvideo -pix_fmt nv12 -s "$sz" -framerate 25 -i - \
        -vf "format=yuv420p" -movflags +faststart "$out"
  else
    out="$OUTDIR/surface_${name}_$(stamp).png"
    ffmpeg -y -hide_banner -loglevel error -f rawvideo -pix_fmt nv12 -s "$sz" \
        -i "${frames[-1]}" -frames:v 1 "$out"
  fi
  rm -rf "$tmp"; echo "  -> $out  (${sz})"
}

for t in "${targets[@]}"; do grab "$t" || true; done
