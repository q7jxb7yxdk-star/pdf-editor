# PDF Editor Release Checklist

## Required before distribution

- [x] Add the user-supplied macOS and iOS App Icon assets.
- [ ] Generate and bundle the complete PDFium and transitive dependency notice
      set for revision `9e5d491ff73630b6a423689698290650050e7b3f`.
- [ ] Confirm the final bundle exposes the Noto Sans CJK SIL OFL license.
- [ ] Review encryption export-compliance answers for the intended store and
      distribution channel.
- [ ] Choose the final bundle identifier, version, build number, signing team,
      sandbox entitlements, and document-handler rank.

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

Archive, signing, notarization, physical-device installation, TestFlight, and
store submission require separate approval and are intentionally outside the
automated development workflow.
