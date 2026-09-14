# Export Compliance Assessment

Assessment date: 2026-09-14

This is a technical inventory for App Store Connect, not legal advice. The
developer remains responsible for the final answers, distribution territories,
and any government filings.

## Repository evidence

PDF Editor uses or contains cryptography in these paths:

- `PDFSigningIdentityService` imports PKCS#12 identities and uses Apple
  CryptoKit and Security.framework for SHA-256 fingerprints and RSA/ECDSA
  signing.
- `PDFCMSService` creates standards-based CMS signatures while private-key
  operations remain in Security.framework.
- Swift Crypto supplies its `Crypto` API through CryptoKit on Apple platforms;
  its BoringSSL targets are conditionally excluded for Darwin in the pinned
  package manifest.
- The bundled PDFium engine independently implements standard PDF security
  algorithms, including RC4 and AES-128/AES-256 encryption/decryption and SHA
  digest operations. This code is part of the shipped framework rather than an
  Apple operating-system crypto service.
- PDFKit can create password-protected documents and open encrypted PDFs.

No proprietary or unpublished cryptographic algorithm was found in the
reviewed source or pinned dependencies.

## App Store Connect determination and Info.plist declaration

Both platform property lists set:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This does not claim that the app contains no cryptography. It records that the
app's encryption is exempt from App Store Connect documentation for the chosen
storefronts. `ITSEncryptionExportComplianceCode` is omitted because App Store
Connect determined that no documents need to be uploaded and therefore did not
issue a code.

Apple states that apps using standard algorithms outside the operating system
may require a French encryption declaration when distributed in France. In the
2026-09-14 App Store Connect questionnaire, the developer selected that the app
will not be distributed in France after declaring standard cryptography outside
Apple's operating system. App Store Connect displayed that no documents need to
be uploaded. Preserve these answers and the matching storefront restriction:

1. Confirm that the app uses encryption.
2. Confirm that it does not contain proprietary or non-standard algorithms.
3. Confirm that it contains standard cryptography outside Apple's operating
   system because PDFium implements PDF password security.
4. Answer No to distribution in France.
5. Exclude France in Pricing and Availability before submission.

Reassess this inventory and repeat App Store Connect's determination whenever
PDFium, signing dependencies, encryption behavior, or storefront availability
changes. Distribution in France requires a new determination before the
storefront is enabled.

## Apple references

- [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/)
- [Determine and upload app encryption documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)
- [`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)
