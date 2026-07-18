# Phase 1 validation results

Date: 2026-07-18  
Target: macOS 26.5.2 (build 25F84), Apple Silicon (`arm64`)  
Printer: HP LaserJet M1005 MFP

## Hardware discovery

- USB vendor/product: `03f0:3b17`
- USB: 2.0 high speed, one configuration, two interfaces
- Interface 0: vendor-specific (`ff/ff/ff`), endpoints `0x01`, `0x81`, `0x83`
- Interface 1: printer class (`07/01/02`), bulk OUT `0x02`, bulk IN `0x82`
- Printer interface kernel driver: inactive
- Printer interface can be claimed and released through libusb in normal
  macOS user space; DriverKit is not required for the validated transport path
- USB printer status before and after the job: `0x18` (selected, paper present,
  no error)

## Baseline print test: PASS

- Media: A4
- Raster input: PBM, 4960 x 7016 at 600 x 600 dpi
- Validated image area after model margins: 4784 x 6848
- XQX encoder: OpenPrinting `foo2xqx`, built natively for arm64
- Upstream commit: `3805c5d14b694167fb1e281fa6eff50312dd4cfa`
- XQX stream size: 2717 bytes
- PBM SHA-256: `78cf7ee5621ae856624b67dd81ed2b6bc880040531248652a158815fd2b29918`
- XQX SHA-256: `b8ba42999dd7b8e4ac2d284cb3d5a2772a4f593f3403123e36ff5040da1e7ece`
- USB transfer result: all 2717 bytes accepted on endpoint `0x02`
- Physical result reported by user: **everything printed exactly and perfectly**

This proves the Phase 1 end-to-end baseline:

```text
deterministic macOS raster -> foo2xqx/JBIG -> XQX -> libusb -> M1005
```

## Remaining Phase 1 checks

- Cancellation
- Power cycle and USB reconnect

## Multi-page print test: PASS

- Media/resolution: A4 at 600 x 600 dpi
- XQX structure: one document with two `XQX_START_PAGE` records
- USB transfer: all 5030 bytes accepted on endpoint `0x02`
- Physical result: exactly two correct pages, distinctly labeled `PAGE 1 OF 2`
  and `PAGE 2 OF 2`, printed in order

## Printer-side copies test: PASS

- XQX structure: one page record with `XQXI_COPIES = 2`
- USB transfer: all 2717 bytes accepted on endpoint `0x02`
- Physical result: exactly two identical, correct `PHASE 1 TEST` sheets
- Implementation consequence: copies can be delegated to the M1005; raster pages
  do not need to be duplicated by the Mac application

## Resolution policy: PASS WITH 600-DPI-ONLY CAPABILITY

- Native 600 x 600 dpi: physically validated with correct output
- The model database declares a 600 x 600 dpi mechanism
- The historical PPD exposes 600 x 600 and an enhanced 1200 x 600 mode, not
  native 300 x 300
- A local-only 300 x 300 encoder diagnostic produced invalid XQX metadata
  (`VIDEO_BPP = 0`, `VIDEO_X = 0`); this stream was not sent to the printer
- Implementation consequence: advertise 600 x 600 dpi only in the initial
  Printer Application. If 300-dpi source content must be accepted, upscale it
  to a 600-dpi raster before encoding.
