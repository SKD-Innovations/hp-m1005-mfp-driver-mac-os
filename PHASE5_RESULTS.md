# Phase 5 macOS integration and packaging results

Date: 2026-07-18  
Target: macOS 26.5.2, Apple Silicon (`arm64`)  
Application version: `0.5.2`

## Result

**DEVELOPMENT AND PHYSICAL PASS; RELEASE SIGNING PENDING.** The
native setup app, background service, driverless macOS queue, managed state/log
paths, uninstall flow, self-contained app bundle, and unsigned installer have
passed on the target Mac. A later document with a grayscale portrait exposed a
constant-threshold defect that was not visible in the initial Preview test.
Version 0.5.1 corrected the halftone defect. Version 0.5.2 also removes the
application-visible binary mode so Adobe Acrobat Reader's grayscale checkbox
cannot select or infer bi-level output. The same tonal document was reprinted
from Acrobat both with and without that checkbox, and the user confirmed that
its photo reproduces correctly in both cases. The installed development build
reports:

```text
usb=connected
service=enabled
server=running
queue=installed
```

The final Developer ID signature, installer signature, Apple notarization,
and stapled ticket cannot be produced yet because this Mac has no Developer ID
Application or Developer ID Installer identity installed.

## Installed development integration

- App: `/Applications/M1005Printer.app`
- Queue: `HP_LaserJet_M1005`
- Queue URI:
  `ipp://localhost:8765/ipp/print/HP_LaserJet_M1005_MFP_(USB)`
- Embedded service: `Contents/Resources/m1005-printer-service`
- Embedded encoder: `Contents/Resources/m1005-xqx-encode`
- LaunchAgent registration: `SMAppService`, visible in Login Items
- Managed state/spool: `~/Library/Application Support/M1005Printer`
- Managed log: `~/Library/Logs/M1005Printer/service.log`

The service is a user LaunchAgent, not a privileged daemon. It requires no
kernel extension, system extension, DriverKit entitlement, SIP modification,
or files inside `/System`.

## Native setup app

The AppKit setup/status window provides:

- direct detection of USB `03f0:3b17`
- Login Item registration state
- local IPP server reachability
- macOS queue state, including detection of an obsolete/wrong queue URI
- enable service and add/update printer
- disable service and remove printer
- link to the local PAPPL printer page
- link to Login Items settings
- recent service logs
- confirmed uninstall flow for the queue, service, spool/state, and logs

The same functions are available for testing through `M1005 Setup` command
options such as `--status`, `--enable`, `--disable`, and `--uninstall`.

## Self-contained bundle

The Phase 4 service originally depended at runtime on Homebrew libusb and
OpenSSL paths. The Phase 5 service links PAPPL, libusb, OpenSSL, and the encoder
support statically. `otool -L` now lists only macOS system libraries and
frameworks. The bundle therefore does not require Homebrew on an installed
Mac.

The app contains the exact GPL encoder source, GPL license, PAPPL license, and
PAPPL notice under `Contents/Resources`. The bundled encoder also passes the
known-good byte-for-byte fixture test when launchd supplies a bundle-relative
`argv[0]`.

## Live acceptance record

The live integration passed:

- app bundle copied to `/Applications`
- embedded LaunchAgent registered with `SMAppService`
- background service started and remained running
- USB printer detected by the installed app
- IPP endpoint and DNS-SD service exposed on port 8765
- existing legacy `usb://` queue identified as needing an update
- queue changed to the local driverless `ipp://` endpoint
- real image printed from macOS Preview through the installed CUPS queue
- macOS converted the Preview job to Apple Raster (`4960x7015x8`, sGray)
- bundled encoder completed
- 20,007-byte XQX stream transmitted over USB
- PAPPL job completed with one impression
- initial sheet confirmed correct geometry, text, and USB delivery, but did
  not adequately expose grayscale tonal reproduction
- full uninstall removed only M1005 integration/data
- re-enable restored the service and queue
- exactly one final process listens on IPv4 and IPv6 port 8765

Two diagnostic submissions did not print: job 6 intentionally exposed that a
PWG fixture is not a normal image input to the macOS CUPS client filter, and
job 7 exposed launchd's bundle-relative executable path. Both issues were
fixed. Job 8's specially generated 1-bit PBM-to-PDF input produced an
822-byte, border-heavy diagnostic page; that result was an artifact of the
synthetic source conversion, not the normal driver path. A subsequent Preview
image proved the normal queue and USB path, but a more demanding document later
showed that intermediate tones were being reduced to binary black/white.

## Grayscale quality correction

The cause was two `memset(..., 127, ...)` calls that replaced PAPPL's document
and photo halftone matrices with one constant threshold. Version 0.5.1 removes
those overrides and uses PAPPL's complete 16×16 matrices. It also sets and
migrates both the PAPPL printer and macOS CUPS queue to:

- monochrome output (not the optional explicit bi-level mode)
- High print quality
- the M1005's maximum supported 600×600 dpi resolution
- the 256-threshold blue-noise photo matrix

The setup app reapplies these defaults when adding or updating the queue, so an
older saved `Normal` setting cannot silently survive an upgrade. Automated and
live IPP checks pass. The user reprinted the original grayscale document and
confirmed that the photo now prints correctly; grayscale physical acceptance
therefore passed.

### Adobe Acrobat Reader compatibility

Acrobat Reader initially produced a binary-looking photo only when its
**Print in grayscale (black and white)** checkbox was selected. Both affected
and successful jobs reached the service as 8-bit `sGray`, `monochrome`, High
quality jobs, showing that Acrobat changed the source pixels without supplying
a distinct IPP/CUPS option for the driver to override.

Version 0.5.2 removes `PAPPL_COLOR_MODE_BI_LEVEL` from the advertised
capabilities. The live service now exposes only `monochrome`, while retaining
High quality, 600 dpi, and the full 256-threshold photo matrix. After the queue
was refreshed, the original document printed with correct grays from Acrobat
both with the checkbox clear and with it selected.

## Automated verification

`make test` includes Phase 5 checks for:

- valid app and LaunchAgent property lists
- correct bundle identifier and structure
- native arm64 app, service, and encoder
- self-contained service with no Homebrew runtime path
- hardened-runtime ad-hoc development signatures
- nested-code signature integrity
- GPL corresponding encoder source in the app
- bundle-relative encoder discovery
- byte-for-byte known-good XQX generation
- preservation of non-constant document and photo halftone matrices
- all 256 photo thresholds and High-quality default

Build products:

- `build/M1005Printer.app`
- `build/HP-LaserJet-M1005-0.5.2-unsigned.pkg`

The unsigned package is for local development only and must not be distributed
as the release installer.

## Developer ID and notarization gate

The release script is `scripts/release_macos.sh`, exposed as
`make phase5-release`. It:

1. signs both embedded executables with Developer ID Application
2. signs the outer app with Hardened Runtime
3. verifies all nested code
4. builds and signs the installer with Developer ID Installer
5. submits the package with `xcrun notarytool`
6. staples and validates the ticket
7. verifies Gatekeeper installer assessment

Before running it, install the two Developer ID identities in the login
keychain and create a notarytool keychain profile. Then set:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: NAME (TEAMID)'
export DEVELOPER_ID_INSTALLER='Developer ID Installer: NAME (TEAMID)'
export NOTARY_PROFILE='m1005-notary'
make phase5-release
```

Do not send private keys or account passwords through chat. Install the
certificates locally in Keychain Access. The final reverse-DNS bundle IDs
should also be confirmed before a public release.
