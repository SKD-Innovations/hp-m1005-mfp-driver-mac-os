# Physically validated regression fixture

`known-good-m1005-a4-600.xqx` is the exact 2717-byte XQX stream sent during
the first successful Phase 1 print on 2026-07-18. The HP LaserJet M1005 MFP
printed the complete A4 calibration page correctly.

- SHA-256: `b8ba42999dd7b8e4ac2d284cb3d5a2772a4f593f3403123e36ff5040da1e7ece`
- Job timestamp embedded in the fixture: `20260718172322`
- Source raster SHA-256: `78cf7ee5621ae856624b67dd81ed2b6bc880040531248652a158815fd2b29918`
- Media: A4
- Resolution: 600 x 600 dpi
- Copies: 1
- Duplex: off
- Input source: auto

The Phase 2 test suite regenerates the deterministic source raster, fixes the
job timestamp through the test-only `M1005_XQX_TIMESTAMP` environment variable,
and requires a byte-for-byte match with this fixture.

