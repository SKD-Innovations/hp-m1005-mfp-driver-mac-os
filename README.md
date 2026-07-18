# HP LaserJet M1005 MFP on macOS 26

This workspace contains the validated macOS USB transport and the isolated XQX
encoder port for an HP LaserJet M1005 MFP Printer Application.

## Confirmed hardware

- USB vendor ID: `0x03f0` (Hewlett-Packard)
- USB product ID: `0x3b17` (HP LaserJet M1005)
- Interface 0: vendor-specific, expected scanner/control interface
- Interface 1: USB printer class, bidirectional protocol

The production encoder source is vendored under `vendor/foo2xqx` from
OpenPrinting's `foo2zjs` repository at commit
`3805c5d14b694167fb1e281fa6eff50312dd4cfa`. It is GPL-2.0-or-later;
distributing a derivative requires GPL compliance.

## Build and validation

```sh
make all
make validate
make phase2-test
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

## Cancellation and recovery

The M1005 does not acknowledge the standard USB printer-class soft-reset
request. Cancellation therefore stops bulk transmission and calls libusb's
device reset, after which the program rediscovers the device and reopens the
printer interface. This path was physically validated with no partial sheet.

```sh
build/m1005-usb --cancel-after 65536 artifacts/m1005-cancel-stress.xqx
```

See `PHASE1_RESULTS.md` for the complete hardware and physical-test record.

## Phase 2 encoder

The modern standalone build produces:

- `build/m1005-xqx-encode`
- `build/m1005-xqx-decode`
- `build/libjbig-m1005.a`

It builds as C11 with current Clang warnings promoted to errors and has no
Foomatic, PPD, Ghostscript, CUPS-filter, installer, or system-JBIG dependency.
The regression suite requires a byte-for-byte match with the exact XQX stream
that printed correctly during Phase 1.

See `PHASE2_RESULTS.md` for provenance, test coverage, sanitizer results, and
the Phase 3 handoff constraint.
