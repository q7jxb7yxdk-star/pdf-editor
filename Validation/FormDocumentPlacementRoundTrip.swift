#if FORM_DOCUMENT_PLACEMENT_STANDALONE_VALIDATION
import CoreGraphics
import Foundation
import PDFKit

@main
struct FormDocumentPlacementRoundTrip {
    @MainActor
    static func main() throws {
        let document = PDFEditorDocument()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        func grouped<T>(_ action: () throws -> T) rethrows -> T {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return try action()
        }
        let options = ["Option 1", "Option 2", "Option 3"]
        let first = try grouped {
            try document.addPlacedFormField(
                kind: .dropdown,
                pageIndex: 0,
                bounds: CGRect(x: 40, y: 650, width: 80, height: 28),
                radioGroupName: nil,
                choiceOptions: options,
                undoManager: undoManager
            )
        }
        guard let firstWidget = PDFFormDesignService().authoredAnnotation(
            for: first.id,
            in: document.pdfDocument
        ) else {
            throw Failure("The first live Dropdown Widget is missing")
        }
        firstWidget.widgetStringValue = "Option 1"
        try grouped {
            try document.synchronizeAcroFormChangesIfNeeded(undoManager: undoManager)
        }
        let second = try grouped {
            try document.addPlacedFormField(
                kind: .dropdown,
                pageIndex: 0,
                bounds: CGRect(x: 40, y: 600, width: 80, height: 28),
                radioGroupName: nil,
                choiceOptions: options,
                undoManager: undoManager
            )
        }
        let fields = PDFFormDesignService().fields(in: document.pdfDocument)
        guard fields.count == 2,
              Set(fields.map(\.id)) == [first.id, second.id],
              first.name != second.name,
              fields.first(where: { $0.id == first.id })?.value == "Option 1",
              fields.first(where: { $0.id == first.id })?.defaultValue == "" else {
            throw Failure("Sequential Dropdown placement did not retain two distinct fields")
        }
        let originalSecondWidth = second.bounds.width
        let resizedSecond = try grouped {
            try document.setAuthoredFormFieldFontSize(
                id: second.id,
                fontSize: 18,
                undoManager: undoManager
            )
        }
        guard abs(resizedSecond.fontSize - 18) < 0.01,
              resizedSecond.bounds.width > originalSecondWidth,
              abs(resizedSecond.bounds.midX - second.bounds.midX) < 0.01 else {
            throw Failure("Dropdown font-size update did not refit its centered width")
        }
        try grouped {
            try document.deleteAuthoredFormField(id: second.id, undoManager: undoManager)
        }
        guard PDFFormDesignService().fields(in: document.pdfDocument).map(\.id) == [first.id] else {
            throw Failure("Dropdown deletion did not retain only its sibling")
        }
        undoManager.undo()
        let restoredFields = PDFFormDesignService().fields(in: document.pdfDocument)
        guard Set(restoredFields.map(\.id)) == [first.id, second.id],
              abs((restoredFields.first { $0.id == second.id }?.fontSize ?? 0) - 18) < 0.01 else {
            throw Failure("Dropdown deletion Undo did not restore its font and field identity")
        }
        let listBoxSize = PDFFormDesignKind.listBox.placementSize(
            choices: options,
            fontSize: 11
        )
        let listBox = try grouped {
            try document.addPlacedFormField(
                kind: .listBox,
                pageIndex: 0,
                bounds: CGRect(
                    x: 40,
                    y: 500,
                    width: listBoxSize.width,
                    height: listBoxSize.height
                ),
                radioGroupName: nil,
                choiceOptions: options,
                undoManager: undoManager
            )
        }
        let resizedListBox = try grouped {
            try document.setAuthoredFormFieldFontSize(
                id: listBox.id,
                fontSize: 18,
                undoManager: undoManager
            )
        }
        guard abs(resizedListBox.fontSize - 18) < 0.01,
              resizedListBox.bounds.width > listBox.bounds.width,
              resizedListBox.bounds.height > listBox.bounds.height,
              abs(resizedListBox.bounds.midX - listBox.bounds.midX) < 0.01,
              abs(resizedListBox.bounds.maxY - listBox.bounds.maxY) < 0.01 else {
            throw Failure("List Box font-size update did not refit width and expand downward")
        }
        try grouped {
            try document.deleteAuthoredFormField(id: listBox.id, undoManager: undoManager)
        }
        guard !PDFFormDesignService().fields(in: document.pdfDocument).contains(where: {
            $0.id == listBox.id
        }) else {
            throw Failure("List Box deletion retained the deleted field")
        }
        undoManager.undo()
        guard let restoredListBox = PDFFormDesignService().fields(in: document.pdfDocument)
            .first(where: { $0.id == listBox.id }),
              abs(restoredListBox.fontSize - 18) < 0.01,
              abs(restoredListBox.bounds.height - resizedListBox.bounds.height) < 0.01,
              abs(restoredListBox.bounds.maxY - listBox.bounds.maxY) < 0.01 else {
            throw Failure("List Box deletion Undo did not restore its font, height and field identity")
        }
        print("Dropdown and List Box font-size update, deletion and Undo passed.")
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

}
#endif
