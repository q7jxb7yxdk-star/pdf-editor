import Foundation
import SwiftASN1
@_spi(CMS) @_spi(FixedExpiryValidationTime) import X509

/// All use of Swift Certificates' CMS SPI is isolated here and pinned to 1.20.0.
/// SecKey signing stays inside Security.framework; no private-key export occurs.
nonisolated enum PDFCMSService {
    static func sign(_ content: Data, identity: PDFSigningIdentity, signingDate: Date) async throws -> Data {
        guard signingDate >= identity.summary.validFrom, signingDate <= identity.summary.validUntil else {
            throw PDFDigitalSignatureError.certificateNotValid
        }
        let cms = Data(try CMS.sign(
            content,
            signatureAlgorithm: identity.signatureAlgorithm,
            additionalIntermediateCertificates: identity.intermediates,
            certificate: identity.certificate,
            privateKey: identity.privateKey,
            signingTime: signingDate,
            detached: true
        ))
        try await verify(cms, content: content, identity: identity, signingDate: signingDate)
        return cms
    }

    static func verify(_ cms: Data, content: Data, identity: PDFSigningIdentity, signingDate: Date) async throws {
        // This is a local integrity check with the user's selected leaf as an
        // explicit anchor. It does NOT establish system/public certificate trust,
        // revocation status, a trusted timestamp, or long-term validity.
        let parsed = try CMSSignature(derEncoded: Array(cms))
        let signers = try parsed.signers
        guard signers.count == 1, signers[0].certificate == identity.certificate else {
            throw PDFDigitalSignatureError.signatureVerificationFailed
        }
        let result = await CMS.isValidSignature(
            dataBytes: content,
            signatureBytes: cms,
            trustRoots: CertificateStore([identity.certificate])
        ) {
            RFC5280Policy(fixedExpiryValidationTime: signingDate)
        }
        guard case .success = result else { throw PDFDigitalSignatureError.signatureVerificationFailed }
    }
}
