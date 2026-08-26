import CoreGraphics
import Foundation

nonisolated struct PDFAnnotationReference: Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
}

nonisolated enum PDFEditableAnnotationKind: String, Sendable {
    case note = "Text"
    case freeText = "FreeText"
    case highlight = "Highlight"
    case ink = "Ink"
    case other

    init(pdfSubtype: String?) {
        self = Self(rawValue: pdfSubtype ?? "") ?? .other
    }

    var displayName: String {
        switch self {
        case .note: "便條"
        case .freeText: "自由文字"
        case .highlight: "標示"
        case .ink: "手寫簽名／墨跡"
        case .other: "註解"
        }
    }
}

nonisolated struct PDFAnnotationColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let yellow = PDFAnnotationColor(red: 1, green: 0.8, blue: 0, alpha: 0.45)
    static let red = PDFAnnotationColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 1)
    static let blue = PDFAnnotationColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1)
    static let black = PDFAnnotationColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)

    func withAlpha(_ alpha: CGFloat) -> Self {
        var copy = self
        copy.alpha = min(max(alpha, 0.05), 1)
        return copy
    }
}

nonisolated struct PDFAnnotationSnapshot: Identifiable, Equatable, Sendable {
    let reference: PDFAnnotationReference
    let kind: PDFEditableAnnotationKind
    var bounds: CGRect
    var contents: String
    var color: PDFAnnotationColor
    var fontColor: PDFAnnotationColor?
    var fontSize: CGFloat?
    var lineWidth: CGFloat
    let geometryPointCount: Int
    let hasAppearanceStream: Bool

    var id: PDFAnnotationReference { reference }
}

nonisolated struct PDFAnnotationColorUpdateEvent: Equatable, Sendable {
    let generation: Int
    let reference: PDFAnnotationReference
    let color: PDFAnnotationColor
}

nonisolated struct PDFAnnotationBackgroundFailureEvent: Equatable, Sendable {
    let generation: Int
    let message: String
    let requiresDigitalSignatureConsent: Bool
}

nonisolated struct PDFAnnotationUpdate: Sendable {
    var bounds: CGRect?
    var contents: String?
    var color: PDFAnnotationColor?
    var fontColor: PDFAnnotationColor?
    var fontSize: CGFloat?
    var lineWidth: CGFloat?

    static func bounds(_ bounds: CGRect) -> Self {
        PDFAnnotationUpdate(bounds: bounds)
    }

    var isEmpty: Bool {
        bounds == nil && contents == nil && color == nil && fontColor == nil &&
            fontSize == nil && lineWidth == nil
    }

    func changes(from snapshot: PDFAnnotationSnapshot) -> Self {
        PDFAnnotationUpdate(
            bounds: bounds.flatMap {
                approximatelyEqual($0.standardized, snapshot.bounds.standardized) ? nil : $0
            },
            contents: contents == snapshot.contents ? nil : contents,
            color: color.flatMap { approximatelyEqual($0, snapshot.color) ? nil : $0 },
            fontColor: fontColor.flatMap { proposedColor in
                snapshot.fontColor.map { approximatelyEqual(proposedColor, $0) } == true
                    ? nil
                    : proposedColor
            },
            fontSize: fontSize.flatMap { proposedSize in
                snapshot.fontSize.map { abs(proposedSize - $0) < 0.01 } == true
                    ? nil
                    : proposedSize
            },
            lineWidth: lineWidth.flatMap {
                abs($0 - snapshot.lineWidth) < 0.01 ? nil : $0
            }
        )
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.01 &&
            abs(lhs.minY - rhs.minY) < 0.01 &&
            abs(lhs.width - rhs.width) < 0.01 &&
            abs(lhs.height - rhs.height) < 0.01
    }

    private func approximatelyEqual(
        _ lhs: PDFAnnotationColor,
        _ rhs: PDFAnnotationColor
    ) -> Bool {
        abs(lhs.red - rhs.red) < 0.005 &&
            abs(lhs.green - rhs.green) < 0.005 &&
            abs(lhs.blue - rhs.blue) < 0.005 &&
            abs(lhs.alpha - rhs.alpha) < 0.005
    }
}
