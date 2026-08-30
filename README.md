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

- Open, display, edit, and create PDF documents through the platform document architecture. iOS and iPadOS use SwiftUI `DocumentGroup`; macOS uses the app-owned `PDFEditorNSDocument` so Save, Save As, close protection, file coordination, and document identity stay inside AppKit's native lifecycle. The macOS document explicitly disables autosave-in-place and permanent Versions history, so it retains traditional Save/Save As behavior and the unsaved-changes close prompt without offering Browse All Versions or showing volume-version-storage warnings. Pending text and AcroForm edits are prepared and verified before the native write. Save As updates the window title, represented URL, and later Save target only after the write succeeds, while the original remains unchanged. Save As is also available from the toolbar on iOS/iPadOS, and macOS additionally provides File → Save, File → Save As…, Command-S, and Shift-Command-S.
- Start each document with the left Tools sidebar visible and toggle it from the toolbar. In wide layouts, this toggle changes the available PDF width without a transition animation so PDFKit does not repeatedly auto-scale and redraw the page while the sidebar opens or closes. On macOS, Open appears before Save in the leading toolbar and invokes the same native document picker as File → Open… and Command-O. File → Open Recent exposes AppKit's recent-document list, reports open failures, removes entries whose files no longer exist, and provides Clear Menu. Open, Save, Save As, Undo, Redo, Tools, and OCR are separate leading toolbar items with hidden shared backgrounds. The app-owned macOS `NSDocument` supplies the title and represented URL, opts document windows into native tabbing, and routes Command-W through AppKit's native close protection. Each opened PDF window waits until it becomes key after any native Open panel has closed, then applies a one-time, non-animated fill frame on the next main-actor turn and restores the arrow cursor. The English tool workspace groups text/annotation, organization, export, e-signature, and security actions. Its bottom Recent files section shows up to five recent PDFs using Quick Look thumbnails sized like Pages-sidebar thumbnails, opens a selected file, removes missing-file records, and can clear the complete shared recent list. The E-sign category exposes Fill in form fields, Add a signature, Add a checkmark, and Add a crossmark; Request e-signatures is not listed. Secure PDF exposes Protect PDF. The five tool categories and, on macOS, Recent files start expanded when no preference has been stored; a disclosure click persists that section selection for later Tools sidebars and app launches, while ignoring stored section names the current workspace does not recognize.
- Toggle the Pages thumbnail panel immediately to the left of the narrow right-side viewing rail. Select a thumbnail to navigate, drag thumbnails to reorder pages, extract that page as a standalone PDF, rotate it left or right, or delete it except when it is the final remaining page. Each thumbnail places Extract immediately before Rotate left. iOS exposes the standard Edit control for list reordering; macOS uses the list's direct move interaction. After the rail's Zoom out control, a 44-point page-number field, a 44-point total-page display, and separate Previous page and Next page buttons provide direct page navigation; page changes originating in PDFKit remain synchronized with the field.
- Merge another PDF at the end of the open document, including a password-protected source after password entry. Imported pages preserve their existing embedded fonts and visual appearance.
- Extract any page directly from its thumbnail. Extracted pages preserve the source page's embedded fonts and visual appearance.
- Export the current page or every page as separate PNG or JPEG files at 72, 144, or 300 DPI, with 300 DPI selected by default. Image export renders the PDF crop box with page rotation, reports per-page progress, supports cancellation between pages, commits pending inline text first, and uses sortable `page-0001` filenames for multi-page output. The macOS options sheet uses a compact two-column layout with aligned format, page-scope, and resolution controls.
- Inspect recursively discovered page objects, including objects nested in Form XObjects.
- Add text and images; replace existing text and images; move, scale, rotate, reorder, and delete supported page objects. Text and image objects can be targeted directly on the document without first enabling a separate object-editing mode. On macOS, single-clicking or dragging original selectable text remains in PDFKit's native selection path, including selections across whitespace and adjacent text runs; double-clicking activates inline editing. If background PDFium inspection has not yet resolved the page object, the PDFKit word selection supplies the initial editor position and visible selection outline until the object arrives. Non-text objects continue to use screen-space hit testing for direct selection. On iOS, taps use screen-space hit testing to select objects and double-taps activate type-specific editing. Pending macOS multi-line text uses its rendered layout for hit testing and copying; double-clicking a pending line reopens the editor with the insertion cursor at that line's clicked word. The first committed macOS inline edit remains visible through an atomic handoff from the live editor to a page-mounted, noneditable staged-text overlay. Starting a macOS scroll commits the active inline edit and clears its object selection before PDFKit processes the scroll event. Leaving an inline text editor stages the replacement in memory; PDFium applies staged text only when the user selects Save, and iOS does not auto-save inline edits.
- Inspect the current page on a background PDFium handle, reuse a cached snapshot when the current page is already cached, and prefetch the next page without making PDFKit wait before displaying or scrolling the document. Locked documents skip this background object scan until a password has been supplied, so opening a protected PDF presents the password-required view without surfacing a premature invalid-password alert. Each display scan loads the native page once and batch-collects recursive object paths and lightweight display metadata, avoiding a full page parse for every object. Stale page requests are cancelled or discarded, and PDFium calls are serialized because the library is not treated as thread-safe.
- Reuse embedded PDF font data for inline text display and replacement when available. Inline existing-text editing provides Bold and Italic controls on macOS and iOS, stages those choices until Save, and persists changed styles as searchable CoreText vector text. When text and style remain compatible with the original font, preserve the existing object; unsupported glyphs, complex shaping, or changed bold/italic styling hide and blank the original text object before importing the searchable overlay so the two visual layers cannot overlap.
- Fill existing AcroForm text fields, checkboxes, radio-button groups, combo boxes, and list boxes directly through PDFKit's native Widget controls. Widget fields are excluded from the app's general annotation move/delete gestures. A committed field change is compared with the PDFium working copy, registered with the document Undo manager, marked unsaved, serialized through the current encryption policy, and rejected unless the resulting PDF reopens with the same field values. Save and Save As perform this synchronization again so an active text editor cannot leave its latest value only in the PDFKit presentation document. Read-only fields remain read-only. XFA forms, PDF JavaScript/calculation/submit actions, AcroForm authoring, and cryptographic signing of Signature Widgets are not supported.
- Add notes, free-text annotations, highlights, signatures, checkmarks, crossmarks, and freehand Ink strokes. When a PDF does not already provide a field at the desired location, Fill in form fields enters a one-shot placement mode: click or tap anywhere on a PDF page to open a transparent, outlined multiline text box at a one-line minimum size with an 11-point default font. The blank draft starts at 72 by 28 points so it remains visible and easy to select. Once text is entered, its width follows the widest line's measured glyph width plus six-point left and right insets, with a 24-point selectable minimum; it reaches the crop-box limit before wrapping. Its nonempty height follows the rendered single-line or multiline height plus four-point top and bottom insets instead of retaining the blank 28-point height. The first page click also presents the color, text-size, and delete action bar for the uncommitted draft; color and size update the editor immediately, while delete cancels the draft and exits placement. The box grows and shrinks from measured glyph widths and explicit or wrapped line heights, remains clamped to the crop box, and commits its current color, size, and fitted bounds as an editable FreeText annotation rather than creating a new AcroForm field. Committed FreeText writes a PDF `/RD` inner text rectangle with matching top and bottom differences; content-hugging annotation height prevents PDFKit's top-origin layout from leaving excess space below the text. Changing its contents, bounds, or font size recalculates both the fitted bounds and these insets. On macOS, Return inserts a line break, Command-Return finishes, and Escape cancels; on iOS/iPadOS, Return inserts a line break and the keyboard accessory Done button finishes. Blank input is discarded. Add a signature opens a local reusable signature library: create and save multiple handwritten signatures, select or delete a saved signature, then click any PDF page location to place it. Add a checkmark and Add a crossmark immediately enter one-shot placement with fixed black vector marks sized like ordinary 11-point text, using an 11-by-11-point preview and a one-point stroke; they do not modify or persist in the signature library. On macOS, a translucent copy of the selected E-sign item follows the pointer over PDF pages and shows the exact clamped placement before the click; scrolling or leaving the page hides the preview. iOS retains direct tap placement because it has no general hover pointer requirement. Signature previews use a 200-by-80-point container, while mark previews use their compact square; each committed Ink annotation then uses tight bounds around its visible strokes rather than retaining unused canvas space. It starts as opaque black, and Ink palette choices remain opaque so PDFKit and PDFium agree on the serialized appearance. It remains selectable for moving, resizing, deletion, color and thickness changes, Undo, and Redo. Saved signature templates persist in the app's local Application Support container on each device; no cloud synchronization is provided. Draw freehand enters a cross-platform canvas gesture that previews the stroke immediately in red, commits one red Ink annotation when the drag ends, and selects it for editing. On macOS, pressing and holding Shift before clicking anchors a red dot at the current pointer location; moving previews a straight segment, and a Shift-click elsewhere on the same page commits that two-point Ink line. Releasing Shift, leaving the page, scrolling, or cancelling clears an unfinished straight-line preview without disturbing the original drag gesture. Drawings are deleted through the selected-Ink action bar rather than a separate Erase a drawing tool. Comment placement opens a larger multi-line editor on both macOS and iOS. Return inserts a line break, Shift-Return adds the comment, and Escape cancels comment placement or either comment-entry step on macOS.
- Use Highlight even before selecting text. Opening Tools preserves an existing valid PDF selection; otherwise Highlight enters an English selection banner with Apply Highlight and Cancel actions. Return applies a valid selection, Escape cancels, and the Tools panel remains open. Multi-line selections store PDFKit quadrilateral points relative to each highlight annotation's bounds so their geometry survives serialization and reopen.
- Select annotations directly on the page without a separate annotation-editing mode; move, resize, edit supported properties of, and delete them. Selecting a Highlight, Ink stroke, or FreeText annotation presents a compact action bar above it, or below it when the visible top edge leaves insufficient space. Selected FreeText retains the draft editor's one-point, 75%-opaque blue solid rounded frame instead of switching to the shared dashed outline and corner handles; opening its inline editor reuses the editor's own identical frame without drawing a duplicate. The current color appears as a circular button that opens a popover of alternate circular swatches. FreeText also provides a text-size popover and can be deleted from the same bar; its color control updates the font rather than the transparent annotation background. Ink provides a graphical line-thickness popover and preserves the compact line previews while expanding each option's invisible hit shape by 12 points on macOS and 22 points on iOS. A trash button deletes the selected annotation; the controls provide tooltips and accessibility labels. Ink page hit testing also keeps a minimum screen-space tolerance as the PDF zoom changes. The left-panel Edit comment action opens a page-scoped Comment List for the same editing operations. The Comment Editor offers Red, Orange, Yellow, Green, Blue, Indigo, and Purple swatches in that order while preserving the selected opacity; other annotation editors retain their existing palette. On macOS, hovering a note icon suppresses PDFKit's tooltip and opens a dynamically sized Comment Editor popover anchored beside that icon. The pointer can cross from the icon into the editor during a short grace period; a hover-opened editor closes after the pointer leaves it, while a clicked editor remains open until dismissed. iOS retains its sheet presentation. A pure Comment color Apply updates the existing PDFKit annotation and targeted SwiftUI state immediately, then synchronizes and verifies PDFium on the prepared session or finishes that work after the shared background preparation completes. Stale rapid color requests are discarded, and a failed background synchronization restores the previous color and reports the error. Other successful annotation changes update the existing PDFKit document in place to avoid a visible reload. Byte-snapshot rollback and Undo/Redo also synchronize replacement pages into the existing unlocked presentation document instead of replacing it, avoiding an empty-document frame. Pure color changes for comments and highlights may discard and regenerate a fixed normal appearance stream. FreeText font color and size changes discard any fixed appearance stream so PDFKit can regenerate it. Ink color and thickness changes regenerate the PDFKit appearance while preserving annotation-local paths; because PDFium cannot read annotation color when an appearance stream exists, the serialized PDFKit snapshot supplies that scoped color verification. Other fixed-appearance style changes remain disabled.
- Run on-device Vision text recognition on one page or all scanned pages. Pages that already contain selectable text are skipped, and recognized text is reviewed before an invisible searchable text layer is added. Each run retains its original target pages and is rejected if the document changes before review or insertion.
- Unlock encrypted PDFs and preserve encryption during ordinary saves. Empty password submissions are ignored, and locked documents create the PDFium editing session only after a non-empty password is accepted. Protect PDF requires matching nonempty password fields and applies that password to the next explicit Save or Save As. The prepared output is rejected unless PDFKit reports it encrypted and locked, rejects an unrelated password, and accepts the requested password; after a successful write, the open editing session adopts that password for later edits and saves. Remove Password becomes available after an encrypted PDF has been unlocked with its known password, requires explicit confirmation, and uses the next Save or Save As to produce a verified unencrypted PDF. A security-only save updates the verified working bytes and editing session without replacing the content-identical pages already displayed by PDFKit. On macOS, an existing file is saved by its native document object after staging the prepared file-document snapshot, so the app's own Save is not reported back as an external atomic replacement. Later PDFKit annotation serialization is normalized to the active session's security state before verification, preventing the retained presentation document from restoring an earlier password policy.
- Detect the presence of PDF signature objects and require confirmation before the first in-place mutation that may invalidate them.
- Register document mutations and pending text replacements with the focused document Undo manager. The temporary macOS inline text view uses an isolated Undo history that is cleared before the view is removed.

