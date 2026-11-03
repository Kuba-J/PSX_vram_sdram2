# PSX MiSTer — GPU VRAM on SDRAM2

This is a modified version of the [PSX_MiSTer_core](https://github.com/MiSTer-devel/PSX_MiSTer) that moves the GPU's 1 MB of VRAM from DDR3 to a dedicated second SDRAM module.

The goal is to give the GPU its own memory, separate from the rest of the system, while preserving the original PlayStation's GPU timing and behavior.

All other core features, including game compatibility, BIOS support, memory cards, CD image formats, controllers, and save states, remain unchanged.

For general setup and usage instructions, please refer to the official [README](https://github.com/MiSTer-devel/PSX_MiSTer/blob/main/README.md).

This README covers only the differences specific to the SDRAM2 version.

## Hardware requirements

* MiSTer with the usual SDRAM module for main RAM.
* **A second SDRAM module of any size is required.**

VRAM has no DDR3 path here, so the second module is not optional.

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
