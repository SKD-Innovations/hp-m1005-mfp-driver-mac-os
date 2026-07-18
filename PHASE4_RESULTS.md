# Phase 4 reliable USB transport results

Date: 2026-07-18  
Target: macOS 26.5.2, Apple Silicon (`arm64`)  
Printer: HP LaserJet M1005 MFP, USB `03f0:3b17`

## Result

**PASS.** The Printer Application now handles short USB writes, transient
timeouts, endpoint stalls, cancellation during encoding or transmission,
device removal, reconnection, and printer power cycles. The physical M1005
recovered automatically after both cable reconnection and power-on.

The Phase 4 development executable is:

- `build/m1005-printer-app` version `0.4.0`

## USB write state machine

`src/m1005_usb_io.c` isolates USB transfer policy from PAPPL and libusb so it
can be tested deterministically. It:

- limits each bulk transfer to 16 KiB, providing frequent cancellation points
- preserves progress from short writes and timeouts that transferred data
- clears the bulk-out endpoint halt after `LIBUSB_ERROR_PIPE`
- retries timeout, interrupted, busy, I/O, and pipe errors up to five times
  with a 100 ms delay in the live transport
- uses a one-second transfer timeout so cancellation and removal are detected
  promptly
- fails immediately when libusb reports that the device is gone
- requests a full device reset after cancellation or an unrecoverable
  transmission error
- reports any bytes transmitted before cancellation or failure

The Printer Application writes directly through this state machine instead of
PAPPL's buffered device writer. This allows cancellation and partial progress
to be observed at the actual USB boundary.

## End-to-end cancellation

Cancellation is checked at each stage:

1. PAPPL stops raster callbacks when the IPP job is cancelled.
2. The isolated `foo2xqx` child process is polled and terminated if the job is
   cancelled while encoding.
3. USB cancellation is checked between 16 KiB transfers. If any bytes were
   sent, the device is reset when the transport closes.

The live IPP tests used separate Create-Job, Send-Document, and Cancel-Job
operations. An eight-page, 31 MB PWG Raster stress job was cancelled during
the raster/encoder path. A raw 4 MB XQX stress job was then cancelled after
USB transmission began; the writer returned `LIBUSB_ERROR_INTERRUPTED`,
requested a reset, and PAPPL recorded the job as cancelled. A normal job sent
afterwards completed and printed, proving post-cancellation recovery.

## Disconnect, reconnect, and power-cycle record

The live Printer Application ran on local test port 8767.

- With the USB cable removed, device discovery returned no M1005 and the next
  job remained queued instead of failing or being lost.
- One sheet emerged just after cable removal. The server log showed that this
  was the preceding recovery job, whose complete 2,717-byte XQX stream had
  already been accepted by the printer before removal.
- After reconnection, the queued job was automatically encoded, transmitted,
  completed in IPP, and physically printed one sheet.
- With the printer powered off while still connected by cable, discovery again
  returned no M1005 and another submitted job remained queued.
- As soon as the printer was powered on and initialized, that job was
  automatically encoded, transmitted, marked complete, and physically printed
  one sheet.

No service restart, queue recreation, Mac reboot, or manual job retry was
required for either recovery.

## Automated verification

`make test` passes the Phase 2 encoder regression, Phase 3 raster bridge and
capability checks, job-control fixture validation, and the new Phase 4 USB
state-machine suite.

The state-machine tests cover:

- multiple partial writes
- a timeout that also reports partial progress
- an endpoint stall followed by successful halt clearing
- retry exhaustion and reset request
- cancellation after one 16 KiB transfer
- immediate device removal

The USB tests also pass with Clang AddressSanitizer and UndefinedBehaviorSanitizer.

## DriverKit decision and remaining boundary

libusb consistently claimed the printer-class interface and recovered after
cancellation, cable removal, reconnection, and a full printer power cycle.
A USBDriverKit system extension is therefore **not required** for this printer
and target Mac.

Endpoint-stall recovery is deterministic automated coverage; a physical stall
was not deliberately forced on the printer. Paper-empty, cover-open, sleep/wake,
Mac reboot, and power-off or unplugging in the middle of a large physical page
remain broader compatibility/fault-injection tests for Phase 7. Phase 5 can
now proceed with macOS service integration and packaging.