### Experimental or inactive paths

- `PDFKitEditingEngine` is an alternate page-level backend. The normal document path uses `PDFiumEditingEngine`; PDFKit's editing session is currently invoked internally only for document metadata mutation.
- The engine command surface includes document metadata updates, but the current UI does not expose metadata editing directly.
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
- PDFium `chromium/7811`, revision `9e5d491ff73630b6a423689698290650050e7b3f`, with the pinned build patch and three local source patches documented under `Packages/PDFiumBridge/Vendor/Fork/`.
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
  Document/                       ReferenceFileDocument and PDF export wrappers
  Platform/                       PDFKit platform bridge and page thumbnails
  Services/                       Explicit saving, annotation, OCR, shaping, image conversion, and PDF-page image export services
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

The package XCTest suite covers page assembly, encryption behavior, malformed input rejection, annotation color including fixed-appearance Highlight color/opacity and geometry preservation, PDFium's documented inability to inspect an Ink color through the annotation API when an appearance stream exists, page-object editing, single-load batch display enumeration, nested Form isolation, image handling, and searchable regular/bold/italic CoreText overlays. These are package-level tests, not app UI tests.

The `Validation/` directory contains standalone programs for annotation round trips, OCR policy, PNG/JPEG page export, fixture generation, and a larger mixed/protected/truncated PDF corpus. They are not attached to an Xcode test target and must be compiled with the relevant app source files. The exact commands verified during this documentation task are recorded in `TECHNICAL_DOCUMENTATION.md`.

