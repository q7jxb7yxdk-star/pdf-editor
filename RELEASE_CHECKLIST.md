# PDF Editor Release Checklist

## Required before distribution

- [x] Add the user-supplied macOS and iOS App Icon assets.
- [x] Add the public privacy-policy document, in-app links, and app/framework
      privacy manifests for the currently identified required-reason APIs.
- [x] Use a one-to-three-component `CFBundleVersion` in every PDFium framework
      slice and refresh its ad-hoc signature and recorded binary hash.
- [x] Rebuild the iOS device PDFium slice with full DWARF information and add
      its UUID-matched dSYM to the XCFramework debug-symbols path.
- [x] Generate and add the complete PDFium and transitive dependency notice
      set for revision `9e5d491ff73630b6a423689698290650050e7b3f`.
- [x] Add the Noto Sans CJK SIL OFL and pinned Swift package notices to the
      bundled Acknowledgements resource and provide an in-app viewer.
- [x] Inventory bundled cryptography, declare documentation-exempt encryption
      in both platform plists, and record App Store Connect's no-document result
      for distribution that excludes France.
- [x] Review and preserve the current bundle identifier, version/build, signing
      team, App Sandbox/Hardened Runtime, and alternate PDF-handler rank.
- [ ] Save the App Store Connect encryption declaration and exclude France in
      Pricing and Availability; no documentation or compliance code is required
      for the recorded storefront selection.
- [ ] Confirm the registered iOS and macOS App Store records match bundle ID
      `com.sunny.pdf-editor`, version `1.1.1`, and the intended signing team.

## Automated acceptance

- [ ] Run `swift test --package-path Packages/PDFiumBridge`.
- [ ] Compile and run `Validation/OCRPolicyValidation.swift`.
- [ ] Compile and run `Validation/PhaseSixCorpus.swift` followed by
      `Validation/PhaseSixAcceptance.swift`.
- [ ] Render the generated valid PDF fixtures and inspect the first, middle,
      last, rotated, scanned-content, and password-protected pages.
- [ ] Build the macOS Apple Silicon, generic iOS Simulator, and generic iOS
      device destinations without signing.
- [ ] Run `git diff --check` and confirm only intended files changed.
- [ ] Generate the Archive privacy report and confirm the final app and embedded
      frameworks contain the intended manifests without undeclared API use.
- [ ] Inspect the final Archive and confirm `PDFium.framework.dSYM` is present
      and its arm64 UUID matches the archived `PDFium.framework` binary.
- [ ] Inspect the final Archive and confirm `THIRD_PARTY_NOTICES.txt` is bundled
      and the Acknowledgements view displays its complete contents.

## Manual acceptance

- [ ] Open a normal PDF, a password-protected PDF, and a 100+ page PDF.
- [ ] Confirm PDF, image-add, and image-replacement pickers each open once and
      cancellation does not display an error.
- [ ] Confirm real PDF text can be selected and edited without OCR.
- [ ] Confirm scanned pages use OCR while pages with selectable text are
      skipped.
- [ ] Confirm page editing, merge, split, annotation, signature, Undo, Redo,
      save, close, and reopen all preserve the expected result.
- [ ] Use Protect PDF with matching passwords, save, close, and confirm the
      output rejects a wrong password and reopens with the requested password.
- [ ] Confirm mismatched Protect PDF passwords cannot be submitted and
      cancelling Save does not write or discard the pending protection request.
- [ ] Unlock a protected PDF with its known password, select Remove Password,
      save without a visible page flash, close, and confirm the output reopens
      without a password.
- [ ] Inspect iPhone, iPad, and macOS layouts with accessibility text sizes.

Archive, signing, notarization, physical-device installation, and store
submission require separate approval. TestFlight is intentionally excluded
from this release workflow.
