# PDF Editor

PDF Editor is a document-based SwiftUI application for opening and modifying PDF files on iPhone, iPad, and Mac. It combines PDFKit for document presentation and annotation workflows with a bundled, locally patched PDFium build for page and page-object editing.

The application is intended for local PDF work such as reorganizing pages, editing existing text and images, adding annotations, and making scanned pages searchable without sending document content to an application-operated backend.

## Status terminology

This repository uses the following terms:

- **Implemented**: present in source and connected to the normal application path.
- **Test-covered**: covered by repository tests or validation programs; this does not mean the test was run for the current change.
- **Verified in this task**: successfully built, tested, or validated while preparing these documents.
- **Externally unverified**: requires a signed build, device, distribution account, network observation, or other environment outside this repository.
- **Experimental / inactive**: present in source but not part of the normal user path.
- **Planned / not implemented**: a documented extension direction only.

## Features

### Implemented

- Open, display, edit, and create PDF documents through SwiftUI's document architecture. Edits remain in memory until the user selects the cross-platform Save toolbar action; macOS also provides File → Save and Command-S.
- Start each document with the left Tools panel hidden and toggle it from the toolbar. The English tool workspace groups text/annotation, page, organization, export, e-signature, and security actions alongside the right-side viewing controls.
- Navigate pages with PDF thumbnails.
- Insert an A4 page, delete a page, rotate a page, and move a page one position at a time.
- Merge another PDF at the end of the open document, including a password-protected source after password entry.
- Export the selected page or split the document into one PDF per page.
- Inspect recursively discovered page objects, including objects nested in Form XObjects.
- Add text and images; replace existing text and images; move, scale, rotate, reorder, and delete supported page objects. Text and image objects can be selected directly on the document without first enabling a separate object-editing mode. Single-click or tap uses a screen-space hit tolerance to select an object, while double-click on macOS or double-tap on iOS edits text in place at its page location or opens image replacement for the selected object. On macOS, pending multi-line text uses its rendered layout for hit testing and copying; double-clicking a pending line reopens the editor with the insertion cursor at that line's clicked word. The first committed macOS inline edit remains visible through an atomic handoff from the live editor to a page-mounted, noneditable staged-text overlay. Leaving an inline text editor stages the replacement in memory; PDFium applies staged text only when the user selects Save, and iOS does not auto-save inline edits.
- Inspect the current page on a background PDFium handle, cache page-object snapshots, and prefetch the next page without making PDFKit wait before displaying or scrolling the document. Stale page requests are cancelled or discarded, and PDFium calls are serialized because the library is not treated as thread-safe.
- Reuse embedded PDF font data for inline text display and replacement when available. Inline existing-text editing provides Bold and Italic controls on macOS and iOS, stages those choices until Save, and persists changed styles as searchable CoreText vector text. When text and style remain compatible with the original font, preserve the existing object; unsupported glyphs, complex shaping, or changed bold/italic styling use the searchable overlay path.
- Add notes, free-text annotations, highlights, and ink-based handwritten signatures. Comment placement opens a larger multi-line editor on both macOS and iOS.
- Select annotations directly on the page without a separate annotation-editing mode; move, resize, edit supported properties of, and delete them. The left-panel Edit comment action opens a page-scoped Comment List for the same editing operations. Successful annotation changes update the existing PDFKit document in place to avoid a visible reload; error rollback and Undo/Redo may rebuild it from serialized bytes. Style changes are intentionally disabled for annotations with fixed appearance streams.
- Run on-device Vision text recognition on one page or all scanned pages. Pages that already contain selectable text are skipped, and recognized text is reviewed before an invisible searchable text layer is added.
- Unlock encrypted PDFs and preserve encryption during ordinary saves. Password removal is an explicit save option for an already unlocked document.
- Detect the presence of PDF signature objects and require confirmation before the first in-place mutation that may invalidate them.
- Register document mutations and pending text replacements with the focused document Undo manager. The temporary macOS inline text view uses an isolated Undo history that is cleared before the view is removed.

### Experimental or inactive paths

- `PDFKitEditingEngine` is an alternate page-level backend. The normal document path uses `PDFiumEditingEngine`; PDFKit's editing session is currently invoked internally only for document metadata mutation.
- The engine command surface includes full page reordering and document metadata updates, but the current UI does not expose those commands directly.
- A direct JPEG insertion API exists in the engine and C bridge, while the normal image-import UI decodes supported images into a bounded BGRA bitmap first.

## Requirements

| Requirement | Repository evidence |
| --- | --- |
| Xcode | The project records Xcode 26.6 creation/upgrade metadata. No separate `.xcode-version` file is present. |
| iOS / iPadOS | Deployment target 26.0; iPhone and iPad device families. |
| macOS | Deployment target 26.0. |
| Swift language mode | `SWIFT_VERSION = 5.0` in the app target. |
| Swift Package Manager | `PDFiumBridge` declares Swift tools 5.9. |
| SDKs | Apple SDKs supplied by Xcode; no independently pinned SDK version is declared. |

