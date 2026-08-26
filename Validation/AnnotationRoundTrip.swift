import AppKit
import CoreText
import Foundation
import PDFKit

#if ANNOTATION_STANDALONE_VALIDATION
nonisolated struct PDFTextStyle: OptionSet {
    let rawValue: UInt8

    static let bold = PDFTextStyle(rawValue: 1 << 0)
    static let italic = PDFTextStyle(rawValue: 1 << 1)
}

nonisolated struct PDFObjectColor {
    let red: UInt32
    let green: UInt32
    let blue: UInt32
    let alpha: UInt32
}

nonisolated struct PDFPageObjectSnapshot {
    let bounds: CGRect
    let fillColor: PDFObjectColor
    let fontSize: CGFloat?
}
#endif

@main
struct AnnotationRoundTripValidation {
    static func main() throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
        ]
        for (text, position) in [
            ("Highlight this text", CGPoint(x: 90, y: 365)),
            ("across two lines", CGPoint(x: 90, y: 340)),
        ] {
            context.textPosition = position
            CTLineDraw(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: textAttributes)
                ),
                context
            )
        }
        context.endPDFPage()
        context.closePDF()
        let document = PDFDocument(data: data as Data)!
        let page = document.page(at: 0)!

        let service = PDFAnnotationService()
        let note = try service.addNote(
            text: "Original note",
            at: CGPoint(x: 40, y: 700),
            to: page
        )
        _ = try service.addFreeText(
            text: "Original text",
            bounds: CGRect(x: 80, y: 600, width: 220, height: 50),
            to: page
        )
        _ = try service.addSignature(
            strokes: [SignatureStroke(points: [
                CGPoint(x: 0, y: 0.6),
                CGPoint(x: 0.35, y: 0.2),
                CGPoint(x: 0.7, y: 0.8),
                CGPoint(x: 1, y: 0.3),
            ])],
            bounds: CGRect(x: 120, y: 450, width: 240, height: 90),
            to: page
        )
        guard let pageText = page.string,
              let textSelection = page.selection(
                for: NSRange(location: 0, length: pageText.utf16.count)
              ) else {
            throw NSError(
                domain: "AnnotationValidation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not select generated PDF text"]
            )
        }
        let highlights = try service.addHighlight(to: textSelection)
        precondition(highlights.count == 1)
        let highlight = highlights[0]
        let highlightBounds = highlight.bounds
        let highlightPoints = highlight.quadrilateralPoints?.map(\.pointValue) ?? []
        precondition(highlightPoints.count == 8)
        precondition(highlightPoints.allSatisfy {
            $0.x >= -0.05 && $0.x <= highlightBounds.width + 0.05 &&
                $0.y >= -0.05 && $0.y <= highlightBounds.height + 0.05
        })

        var snapshots = service.snapshots(on: page, pageIndex: 0)
        guard snapshots.count == 4 else {
            throw NSError(
                domain: "AnnotationValidation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected 4 annotations, found \(snapshots.count): \(snapshots.map(\.kind.rawValue))"]
            )
        }

        var expectedNote = snapshots[0]
        precondition(note.iconType == .comment)
        precondition(abs(expectedNote.bounds.width - 24) < 0.05)
        precondition(abs(expectedNote.bounds.height - 24) < 0.05)
        let noteColor = PDFAnnotationColor(
            red: 0.1,
            green: 0.4,
            blue: 0.95,
            alpha: 0.35
        )
        expectedNote = try service.update(
            expectedNote.reference,
            with: PDFAnnotationUpdate(color: noteColor),
            in: document
        )
        precondition(abs(expectedNote.color.alpha - 0.35) < 0.01)

        let freeText = snapshots[1]
        let expectedText = try service.update(
            freeText.reference,
            with: PDFAnnotationUpdate(
                contents: "Edited text",
                color: .blue,
                fontColor: .blue,
                fontSize: 24,
                lineWidth: 2
            ),
            in: document
        )

        let ink = snapshots[2]
        let resizedBounds = CGRect(x: 160, y: 410, width: 300, height: 120)
        let expectedInk = try service.update(
            ink.reference,
            with: PDFAnnotationUpdate(
                bounds: resizedBounds,
                color: .red,
                lineWidth: 4
            ),
            in: document
        )
        precondition(expectedInk.geometryPointCount == ink.geometryPointCount)
        let markup = snapshots[3]
        let expectedMarkup = try service.update(
            markup.reference,
            with: .bounds(CGRect(x: 110, y: 330, width: 220, height: 30)),
            in: document
        )
        precondition(expectedMarkup.geometryPointCount == 8)

        guard let serialized = document.dataRepresentation(),
              let reopened = PDFDocument(data: serialized) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try service.verify(expectedNote, in: reopened)
        try serialized.write(
            to: URL(fileURLWithPath: "/tmp/PDFEditor-Phase4-Annotations.pdf"),
            options: .atomic
        )
        try service.verify(expectedText, in: reopened)
        try service.verify(expectedInk, in: reopened)
        try service.verify(expectedMarkup, in: reopened)

        let reopenedPage = reopened.page(at: 0)!
        precondition(reopenedPage.annotations[0].iconType == .comment)
        snapshots = service.snapshots(on: reopenedPage, pageIndex: 0)
        precondition(snapshots[1].contents == "Edited text")
        precondition(abs(snapshots[1].fontSize! - 24) < 0.05)
        precondition(abs(snapshots[2].bounds.width - 300) < 0.05)
        precondition(snapshots[2].geometryPointCount == 4)
        precondition(snapshots[3].geometryPointCount == 8)

        print("Annotation round-trip validation passed (note, free text, ink, highlight geometry and style).")
    }
}
