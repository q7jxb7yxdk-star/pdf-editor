import Foundation
import PDFKit

@main
struct PhaseSixAcceptance {
    static func main() throws {
        let directory = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "tmp/pdfs", isDirectory: true)
        let large = try open("phase6-large-120-pages.pdf", in: directory)
        let mixed = try open("phase6-mixed-content.pdf", in: directory)
        let protectedURL = directory.appendingPathComponent("phase6-protected.pdf")
        let truncatedURL = directory.appendingPathComponent("phase6-truncated.pdf")

        guard large.pageCount == 120,
              large.page(at: 0)?.string?.contains("Large corpus page 001") == true,
              large.page(at: 119)?.string?.contains("Large corpus page 120") == true else {
            throw AcceptanceError.largeDocumentMismatch
        }

        let ocrService = VisionOCRService()
        guard mixed.pageCount == 4,
              let firstPage = mixed.page(at: 0),
              let secondPage = mixed.page(at: 1),
              let thirdPage = mixed.page(at: 2),
              let fourthPage = mixed.page(at: 3),
              !ocrService.requiresOCR(firstPage),
              ocrService.requiresOCR(secondPage),
              !ocrService.requiresOCR(thirdPage),
              ocrService.requiresOCR(fourthPage),
              thirdPage.rotation == 90 else {
            throw AcceptanceError.mixedContentMismatch
        }

        guard let protectedDocument = PDFDocument(url: protectedURL),
              protectedDocument.isLocked,
              !protectedDocument.unlock(withPassword: "wrong-password"),
              protectedDocument.unlock(withPassword: "phase6-test"),
              protectedDocument.pageCount == 4 else {
            throw AcceptanceError.protectedDocumentMismatch
        }

        let truncatedData = try Data(contentsOf: truncatedURL)
        guard PDFDocument(data: truncatedData) == nil else {
            throw AcceptanceError.truncatedDocumentOpened
        }

        print(
            "Phase six acceptance passed: 120-page, mixed OCR policy, rotated, " +
            "protected, and truncated PDF cases."
        )
    }

    private static func open(_ filename: String, in directory: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: directory.appendingPathComponent(filename)) else {
            throw AcceptanceError.documentOpenFailed(filename)
        }
        return document
    }
}

private enum AcceptanceError: Error {
    case documentOpenFailed(String)
    case largeDocumentMismatch
    case mixedContentMismatch
    case protectedDocumentMismatch
    case truncatedDocumentOpened
}