No repository configuration was found for UI tests, CI, linting, formatting, type checking as a separate step, or an additional static-analysis tool. Xcode compiler warnings and analyzers remain enabled through the project build settings.

## Known limitations

- The user interface is currently hard-coded in English and no string catalog or other localization source is checked in.
- App builds target only iOS/iPadOS and macOS. The bundled PDFium XCFramework also contains a Mac Catalyst slice, but Mac Catalyst is not an app target platform.
- OCR is a local Vision workflow, not a full document-layout reconstruction system. It skips any page with nonempty selectable text, processes remaining pages sequentially, and rejects results whose captured document revision is stale.
- Imported images are decoded with ImageIO and capped at 8,192 pixels on their longest dimension. The normal UI imports a flattened BGRA representation.
- Image export renders pages sequentially and enforces per-page dimension, pixel-count, and estimated decoded-memory limits. Encoded output data remains in memory until the multi-file exporter completes, so exporting a very large document at high resolution can still consume substantial aggregate memory.
- Existing text replacement can change page-content implementation strategy: unsupported glyph coverage, complex shaping, or changed bold/italic styling uses a new searchable CoreText Form overlay rather than rewriting the original text object with its font. That path makes the original object invisible and blanks its text before importing the replacement. Before accepting either page-content rewrite, the PDFium bridge serializes and reopens the page, then verifies every non-target text object's path and exact UTF-16 content as well as sampled color metrics. The saved replacement is never implemented as a Square mask or FreeText annotation.
- The bundled PDFium fork converts non-pattern object colors to equivalent RGB, re-emits Shading objects, and regenerates Pattern paint operators while retaining the original Pattern resource object. Colored and uncolored tiling patterns and shading patterns therefore survive existing-text replacement; uncolored operands are normalized through a Pattern/DeviceRGB color space. A rewrite that changes unrelated subset-font text, sampled color, or protected resource counts is rolled back and rejected. The Save operation preserves the original document instead of silently producing a visual annotation replacement. Full Acrobat-style paragraph reflow is not implemented; the CoreText fallback is a searchable vector content layer with the original object's placement transform.
- Inline text changes are pending view state until Save. Closing the document without saving discards them. Save preparation runs on an isolated background document and atomically installs the verified candidate, but file coordination and final UI interaction still occur in their platform save paths. On macOS, the short-lived presentation fallback used before a staged page overlay mounts is noninteractive and is removed or migrated when its page overlay becomes available, or when scrolling or document replacement occurs. Its mask exists only in the live editing UI, is aligned to backing pixels without a fixed horizontal expansion, and is never serialized into the PDF. The app has no automated UI test proving exact font metrics, save-panel interaction, or scrolling behavior for every PDF producer and embedded-font format.
- Page-assembly operations explicitly check PDF permission bit `0x400`. The reviewed source does not provide an equivalent explicit permission guard for every object or annotation mutation; runtime behavior of restricted documents remains unverified.
- Signature handling detects signature objects and warns about invalidation. It does not validate the signer, certificate trust, signed byte ranges, or cryptographic validity. Once granted, invalidation consent lasts for the current open document object.
- Accepted document passwords remain in memory for the open editing session so encrypted data can be reopened during mutation and undo/redo. The source does not deliberately persist them, but it does not provide secure-memory or zeroization guarantees.
- Extracted pages are newly assembled outputs and are opened without a password by the validation path; they are distinct from the explicit “remove password on save” option.
- App Sandbox and Hardened Runtime are enabled in build settings, but a built, signed, and distributed application was not inspected in this documentation task. No explicit entitlements file is present.
- The complete transitive PDFium notice set, final license exposure in the app bundle, export-compliance classification, signing, notarization, device installation, and store behavior remain externally unverified release work.

