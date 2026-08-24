import CoreGraphics
import CoreText
import Foundation
import PDFKit

@main
struct OCRPolicyValidation {
    static func main() throws {
        let service = VisionOCRService()
        let blankDocument = try makePDF(text: nil)
        let textDocument = try makePDF(text: "REAL PDF TEXT")

        guard let blankPage = blankDocument.page(at: 0),
              let textPage = textDocument.page(at: 0) else {
            throw ValidationError.pageCreationFailed
        }
        guard textPage.string?.contains("REAL PDF TEXT") == true else {
            throw ValidationError.textExtractionFailed
        }

        precondition(service.requiresOCR(blankPage))
        precondition(!service.requiresOCR(textPage))

        let result = OCRBatchResult(
            recognizedPages: [
                OCRRecognizedPage(
                    pageIndex: 0,
                    observations: [
                        OCRTextObservation(
                            text: "Scan",
                            confidence: 0.95,
                            normalizedBounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                            pageBounds: CGRect(x: 61.2, y: 158.4, width: 183.6, height: 79.2)
                        ),
                    ]
                ),
            ],
            skippedTextPageIndices: [1],
            emptyPageIndices: [2]
        )
        precondition(result.recognizedPageCount == 1)
        precondition(result.recognizedItemCount == 1)

        print("OCR policy validation passed (image-only pages require OCR; real PDF text is skipped).")
    }

    private static func makePDF(text: String?) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ValidationError.pageCreationFailed
        }
        context.beginPDFPage(nil)
        if let text {
            context.setFillColor(gray: 0, alpha: 1)
            context.textPosition = CGPoint(x: 72, y: 700)
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw ValidationError.pageCreationFailed
        }
        return document
    }
}

private enum ValidationError: Error {
    case pageCreationFailed
    case textExtractionFailed
}
