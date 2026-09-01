import Foundation
import PDFKit

nonisolated enum PDFAcroFormError: LocalizedError {
    case serializationFailed
    case unlockFailed
    case roundTripVerificationFailed(fieldName: String)

    var errorDescription: String? {
        switch self {
        case .serializationFailed:
            "The AcroForm changes could not be serialized."
        case .unlockFailed:
            "The AcroForm PDF could not be unlocked for verification."
        case let .roundTripVerificationFailed(fieldName):
            "The AcroForm field \"\(fieldName)\" did not retain its value after saving."
        }
    }
}

nonisolated final class PDFAcroFormService {
    func snapshots(in document: PDFDocument) -> [PDFAcroFormFieldSnapshot] {
        (0..<document.pageCount).flatMap { pageIndex -> [PDFAcroFormFieldSnapshot] in
            guard let page = document.page(at: pageIndex) else { return [] }
            return page.annotations.enumerated().compactMap { annotationIndex, annotation in
                snapshot(
                    annotation,
                    reference: PDFAcroFormFieldReference(
                        pageIndex: pageIndex,
                        annotationIndex: annotationIndex
                    )
                )
            }
        }
    }

    func hasAcroFormFields(in document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { pageIndex in
            document.page(at: pageIndex)?.annotations.contains(where: isWidget) == true
        }
    }

    func hasValueChanges(
        from previous: [PDFAcroFormFieldSnapshot],
        to current: [PDFAcroFormFieldSnapshot]
    ) -> Bool {
        let previousState = Dictionary(uniqueKeysWithValues: previous.map {
            ($0.reference, persistentState(of: $0))
        })
        let currentState = Dictionary(uniqueKeysWithValues: current.map {
            ($0.reference, persistentState(of: $0))
        })
        return previousState != currentState
    }

    func verify(
        _ expected: [PDFAcroFormFieldSnapshot],
        in data: Data,
        password: String?
    ) throws {
        guard let reopened = PDFDocument(data: data) else {
            throw PDFAcroFormError.serializationFailed
        }
        if reopened.isLocked {
            guard let password, reopened.unlock(withPassword: password) else {
                throw PDFAcroFormError.unlockFailed
            }
        }
        let actual = Dictionary(uniqueKeysWithValues: snapshots(in: reopened).map {
            ($0.reference, $0)
        })
        guard actual.count == expected.count else {
            throw PDFAcroFormError.roundTripVerificationFailed(fieldName: "Field count")
        }
        for field in expected where field.kind != .pushButton {
            guard let reopenedField = actual[field.reference],
                  abs(reopenedField.bounds.minX - field.bounds.minX) < 0.05,
                  abs(reopenedField.bounds.minY - field.bounds.minY) < 0.05,
                  abs(reopenedField.bounds.width - field.bounds.width) < 0.05,
                  abs(reopenedField.bounds.height - field.bounds.height) < 0.05,
                  persistentState(of: reopenedField) == persistentState(of: field) else {
                throw PDFAcroFormError.roundTripVerificationFailed(
                    fieldName: field.fieldName ?? "Unnamed field"
                )
            }
        }
    }

    func isWidget(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Widget"
    }

    private func snapshot(
        _ annotation: PDFAnnotation,
        reference: PDFAcroFormFieldReference
    ) -> PDFAcroFormFieldSnapshot? {
        guard isWidget(annotation) else { return nil }
        let kind: PDFAcroFormFieldKind
        switch annotation.widgetFieldType {
        case .text:
            kind = .text
        case .choice:
            kind = .choice
        case .signature:
            kind = .signature
        case .button:
            switch annotation.widgetControlType {
            case .checkBoxControl: kind = .checkBox
            case .radioButtonControl: kind = .radioButton
            case .pushButtonControl: kind = .pushButton
            default: kind = .unsupported
            }
        default:
            kind = .unsupported
        }
        let tracksButtonState = kind == .checkBox || kind == .radioButton
        return PDFAcroFormFieldSnapshot(
            reference: reference,
            fieldName: annotation.fieldName,
            kind: kind,
            bounds: annotation.bounds,
            isReadOnly: annotation.isReadOnly,
            value: annotation.widgetStringValue,
            buttonState: tracksButtonState ? annotation.buttonWidgetState.rawValue : nil,
            buttonStateName: tracksButtonState ? annotation.buttonWidgetStateString : nil,
            choices: annotation.choices ?? [],
            exportValues: annotation.values ?? []
        )
    }

    private func persistentState(
        of snapshot: PDFAcroFormFieldSnapshot
    ) -> PDFAcroFormPersistentState {
        PDFAcroFormPersistentState(
            fieldName: snapshot.fieldName,
            kind: snapshot.kind,
            isReadOnly: snapshot.isReadOnly,
            value: snapshot.value,
            buttonState: snapshot.buttonState,
            buttonStateName: snapshot.buttonStateName,
            choices: snapshot.choices,
            exportValues: snapshot.exportValues
        )
    }
}

nonisolated private struct PDFAcroFormPersistentState: Equatable {
    let fieldName: String?
    let kind: PDFAcroFormFieldKind
    let isReadOnly: Bool
    let value: String?
    let buttonState: Int?
    let buttonStateName: String?
    let choices: [String]
    let exportValues: [String]
}