## License

No project-wide `LICENSE` file or project-wide license declaration was found. Do not assume permission to redistribute the application source solely from third-party notices.

Third-party licensing is documented separately:

- `THIRD_PARTY_NOTICES.md` indexes the bundled dependencies.
- `PDF Editor/NotoSansTC-LICENSE.txt` contains the SIL Open Font License 1.1 text for the bundled font.
- `Packages/PDFiumBridge/Vendor/NOTICE.md` records PDFium provenance and identifies the outstanding requirement to generate complete notices for the pinned build and its transitive components.

## Verification status

Verified in this documentation task through 2026-08-29:

- `PDFiumBridge` package tests: 36 tests executed with 35 passes, 1 skipped local-fixture test, and 0 failures after replacing the XCFramework. The suite includes visible-color retention for ICC/custom ColorSpace, Shading, colored and uncolored tiling Pattern, and shading Pattern regeneration. An earlier run with the then-available real subset-font integrity fixture passed all 32 tests in the previous suite.
- Standalone annotation round-trip and OCR policy validations passed.
- Protected-PDF fixture self-validation passed.
- Phase-six corpus acceptance passed for the 120-page, mixed selectable/scanned content, rotated, protected, and truncated cases.
- Unsigned Debug builds succeeded for macOS, generic iOS Simulator, and generic iOS device destinations.
- Standalone image export validation passed for PNG/JPEG type, 72/144/300 DPI pixel dimensions, 90-degree rotation, multi-page progress and filenames, and the oversized-page limit. The image-export changes also passed unsigned Debug builds for macOS and the generic iOS Simulator destination.
- The latest pending-text Save and Undo flow, embedded-font and multi-line editing preview, background page-object inspection, central PDF scrolling, explicit-save, panel, annotation-style, and no-flash Apply changes were revalidated with Debug builds for macOS and the generic iOS Simulator destination. Exact cursor placement and visual layout remain manual UI checks.
- The macOS native Save As panel path and independent iOS exporter presentation state passed Debug builds for macOS and the generic iOS Simulator destination on 2026-08-28. Actual Save As panel interaction remains a manual UI check.
- The immediate-panel Save As flow, isolated `ReferenceFileDocument` snapshot policy, background Save candidate, and special-resource guard passed unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-28. The former annotation-based text-replacement fallback was removed on 2026-08-29. After the Pattern-capable PDFium rebuild, standalone production-path validation replaced the title in `OBM Timetable 2026.08.29.pdf`, retained all eight Pattern resources, preserved chromatic coverage, reopened with searchable replacement text, and created no FreeText replacement; an app-level runtime Save check remains manual.
- The Save-adjacent Undo/Redo controls, in-place presentation-page synchronization, and deferred SwiftUI `EditorState` publication passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. The absence of a visible flash and the runtime warning during actual Undo/Redo remain manual UI checks.
- The macOS native text-selection routing change passed `git diff --check` and an unsigned arm64 Debug build. Exact drag-selection behavior with real-world PDF text runs remains a manual UI check.
- The pending first-double-click outline and pre-scroll inline commit changes passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination. Exact first-launch timing and visual scroll behavior remain manual macOS UI checks.
- The right-side page-number, total-page, Previous page, and Next page controls passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination. Their exact 44-point visual sizing, rail placement, focus behavior, and runtime page navigation remain manual UI checks.
- The rapid-scroll inspection fix passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. Actual rapid dragging of the scroll bar remains a manual macOS UI check.
- The nonanimated wide-layout Tools-panel resize passed `git diff --check` plus an unsigned macOS Debug build on 2026-08-26. The absence of transient white corner artifacts during actual panel toggling remains a manual macOS UI check.
- The Highlight geometry and standalone selectable-text round trip passed the annotation validation, and the Highlight/Comment keyboard and anchored macOS Comment Editor changes passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. Exact popover placement, hover timing, dynamic editor height, keyboard focus, and PDF selection behavior remain manual UI checks.
- The selected-Highlight color/delete action bar passed `git diff --check` plus unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. A focused PDFiumBridge regression test reproduced and then verified the fix for changing the color of a Highlight with a fixed appearance stream; the complete 27-test package suite and the standalone annotation round trip passed. Exact action-bar placement, popover interaction, tooltips, and deletion behavior remain manual UI checks.
- User-validated macOS runtime behavior: the first committed inline text edit remained visibly continuous through the live-editor-to-page-overlay handoff, with no vertical mask seam. This is scoped visual runtime evidence, not build validation; disk persistence still required explicit Save.
- A macOS UI workflow created and edited a comment, applied a blue color and approximately 36% opacity, and confirmed that the Comment Editor remained stable without resetting after Apply.
- The first-Comment-color path, ordered seven-color Comment palette, and single-load PDFium display enumeration passed `git diff --check`, the 27-test PDFiumBridge suite, the standalone annotation round trip, and unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. Exact first-Apply latency, swatch appearance, and absence of the macOS spinning wait cursor with the reported real-world PDF remain manual UI checks.
- The freehand Ink workflow, red preview/default stroke, removal of the separate Erase a drawing tool, annotation-local path and appearance regeneration, selected-Ink color/thickness/delete action bar, zoom-aware page hit testing, and expanded invisible thickness-option hit shapes passed `git diff --check`, the standalone annotation round trip, the complete 28-test PDFiumBridge suite, and Debug builds for macOS and the generic iOS Simulator destination on 2026-08-26. The rendered validation fixture visibly contained the Ink stroke. Exact drawing feel, action-bar placement, and hit-target behavior remain manual UI checks.
- The macOS Shift straight-line extension for Draw freehand passed `git diff --check`, the standalone annotation round trip, and unsigned Debug builds for macOS and the generic iOS Simulator destination on 2026-08-28. Exact anchor-dot placement, live line preview, Shift-click timing, and interaction feel remain manual UI checks.
- The E-sign checkmark and crossmark paths passed `git diff --check`, Signature Library validation, an annotation round trip covering their tight local Ink geometry and serialization/reopen behavior, and unsigned Debug builds for macOS arm64 and the generic iOS Simulator destination on 2026-08-28. Exact tool-row appearance, macOS pointer-preview alignment, iOS tap placement, and interaction feel remain manual UI checks.
- The protected-PDF open guard passed `git diff --check` on 2026-08-29. It prevents locked documents from starting the background page-object scan before a password is entered and ignores empty password submissions. Runtime confirmation with an actual protected PDF remains a manual UI check.
- The key-window-gated macOS document-window fill passed `git diff --check` on 2026-08-30. Confirming that File → Open retains the normal arrow cursor during and after the native selection panel remains a manual macOS UI check.
- The rebuilt macOS, iOS device, iOS Simulator, and Mac Catalyst PDFium binaries passed architecture, platform load-command, install-name, exported-symbol, strict ad-hoc signature, and SHA-256 checks; the final hashes are recorded in `Packages/PDFiumBridge/Vendor/NOTICE.md`.

The exact commands and boundaries are recorded in `TECHNICAL_DOCUMENTATION.md`. No automated app UI test, physical-device run, signed app build, archive, installation, or external-service validation was performed. Source, package tests, the scoped macOS UI evidence, and the verified local PDFium rebuild do not establish App Store compliance, independent clean-environment reproducibility, third-party vulnerability status, or complete license compliance.
