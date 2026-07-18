# HP LaserJet M1005 MFP driver plan

## Current progress (2026-07-18)

- Phase 1: complete; direct USB/XQX printing and recovery validated physically.
- Phase 2: complete; isolated arm64 encoder and byte-for-byte regression suite.
- Phase 3: complete; PWG Raster and Apple Raster printed correctly and
  identically through the IPP Printer Application on the physical M1005.
- Phase 4: complete; cancellation-aware USB retries, endpoint-stall handling,
  reconnect recovery, and printer power-cycle recovery validated.
- Phase 5: development implementation and live integration complete. Version
  0.5.1 fixes a grayscale threshold defect and is installed at 600 dpi/High;
  physical grayscale revalidation passed. Developer ID signing/notarization
  remain pending. See `PHASE5_RESULTS.md`.
- Phases 6–7: not started.

No ready-to-install, signed, notarized driver was found on GitHub that is verified for HP LaserJet M1005 MFP on macOS Tahoe 26.5. The best code base is usable for building one, but its existing Mac installation method is obsolete.

## 1. Compatible driver for macOS 26.5

### Native driver

No currently supported native driver was found from HP, Apple, or GitHub.

The closest open-source implementation is [[OpenPrinting/foo2zjs](https://github.com/OpenPrinting/foo2zjs)](https://github.com/OpenPrinting/foo2zjs). It includes:

- Explicit HP LaserJet M1005 MFP support.
- The `foo2xqx` encoder for the printer’s proprietary XQX language.
- An [[M1005 PPD](https://github.com/OpenPrinting/foo2zjs/tree/main-fixes/PPD)](https://github.com/OpenPrinting/foo2zjs/tree/main-fixes/PPD).
- USB printing code.

However, it is not a macOS 26.5 driver package:

- It does not provide a signed/notarized Tahoe installer.
- Its [[Mac installation instructions](https://github.com/OpenPrinting/foo2zjs/blob/main-fixes/INSTALL.osx)](https://github.com/OpenPrinting/foo2zjs/blob/main-fixes/INSTALL.osx) refer to old Xcode/MacPorts versions and even suggest disabling System Integrity Protection. Do not follow that advice on a current Mac.
- The old PPD/filter design is deprecated.
- I found no evidence of successful M1005 testing on Tahoe 26.5.

### Practical workaround available now

The most dependable solution is a small Linux print server:

1. Connect the M1005 by USB to a Raspberry Pi or other Linux machine.
2. Install `foo2zjs/foo2xqx` and CUPS.
3. Advertise the queue as an AirPrint/IPP printer.
4. Add it normally on the Mac using AirPrint.

This moves the legacy driver off the Mac. macOS then sees a modern driverless printer. OpenPrinting confirms that `foo2xqx` supports this model, while Apple confirms that AirPrint requires no locally installed driver. [[OpenPrinting M1005 entry](https://www.openprinting.org/printer/HP/HP-LaserJet_M1005_MFP/)](https://www.openprinting.org/printer/HP/HP-LaserJet_M1005_MFP/), [[Apple AirPrint documentation](https://support.apple.com/en-us/102895)](https://support.apple.com/en-us/102895).

Scanning would be separate. SANE has an `hpljm1005` backend that explicitly supports the scanner, but it would need a Linux frontend or a new macOS scanning application. [[SANE backend documentation](https://www.sane-project.org/man/sane.7.html)](https://www.sane-project.org/man/sane.7.html).

## 2. Last compatible Mac driver

There are three different compatibility cutoffs:

| Capability | Last known software/support | Last relevant macOS |
|---|---|---|
| Printing driver | HP LaserJet M1005 driver **1.6.1**, contained in Apple/HP Printer Software **5.1.1** | The package metadata excludes macOS 12 and newer, making **macOS 11 Big Sur** its implied ceiling |
| Original product compatibility | HP’s model specifications list Mac OS X 10.3–10.7 | **Mac OS X 10.7 Lion** |
| HP-supported scanning | Original HP scanning software | **Mac OS X 10.6 Snow Leopard** |

Apple’s current HP 5.1.1 page explicitly says it is “not compatible with macOS v12 and newer.” [[Apple HP 5.1.1 package](https://support.apple.com/en-us/106385)](https://support.apple.com/en-us/106385). HP identifies version 5.1 as the package for older printers on OS X 10.9 and later, and version 3.1 for 10.7–10.8. [[HP older-printer installation instructions](https://support.hp.com/in-en/document/ish_6684703-6684754-16)](https://support.hp.com/in-en/document/ish_6684703-6684754-16).

There are reports of driver 1.6.1 printing under Catalina and sometimes Big Sur, but installation on Big Sur was inconsistent. Therefore:

- **Last nominal printing ceiling:** macOS 11 Big Sur.
- **Last strongly evidenced normal printing environment:** macOS 10.15 Catalina.
- **Last full print-and-scan environment:** Mac OS X 10.6 Snow Leopard.
- **No compatibility from macOS 12 through macOS 26.5.**

The HP 5.1.1 package’s 2024 publication date does not mean the M1005 driver was newly developed in 2024; it is a republished legacy driver collection.

## 3. Current macOS printer-driver standards

The preferred modern architecture is driverless printing, not a traditional PPD/filter driver.

A current solution should use:

- IPP/2.0 or later for job and capability communication.
- IPP Everywhere 1.1 behavior.
- DNS-SD/mDNS for automatic discovery.
- PWG Raster as the required raster format.
- Apple Raster where useful for Apple clients.
- PDF optionally.
- An IPP “Printer Application” to translate modern jobs for a legacy printer.

PWG lists IPP/2.0, DNS-SD, and PWG Raster as core IPP Everywhere requirements. [[PWG IPP Everywhere specification](https://www.pwg.org/ipp/everywhere.html)](https://www.pwg.org/ipp/everywhere.html).

Traditional CUPS drivers, filters, backends, and PPD files are deprecated. OpenPrinting recommends Printer Applications that emulate an IPP printer and translate output for older hardware. [[Printer Applications and Printer Drivers](https://openprinting.github.io/cups/drivers.html)](https://openprinting.github.io/cups/drivers.html).

For distribution on current macOS, the software should also be:

- Native Apple Silicon, preferably universal `arm64` and `x86_64` if required.
- Developer ID signed.
- Built with Hardened Runtime.
- Notarized and stapled.
- Entirely user-space—no kernel extension.
- Installable without disabling SIP or changing protected system directories.

Apple requires signed executables and Hardened Runtime for normal notarization. [[Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

USB can initially be handled through PAPPL/libusb. If direct USB access proves unreliable because macOS claims the printer interface, USBDriverKit is the modern Apple framework for a user-space USB system extension. It requires additional Apple entitlements and should be used only if necessary. [[USBDriverKit](https://developer.apple.com/documentation/usbdriverkit)](https://developer.apple.com/documentation/usbdriverkit).

## 4. Development plan for macOS 26.5

The recommended design is:

```text
Mac print dialog
      ↓
AirPrint / IPP Everywhere
      ↓
Local M1005 Printer Application
      ↓
PWG/Apple Raster conversion
      ↓
foo2xqx XQX encoder
      ↓
USB
      ↓
HP LaserJet M1005 MFP
```

### Phase 1 — Hardware and protocol validation

- Confirm USB vendor/product ID and endpoint layout on the actual printer.
- Capture a known-working Linux print job.
- Verify that current `foo2xqx` output prints correctly.
- Test A4, Letter, multi-page jobs, 300/600 dpi, copies and cancellation.
- Determine whether the printer requires any initialization or firmware upload after power-on.

Deliverable: a small command-line program that sends an XQX test page from macOS 26.5.

### Phase 2 — Port the encoder

- Build the relevant `foo2xqx`, JBIG and raster-processing code with current Clang.
- Remove obsolete shell, Foomatic and PPD dependencies.
- Add automated tests comparing generated XQX with known-good output.
- Build at least for Apple Silicon.

`foo2zjs` is GPL-licensed, so a distributed derivative must comply with its source-code and license requirements. A permissively licensed product would require a clean-room XQX reimplementation.

### Phase 3 — Implement the Printer Application

Use [[PAPPL](https://github.com/michaelrsweet/pappl)](https://github.com/michaelrsweet/pappl), which:

- Runs on macOS.
- Implements an embedded IPP Everywhere service.
- Supports PWG Raster and Apple Raster.
- Supports USB through libusb.
- Is specifically intended to replace old printer drivers.

The service should advertise only capabilities the M1005 really supports:

- Monochrome.
- 600×600 dpi and any validated lower resolution.
- A4, Letter and tested media sizes.
- Single-sided printing.
- Manual duplex instructions rather than false automatic duplex support.

### Phase 4 — Reliable USB transport

Status: **complete on 2026-07-18.** See `PHASE4_RESULTS.md` for the automated,
live IPP, and physical recovery record.

- Detect USB connect, disconnect and power cycles.
- Handle endpoint stalls, partial writes and printer-busy states.
- Make job cancellation stop both rasterization and USB transmission.
- If libusb cannot reliably claim the interface, build a minimal USBDriverKit extension and request Apple’s entitlement.

### Phase 5 — macOS integration and packaging

Status: **development and physical pass on 2026-07-18; release credentials
pending.** The native app, embedded LaunchAgent, local IPP queue, logs,
uninstall flow, and unsigned installer are implemented and tested. Version
0.5.1 restores the full halftone matrices, defaults both printer layers to 600
dpi/High, and printed the original grayscale photo correctly. See
`PHASE5_RESULTS.md`.

Create a small Mac setup application that:

- Detects the M1005.
- Starts and manages the local IPP service.
- Adds the IPP queue.
- Shows printer/offline/error status.
- Provides logs and uninstall support.

Package it with:

- Developer ID signatures.
- Hardened Runtime.
- Notarization.
- A signed installer or app-managed helper.
- No SIP changes and no modifications inside `/System`.

### Phase 6 — Scanner support, separately

Printing and scanning should be separate milestones.

For scanning:

- Port or reuse SANE’s `hpljm1005` backend.
- Provide a native SwiftUI scanning interface.
- Support resolution, page area, grayscale/color and PDF/image export.
- Do not initially depend on Image Capture integration; a standalone scanning application is substantially easier to maintain.

### Phase 7 — Compatibility testing

Test at minimum:

- macOS Tahoe 26.5 on actual target Mac hardware.
- Clean installation with no old HP software.
- Reboot, sleep/wake and USB reconnection.
- Printer power-off during a job.
- Large PDFs and multi-page documents.
- Gatekeeper installation on a different Mac.
- Upgrade and complete uninstall.

A realistic estimate is approximately **6–10 weeks for a polished print-only driver** for one experienced C/macOS developer with the printer available. Scanning could add another **3–6 weeks**.

The shortest successful route is to first prove the same architecture on Linux/Raspberry Pi. Once `foo2xqx` reliably drives the printer through an IPP service, porting and packaging that service for macOS becomes a controlled engineering task rather than protocol reverse engineering.
