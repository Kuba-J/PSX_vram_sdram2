# PlayStation for MiSTer — SDRAM2 VRAM edition

A fork of [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) in which the
GPU keeps its 1 MB of VRAM in a **second SDRAM module** instead of DDR3.

Everything else about the core — games, BIOS handling, memory cards, CD formats,
controllers, savestates — works the same as upstream, so the
[upstream README](https://github.com/MiSTer-devel/PSX_MiSTer/blob/main/README.md)
remains the manual for day-to-day use. This page only covers what is specific to
this edition.

## Hardware requirements

* MiSTer with the usual SDRAM module for main RAM.
* **A second SDRAM module of any size is required.**

VRAM has no DDR3 path here, so the second module is not optional. A build without
it stops in the fitter instead of producing a core that cannot display anything.

## Installing

Copy the `.rbf` to `/media/fat/_Console/` on the SD card, same as any other core.

## Building

Quartus 17.0.2. There is a single project revision:

```
PSX_DualSDRAM.qpf
```

## Differences from the upstream core

* **VRAM lives in SDRAM2.** The GPU reads and writes it through its own
  controller on the second module, independently of DDR3 traffic.
* **GPU logic runs at the PlayStation's own rate** — 53.693 MHz for NTSC and
  53.203 MHz for PAL — rather than at the core's internal clock.
* **SPU RAM is always DDR3.** The SDRAM2 slot belongs to the GPU, so the
  `SPU RAM select` option is gone from the OSD.
* **The HDMI debug framebuffer is unavailable.** It reads VRAM out of DDR3, which
  no longer holds it, so the `DDR3 Framebuffer`, `DDR3 FB Color` and `VRAMViewer`
  entries on the debug page have no effect. Normal video output over HDMI and
  analog is unaffected.
* **The 480i to 480p hack and the GPU Slowdown option have been removed.**

## License

GPL-2.0, inherited from the upstream core. See [LICENSE](LICENSE).
