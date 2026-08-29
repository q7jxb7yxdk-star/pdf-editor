# PDFium object-editing fork

This XCFramework is built from PDFium `chromium/7811` at revision
`9e5d491ff73630b6a423689698290650050e7b3f` (2026-04-23). The local patches
add copy-on-write Form XObject streams, isolated Image XObject replacement,
persistent drawing-order changes for pages and Forms, non-pattern color-space
conversion, Shading regeneration, and Pattern paint regeneration. Colored and
uncolored tiling patterns plus shading patterns retain their original resource
objects; uncolored operands are normalized through a Pattern/DeviceRGB color
space. The C bridge clones every Form ancestor before changing a descendant, so
separately placed references to a shared Form remain isolated.

## Reproduction inputs

- `depot_tools` revision `f70835271105ca56d2cd5382a0118152bc2bdeea`
- `bblanchon/pdfium-binaries` revision
  `cf2b11286a7960c39eb75c736910c999696b91a7`
- `simdutf` revision `f7356eed293f8208c40b3c1b344a50bd70971983`
- Xcode 26.5 SDKs
- bblanchon patches: `shared_library.patch`, `public_headers.patch`,
  `ios/pdfium.patch`, and `mac/build.patch`
- `pdfium-clang-rt-pinned.patch`, applied in the `build` checkout in place of
  bblanchon's `clang_rt.patch`, whose AIX context does not match this revision
- local patches, applied in this order:
  1. `pdfium-form-xobject-cow.patch`
  2. `pdfium-phase3-object-editing.patch`
  3. `pdfium-page-content-preservation.patch`

Fetch PDFium with a `.gclient` whose `target_os` is `["mac", "ios"]`, checkout
the pinned revision, sync without history, apply the listed bblanchon patches,
apply `pdfium-clang-rt-pinned.patch` from the `build` checkout, then apply the
three PDFium-source patches. Generate and build `pdfium` with `gn gen` and
`autoninja -C <output> pdfium` for these configurations:

| Output | `target_os` | `target_environment` | `target_cpu` |
| --- | --- | --- | --- |
| macOS | `mac` | — | `arm64`, `x64` |
| iOS device | `ios` | `device` | `arm64` |
| iOS Simulator | `ios` | `simulator` | `arm64`, `x64` |
| Mac Catalyst | `ios` | `catalyst` | `arm64`, `x64` |

Common GN arguments:

```gn
clang_use_chrome_plugins = false
is_component_build = false
is_debug = false
pdf_enable_v8 = false
pdf_enable_xfa = false
pdf_is_standalone = false
pdf_use_partition_alloc = false
treat_warnings_as_errors = false
```

macOS uses `mac_deployment_target = "10.15"`. iOS-family builds use
`ios_deployment_target = "17.0"`, `ios_enable_code_signing = false`, and
`use_blink = true`. Catalyst arm64 additionally uses `use_lld = false` because
the Xcode 26.5 macCatalyst SDK TBD format is incompatible with the bundled lld.

Create universal macOS, Simulator, and Catalyst binaries with `lipo`, preserve
the existing XCFramework slice layout and headers, set each install name to
`@rpath/PDFium.framework/PDFium`, and ad-hoc sign each framework bundle.

## Required verification

- Each slice exports `_FPDFFormObj_CloneForEditing`,
  `_FPDFImageObj_SetBitmapIsolated`, `_FPDFPage_MoveObject`, and
  `_FPDFFormObj_MoveObject`.
- `lipo -info`, `otool -l`, and `codesign --verify --strict` match the intended
  platform and architecture.
- `swift test` passes nested text replacement, translation, deletion, z-order,
  shared page/Form image isolation, clipping and marked-content preservation,
  alpha bitmap, searchable CoreText overlay, ICC color, Shading, colored and
  uncolored tiling Pattern, and shading Pattern regressions.
