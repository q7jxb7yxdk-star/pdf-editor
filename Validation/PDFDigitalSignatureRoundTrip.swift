#if PDF_DIGITAL_SIGNATURE_STANDALONE_VALIDATION
import Foundation
import CoreGraphics
import Darwin

/// Opt-in, local-only integration harness. Compile explicitly with the signing
/// core and the project's pinned X509 dependency; it is not part of the app.
/// Usage: <validator> <throwaway-test-identity.p12> <new-output-directory>
/// It prompts for the password (never pass it as a command-line argument).
/// Use only a disposable test identity, never a production signing credential.
/// After it succeeds, independently verify signed.pdf using pyHanko and render
/// its signature appearance using Poppler. Trust the disposable certificate only
/// for that validation invocation, never by changing the system trust store.
@main
struct PDFDigitalSignatureRoundTrip {
    private static let fieldID = UUID(uuidString: "AFE24343-B726-41D0-BD63-60184294FA31")!
    private static let fieldName = "Signature1"

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw Failure("Expected a test .p12 path and a NEW output directory") }
        let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure("Output directory already exists; validation never overwrites files")
        }
        guard let passwordBuffer = getpass("Disposable test identity password: ") else {
            throw Failure("Could not read the test password")
        }
        var password = String(cString: passwordBuffer)
        let passwordLength = strlen(passwordBuffer)
        memset(passwordBuffer, 0, passwordLength)
        let identity = try PDFSigningIdentityService.load(
            pkcs12: Data(contentsOf: URL(fileURLWithPath: arguments[1])), password: password
        )
        password.removeAll(keepingCapacity: false)
        let unsigned = fixture()
        try PDFDigitalSignatureWriter.preflight(data: unsigned, fieldID: fieldID, fieldName: fieldName)
        try reject(fixture(marker: false), "Foreign field")
        try reject(fixture(fieldExtra: "/Lock << /Action /All >>"), "Locked field")
        try reject(fixture(fieldExtra: "/Ff 1"), "Read-only field")
        try reject(fixture(fieldExtra: "/V << /Type /Sig >>"), "Existing signature value")
        try reject(fixture(fieldExtra: "/Byte#52ange [0 1 2 3]"), "Escaped ByteRange key")
        try reject(fixture(fieldExtra: "/T (DuplicateName)"), "Duplicate dictionary key")
        try reject(fixture(trailerExtra: "/Encrypt 7 0 R"), "Encryption")
        try reject(fixture(trailerExtra: "/XRefStm 12"), "Hybrid xref")
        try reject(fixture(trailerExtra: "/Prev -1"), "Invalid previous revision")
        try reject(fixture(duplicatePlacement: true), "Duplicate widget placement")
        try reject(fixture(catalogExtra: "/Perms << /DocMDP 7 0 R >>"), "Certification permissions")
        try reject(unsigned + Data("TRAILING PAYLOAD".utf8), "Unaccounted trailing payload")

        let result = try await PDFDigitalSignatureWriter.sign(
            data: unsigned, fieldID: fieldID, fieldName: fieldName, identity: identity,
            reason: "Disposable local interoperability validation"
        )
        try require(result.data.prefix(unsigned.count).elementsEqual(unsigned), "Original revision changed")
        try reject(result.data, "Second signature")
        let extracted = try extractedSignature(result.data)
        try await PDFCMSService.verify(extracted.cms, content: extracted.content, identity: identity, signingDate: result.signedAt)
        var tampered = extracted.content
        tampered[10] ^= 1
        do {
            try await PDFCMSService.verify(extracted.cms, content: tampered, identity: identity, signingDate: result.signedAt)
            throw Failure("Tampered content unexpectedly verified")
        } catch is PDFDigitalSignatureError { /* Expected integrity rejection. */ }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try unsigned.write(to: destination.appendingPathComponent("unsigned.pdf"), options: .withoutOverwriting)
        let signedURL = destination.appendingPathComponent("signed.pdf")
        try result.data.write(to: signedURL, options: .withoutOverwriting)
        let copyURL = destination.appendingPathComponent("signed-copy.pdf")
        try result.data.write(to: copyURL, options: .withoutOverwriting)
        try require(try Data(contentsOf: signedURL) == Data(contentsOf: copyURL), "Byte-preserving Save As changed bytes")
        print("PASS: strict preflight rejection cases, detached CMS, whole-file ByteRange, tamper rejection, and byte-preserving copy")
        print("Independent pyHanko validation and visual rendering remain required.")
    }

    private static func reject(_ data: Data, _ label: String) throws {
        do {
            try PDFDigitalSignatureWriter.preflight(data: data, fieldID: fieldID, fieldName: fieldName)
            throw Failure("\(label) was accepted")
        } catch is PDFDigitalSignatureError { /* Expected bounded rejection. */ }
    }

    private static func fixture(marker: Bool = true, fieldExtra: String = "", trailerExtra: String = "",
                                duplicatePlacement: Bool = false, catalogExtra: String = "") -> Data {
        let content = "q 0.92 g 30 30 535 782 re f Q"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R \(catalogExtra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << >> /Contents 4 0 R /Annots [5 0 R \(duplicatePlacement ? "5 0 R" : "")] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (\(fieldName)) /Rect [50 650 330 710] /P 3 0 R \(marker ? "/PDFEditorFormID (\(fieldID.uuidString))" : "") \(fieldExtra) >>",
            "<< /Fields [5 0 R] >>"
        ]
        var output = Data("%PDF-1.7\n%Fixture\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let startXRef = output.count
        output.append(contentsOf: "xref\n0 7\n0000000000 65535 f \n".utf8)
        for offset in offsets { output.append(contentsOf: String(format: "%010lld 00000 n \n", Int64(offset)).utf8) }
        output.append(contentsOf: "trailer\n<< /Size 7 /Root 1 0 R \(trailerExtra) >>\nstartxref\n\(startXRef)\n%%EOF\n".utf8)
        return output
    }

    /// Use Apple's independent PDF parser to read the actual output ranges.
    private static func extractedSignature(_ data: Data) throws -> (cms: Data, content: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let catalog = document.catalog else { throw Failure("CoreGraphics could not reopen signed PDF") }
        var form: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        var field: CGPDFDictionaryRef?
        var signature: CGPDFDictionaryRef?
        var range: CGPDFArrayRef?
        var contents: CGPDFStringRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields,
              CGPDFArrayGetDictionary(fields, 0, &field), let field,
              CGPDFDictionaryGetDictionary(field, "V", &signature), let signature,
              CGPDFDictionaryGetArray(signature, "ByteRange", &range), let range,
              CGPDFArrayGetCount(range) == 4,
              CGPDFDictionaryGetString(signature, "Contents", &contents), let contents,
              let bytes = CGPDFStringGetBytePtr(contents) else { throw Failure("Missing signature dictionary") }
        var values = [CGPDFInteger](repeating: 0, count: 4)
        for index in 0..<4 { try require(CGPDFArrayGetInteger(range, index, &values[index]), "Invalid ByteRange integer") }
        try require(values[0] == 0 && values[1] > 0 && values[2] > values[1] && values[3] >= 0 && values[2] + values[3] == data.count,
                    "ByteRange does not cover the whole file")
        var content = data.subdata(in: 0..<values[1])
        content.append(data.subdata(in: values[2]..<data.count))
        let paddedCMS = Array(UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(contents)))
        // Read the outer DER length; do not trim legitimate trailing zero bytes.
        guard paddedCMS.count > 2, paddedCMS[0] == 0x30 else { throw Failure("Invalid CMS DER") }
        var bodyLength = Int(paddedCMS[1]); var headerLength = 2
        if bodyLength & 0x80 != 0 {
            let octets = bodyLength & 0x7F
            guard (1...4).contains(octets), paddedCMS.count >= 2 + octets else { throw Failure("Invalid CMS length") }
            bodyLength = 0
            for index in 0..<octets { bodyLength = bodyLength * 256 + Int(paddedCMS[2 + index]) }
            headerLength += octets
        }
        let total = headerLength + bodyLength
        try require(total <= paddedCMS.count && paddedCMS.dropFirst(total).allSatisfy { $0 == 0 }, "Invalid CMS padding")
        return (Data(paddedCMS.prefix(total)), content)
    }

    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
