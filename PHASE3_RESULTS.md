# Phase 3 Printer Application results

Date: 2026-07-18  
Target: macOS 26.5.2, Apple Silicon (`arm64`)  
Framework: PAPPL 1.4.11

## Result

**PASS.** The Phase 3 Printer Application passes its software, live USB
discovery, IPP, DNS-SD, PWG Raster, Apple Raster, and physical-print checks on
the target HP LaserJet M1005 MFP.

Release executable:

- `build/m1005-printer-app`

## Advertised capabilities

The live Get-Printer-Attributes response was validated with Apple's `ipptool`:

- IPP Everywhere (`ipp-features-supported=ipp-everywhere`)
- `image/pwg-raster` and Apple Raster `image/urf`
- A4 only (`iso_a4_210x297mm`)
- 600 x 600 dpi only
- one-bit device black; monochrome and bi-level print modes
- one-sided only; no automatic or manual duplex claim
- main source, stationery media, face-down output
- printable margins matching the validated XQX clip: 3.73 mm left/right and
  3.56 mm top/bottom

Letter, 300 dpi, color, and duplex are deliberately not advertised.

## Raster and encoder bridge

CUPS represents exact A4 at 600 dpi as 4960 x 7015 pixels. The physically
validated M1005 XQX stream uses a 4960 x 7016 source raster and clips it to a
4864 x 6848 device raster. The bridge adds one white bottom row before calling
the encoder, preserving the proven device geometry.

Each job is staged to a private temporary PBM and encoded by the Phase 2 CLI in
a child process. This isolates the legacy encoder's global state and fatal
error handling from the long-running PAPPL service. The self-test regenerates
the known-good Phase 1 XQX fixture byte-for-byte.

## USB transport

The custom `m1005usb://` PAPPL device scheme:

- matches only USB `03f0:3b17`
- discovers the printer-class interface and bulk endpoints at runtime
- claims only the printer interface
- reports USB printer-class paper, selected, and error status
- sends XQX using libusb bulk transfers
- requests a full USB device reset after cancellation or a transmission error

PAPPL's generic `usb://` path remains visible in device enumeration but is not
auto-added. The live web interface confirmed exactly one configured M1005
queue.

## Test record

`make test` passes:

- Phase 2 byte-for-byte encoder regression
- Phase 3 known-good bridge regression
- capability assertions
- native arm64 executable check
- PWG Raster and Apple Raster test-file generation
- multi-page and copies validation

Live checks passed:

- PAPPL custom USB discovery
- embedded web server on port 8765
- DNS-SD discovery with `ippfind`
- Get-Printer-Attributes with `ipptool`
- one PWG Raster Print-Job (job 1, completed successfully)
- one Apple Raster Print-Job (job 2, completed successfully)
- physical inspection: both pages printed completely, correctly, and
  identically

The PAPPL log received PWG as 4960 x 7015 x 1 black and Apple Raster as
4960 x 7015 x 8 sGray. Both jobs traversed the raster callbacks, XQX encoder,
and custom USB transport; neither used the Phase 1 direct-send utility.

The user inspected both sheets and confirmed the PWG Raster and Apple Raster
results are correct and identical. Phase 3 is therefore complete.

## Current boundary

This is a development Printer Application, not yet a signed/notarized `.app`
or installer. JPEG and PDF input are not enabled in this phase; macOS printing
uses the advertised driverless raster formats. Packaging, launch-at-login,
code signing, notarization, and polished installation belong to later phases.
