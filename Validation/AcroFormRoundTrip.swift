#if ACROFORM_STANDALONE_VALIDATION
import CoreGraphics
import Foundation
import PDFKit

@main
struct AcroFormRoundTripValidation {
    static func main() throws {
        let document = try makeDocument()
        guard let page = document.page(at: 0) else {
            throw ValidationFailure("Missing validation page")
        }

        let text = PDFAnnotation(
            bounds: CGRect(x: 36, y: 700, width: 220, height: 24),
            forType: .widget,
            withProperties: nil
        )
        text.widgetFieldType = .text
        text.fieldName = "person_name"
        text.widgetStringValue = "Before"
        page.addAnnotation(text)

        let checkBox = PDFAnnotation(
            bounds: CGRect(x: 36, y: 650, width: 20, height: 20),
            forType: .widget,
            withProperties: nil
        )
        checkBox.widgetFieldType = .button
        checkBox.widgetControlType = .checkBoxControl
        checkBox.fieldName = "accepts_terms"
        checkBox.buttonWidgetStateString = "Yes"
        checkBox.buttonWidgetState = .offState
        page.addAnnotation(checkBox)

        let radioYes = PDFAnnotation(
            bounds: CGRect(x: 90, y: 650, width: 20, height: 20),
            forType: .widget,
            withProperties: nil
        )
        radioYes.widgetFieldType = .button
        radioYes.widgetControlType = .radioButtonControl
        radioYes.fieldName = "attending"
        radioYes.buttonWidgetStateString = "Yes"
        radioYes.buttonWidgetState = .onState
        page.addAnnotation(radioYes)

        let radioNo = PDFAnnotation(
            bounds: CGRect(x: 130, y: 650, width: 20, height: 20),
            forType: .widget,
            withProperties: nil
        )
        radioNo.widgetFieldType = .button
        radioNo.widgetControlType = .radioButtonControl
        radioNo.fieldName = "attending"
        radioNo.buttonWidgetStateString = "No"
        radioNo.buttonWidgetState = .offState
        page.addAnnotation(radioNo)

        let choice = PDFAnnotation(
            bounds: CGRect(x: 36, y: 600, width: 220, height: 24),
            forType: .widget,
            withProperties: nil
        )
        choice.widgetFieldType = .choice
        choice.fieldName = "meal"
        choice.choices = ["Breakfast", "Lunch", "Dinner"]
        choice.values = ["breakfast", "lunch", "dinner"]
        choice.widgetStringValue = "Lunch"
        page.addAnnotation(choice)

        let service = PDFAcroFormService()
        let initial = service.snapshots(in: document)
        guard initial.count == 5 else {
            throw ValidationFailure("Expected five AcroForm widgets")
        }

        text.widgetStringValue = "陳大文"
        checkBox.buttonWidgetState = .onState
        radioYes.buttonWidgetState = .offState
        radioNo.buttonWidgetState = .onState
        choice.widgetStringValue = "Dinner"
        let expected = service.snapshots(in: document)
        guard let data = document.dataRepresentation() else {
            throw ValidationFailure("Could not serialize validation form")
        }
        try service.verify(expected, in: data, password: nil)

        guard let reopened = PDFDocument(data: data) else {
            throw ValidationFailure("Could not reopen validation form")
        }
        let reopenedFields = service.snapshots(in: reopened)
        guard reopenedFields.first(where: { $0.fieldName == "person_name" })?.value == "陳大文",
              reopenedFields.first(where: { $0.fieldName == "meal" })?.value == "Dinner" else {
            throw ValidationFailure("Text or choice value did not persist")
        }
        print("AcroForm round-trip validation passed (text, checkbox, radio, and choice).")
    }

    private static func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ValidationFailure("Could not create PDF context")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw ValidationFailure("Could not open blank validation PDF")
        }
        return document
    }
}

private struct ValidationFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
#endif