The local package separately declares iOS 17 and macOS 14 minimum platforms, but the application target's effective minimum versions are iOS 26.0 and macOS 26.0.

### Dependencies

- Apple frameworks: SwiftUI, Combine, PDFKit, Vision, CoreText, CoreGraphics, ImageIO, Uniform Type Identifiers, and AppKit or UIKit depending on the platform.
- `Packages/PDFiumBridge`: a local Swift package containing a C bridge and a checked-in PDFium XCFramework.
- PDFium `chromium/7811`, revision `9e5d491ff73630b6a423689698290650050e7b3f`, with the two local patches documented under `Packages/PDFiumBridge/Vendor/Fork/`.
- Noto Sans CJK Traditional Chinese Regular, bundled for Unicode text and OCR layers.

There is no remote package dependency, CocoaPods configuration, dependency lockfile, or dependency installation script. The PDFium binary dependency is already present in the repository.

## Installation and setup

1. Clone or otherwise obtain the repository, including the checked-in `Packages/PDFiumBridge/Vendor/PDFium.xcframework` directory.
2. Open `PDF Editor.xcodeproj` in Xcode.
3. Select the `PDF Editor` scheme and either a macOS run destination or an iPhone/iPad simulator running a compatible OS.
4. For local unsigned command-line builds, disable code signing as shown below. Running on a physical device requires an appropriate development team and signing configuration.

No environment variables, API keys, account credentials, certificates, `.env` files, or backend configuration are required by the reviewed source. PDF passwords are entered interactively when needed.

The project currently contains a development-team identifier in its Xcode build settings. Developers using a different Apple account may need to select their own team for a signed device build; do not treat the checked-in value as portable configuration.

## How to run

### Xcode

Open the project, select the `PDF Editor` scheme, choose macOS or a compatible iOS Simulator, and run the app. The application opens as a document-based editor and can create a blank one-page PDF or open an existing PDF.

### Command line

Build for macOS without signing:

```sh
xcodebuild -project "PDF Editor.xcodeproj" -scheme "PDF Editor" -destination 'platform=macOS' -derivedDataPath /tmp/PDFEditorDerivedData-mac CODE_SIGNING_ALLOWED=NO build
```

Build for a generic iOS Simulator without signing:

```sh
xcodebuild -project "PDF Editor.xcodeproj" -scheme "PDF Editor" -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PDFEditorDerivedData-iossim CODE_SIGNING_ALLOWED=NO build
```

Build for a generic iOS device without signing:

```sh
xcodebuild -project "PDF Editor.xcodeproj" -scheme "PDF Editor" -destination 'generic/platform=iOS' -derivedDataPath /tmp/PDFEditorDerivedData-ios CODE_SIGNING_ALLOWED=NO build
```

These commands compile the application; they do not launch the UI, sign an archive, install on a device, or verify document behavior.

### Runtime modes

There is no separate online, backend, demo, or fixture-driven runtime mode. OCR uses Apple's local Vision API in the application source. No first-party networking or account integration was found, but a fully offline or no-egress claim would require runtime network observation and review of the bundled native dependency.

## Project structure

```text
PDF Editor.xcodeproj/             Xcode project and app target settings
PDF Editor/                       SwiftUI application source and resources
  Core/                           Editing protocols, models, and PDFKit/PDFium engines
  Document/                       ReferenceFileDocument and split/export wrappers
  Platform/                       PDFKit platform bridge and page thumbnails
  Services/                       Explicit saving, annotation, OCR, shaping, and image conversion services
  Assets.xcassets/                App icons and accent color
Packages/PDFiumBridge/            Local C bridge, binary PDFium dependency, and XCTest suite
Validation/                       Standalone local validation and fixture-generation programs
RELEASE_CHECKLIST.md              Outstanding automated, manual, and distribution checks
THIRD_PARTY_NOTICES.md            Third-party notice index
```

See `TECHNICAL_DOCUMENTATION.md` for component and data-flow details.

## Development

Run the PDFium bridge test suite:

```sh
swift test --package-path Packages/PDFiumBridge
```

The package XCTest suite covers page assembly, encryption behavior, malformed input rejection, annotation color, page-object editing, nested Form isolation, image handling, and searchable regular/bold/italic CoreText overlays. These are package-level tests, not app UI tests.

The `Validation/` directory contains standalone programs for annotation round trips, OCR policy, fixture generation, and a larger mixed/protected/truncated PDF corpus. They are not attached to an Xcode test target and must be compiled with the relevant app source files. The exact commands verified during this documentation task are recorded in `TECHNICAL_DOCUMENTATION.md`.

