# PDFium binary provenance

- PDFium branch: `chromium/7811`
- PDFium revision: `9e5d491ff73630b6a423689698290650050e7b3f`
- Original full build date: 2026-08-29
- Build tooling: Xcode 26.5 SDKs for the original four-slice build; Xcode 26.6
  (17F113) with iOS SDK 26.5 (23F81a) for the 2026-09-14 iOS device rebuild
  and macOS SDK 26.5 (25F70) for the 2026-09-14 macOS rebuild, both with
  matching dSYMs,
  `depot_tools` revision
  `f70835271105ca56d2cd5382a0118152bc2bdeea`, and
  `bblanchon/pdfium-binaries` revision
  `cf2b11286a7960c39eb75c736910c999696b91a7`
- Local build patch: `Fork/pdfium-clang-rt-pinned.patch`
- Local PDFium source patches, in application order:
  `Fork/pdfium-form-xobject-cow.patch`,
  `Fork/pdfium-phase3-object-editing.patch`,
  `Fork/pdfium-page-content-preservation.patch`
- Reproduction notes: `Fork/README.md`
- Upstream engine: <https://pdfium.googlesource.com/pdfium/>

Framework binary SHA-256 values after universal-slice assembly and signing:

- iOS device: `e2365842ce61bec3d7eafd36d4711bfcb9912882194d3d1b6856ea20a6e17ad1`
- iOS Simulator: `fa7e53466910f2dddc7bc4f5502f594480c34c3fd74487220fedb308d081bb51`
- Mac Catalyst: `22762a7be35cb33c45ad7c7de94bc80ee9e836e3409ea7373dafb01966e43f24`
- macOS: `db4cdeac426906811a9511e66e2b608a0fc69af7cbf8f91ce8f462dfa87b2f83`

Each framework slice uses the three-component bundle build version
`144.0.7811` and includes a `PrivacyInfo.xcprivacy` file declaring no tracking
or data collection. The manifest records the bundled library's file-metadata
API category for app-container and user-selected files. The hashes above cover
the binaries after the framework resources were updated and each bundle was
ad-hoc signed again on 2026-09-14.

The iOS device slice was rebuilt from the same pinned, patched source on
2026-09-14 with full DWARF information. Its XCFramework entry includes
`DebugSymbolsPath = dSYMs`; the bundled `PDFium.framework.dSYM` has the same
arm64 UUID as the framework binary. Its DWARF file SHA-256 is
`ad1e9e3ad3373484b39966a30dfd546df79e6e6a3f59a60a6e6074244d95e9d2`.
The macOS universal slice was rebuilt from the same source with line-table
debug information. Its x86_64 and arm64 UUIDs match the two UUIDs in its
bundled dSYM, whose DWARF file SHA-256 is
`1b762e90c344be30140243cc9c6c39a7125fbb040c777b8e1033ac82f25bc5d2`.
The Simulator and Mac Catalyst binaries remain byte-for-byte identical to the
original Xcode 26.5 build.

PDFium's top-level BSD-style license and the complete generated notices for the
seven compiled dependencies in the shipping `//:pdfium` graph are included in
`PDF Editor/THIRD_PARTY_NOTICES.txt`. The generation inputs, tool revision,
cross-slice comparison, adaptations, and output hash are recorded in the root
`THIRD_PARTY_NOTICES.md`. This fork is pinned for development and regression
testing; updating it requires regenerated notices plus checksum,
exported-symbol, platform, build, and corpus verification.
