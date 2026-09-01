#if FORM_DESIGN_STANDALONE_VALIDATION
import CoreGraphics
import Foundation
import PDFKit

/// Opt-in validation; not run automatically by the app or this implementation.
@main
struct FormDesignRoundTrip {
    static func main() throws {
        let service = PDFFormDesignService()
        let shortDropdownSize = PDFFormDesignKind.dropdown.placementSize(
            choices: ["Short"], fontSize: 11
        )
        let longDropdownSize = PDFFormDesignKind.dropdown.placementSize(
            choices: ["A much longer Dropdown option"], fontSize: 11
        )
        let largeFontDropdownSize = PDFFormDesignKind.dropdown.placementSize(
            choices: ["A much longer Dropdown option"], fontSize: 18
        )
        try require(
            longDropdownSize.width > shortDropdownSize.width,
            "Dropdown width did not follow its longest option"
        )
        try require(
            largeFontDropdownSize.width > longDropdownSize.width,
            "Dropdown width did not follow its font size"
        )
        let shortListBoxSize = PDFFormDesignKind.listBox.placementSize(
            choices: ["Short"], fontSize: 11
        )
        let longListBoxSize = PDFFormDesignKind.listBox.placementSize(
            choices: ["A much longer List Box option"], fontSize: 11
        )
        let largeFontListBoxSize = PDFFormDesignKind.listBox.placementSize(
            choices: ["Option 1", "Option 2", "Option 3"], fontSize: 18
        )
        try require(
            longListBoxSize.width > shortListBoxSize.width &&
                longListBoxSize.height == PDFFormDesignKind.listBox.defaultSize.height,
            "List Box width did not follow its longest option"
        )
        try require(
            largeFontListBoxSize.height > PDFFormDesignKind.listBox.defaultSize.height,
            "List Box height did not follow its row count and font size"
        )
        let blank = try blankDocument()
        var placedOnBlank = try service.fieldForPlacement(
            kind: .text, pageIndex: 0, bounds: CGRect(x: 50, y: 600, width: 180, height: 28),
            radioGroupName: nil, in: blank
        )
        try require(abs(placedOnBlank.fontSize - 11) < 0.01, "Placed textbox did not default to 11 pt")
        try service.replaceFields([placedOnBlank], in: blank)
        guard let originalWidget = blank.page(at: 0)?.annotations.first else {
            throw Failure("Missing placed textbox")
        }
        placedOnBlank.bounds = CGRect(x: 65, y: 590, width: 240, height: 36)
        let boundsUpdate = try service.prepareBoundsUpdate(for: placedOnBlank, in: blank)
        boundsUpdate.apply()
        guard let resizedWidget = blank.page(at: 0)?.annotations.first else {
            throw Failure("Missing resized textbox")
        }
        try require(originalWidget === resizedWidget, "Resize replaced the live Widget annotation")
        try require(resizedWidget.bounds == placedOnBlank.bounds, "Resize did not update Widget bounds")
        // Simulate PDFKit changing a live value after an older canonical/design
        // snapshot was captured. A font-only presentation update must be based
        // on the latest live field rather than rejecting this unrelated drift.
        resizedWidget.widgetStringValue = "Live value"
        guard var liveFontField = service.fields(in: blank).first(where: { $0.id == placedOnBlank.id }) else {
            throw Failure("Missing live textbox before font update")
        }
        let previousFontBounds = liveFontField.bounds
        liveFontField.fontSize = 18
        liveFontField.bounds = CGRect(
            x: previousFontBounds.minX,
            y: previousFontBounds.midY - (previousFontBounds.height + 7) / 2,
            width: previousFontBounds.width,
            height: previousFontBounds.height + 7
        )
        let fontUpdate = try service.prepareFontSizeUpdate(for: liveFontField, in: blank)
        fontUpdate.apply()
        guard let resizedTextWidget = blank.page(at: 0)?.annotations.first else {
            throw Failure("Missing font-updated textbox")
        }
        try require(originalWidget === resizedTextWidget, "Font update replaced the live Widget annotation")
        try require(abs((resizedTextWidget.font?.pointSize ?? 0) - 18) < 0.01,
                    "Font update did not change the Widget font size")
        try require(resizedTextWidget.bounds == liveFontField.bounds,
                    "Font update did not resize the live Textbox")
        try require(abs(resizedTextWidget.bounds.midX - previousFontBounds.midX) < 0.01 &&
                    abs(resizedTextWidget.bounds.midY - previousFontBounds.midY) < 0.01,
                    "Font update did not preserve the Textbox center")
        let beforeDeletion = try reopen(blank)
        try service.verify([liveFontField], in: beforeDeletion)
        let deletionCandidate = try reopen(blank)
        try service.replaceFields([], in: deletionCandidate)
        let afterDeletion = try reopen(deletionCandidate)
        try service.verify([], in: afterDeletion)
        try service.verifyFieldTree([], in: afterDeletion)
        let undoDocument = try reopen(beforeDeletion)
        try service.verify([liveFontField], in: undoDocument)
        try service.verifyFieldTree([liveFontField], in: undoDocument)
        let redoDocument = try reopen(afterDeletion)
        try service.verify([], in: redoDocument)
        try service.verifyFieldTree([], in: redoDocument)
        try require(beforeDeletion !== afterDeletion &&
                    afterDeletion !== undoDocument &&
                    undoDocument !== redoDocument,
                    "Delete/Undo/Redo did not use distinct verified documents")

        let document = try blankDocument()
        guard let page = document.page(at: 0) else { throw Failure("Missing page") }
        let foreign = PDFAnnotation(bounds: CGRect(x: 40, y: 650, width: 100, height: 24),
                                    forType: .widget, withProperties: nil)
        foreign.widgetFieldType = .text
        foreign.fieldName = "existing"
        foreign.widgetStringValue = "Preserve me"
        page.addAnnotation(foreign)

        let text = PDFFormDesignField(pageIndex: 0, kind: .text, name: "name",
                                      bounds: CGRect(x: 40, y: 500, width: 200, height: 48),
                                      value: "陳大文\nHello", defaultValue: "姓名", isMultiline: true)
        let check = PDFFormDesignField(pageIndex: 0, kind: .checkBox, name: "consent",
                                       bounds: CGRect(x: 40, y: 450, width: 22, height: 22),
                                       isSelected: true, isDefaultSelected: true)
        let yes = PDFFormDesignField(pageIndex: 0, kind: .radioButton, name: "attending",
                                     bounds: CGRect(x: 40, y: 400, width: 22, height: 22),
                                     exportValue: "Yes", isSelected: true, isDefaultSelected: true)
        let no = PDFFormDesignField(pageIndex: 0, kind: .radioButton, name: "attending",
                                    bounds: CGRect(x: 100, y: 400, width: 22, height: 22), exportValue: "No")
        let dropdown = PDFFormDesignField(
            pageIndex: 0, kind: .dropdown, name: "department",
            bounds: CGRect(x: 40, y: 350, width: 180, height: 28),
            value: "Sales", defaultValue: "Engineering", fontSize: 11,
            choices: ["Engineering", "Sales", "Support"]
        )
        let listBox = PDFFormDesignField(
            pageIndex: 0, kind: .listBox, name: "colour",
            bounds: CGRect(x: 40, y: 250, width: 180, height: 72),
            value: "Green", defaultValue: "Blue", fontSize: 11,
            choices: ["Red", "Green", "Blue"]
        )
        var fields = [text, check, yes, no, dropdown, listBox]
        try service.replaceFields(fields, in: document)
        let reopened = try reopen(document)
        try service.verify(fields, in: reopened)
        try require(reopened.page(at: 0)?.annotations.first { $0.fieldName == "existing" }?.widgetStringValue == "Preserve me",
                    "Existing field value changed")

        // Values changed through PDFKit must survive the same registration
        // and reopen path as the app, without changing button defaults.
        let filled = try reopen(reopened)
        guard let fillPage = filled.page(at: 0),
              let textWidget = fillPage.annotations.first(where: { $0.fieldName == "name" }),
              let checkWidget = fillPage.annotations.first(where: { $0.fieldName == "consent" }),
              let radioWidget = fillPage.annotations.first(where: {
                  $0.fieldName == "attending" && $0.buttonWidgetStateString == "No"
              }),
              let dropdownWidget = fillPage.annotations.first(where: { $0.fieldName == "department" }),
              let listWidget = fillPage.annotations.first(where: { $0.fieldName == "colour" }) else {
            throw Failure("Missing fillable Widgets")
        }
        let defaultsBefore = service.fields(in: filled).map(\.isDefaultSelected)
        textWidget.widgetStringValue = "新填寫 ABC"
        checkWidget.buttonWidgetState = .offState
        radioWidget.buttonWidgetState = .onState
        dropdownWidget.widgetStringValue = "Support"
        listWidget.widgetStringValue = "Red"
        let filledFields = service.fields(in: filled)
        try service.verify(filledFields, in: reopen(filled))
        try require(filledFields.first { $0.name == "name" }?.value == "新填寫 ABC", "Native text fill failed")
        try require(filledFields.first { $0.name == "consent" }?.isSelected == false, "Native checkbox fill failed")
        try require(filledFields.filter { $0.name == "attending" && $0.isSelected }.map(\.exportValue) == ["No"],
                    "Radio group is not exclusive")
        try require(filledFields.first { $0.name == "department" }?.value == "Support",
                    "Native Dropdown fill failed")
        try require(filledFields.first { $0.name == "colour" }?.value == "Red",
                    "Native List Box fill failed")
        try require(filledFields.map(\.isDefaultSelected) == defaultsBefore, "Filling changed defaults")

        // Reopening must retain designer IDs. Geometry/default-only edits must
        // survive without depending on a form-value change notification.
        fields[0].bounds = CGRect(x: 70, y: 520, width: 240, height: 60)
        fields[1].bounds = CGRect(x: 45, y: 445, width: 30, height: 26)
        fields[2].bounds = CGRect(x: 35, y: 390, width: 28, height: 30)
        fields[3].bounds = CGRect(x: 95, y: 390, width: 32, height: 28)
        fields[4].bounds = CGRect(x: 60, y: 340, width: 210, height: 30)
        fields[5].bounds = CGRect(x: 60, y: 230, width: 210, height: 84)
        fields[0].fontSize = 18
        fields[0].defaultValue = "New default"
        fields[2].isSelected = false
        fields[2].isDefaultSelected = false
        fields[3].isSelected = true
        fields[3].isDefaultSelected = true
        try service.replaceFields(fields, in: reopened)
        let second = try reopen(reopened)
        try service.verify(fields, in: second)

        // Deletion must clear both page Widgets and canonical /Fields entries.
        try service.replaceFields([], in: second)
        let empty = try reopen(second)
        try service.verify([], in: empty)
        try service.verifyFieldTree([], in: empty)
        try require(empty.page(at: 0)?.annotations.filter { $0.type == "Widget" }.count == 1,
                    "Deletion removed an existing field or retained a designed Widget")
        try require(empty.page(at: 0)?.annotations.first { $0.fieldName == "existing" }?.widgetStringValue == "Preserve me",
                    "Existing field was not retained after deleting all designed fields")

        var collision = text
        collision.name = "existing"
        try rejects { try service.validate([collision], in: empty) }
        var invalidExport = check
        invalidExport.exportValue = "Off"
        try rejects { try service.validate([invalidExport], in: empty) }
        try service.validate([yes], in: empty)
        var secondSelected = no
        secondSelected.isSelected = true
        try rejects { try service.validate([yes, secondSelected], in: empty) }
        var duplicateOption = no
        duplicateOption.exportValue = yes.exportValue
        try rejects { try service.validate([yes, duplicateOption], in: empty) }
        var invalidChoices = dropdown
        invalidChoices.choices = ["Same", "Same"]
        try rejects { try service.validate([invalidChoices], in: empty) }

        // Sidebar production factory: generated names, an individually saved
        // first radio option, then a sibling with a distinct choice on reopen.
        let placedText = try service.fieldForPlacement(
            kind: .text, pageIndex: 0, bounds: text.bounds,
            radioGroupName: nil, in: empty
        )
        try service.replaceFields([placedText], in: empty)
        let placedOnce = try reopen(empty)
        try service.verify([placedText], in: placedOnce)
        let nextText = try service.fieldForPlacement(
            kind: .text, pageIndex: 0, bounds: text.bounds.offsetBy(dx: 0, dy: -60),
            radioGroupName: nil, in: placedOnce
        )
        try require(placedText.name != nextText.name, "Placement reused a text field name")
        let firstRadio = try service.fieldForPlacement(
            kind: .radioButton, pageIndex: 0, bounds: yes.bounds,
            radioGroupName: "placementGroup", in: placedOnce
        )
        try service.replaceFields([placedText, firstRadio], in: placedOnce)
        let firstOptionSaved = try reopen(placedOnce)
        try service.verify([placedText, firstRadio], in: firstOptionSaved)
        let secondRadio = try service.fieldForPlacement(
            kind: .radioButton, pageIndex: 0, bounds: no.bounds,
            radioGroupName: "placementGroup", in: firstOptionSaved
        )
        try require(firstRadio.exportValue != secondRadio.exportValue, "Placement reused a radio choice")
        try service.replaceFields([placedText, firstRadio, secondRadio], in: firstOptionSaved)
        try service.verify([placedText, firstRadio, secondRadio], in: reopen(firstOptionSaved))
        try rejects {
            _ = try service.fieldForPlacement(kind: .radioButton, pageIndex: 0, bounds: no.bounds,
                                               radioGroupName: "existing", in: firstOptionSaved)
        }
        let placedDropdown = try service.fieldForPlacement(
            kind: .dropdown, pageIndex: 0,
            bounds: CGRect(x: 280, y: 350, width: 180, height: 28),
            radioGroupName: nil,
            choiceOptions: ["One", "Two", "Three"],
            in: firstOptionSaved
        )
        try service.replaceFields(
            [placedText, firstRadio, secondRadio, placedDropdown],
            in: firstOptionSaved
        )
        let firstDropdownSaved = try reopen(firstOptionSaved)
        try service.verify(
            [placedText, firstRadio, secondRadio, placedDropdown],
            in: firstDropdownSaved
        )
        let secondDropdown = try service.fieldForPlacement(
            kind: .dropdown, pageIndex: 0,
            bounds: CGRect(x: 280, y: 310, width: 180, height: 28),
            radioGroupName: nil,
            choiceOptions: ["One", "Two", "Three"],
            in: firstDropdownSaved
        )
        try require(
            placedDropdown.name != secondDropdown.name,
            "Placement reused a Dropdown field name"
        )
        let placedList = try service.fieldForPlacement(
            kind: .listBox, pageIndex: 0,
            bounds: CGRect(x: 280, y: 250, width: 180, height: 72),
            radioGroupName: nil,
            choiceOptions: ["Alpha", "Beta", "Gamma"],
            in: firstDropdownSaved
        )
        try service.replaceFields(
            [placedText, firstRadio, secondRadio, placedDropdown, secondDropdown, placedList],
            in: firstDropdownSaved
        )
        try service.verify(
            [placedText, firstRadio, secondRadio, placedDropdown, secondDropdown, placedList],
            in: reopen(firstDropdownSaved)
        )

        let crop = CGRect(x: 20, y: 30, width: 400, height: 600)
        let point = CGPoint(x: 60, y: 100)
        let expected: [(Int, CGPoint)] = [
            (0, CGPoint(x: 40, y: 530)), (90, CGPoint(x: 70, y: 40)),
            (180, CGPoint(x: 360, y: 70)), (270, CGPoint(x: 530, y: 360)),
        ]
        for (rotation, target) in expected {
            let geometry = PDFFormPageGeometry(cropBox: crop, rotation: rotation)
            let displayed = point.applying(geometry.transform)
            try require(displayed == target, "Incorrect placement on rotated/cropped page")
            try require(displayed.applying(geometry.transform.inverted()) == point, "Inverse placement failed")
        }
        print("Form design text/button/choice creation, field tree, defaults, geometry, document-replacement deletion and rejection checks passed.")
    }

    private static func blankDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw Failure("Could not create PDF context")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw Failure("Could not open fixture") }
        return document
    }

    private static func reopen(_ document: PDFDocument) throws -> PDFDocument {
        let service = PDFFormDesignService()
        let expected = service.fields(in: document)
        let expectedValues = PDFAcroFormService().snapshots(in: document)
        guard let serialized = document.dataRepresentation() else { throw Failure("Could not serialize PDF") }
        let data = try service.registeredData(serialized, fields: expected)
        try PDFAcroFormService().verify(expectedValues, in: data, password: nil)
        guard let reopened = PDFDocument(data: data) else { throw Failure("Could not reopen PDF") }
        return reopened
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private static func rejects(_ action: () throws -> Void) throws {
        do { try action() }
        catch is PDFFormDesignError { return }
        throw Failure("Invalid form design was accepted")
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
#endif
