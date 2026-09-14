# Third-Party Notices

The complete distribution notice is bundled as
`PDF Editor/THIRD_PARTY_NOTICES.txt` and is exposed through **All tools →
About → Acknowledgements**. It contains the full license and notice text for:

- PDFium `chromium/7811` at
  `9e5d491ff73630b6a423689698290650050e7b3f`;
- PDFium's compiled dependencies: Abseil, fast_float, HarfBuzz, ICU,
  libjpeg-turbo, llvm-libc, and zlib;
- Noto Sans CJK Traditional Chinese under SIL Open Font License 1.1;
- Swift ASN.1 1.7.2, Swift Certificates 1.20.0, and Swift Crypto 4.5.2,
  including their upstream notices.

The generated app resource is 122,363 bytes and has SHA-256
`cd6bcb68b98241d5bf787bb94dfd8ab14e6c076b9e86d73099442fcc4fe8d9ac`.

## PDFium generation record

The PDFium portion was generated on 2026-09-14 from the patched source tree
using Chromium `tools/licenses/licenses.py` at
`ac3dd4b0858aa10bd8d2aba4e43a59674d1237f7`, the Chromium roll that pins the
same PDFium revision. `depot_tools` was pinned to
`f70835271105ca56d2cd5382a0118152bc2bdeea`; dependencies came from that
PDFium revision's `DEPS` file.

The generator inspected `//:pdfium` with the shipping GN arguments documented
in `Packages/PDFiumBridge/Vendor/Fork/README.md`. Separate graphs were checked
for macOS arm64/x86_64, iOS device arm64, iOS Simulator arm64/x86_64, and Mac
Catalyst arm64/x86_64. All seven graphs produced the same eight-entry notice
set and the same unadapted SHA-256
`86c828b8962e25fc54fc044895b587df6a17ebfad0993337df58f981aac6e710`.
Every graph passed the generator's strict `scan --enable-warnings` check.

The patched graph used these exact patch files and SHA-256 values:

| Patch | SHA-256 |
| --- | --- |
| `shared_library.patch` | `0fbc6207a5c9da8528914418598a494a3ed358ccb8ee91c8b3f8c1f95ab84057` |
| `public_headers.patch` | `b21cedea243ced82977251000e356240de038712b8cf8721b3dda3d595c6affd` |
| `ios/pdfium.patch` | `3ebee9dbdfc134c844c60ea600343c5ecd60ab8b3f2cdb16641fc2713255ee00` |
| `mac/build.patch` | `c5967db42fb63775a6a461859eb39d9db8e9b1c2e8a39198dc00ab7b32dcc006` |
| `pdfium-clang-rt-pinned.patch` | `912b2c9973447561d780e0da688bcae426af1f407cd31679d87f0dee6fdf53ea` |
| `pdfium-form-xobject-cow.patch` | `04fb777c18d5793eafc280dcbf8a51177d6addfec1f1a40b0a4a16a14f029ffa` |
| `pdfium-phase3-object-editing.patch` | `e2bb0f76aab93521a506202752a4271c9391f0585ec33831eee677536d67ed63` |
| `pdfium-page-content-preservation.patch` | `0eb0a7521fafa61315efe9646e1c3eb6e83a72fd8a529f71826c08febaab35f1` |

The two intended `ios/pdfium.patch` changes were applied semantically because
one context block contains older Apple source filenames than this PDFium
revision. They only widen the existing Apple source condition to iOS and
remove a test-bundle certificate override; neither changes a third-party GN
dependency edge.

Two format-only adaptations were required and are recorded here:

1. PDFium names llvm-libc metadata `third_party/llvm-libc/README.md`; a temporary
   byte-identical `README.chromium` copy was supplied because the pinned
   Chromium parser recognizes the latter filename.
2. The generator's hard-coded root heading `The Chromium Project` was changed
   to `PDFium`. The root license text and all third-party entries were left
   unchanged.

The bblanchon and local source patches are recorded in
`Packages/PDFiumBridge/Vendor/Fork/README.md`. The framework binaries link only
Apple system frameworks and `/usr/lib/libSystem.B.dylib`; no additional dynamic
third-party library was found by `otool -L`.

## Other exact inputs

- Noto license source: `PDF Editor/NotoSansTC-LICENSE.txt`.
- Swift package revisions: `PDF Editor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Swift package texts: each pinned checkout's root `NOTICE.txt` and
  `LICENSE.txt`.

This notice file documents third-party terms. It does not grant a license for
the PDF Editor application source itself; no project-wide source license is
declared.
