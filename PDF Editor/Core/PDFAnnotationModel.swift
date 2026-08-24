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
}
