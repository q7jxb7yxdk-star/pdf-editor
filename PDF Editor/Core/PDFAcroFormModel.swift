import CoreGraphics
import Foundation

nonisolated struct PDFAcroFormFieldReference: Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
}

nonisolated enum PDFAcroFormFieldKind: String, Sendable {
    case text
    case checkBox
    case radioButton
    case choice
    case signature
    case pushButton
    case unsupported
}

nonisolated struct PDFAcroFormFieldSnapshot: Equatable, Sendable {
    let reference: PDFAcroFormFieldReference
    let fieldName: String?
    let kind: PDFAcroFormFieldKind
    let bounds: CGRect
    let isReadOnly: Bool
    let value: String?
    let buttonState: Int?
    let buttonStateName: String?
    let choices: [String]
    let exportValues: [String]
}

