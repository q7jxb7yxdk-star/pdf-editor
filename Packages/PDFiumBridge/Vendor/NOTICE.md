# PDFium binary provenance

- PDFium branch: `chromium/7811`
- PDFium revision: `9e5d491ff73630b6a423689698290650050e7b3f`
- Build date: 2026-08-24
- Build tooling: Xcode 26.5 SDKs and `bblanchon/pdfium-binaries` revision
  `cf2b11286a7960c39eb75c736910c999696b91a7`
- Local source patches, in application order:
  `Fork/pdfium-form-xobject-cow.patch`,
  `Fork/pdfium-phase3-object-editing.patch`
- Reproduction notes: `Fork/README.md`
- Upstream engine: <https://pdfium.googlesource.com/pdfium/>

Framework binary SHA-256 values after universal-slice assembly and signing:

- iOS device: `efcd1dc5f5be02c2e8c8f78e81b2e186c75b18d430dbf0a85fcfad314cd4fb5c`
- iOS Simulator: `e1eca5b75c8cae4a29f1d9c9067b999d98aebdbfb08a846cc15e808df997a306`
- Mac Catalyst: `6603a0b2c3bad0a84a21fb8456ce20a5a04c0df6b6b6d0295f46acacfc9f8578`
- macOS: `116ae8b414abb6f9c8a2eff586d9371a6abbeda8cfb52a400ccd73b908be5881`

PDFium's top-level source license is BSD-style. It also incorporates third-party
components with their own license notices. Before distributing the application,
generate and include the notices for the exact PDFium revision and its compiled
dependencies. This fork is pinned for development and regression testing;
updating it requires checksum, exported-symbol, platform, build, and corpus
verification.
