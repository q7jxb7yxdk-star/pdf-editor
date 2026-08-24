import CoreGraphics
import CoreText
import Foundation
import PDFKit

private enum CorpusError: Error {
    case contextCreationFailed
    case documentCreationFailed
    case protectedWriteFailed
}

private let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

private func drawText(_ text: String, at point: CGPoint, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    ))
    context.textMatrix = .identity
    context.textPosition = point
    CTLineDraw(line, context)
}

private func makePDF(pageCount: Int, mixedContent: Bool) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw CorpusError.contextCreationFailed
    }

    for pageIndex in 0..<pageCount {
        let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: pageBox]
        context.beginPDFPage(pageInfo as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(pageBox)

        if !mixedContent || pageIndex == 0 || pageIndex == 2 {
            drawText(
                mixedContent ? "Selectable text page \(pageIndex + 1)" : String(
                    format: "Large corpus page %03d",
                    pageIndex + 1
                ),
                at: CGPoint(x: 72, y: 700),
                in: context
            )
        } else {
            for row in 0..<8 {
                for column in 0..<6 {
                    let red = CGFloat((row + column) % 3) / 3 + 0.2
                    let green = CGFloat((row * 2 + column) % 4) / 5 + 0.15
                    context.setFillColor(CGColor(
                        red: min(red, 1),
                        green: min(green, 1),
                        blue: 0.72,
                        alpha: 1
                    ))
                    context.fill(CGRect(
                        x: 72 + CGFloat(column) * 72,
                        y: 120 + CGFloat(row) * 66,
                        width: 62,
                        height: 56
                    ))
                }
            }
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

let outputDirectory = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: "tmp/pdfs", isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let largeData = try makePDF(pageCount: 120, mixedContent: false)
let unrotatedMixedData = try makePDF(pageCount: 4, mixedContent: true)
guard let mixedDocument = PDFDocument(data: unrotatedMixedData),
      let rotatedPage = mixedDocument.page(at: 2) else {
    throw CorpusError.documentCreationFailed
}
rotatedPage.rotation = 90
guard let mixedData = mixedDocument.dataRepresentation() else {
    throw CorpusError.documentCreationFailed
}
let largeURL = outputDirectory.appendingPathComponent("phase6-large-120-pages.pdf")
let mixedURL = outputDirectory.appendingPathComponent("phase6-mixed-content.pdf")
let protectedURL = outputDirectory.appendingPathComponent("phase6-protected.pdf")
let truncatedURL = outputDirectory.appendingPathComponent("phase6-truncated.pdf")

try largeData.write(to: largeURL, options: .atomic)
try mixedData.write(to: mixedURL, options: .atomic)

guard let protectedDocument = PDFDocument(data: mixedData) else {
    throw CorpusError.documentCreationFailed
}
guard protectedDocument.write(
    to: protectedURL,
    withOptions: [
        .userPasswordOption: "phase6-test",
        .ownerPasswordOption: "phase6-test",
    ]
) else {
    throw CorpusError.protectedWriteFailed
}

try Data(largeData.prefix(128)).write(to: truncatedURL, options: .atomic)

for url in [largeURL, mixedURL, protectedURL, truncatedURL] {
    print(url.path)
}
