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

- iOS device: `7e6d38124cf163e1884a87291adc798f0f93c1822aee56946b9eaafc5fedd560`
- iOS Simulator: `1c3c63211d21ed741a228c36996ce674869c24fab3b38f50c41dc146f5a1cae4`
- Mac Catalyst: `710dc90bd45b4e1d6fa34cf314c15a5c718eb7ffcc92830b6ee60ed506ba8ef9`
- macOS: `9fcc7d7bf9fa5e537cd3c94e5f43a75727d93167c11eed27f5f5ffaf9b7e8494`

PDFium's top-level source license is BSD-style. It also incorporates third-party
components with their own license notices. Before distributing the application,
generate and include the notices for the exact PDFium revision and its compiled
dependencies. This fork is pinned for development and regression testing;
updating it requires checksum, exported-symbol, platform, build, and corpus
verification.
