import CoreGraphics
import Foundation
import PDFKit

#if BOOKMARK_PDFIUM_VALIDATION
import CPDFiumBridge
#endif

@main
struct BookmarkRoundTripValidation {
    static func main() throws {
#if BOOKMARK_PDFIUM_VALIDATION
        PEPDFLibraryInitialize()
        defer { PEPDFLibraryDestroy() }
#endif
        let service = PDFBookmarkService()
        let writer = PDFIncrementalBookmarkWriter()
        let fixtureData = makeDocumentData(pageCount: 3)

        let (initialData, reopened) = try incrementalRoundTrip(
            sourceData: fixtureData,
            service: service,
            writer: writer
        ) { document in
            try service.addBookmark(title: "Introduction", pageIndex: 0, to: document)
            try service.addBookmark(title: "附錄", pageIndex: 2, to: document)

            guard let first = document.outlineRoot?.child(at: 0),
                  let secondPage = document.page(at: 1) else {
                throw ValidationError.fixtureCreationFailed
            }
            let section = PDFOutline()
            section.label = "Section 1"
            section.destination = PDFDestination(
                page: secondPage,
                at: CGPoint(x: 0, y: secondPage.bounds(for: .cropBox).maxY)
            )
            first.insertChild(section, at: 0)
        }

        let initial = service.snapshots(in: reopened)
        precondition(initial.count == 2)
        precondition(initial[0].title == "Introduction")
        precondition(initial[0].pageIndex == 0)
        precondition(initial[0].children.first?.title == "Section 1")
        precondition(initial[0].children.first?.pageIndex == 1)
        precondition(initial[1].title == "附錄")
        precondition(initial[1].pageIndex == 2)

        let (renamedData, renamedDocument) = try incrementalRoundTrip(
            sourceData: initialData,
            service: service,
            writer: writer
        ) { document in
            try service.renameBookmark(
                at: PDFBookmarkPath(indices: [0, 0]),
                title: "First Section",
                in: document
            )
        }
        let renamed = service.snapshots(in: renamedDocument)
        precondition(renamed.count == 2)
        precondition(renamed[0].children.first?.title == "First Section")

        let (finalData, finalDocument) = try incrementalRoundTrip(
            sourceData: renamedData,
            service: service,
            writer: writer
        ) { document in
            try service.deleteBookmark(
                at: PDFBookmarkPath(indices: [1]),
                in: document
            )
        }
        let final = service.snapshots(in: finalDocument)
        precondition(final.count == 1)
        precondition(final[0].title == "Introduction")
        precondition(final[0].children.first?.title == "First Section")
        precondition(final[0].children.first?.pageIndex == 1)

        let (_, emptyDocument) = try incrementalRoundTrip(
            sourceData: finalData,
            service: service,
            writer: writer
        ) { document in
            try service.deleteBookmark(
                at: PDFBookmarkPath(indices: [0]),
                in: document
            )
        }
        let emptySnapshots = service.snapshots(in: emptyDocument)
        if !emptySnapshots.isEmpty {
            FileHandle.standardError.write(
                Data("Unexpected final snapshots: \(emptySnapshots)\n".utf8)
            )
            throw ValidationError.roundTripFailed
        }

        try validateEncryptedRejection(service: service, writer: writer)
#if BOOKMARK_PDFIUM_VALIDATION
        try validatePDFKitOnlyFallback(service: service, writer: writer)
        print("PDFKit-only fallback validation passed (PDFium error 3 source).")
        try validateRewriteRecovery(service: service, writer: writer)
        print("PDFKit rewrite recovery passed (injected error 3; add, rename, delete; form values; PDFium export).")
#endif

        print(
            "Incremental bookmark validation passed (sequential add, rename, and " +
            "delete including the final item; nested outlines; Unicode titles; page destinations; " +
            "encrypted-document rejection)."
        )
    }

    private static func makeDocument(pageCount: Int) throws -> PDFDocument {
        guard let document = PDFDocument(data: makeDocumentData(pageCount: pageCount)) else {
            throw ValidationError.fixtureCreationFailed
        }
        return document
    }