No repository configuration was found for UI tests, CI, linting, formatting, type checking as a separate step, or an additional static-analysis tool. Xcode compiler warnings and analyzers remain enabled through the project build settings.

## Known limitations

- The user interface is currently hard-coded in English and no string catalog or other localization source is checked in.
- App builds target only iOS/iPadOS and macOS. The bundled PDFium XCFramework also contains a Mac Catalyst slice, but Mac Catalyst is not an app target platform.
- OCR is a local Vision workflow, not a full document-layout reconstruction system. It skips any page with nonempty selectable text and processes remaining pages sequentially.
- Imported images are decoded with ImageIO and capped at 8,192 pixels on their longest dimension. The normal UI imports a flattened BGRA representation.
- Existing text replacement can change implementation strategy: unsupported glyph coverage or complex shaping uses a new searchable CoreText overlay rather than rewriting the original text object with its font. If PDFium regeneration would discard ICC or pattern color resources, the app preserves the page and creates an opaque, editable FreeText visual replacement instead. That safety fallback leaves the original content-stream text underneath the annotation, so searches may still find the original text.
- Inline text changes are pending view state until Save. Closing the document without saving discards them; Save may take noticeable time while PDFium applies and verifies replacements. On macOS, the short-lived fallback used before a page overlay mounts is noninteractive and is removed or migrated when its page overlay becomes available, or when scrolling or document replacement occurs. Its mask is aligned to backing pixels without a fixed horizontal expansion to avoid a vertical seam. The app has no automated UI test proving exact font metrics or scrolling behavior for every PDF producer and embedded-font format.
- Page-assembly operations explicitly check PDF permission bit `0x400`. The reviewed source does not provide an equivalent explicit permission guard for every object or annotation mutation; runtime behavior of restricted documents remains unverified.
- Signature handling detects signature objects and warns about invalidation. It does not validate the signer, certificate trust, signed byte ranges, or cryptographic validity. Once granted, invalidation consent lasts for the current open document object.
- Accepted document passwords remain in memory for the open editing session so encrypted data can be reopened during mutation and undo/redo. The source does not deliberately persist them, but it does not provide secure-memory or zeroization guarantees.
- Split files are newly assembled outputs and are opened without a password by the validation path; they are distinct from the explicit “remove password on save” option.
- App Sandbox and Hardened Runtime are enabled in build settings, but a built, signed, and distributed application was not inspected in this documentation task. No explicit entitlements file is present.
- The complete transitive PDFium notice set, final license exposure in the app bundle, export-compliance classification, signing, notarization, device installation, and store behavior remain externally unverified release work.

## License

No project-wide `LICENSE` file or project-wide license declaration was found. Do not assume permission to redistribute the application source solely from third-party notices.

Third-party licensing is documented separately:

- `THIRD_PARTY_NOTICES.md` indexes the bundled dependencies.
- `PDF Editor/NotoSansTC-LICENSE.txt` contains the SIL Open Font License 1.1 text for the bundled font.
- `Packages/PDFiumBridge/Vendor/NOTICE.md` records PDFium provenance and identifies the outstanding requirement to generate complete notices for the pinned build and its transitive components.

## Verification status

Verified in this documentation task through 2026-08-25:

- `PDFiumBridge` package tests: 25 tests passed with 0 failures.
- Standalone annotation round-trip and OCR policy validations passed.
- Protected-PDF fixture self-validation passed.
- Phase-six corpus acceptance passed for the 120-page, mixed selectable/scanned content, rotated, protected, and truncated cases.
- Unsigned Debug builds succeeded for macOS, generic iOS Simulator, and generic iOS device destinations.
- The latest pending-text Save and Undo flow, embedded-font and multi-line editing preview, background page-object inspection, central PDF scrolling, explicit-save, panel, annotation-style, and no-flash Apply changes were revalidated with Debug builds for macOS and the generic iOS Simulator destination. Exact cursor placement and visual layout remain manual UI checks.
- User-validated macOS runtime behavior: the first committed inline text edit remained visibly continuous through the live-editor-to-page-overlay handoff, with no vertical mask seam. This is scoped visual runtime evidence, not build validation; disk persistence still required explicit Save.
- A macOS UI workflow created and edited a comment, applied a blue color and approximately 36% opacity, and confirmed that the Comment Editor remained stable without resetting after Apply.
- The four checked-in PDFium binary SHA-256 values matched `Packages/PDFiumBridge/Vendor/NOTICE.md`.

The exact commands and boundaries are recorded in `TECHNICAL_DOCUMENTATION.md`. No automated app UI test, physical-device run, signed build, archive, installation, or external-service validation was performed. Source, compile, and the scoped macOS UI evidence do not establish App Store compliance, PDFium reproducibility, third-party vulnerability status, or complete license compliance.
