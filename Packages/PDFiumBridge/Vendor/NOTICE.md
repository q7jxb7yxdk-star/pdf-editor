# PDFium binary provenance

- PDFium branch: `chromium/7811`
- PDFium revision: `9e5d491ff73630b6a423689698290650050e7b3f`
- Build date: 2026-08-29
- Build tooling: Xcode 26.5 SDKs, `depot_tools` revision
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

- iOS device: `1d1a997a782baec98882e5f4b4241e631bf1898434c36eafaafc4207d0729692`
- iOS Simulator: `fa7e53466910f2dddc7bc4f5502f594480c34c3fd74487220fedb308d081bb51`
- Mac Catalyst: `22762a7be35cb33c45ad7c7de94bc80ee9e836e3409ea7373dafb01966e43f24`
- macOS: `17e37bd51574533fa788dc00fc3dfdbda1d70881d5a72784bedda063f0836589`

Each framework slice uses the three-component bundle build version
`144.0.7811` and includes a `PrivacyInfo.xcprivacy` file declaring no tracking
or data collection. The manifest records the bundled library's file-metadata
API category for app-container and user-selected files. The hashes above cover
the binaries after the framework resources were updated and each bundle was
ad-hoc signed again on 2026-09-14.

PDFium's top-level BSD-style license and the complete generated notices for the
seven compiled dependencies in the shipping `//:pdfium` graph are included in
`PDF Editor/THIRD_PARTY_NOTICES.txt`. The generation inputs, tool revision,
cross-slice comparison, adaptations, and output hash are recorded in the root
`THIRD_PARTY_NOTICES.md`. This fork is pinned for development and regression
testing; updating it requires regenerated notices plus checksum,
exported-symbol, platform, build, and corpus verification.
