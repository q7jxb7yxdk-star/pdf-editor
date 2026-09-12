import Foundation
import CryptoKit
@preconcurrency import Security
import SwiftASN1
import X509

/// A short-lived, opaque identity. Do not put this in document state, preferences,
/// logs, or an undo stack. Releasing it releases the imported in-memory SecKey.
nonisolated struct PDFSigningIdentity: Sendable {
    let summary: PDFSigningCertificateSummary
    let certificate: Certificate
    let intermediates: [Certificate]
    let privateKey: Certificate.PrivateKey
    let signatureAlgorithm: Certificate.SignatureAlgorithm
}

nonisolated enum PDFSigningIdentityService {
    static func load(pkcs12: Data, password: String, at date: Date = Date()) throws -> PDFSigningIdentity {
        guard !pkcs12.isEmpty, pkcs12.count <= 16 * 1024 * 1024 else {
            throw PDFDigitalSignatureError.identityImportFailed
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, iOS 18, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            #if os(macOS)
            // Never fall back to the legacy macOS import, which writes Keychain.
            throw PDFDigitalSignatureError.memoryImportUnavailable
            #endif
            // iOS SecPKCS12Import has always returned in-memory objects only.
        }
        var imported: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &imported)
        // No password or underlying error descriptions are logged or retained.
        options.removeAll(keepingCapacity: false)
        guard status == errSecSuccess else {
            throw status == errSecAuthFailed
                ? PDFDigitalSignatureError.incorrectPassword
                : PDFDigitalSignatureError.identityImportFailed
        }
        guard let items = imported as? [[String: Any]], items.count == 1,
              let identityValue = items[0][kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw PDFDigitalSignatureError.ambiguousIdentity
        }
        let identity = identityValue as! SecIdentity
        var securityCertificate: SecCertificate?
        var securityKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &securityCertificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &securityKey) == errSecSuccess,
              let securityCertificate, let securityKey,
              let attributes = SecKeyCopyAttributes(securityKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            throw PDFDigitalSignatureError.identityImportFailed
        }
        let signatureAlgorithm: Certificate.SignatureAlgorithm
        let securityAlgorithm: SecKeyAlgorithm
        let algorithm: String
        if keyType == kSecAttrKeyTypeRSA as String, (2048...8192).contains(bits) {
            signatureAlgorithm = .sha256WithRSAEncryption
            securityAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
            algorithm = "SHA-256 / RSA \(bits)"
        } else if keyType == kSecAttrKeyTypeECSECPrimeRandom as String, [256, 384, 521].contains(bits) {
            signatureAlgorithm = .ecdsaWithSHA256
            securityAlgorithm = .ecdsaSignatureMessageX962SHA256
            algorithm = "SHA-256 / ECDSA P-\(bits)"
        } else {
            throw PDFDigitalSignatureError.unsupportedIdentity
        }
        guard SecKeyIsAlgorithmSupported(securityKey, .sign, securityAlgorithm) else {
            throw PDFDigitalSignatureError.unsupportedIdentity
        }
        let certificateDER = SecCertificateCopyData(securityCertificate) as Data
        let certificate = try Certificate(derEncoded: Array(certificateDER))
        guard date >= certificate.notValidBefore, date <= certificate.notValidAfter else {
            throw PDFDigitalSignatureError.certificateNotValid
        }
        if let usage = try certificate.extensions.keyUsage, !usage.digitalSignature && !usage.nonRepudiation {
            throw PDFDigitalSignatureError.certificateCannotSign
        }
        let privateKey = try Certificate.PrivateKey(securityKey)
        guard privateKey.publicKey == certificate.publicKey else {
            throw PDFDigitalSignatureError.identityImportFailed
        }
        let securityChain = items[0][kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        guard securityChain.count <= 16 else { throw PDFDigitalSignatureError.signatureTooLarge }
        var seen = Set<Data>([certificateDER])
        let intermediates = try securityChain.compactMap { item -> Certificate? in
            let der = SecCertificateCopyData(item) as Data
            guard seen.insert(der).inserted else { return nil }
            return try Certificate(derEncoded: Array(der))
        }
        let name = (SecCertificateCopySubjectSummary(securityCertificate) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = PDFSigningCertificateSummary(
            signerName: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Certificate holder",
            fingerprintSHA256: SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined(separator: ":"),
            validFrom: certificate.notValidBefore,
            validUntil: certificate.notValidAfter,
            algorithm: algorithm
        )
        return PDFSigningIdentity(summary: summary, certificate: certificate, intermediates: intermediates,
                                  privateKey: privateKey, signatureAlgorithm: signatureAlgorithm)
    }
}
