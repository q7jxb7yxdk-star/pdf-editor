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
    let transform: CGAffineTransform
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
        _ = try service.addInkStroke(
            points: [
                CGPoint(x: 120, y: 486),
                CGPoint(x: 204, y: 522),
                CGPoint(x: 288, y: 468),
                CGPoint(x: 360, y: 513),
            ],
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
        let unchangedNoteUpdate = PDFAnnotationUpdate(
            contents: expectedNote.contents,
            color: expectedNote.color
        ).changes(from: expectedNote)
        precondition(unchangedNoteUpdate.isEmpty)
        let changedNoteUpdate = PDFAnnotationUpdate(
            contents: expectedNote.contents,
            color: .red
        ).changes(from: expectedNote)
        precondition(changedNoteUpdate.contents == nil)
        precondition(changedNoteUpdate.color == .red)

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
        try requireInkPathsInsideAnnotationBounds(
            ink.reference,
            in: document,
            service: service
        )
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
        try requireInkPathsInsideAnnotationBounds(
            expectedInk.reference,
            in: document,
            service: service
        )
        let markup = snapshots[3]
        let markupColor = PDFAnnotationColor(
            red: 0.16,
            green: 0.68,
            blue: 0.32,
            alpha: markup.color.alpha
        )
        let expectedMarkup = try service.update(
            markup.reference,
            with: PDFAnnotationUpdate(
                bounds: CGRect(x: 110, y: 330, width: 220, height: 30),
                color: markupColor
            ),
            in: document
        )
        precondition(expectedMarkup.geometryPointCount == 8)
        precondition(abs(expectedMarkup.color.red - markupColor.red) < 0.01)
        precondition(abs(expectedMarkup.color.green - markupColor.green) < 0.01)
        precondition(abs(expectedMarkup.color.blue - markupColor.blue) < 0.01)
        precondition(abs(expectedMarkup.color.alpha - markupColor.alpha) < 0.01)

        let signatureContainers = [
            CGRect(x: 48, y: 210, width: 200, height: 80),
            CGRect(x: 310, y: 120, width: 180, height: 72),
        ]
        for bounds in signatureContainers {
            _ = try service.addSignature(
                strokes: [
                    SignatureStroke(points: [
                        CGPoint(x: 0.32, y: 0.58),
                        CGPoint(x: 0.46, y: 0.36),
                        CGPoint(x: 0.58, y: 0.61),
                    ]),
                    SignatureStroke(points: [
                        CGPoint(x: 0.48, y: 0.48),
                        CGPoint(x: 0.61, y: 0.42),
                        CGPoint(x: 0.68, y: 0.53),
                    ]),
                ],
                bounds: bounds,
                to: page
            )
        }
        let signatureSnapshots = Array(service.snapshots(on: page, pageIndex: 0).suffix(2))
        precondition(signatureSnapshots.count == 2)
        for (signature, container) in zip(signatureSnapshots, signatureContainers) {
            precondition(signature.kind == .ink)
            precondition(signature.bounds.width < container.width * 0.5)
            precondition(signature.bounds.height < container.height * 0.5)
            precondition(signature.geometryPointCount == 6)
            precondition(abs(signature.color.alpha - 1) < 0.01)
            try requireInkPathsInsideAnnotationBounds(
                signature.reference,
                in: document,
                service: service
            )
        }

        let markContainers = [
            CGRect(origin: CGPoint(x: 500, y: 230), size: ESignMark.preferredSize),
            CGRect(origin: CGPoint(x: 500, y: 150), size: ESignMark.preferredSize),
        ]
        for (mark, bounds) in zip(ESignMark.allCases, markContainers) {
            _ = try service.addSignature(
                strokes: mark.normalizedStrokes.map(SignatureStroke.init(points:)),
                bounds: bounds,
                lineWidth: ESignMark.lineWidth,
                minimumPadding: ESignMark.annotationPadding,
                to: page
            )
        }
        let markSnapshots = Array(service.snapshots(on: page, pageIndex: 0).suffix(2))
        precondition(markSnapshots.count == 2)
        let expectedMarkPointCounts = [3, 4]
        for ((mark, container), pointCount) in zip(
            zip(markSnapshots, markContainers),
            expectedMarkPointCounts
        ) {
            precondition(mark.kind == .ink)
            precondition(mark.bounds.width < container.width)
            precondition(mark.bounds.height < container.height)
            precondition(mark.geometryPointCount == pointCount)
            precondition(abs(mark.lineWidth - ESignMark.lineWidth) < 0.01)
            precondition(abs(mark.color.alpha - 1) < 0.01)
            try requireInkPathsInsideAnnotationBounds(
                mark.reference,
                in: document,
                service: service
            )
        }

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
        for signature in signatureSnapshots {
            try service.verify(signature, in: reopened)
        }
        for mark in markSnapshots {
            try service.verify(mark, in: reopened)
        }

        let reopenedPage = reopened.page(at: 0)!
        precondition(reopenedPage.annotations[0].iconType == .comment)
        snapshots = service.snapshots(on: reopenedPage, pageIndex: 0)
        precondition(snapshots[1].contents == "Edited text")
        precondition(abs(snapshots[1].fontSize! - 24) < 0.05)
        precondition(abs(snapshots[2].bounds.width - 300) < 0.05)
        precondition(snapshots[2].geometryPointCount == 4)
        precondition(snapshots[3].geometryPointCount == 8)
        precondition(abs(snapshots[3].color.red - markupColor.red) < 0.01)
        precondition(abs(snapshots[3].color.green - markupColor.green) < 0.01)
        precondition(abs(snapshots[3].color.blue - markupColor.blue) < 0.01)
        precondition(snapshots.count == 9)
        precondition(snapshots[4].geometryPointCount == 6)
        precondition(snapshots[5].geometryPointCount == 6)
        precondition(snapshots[6].geometryPointCount == 3)
        precondition(snapshots[7].geometryPointCount == 4)
        precondition(abs(snapshots[6].lineWidth - ESignMark.lineWidth) < 0.01)
        precondition(abs(snapshots[7].lineWidth - ESignMark.lineWidth) < 0.01)
        precondition(snapshots[8].kind == .freeText)
        precondition(snapshots[8].contents == "替代文字")
        precondition(snapshots[8].bounds.height >= ceil(replacementLineHeight) + 1)

        let restyledSignature = try service.update(
            snapshots[5].reference,
            with: PDFAnnotationUpdate(color: .blue, lineWidth: 6),
            in: reopened
        )
        precondition(abs(restyledSignature.color.alpha - 1) < 0.01)
        guard let restyledData = reopened.dataRepresentation(),
              let restyledDocument = PDFDocument(data: restyledData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try service.verify(restyledSignature, in: restyledDocument)
        try requireInkPathsInsideAnnotationBounds(
            restyledSignature.reference,
            in: restyledDocument,
            service: service
        )

        print("Annotation round-trip validation passed (note, free text, freehand ink, highlight, signatures, checkmark, and crossmark).")
    }

    private static func requireInkPathsInsideAnnotationBounds(
        _ reference: PDFAnnotationReference,
        in document: PDFDocument,
        service: PDFAnnotationService
    ) throws {
        let annotation = try service.resolve(reference, in: document).annotation
        let localBounds = CGRect(origin: .zero, size: annotation.bounds.size)
            .insetBy(dx: -0.05, dy: -0.05)
        guard let paths = annotation.paths, !paths.isEmpty,
              paths.allSatisfy({ localBounds.contains($0.bounds) }) else {
            throw NSError(
                domain: "AnnotationValidation",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ink paths must use annotation-local coordinates inside \(localBounds)."
                ]
            )
        }
    }
}