    private static func makeDocumentData(
        pageCount: Int,
        leadingWhitespaceCount: Int = 0
    ) -> Data {
        let pageObjectStart = 3
        let pageReferences = (0..<pageCount)
            .map { "\(pageObjectStart + $0) 0 R" }
            .joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pageReferences)] /Count \(pageCount) >>",
        ]
        for _ in 0..<pageCount {
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"
            )
        }
        var pdf = String(repeating: " ", count: leadingWhitespaceCount) + "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private static func validateEncryptedRejection(
        service: PDFBookmarkService,
        writer: PDFIncrementalBookmarkWriter
    ) throws {
        let document = try makeDocument(pageCount: 1)
        try service.addBookmark(title: "Protected", pageIndex: 0, to: document)
        let password = "bookmark-test"
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        guard var protectedData = document.dataRepresentation(options: options) else {
            throw ValidationError.encryptionFailed
        }
#if BOOKMARK_PDFIUM_VALIDATION
        protectedData = try pdfiumRoundTrip(protectedData, password: password)
#endif
        guard let protectedDocument = PDFDocument(data: protectedData),
              protectedDocument.isEncrypted,
              protectedDocument.isLocked,
              protectedDocument.unlock(withPassword: password) else {
            throw ValidationError.encryptionFailed
        }
        try service.renameBookmark(
            at: PDFBookmarkPath(indices: [0]),
            title: "Renamed Protected",
            in: protectedDocument
        )
        do {
            _ = try writer.write(
                sourceData: protectedData,
                bookmarks: service.snapshots(in: protectedDocument)
            )
            throw ValidationError.encryptionFailed
        } catch PDFIncrementalBookmarkWriterError.encryptedDocumentUnsupported {
            // Expected: incremental outline strings require the document's
            // object encryption key and must never be appended in plaintext.
        }
    }

    private static func incrementalRoundTrip(
        sourceData: Data,
        service: PDFBookmarkService,
        writer: PDFIncrementalBookmarkWriter,
        mutation: (PDFDocument) throws -> Void
    ) throws -> (Data, PDFDocument) {
        guard let workingDocument = PDFDocument(data: sourceData) else {
            throw ValidationError.roundTripFailed
        }
        try mutation(workingDocument)
        let expected = service.snapshots(in: workingDocument)
        let incrementallyUpdated = try writer.write(
            sourceData: sourceData,
            bookmarks: expected
        )
        precondition(incrementallyUpdated.starts(with: sourceData))

        guard let directlyReopened = PDFDocument(data: incrementallyUpdated),
              service.snapshots(in: directlyReopened) == expected else {
            throw ValidationError.roundTripFailed
        }
#if BOOKMARK_PDFIUM_VALIDATION
        let data = try pdfiumRoundTrip(incrementallyUpdated, password: nil)
#else
        let data = incrementallyUpdated
#endif
        guard let reopened = PDFDocument(data: data),
              service.snapshots(in: reopened) == expected else {
            throw ValidationError.roundTripFailed
        }
        return (data, reopened)
    }

