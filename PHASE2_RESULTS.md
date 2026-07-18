# Phase 2 encoder port results

Date: 2026-07-18  
Target: macOS 26.5.2, Apple Silicon (`arm64`)  
Compiler: Apple Clang 21

## Result

**PASS.** The M1005 XQX encoder, diagnostic decoder, and JBIG implementation
now build as an isolated modern C11 component without the legacy foo2zjs
installation stack.

Release binaries:

- `build/m1005-xqx-encode`
- `build/m1005-xqx-decode`
- `build/libjbig-m1005.a`

The build uses:

```text
-std=c11 -O2 -Wall -Wextra -Wpedantic -Werror
```

Both executables are native arm64 Mach-O files. JBIG is statically linked; the
encoder has no runtime dependency on a system JBIG library.

## Source boundary

Only the required upstream subset is stored under `vendor/foo2xqx`:

- PBM-to-XQX encoder
- XQX/JBIG diagnostic decoder
- XQX protocol definitions
- JBIG-KIT 2.1 encoder/decoder and arithmetic coder
- Upstream GPL license and notices

Production encoding does not depend on:

- Foomatic
- PPD files
- Ghostscript
- CUPS filters or backends
- legacy shell wrappers
- legacy macOS/Linux installers
- firmware or hot-plug helpers
- the full upstream checkout

Upstream provenance is OpenPrinting/foo2zjs `main-fixes` commit
`3805c5d14b694167fb1e281fa6eff50312dd4cfa`.

## Portability and safety changes

- Replaced an out-of-range protocol enum member with `uint32_t` constants.
- Replaced GNU union-cast byte swapping with standard bit operations.
- Replaced deprecated `sprintf` calls with bounded `snprintf` calls.
- Fixed current Clang signedness and unused-parameter warnings.
- Added strict resolution validation. Direct 300 x 300 encoding now fails
  before output instead of producing `VIDEO_BPP=0` metadata.
- Input files are opened in binary mode.
- Added `M1005_XQX_TIMESTAMP`, a validated 14-digit test hook that makes the
  embedded PJL job timestamp reproducible. Normal jobs still use local time.

## Regression oracle: PASS

The test fixture `tests/fixtures/known-good-m1005-a4-600.xqx` is the exact
2717-byte stream that physically printed perfectly in Phase 1.

Fixture SHA-256:

```text
b8ba42999dd7b8e4ac2d284cb3d5a2772a4f593f3403123e36ff5040da1e7ece
```

The Phase 2 encoder regenerates a stream with the same SHA-256 and passes a
byte-for-byte `cmp`. The semantic decoder additionally verifies:

- XQX document/page boundaries
- one copy
- A4 paper code 9
- 600 x 600 dpi
- 4864 x 6848 padded raster
- one-bit video and 4784-pixel logical width
- 2034 bytes of JBIG payload

The suite also validates two-page streams, printer-side copies, invalid
resolution rejection, invalid deterministic timestamp rejection, arm64 output,
and the absence of a dynamic JBIG dependency.

Run it with:

```sh
make phase2-test
```

## Sanitizer result: PASS

The known-good encode/decode cycle passes Apple Clang AddressSanitizer and
UndefinedBehaviorSanitizer with a byte-identical output stream.

## Licensing

The encoder and bundled JBIG code remain GPL-2.0-or-later according to their
source headers. Distribution of a derivative must include the applicable
license notices and corresponding source. A non-GPL product would require a
separate commercial license or clean-room XQX implementation.

## Phase 3 handoff

The encoder is currently a validated process-style CLI with upstream global
state and fatal error exits. Phase 3 should initially isolate it behind a
Printer Application job boundary. Before running it in-process inside a
long-lived service, refactor it into a reentrant API with structured errors.

