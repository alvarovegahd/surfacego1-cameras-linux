# Surface Go (gen 1) cameras on Linux

Getting the **front and rear cameras working on the Microsoft Surface Go (1st gen)**
under Linux — both the 5 MP front (`ov5693`) and 8 MP rear (`ov8865`) cameras, live,
in browsers and video-call apps.

> **TL;DR** — On a modern [linux-surface](https://github.com/linux-surface/linux-surface)
> kernel the cameras are **not a kernel problem any more**. The drivers, sensors, power
> and the Intel IPU3 pipeline all work. The only gap is *integration*: the IPU3 emits
> **raw Bayer** that must be processed by **libcamera**, and your desktop needs to be
> told to use libcamera (via PipeWire) instead of expecting a plain `/dev/video` webcam.
> This repo automates that. Run [`./setup.sh`](setup.sh) and reboot.

---

## Why the cameras "don't work" out of the box

The Surface Go cameras hang off the **Intel IPU3** image-processing unit, not a normal
UVC webcam. Two things follow from that:

1. The sensors (`ov5693`, `ov8865`, plus the `ov7251` IR cam) are described in **ACPI**
   and wired over **I²C/CSI-2**, powered by an `INT3472`/`TPS68470` PMIC. They need the
   right kernel drivers *and* ACPI bridging. Older kernels lacked this — hence the old
   "deep kernel issue" reputation. **Recent linux-surface kernels have it all.**
2. The IPU3 CIO2 only produces **raw 10-bit Bayer** frames. A normal app (Cheese, a
   browser, Zoom, OBS) opens `/dev/video*` expecting YUV/MJPEG and gets nothing usable.
   You need **libcamera** to drive the CIO2 → ImgU pipeline and do debayer + 3A, and a
   bridge so ordinary apps can consume it.

So the fix is **not** patching the kernel — it's wiring libcamera into the desktop.

## Is my system ready? (kernel side)

You need a linux-surface kernel where the sensors are bound. Check:

```bash
# sensors present as subdevices?
media-ctl -d /dev/media0 -p | grep -E 'ov5693|ov8865|ov7251'
# expect lines like:  entity NN: ov5693 4-0036 ... subtype Sensor
ls /dev/v4l-subdev*           # several nodes = sensors bound

# the relevant modules should be loaded:
lsmod | grep -E 'ipu3_cio2|ipu3_imgu|ov5693|ov8865|int3472|tps68470|ipu_bridge'

# and libcamera should enumerate two cameras:
cam --list
#   1: Internal back camera  (\_SB_.PCI0.LNK0)
#   2: Internal front camera (\_SB_.PCI0.LNK1)
```

If `cam --list` shows the two cameras, **the hard part is already done** — go to the fix.
If not, you likely need a newer linux-surface kernel first.

## The fix

```bash
git clone https://github.com/alvarovegahd/surfacego1-cameras-linux
cd surfacego1-cameras-linux
./setup.sh        # user-space only, no sudo, nothing destructive
# log out / reboot once so the PipeWire camera + env changes take hold everywhere
```

`setup.sh` does five small things, all in your home dir:

| Step | What | Where |
|---|---|---|
| Tuning aliases | Copy libcamera's `uncalibrated.yaml` to `ov5693.yaml` / `ov8865.yaml` / `ov7251.yaml` so libcamera stops erroring on missing per-sensor tuning | `~/.local/share/libcamera/ipa/ipu3/` |
| Env | Point libcamera at those files | `~/.config/environment.d/90-libcamera.conf` |
| PipeWire re-scan | A user service that restarts WirePlumber after the sensors are up, so the cameras reliably appear in PipeWire | `~/.config/systemd/user/wireplumber-camera-fix.service` |
| Helper | `snap-photo.sh` capture tool | `~/.local/bin/` |
| Apply now | `set-environment` + restart WirePlumber, then verify | — |

### Why the PipeWire re-scan service is needed

WirePlumber's libcamera monitor enumerates cameras **once at startup**. On the Surface Go
the IPU3 sensors finish probing slightly *after* WirePlumber starts, so at login it finds
no cameras and never looks again — you get only the useless raw `ipu3-imgu`/`CIO2` V4L2
nodes. A single `systemctl --user restart wireplumber` after boot fixes it; the bundled
service automates that. (You can always run that restart by hand to confirm.)

## Using the cameras

Once `wpctl status` lists `ov5693` / `ov8865` under **Video → `[libcamera]`**:

```bash
qcam                     # GUI live preview of the front camera
# rear camera live in qcam needs a forced native resolution (see rear-camera note below):
qcam -c '\_SB_.PCI0.LNK0' -s role=viewfinder,width=1632,height=1224
snap-photo.sh both       # save a still from each camera to ~/Downloads
snap-photo.sh front --video   # ~5 s mp4 clip from the front camera
libcamerify cheese       # run any V4L2-only app through a libcamera shim
libcamerify zoom         # …same for Zoom, OBS (or use OBS's PipeWire source), etc.
```

**Browsers & video calls:** Firefox and Chromium reach libcamera cameras through the
**PipeWire camera portal** automatically once the nodes exist — no flags needed on recent
versions. Pick "Internal front camera" in the site's camera dropdown.

### Zoom / Teams / OBS and other V4L2-only apps

These apps **don't** speak libcamera or the PipeWire camera portal, so the IPU3 cameras
never show up in them. (And `libcamerify` doesn't help on Ubuntu 24.04 — its
`v4l2-compat.so` shim isn't built.)

> ### ⚠ Easiest path: use the **web client** instead
> Zoom, Teams, Meet and friends all have a browser version, and **Firefox/Chromium reach
> the front camera through the PipeWire portal that already works** (see above). Joining a
> call at `app.zoom.us` / `teams.microsoft.com` in the browser needs **zero** extra setup
> and avoids the v4l2loopback mess below. (Snap Firefox may need `snap connect
> firefox:camera` once.) **Recommended.**

If you specifically need a **native** V4L2-only app, the only option is a **virtual webcam**:
a `v4l2loopback` device fed by the front camera. **Heads-up — this currently does NOT work
on kernel ≥ 6.18:** Ubuntu's v4l2loopback 0.12.7 builds (with the fix script below) but then
**kernel-oopses at runtime in `vidioc_reqbufs`** — the device appears but delivers no frames,
because 6.18 reworked the V4L2 buffer framework. You'd need a newer v4l2loopback that
supports 6.18. The setup below is kept for older kernels / future fixed packages.

One-time setup (needs sudo):

```bash
sudo apt install -y v4l2loopback-dkms
```

> **Kernel ≥ 6.18 note:** Ubuntu's v4l2loopback 0.12.7 **fails to build** on Linux 6.18
> (the `v4l2_fh_add()`/`v4l2_fh_del()` API gained a `struct file *` argument). If the apt
> install above ends with a DKMS build error, run the bundled fix and it'll patch, rebuild,
> and load the module:
> ```bash
> sudo ./fix-v4l2loopback-kernel6.18.sh
> ```

```bash
# load now (if not already loaded by the fix script):
sudo modprobe v4l2loopback video_nr=20 card_label="Surface Front Camera" exclusive_caps=1
# (optional) auto-load at boot:
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
printf 'options v4l2loopback video_nr=20 card_label="Surface Front Camera" exclusive_caps=1\n' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
```

Then start the bridge and open the app:

```bash
front-camera-loopback.sh        # runs until Ctrl-C; pipes front cam -> /dev/video20
# now open Zoom and pick "Surface Front Camera"
```

Run it **on demand** (start before a call, Ctrl-C after) so the camera isn't held the rest
of the time. For an always-on bridge instead, enable the bundled user service:

```bash
systemctl --user enable --now front-camera-loopback.service
```

`exclusive_caps=1` is important — without it Chromium-based apps (incl. Zoom) won't detect
the loopback as a capture device. Only the **front** camera is bridged (the rear stalls;
see below).

### `snap-photo.sh`

```
snap-photo.sh                 # photo from BOTH cameras  -> ~/Downloads
snap-photo.sh front           # front only
snap-photo.sh back ~/Pictures # back camera, custom dir
snap-photo.sh front --video   # short mp4 clip
```

It captures a burst with `cam` (raw NV12) and keeps the last frame — the first frames are
dark while auto-exposure settles, so single-frame grabs come out black.

## Known issue: the REAR camera stalls in low-res modes

The **front camera (`ov5693`) works everywhere** — Cheese, browsers, video calls.

The **rear camera (`ov8865`) only streams in its native/binned resolutions.** In the
small modes that most apps default to (640×480, 1280×720) it delivers **exactly one frame
and then stalls** — so Cheese/Zoom show a frozen first frame ("stuck"). The kernel log
shows the cause, a CSI-2 payload-length mismatch (the sensor sends ~one extra line of
embedded data the driver doesn't account for):

```
ipu3-cio2 0000:00:14.3: payload length is 2585088, received 2588672
```

Measured on this device:

| Requested size | Rear camera |
|---|---|
| 640×480 | ❌ 1 frame then stall |
| 1280×720 | ❌ 1 frame then stall |
| **1632×1224** (→ aligned 1600×1224) | ✅ streams |
| **3264×2448** (native) | ✅ streams |

This is a **kernel sensor-driver quirk, below libcamera** — it can't be fixed from the
userspace layer this repo sets up. Workarounds:

- **Stills/clips:** use `snap-photo.sh back`, which drives the rear camera at its working
  native mode.
- **Live preview that works:** `qcam` (libcamera's own GUI viewer) lets you force the
  resolution, so the rear camera streams fine there:
  ```bash
  qcam -c '\_SB_.PCI0.LNK0' -s role=viewfinder,width=1632,height=1224
  ```
  (libcamera adjusts this to 1600×1224 — the IPU3 aligns width down. The front camera is
  just `qcam` with no args, or `-c '\_SB_.PCI0.LNK1'`.)
- **Other apps (Cheese, Zoom, browsers):** they auto-pick 640×480/1280×720 with no way to
  override, so the rear camera **stalls/freezes** in them — it's effectively front-only there.
- **Real fix:** a kernel patch to the `ov8865` driver (account for the embedded-data
  lines / fix the small-mode frame size). Track it with linux-surface; not done here.

## Other caveats

- **Image quality is "functional, not pretty."** The IPU3 libcamera IPA ships **no
  calibrated tuning for any sensor** — upstream only has `uncalibrated.yaml`, and there are
  no `ov5693`/`ov8865` tuning files to download (we checked). Color/auto-exposure are
  therefore uncalibrated: usable for video calls and monitoring, a bit flat/over-exposed on
  color. The aliases here only silence the "file not found" error; they don't add calibration.
- **No Windows Hello / IR face login.** The `ov7251` IR camera enumerates but isn't wired
  up here.
- Autofocus (`dw9719` VCM) is present on the rear camera but not exposed as a nice control.

## How it was diagnosed (for the curious)

- `lspci` shows the IPU3: `8086:1919` Imaging Unit (`00:05.0`) + `8086:9d32` CSI-2 host
  (`00:14.3`).
- `media-ctl` shows all three sensors **bound and linked** into `ipu3-csi2` → `ipu3-cio2`,
  with `dw9719` (focus) and `INT3472`/`tps68470` (power/clocks) loaded.
- `cam --capture` pulls real frames at ~28 fps; the front node reports
  `ip3G` (10-bit Bayer IPU3-packed) — confirming raw output that needs libcamera.
- `wpctl status` initially exposed only raw `ipu3-imgu`/`CIO2` V4L2 devices and **no
  Sources**; restarting WirePlumber made `ov5693`/`ov8865` `[libcamera]` nodes appear.

## Tested environment

| | |
|---|---|
| Device | Surface Go (1st gen), BIOS `1.0.38` |
| OS | Ubuntu 24.04.4 LTS |
| Kernel | `6.18.7-surface-1` (linux-surface) |
| libcamera | 0.2.0 |
| PipeWire / WirePlumber | 1.0.5 / 0.4.17 |
| Sensors | `ov5693` front (i²c 4-0036), `ov8865` rear (i²c 2-0010), `ov7251` IR (i²c 3-0060), `dw9719` VCM |

Newer distros ship WirePlumber 0.5 (different config format) — the env + tuning steps are
identical; the re-scan service may be unnecessary if your WirePlumber already rescans.

## Credits

Built on the work of the [linux-surface](https://github.com/linux-surface/linux-surface)
project (kernel + ACPI) and [libcamera](https://libcamera.org/) (IPU3 pipeline).
This repo is just the desktop-integration glue + docs.

## License

MIT — see [LICENSE](LICENSE).