#if BOOKMARK_PDFIUM_VALIDATION
    private static func validateRewriteRecovery(
        service: PDFBookmarkService,
        writer: PDFIncrementalBookmarkWriter
    ) throws {
        let document = try makeDocument(pageCount: 2)
        guard let page = document.page(at: 1) else {
            throw ValidationError.fixtureCreationFailed
        }
        let field = PDFAnnotation(
            bounds: CGRect(x: 40, y: 50, width: 200, height: 24),
            forType: .widget,
            withProperties: nil
        )
        field.widgetFieldType = .text
        field.fieldName = "bookmark_recovery"
        field.widgetStringValue = "保留欄位值"
        page.addAnnotation(field)
        guard var sourceData = document.dataRepresentation() else {
            throw ValidationError.fixtureCreationFailed
        }
        let forms = PDFAcroFormService()
        for step in 0..<3 {
            guard let working = PDFDocument(data: sourceData) else {
                throw ValidationError.roundTripFailed
            }
            let fields = forms.snapshots(in: working)
            switch step {
            case 0:
                try service.addBookmark(title: "Recovery", pageIndex: 1, to: working)
            case 1:
                try service.renameBookmark(
                    at: PDFBookmarkPath(indices: [0]), title: "Recovered", in: working
                )
            default:
                try service.deleteBookmark(at: PDFBookmarkPath(indices: [0]), in: working)
            }
            let expected = service.snapshots(in: working)
            let incremental = try writer.write(sourceData: sourceData, bookmarks: expected)
            // Inject a rejected candidate, without corrupting the working
            // document that supplies the fallback. This is not a reproduction
            // of the user's as-yet-unidentified malformed revision.
            var rejected = Data(repeating: 0x20, count: 2_048)
            rejected.append(incremental)
            guard pdfiumOpenErrorCode(rejected) == 3,
                  let rewritten = working.dataRepresentation(),
                  pdfiumOpenErrorCode(rewritten) == 0 else {
                throw ValidationError.roundTripFailed
            }
            let exported = try pdfiumRoundTrip(rewritten, password: nil)
            for candidate in [rewritten, exported] {
                guard let reopened = PDFDocument(data: candidate),
                      !reopened.isEncrypted,
                      reopened.pageCount == working.pageCount,
                      service.snapshots(in: reopened) == expected,
                      forms.snapshots(in: reopened).count == fields.count else {
                    throw ValidationError.roundTripFailed
                }
                try forms.verify(fields, in: candidate, password: nil)
                for index in 0..<working.pageCount {
                    guard let before = working.page(at: index),
                          let after = reopened.page(at: index),
                          before.rotation == after.rotation,
                          before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox),
                          before.bounds(for: .cropBox) == after.bounds(for: .cropBox),
                          before.annotations.count == after.annotations.count,
                          PDFPageResourceIntegrityService.preservesPageResources(
                              from: sourceData, to: candidate, pageIndex: index
                          ) else {
                        throw ValidationError.roundTripFailed
                    }
                }
            }
            sourceData = rewritten
        }
    }

    private static func validatePDFKitOnlyFallback(
        service: PDFBookmarkService,
        writer: PDFIncrementalBookmarkWriter
    ) throws {
        // PDFKit scans past this non-standard leading whitespace while PDFium
        // rejects the file because its PDF header is outside the permitted
        // prefix. The bookmark writer must still preserve and update it.
        let sourceData = makeDocumentData(
            pageCount: 1,
            leadingWhitespaceCount: 2_048
        )
        guard pdfiumOpenErrorCode(sourceData) == 3,
              let workingDocument = PDFDocument(data: sourceData) else {
            throw ValidationError.pdfKitOnlyFixtureFailed
        }
        try service.addBookmark(
            title: "PDFKit fallback",
            pageIndex: 0,
            to: workingDocument
        )
        let expected = service.snapshots(in: workingDocument)
        let updatedData = try writer.write(
            sourceData: sourceData,
            bookmarks: expected
        )
        guard updatedData.starts(with: sourceData),
              let reopened = PDFDocument(data: updatedData),
              reopened.pageCount == workingDocument.pageCount,
              service.snapshots(in: reopened) == expected,
              PDFPageResourceIntegrityService.preservesPageResources(
                  from: sourceData,
                  to: updatedData,
                  pageIndex: 0
              ) else {
            throw ValidationError.roundTripFailed
        }
    }

    private static func pdfiumOpenErrorCode(_ data: Data) -> UInt32 {
        var errorCode: UInt32 = 0
        let document = data.withUnsafeBytes { bytes in
            PEPDFDocumentCreate(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                nil,
                &errorCode
            )
        }
        if let document {
            PEPDFDocumentClose(document)
            return 0
        }
        return errorCode
    }

    private static func pdfiumRoundTrip(
        _ data: Data,
        password: String?
    ) throws -> Data {
        var errorCode: UInt32 = 0
        let document = data.withUnsafeBytes { bytes in
            let createDocument: (UnsafePointer<CChar>?) -> PEPDFDocumentRef? = {
                PEPDFDocumentCreate(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    $0,
                    &errorCode
                )
            }
            if let password {
                return password.withCString(createDocument)
            }
            return createDocument(nil)
        }
        guard let document else {
            throw ValidationError.pdfiumOpenFailed(errorCode)
        }
        defer { PEPDFDocumentClose(document) }

        var outputBytes: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        guard PEPDFDocumentCopyData(
            document,
            false,
            false,
            &outputBytes,
            &outputLength
        ), let outputBytes else {
            throw ValidationError.pdfiumExportFailed
        }
        defer { PEPDFFree(outputBytes) }
        return Data(bytes: outputBytes, count: outputLength)
    }
#endif
}

private enum ValidationError: Error {
    case fixtureCreationFailed
    case roundTripFailed
    case encryptionFailed
#if BOOKMARK_PDFIUM_VALIDATION
    case pdfiumOpenFailed(UInt32)
    case pdfiumExportFailed
    case pdfKitOnlyFixtureFailed
#endif
}
