import CoreGraphics
import Foundation
import ImageIO
import PDFKit

@main
@MainActor
struct ImageExportValidation {
    static func main() async throws {
        let document = try makeDocument()
        document.page(at: 1)?.rotation = 90

        let exporter = PDFPageImageExporter()
        var progress: [(Int, Int)] = []
        let pngOutputs = try await exporter.exportPages(
            in: document,
            options: PDFPageImageExportOptions(format: .png, dpi: .dpi72)
        ) { completed, total in
            progress.append((completed, total))
        }

        precondition(pngOutputs.count == 2)
        precondition(pngOutputs.map(\.filename) == ["page-0001.png", "page-0002.png"])
        precondition(progress.map(\.0) == [1, 2])
        precondition(progress.allSatisfy { $0.1 == 2 })
        try verify(
            pngOutputs[0],
            expectedType: "public.png",
            expectedWidth: 612,
            expectedHeight: 792
        )
        try verify(
            pngOutputs[1],
            expectedType: "public.png",
            expectedWidth: 792,
            expectedHeight: 612
        )

        guard let firstPage = document.page(at: 0) else {
            throw ValidationError.missingPage
        }
        let jpegOutput = try await exporter.exportPage(
            firstPage,
            pageIndex: 0,
            options: PDFPageImageExportOptions(format: .jpeg, dpi: .dpi144)
        )
        precondition(jpegOutput.filename == "page-0001.jpg")
        try verify(
            jpegOutput,
            expectedType: "public.jpeg",
            expectedWidth: 1_224,
            expectedHeight: 1_584
        )

        let highResolutionOutput = try await exporter.exportPage(
            firstPage,
            pageIndex: 0,
            options: PDFPageImageExportOptions(format: .png, dpi: .dpi300)
        )
        try verify(
            highResolutionOutput,
            expectedType: "public.png",
            expectedWidth: 2_550,
            expectedHeight: 3_300
        )

        do {
            _ = try await exporter.exportPage(
                firstPage,
                pageIndex: 0,
                options: PDFPageImageExportOptions(
                    format: .png,
                    dpi: .dpi300,
                    maximumPixelDimension: 1_000
                )
            )
            throw ValidationError.expectedLimitFailure
        } catch PDFPageImageExportError.imageTooLarge {
            // Expected fail-closed behavior for oversized output.
        }

        print("Image export validation passed (PNG/JPEG, DPI, rotation, filenames, progress, and limits).")
    }

    private static func verify(
        _ output: PDFPageImageExportOutput,
        expectedType: String,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        guard let source = CGImageSourceCreateWithData(output.data as CFData, nil),
              CGImageSourceGetType(source) as String? == expectedType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == expectedWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == expectedHeight else {
            throw ValidationError.invalidEncodedImage
        }
    }

    private static func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ValidationError.couldNotCreatePDF
        }
        for pageNumber in 1...2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.1 * CGFloat(pageNumber), green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 72, y: 72, width: 200, height: 120))
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount == 2 else {
            throw ValidationError.couldNotCreatePDF
        }
        return document
    }
}

private enum ValidationError: Error {
    case couldNotCreatePDF
    case missingPage
    case invalidEncodedImage
    case expectedLimitFailure
}
