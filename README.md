# HP LaserJet M1005 MFP on macOS 26

This workspace contains the Mac-only Phase 1 hardware and XQX protocol
validation tools for an HP LaserJet M1005 MFP printer application.

## Confirmed hardware

- USB vendor ID: `0x03f0` (Hewlett-Packard)
- USB product ID: `0x3b17` (HP LaserJet M1005)
- Interface 0: vendor-specific, expected scanner/control interface
- Interface 1: USB printer class, bidirectional protocol

The encoder source is downloaded from OpenPrinting's `foo2zjs` repository at
commit `3805c5d14b694167fb1e281fa6eff50312dd4cfa` on the `main-fixes` branch.
It is GPL-2.0-or-later; distributing a derivative requires GPL compliance.

## Build and validation

```sh
make all
make validate
make probe
make claim
```

`make validate` creates a deterministic A4, 600 dpi PBM test page, converts it
to XQX, decodes its structure, and verifies required document fields. It does
not communicate with the printer.

`make probe` reads USB descriptors without claiming an interface. `make claim`
temporarily claims only the printer-class interface, reads its port status, and
releases it without sending print data.

The physical print command is intentionally not a Make target:

```sh
build/m1005-usb --send artifacts/m1005-a4-600.xqx
```

Run it only after reviewing the decoded XQX stream and confirming that A4 paper
is loaded.

## Validated initial capabilities

- A4, monochrome, simplex
- 600 x 600 dpi
- Multiple pages in one XQX document
- Printer-side copies

Do not pass 300 x 300 directly to this version of `foo2xqx`. The encoder maps
horizontal resolution to bits per pixel in units of 600 and produces invalid
zero-valued video metadata at 300 dpi. The initial Printer Application will
advertise 600 x 600 dpi only.
