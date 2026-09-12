import Foundation

nonisolated struct PDFSigningCertificateSummary: Equatable, Sendable {
    let signerName: String
    let fingerprintSHA256: String
    let validFrom: Date
    let validUntil: Date
    let algorithm: String
}

nonisolated struct PDFDigitalSignatureResult: Sendable {
    let data: Data
    let certificate: PDFSigningCertificateSummary
    let fieldID: UUID
    let fieldName: String
    let signedAt: Date
}

nonisolated enum PDFDigitalSignatureError: LocalizedError {
    case unsupportedDocument(String)
    case invalidStructure
    case fieldNotEligible
    case alreadySigned
    case identityImportFailed
    case incorrectPassword
    case ambiguousIdentity
    case unsupportedIdentity
    case certificateNotValid
    case certificateCannotSign
    case memoryImportUnavailable
    case signatureTooLarge
    case signatureVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument(let detail):
            "This PDF cannot be digitally signed: \(detail)"
        case .invalidStructure:
            "The PDF structure could not be verified safely. The original document has not been changed."
        case .fieldNotEligible:
            "Select an empty signature field created by PDF Editor. The field must be registered on one page and must not be locked."
        case .alreadySigned:
            "This document already contains a digital signature. Adding another signature is not supported yet."
        case .identityImportFailed:
            "The signing identity could not be read. Select a valid PKCS#12 (.p12 or .pfx) file containing a certificate and its private key."
        case .incorrectPassword:
            "The identity password is incorrect, or the PKCS#12 file could not be authenticated."
        case .ambiguousIdentity:
            "The PKCS#12 file must contain exactly one signing identity. Export the desired identity to a separate file."
        case .unsupportedIdentity:
            "Use an RSA signing identity with a 2048–8192-bit key, or an ECDSA identity with a P-256, P-384, or P-521 key."
        case .certificateNotValid:
            "The signing certificate is expired or is not yet valid. Check the certificate and your device date."
        case .certificateCannotSign:
            "This certificate's key usage does not permit digital signatures."
        case .memoryImportUnavailable:
            "Importing a signing identity without storing it in Keychain requires macOS 15 or later."
        case .signatureTooLarge:
            "The certificate chain is too large for the reserved signature space."
        case .signatureVerificationFailed:
            "The generated digital signature did not pass verification. No signed copy has been produced."
        }
    }
}
