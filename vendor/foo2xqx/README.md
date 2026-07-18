# Vendored foo2xqx/JBIG subset

This directory contains only the upstream files required to encode and inspect
XQX print streams for the HP LaserJet M1005 MFP.

Upstream: `https://github.com/OpenPrinting/foo2zjs`  
Branch: `main-fixes`  
Commit: `3805c5d14b694167fb1e281fa6eff50312dd4cfa`

Vendored files:

- `foo2xqx.c`: PBM-to-XQX encoder
- `xqxdecode.c`: XQX/JBIG diagnostic decoder
- `xqx.h`: XQX protocol definitions
- `jbig.c`, `jbig.h`, `jbig_ar.c`, `jbig_ar.h`: bundled JBIG-KIT 2.1
- `COPYING`: upstream GNU GPL version 2 license text and notices

Excluded by design:

- Foomatic wrappers and databases
- PPD files
- CUPS filters/backends
- Ghostscript and PostScript scripts
- macOS/Linux installer scripts
- firmware and hot-plug helpers
- unrelated printer encoders

Local portability changes are intentionally small and reviewable:

- protocol constants wider than signed `int` are preprocessor `uint32_t`
  constants instead of enum members;
- byte swapping uses standard bit operations instead of GNU union casts;
- Clang warnings are fixed and the build uses `-Werror`;
- 300 dpi and other invalid resolutions are rejected before encoding;
- tests can supply a 14-digit `M1005_XQX_TIMESTAMP` for reproducible output;
- file input is opened in binary mode.

The code remains licensed under GPL-2.0-or-later according to its source
headers. Any distributed derivative must provide corresponding source and the
applicable license notices.

