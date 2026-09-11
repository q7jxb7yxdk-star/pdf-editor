#if FORM_DOCUMENT_PLACEMENT_STANDALONE_VALIDATION
import CoreGraphics
import Foundation
import PDFKit

@main
struct FormDocumentPlacementRoundTrip {
    @MainActor
    static func main() async throws {
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
        let textBox = try grouped {
            try document.addPlacedFormField(
                kind: .text,
                pageIndex: 0,
                bounds: CGRect(x: 40, y: 400, width: 100, height: 22),
                radioGroupName: nil,
                undoManager: undoManager
            )
        }
        let multilineText = "First line\nSecond line"
        guard textBox.isMultiline,
              PDFFormDesignService().authoredAnnotation(
                  for: textBox.id,
                  in: document.pdfDocument
              )?.isMultiline == true else {
            throw Failure("New Textbox did not install as a multiline Widget")
        }
        let editedTextBox = try grouped {
            try document.updateAuthoredTextFormField(
                id: textBox.id,
                text: multilineText,
                bounds: textBox.bounds,
                undoManager: undoManager
            )
        }
        let resizedTextBox = try grouped {
            try document.setAuthoredFormFieldFontSize(
                id: textBox.id,
                fontSize: 18,
                undoManager: undoManager
            )
        }
        let expectedTextSize = PDFFormDesignKind.text.fittedTextSize(
            text: multilineText,
            fontSize: 18,
            maximumWidth: 572
        )
        guard abs(resizedTextBox.fontSize - 18) < 0.01,
              abs(resizedTextBox.bounds.height - expectedTextSize.height) < 0.01,
              abs(resizedTextBox.bounds.width - expectedTextSize.width) < 0.01,
              abs(resizedTextBox.bounds.maxY - editedTextBox.bounds.maxY) < 0.01 else {
            throw Failure("Textbox font-size update did not fit its text size")
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
        let digitalSignature = try grouped {
            try document.addPlacedFormField(
                kind: .digitalSignature,
                pageIndex: 0,
                bounds: CGRect(x: 240, y: 500, width: 180, height: 50),
                radioGroupName: nil,
                undoManager: undoManager
            )
        }
        guard digitalSignature.name == "Signature1",
              PDFFormDesignService().authoredAnnotation(
                  for: digitalSignature.id,
                  in: document.pdfDocument
              )?.widgetFieldType == .signature else {
            throw Failure("Digital Signature Field placement did not create a Signature Widget")
        }
        let resizedSignature = try grouped {
            try document.resizeAuthoredFormField(
                id: digitalSignature.id,
                bounds: CGRect(x: 230, y: 490, width: 210, height: 60),
                undoManager: undoManager
            )
        }
        guard resizedSignature.bounds == CGRect(
            x: 230, y: 490, width: 210, height: 60
        ) else {
            throw Failure("Digital Signature Field resize did not retain its bounds")
        }
        try grouped {
            try document.deleteAuthoredFormField(
                id: digitalSignature.id,
                undoManager: undoManager
            )
        }
        guard !PDFFormDesignService().fields(in: document.pdfDocument).contains(where: {
            $0.id == digitalSignature.id
        }) else {
            throw Failure("Digital Signature Field deletion retained the field")
        }
        undoManager.undo()
        guard PDFFormDesignService().fields(in: document.pdfDocument).first(where: {
            $0.id == digitalSignature.id
        })?.bounds == resizedSignature.bounds else {
            throw Failure("Digital Signature Field deletion Undo did not restore the field")
        }

        let metadataDocument = try PDFEditorDocument(data: pdfWithXMPMetadata())
        let metadataSignature = try metadataDocument.addPlacedFormField(
            kind: .digitalSignature,
            pageIndex: 0,
            bounds: CGRect(x: 50, y: 680, width: 180, height: 50),
            radioGroupName: nil,
            undoManager: nil
        )
        let savedMetadataData = try await metadataDocument.prepareManualSave(
            applying: []
        ).data
        guard metadataContainsReadableXML(savedMetadataData),
              let savedMetadataDocument = PDFDocument(data: savedMetadataData) else {
            throw Failure("Final save retained XMP compressed without a FlateDecode filter")
        }
        let savedMetadataFields = PDFFormDesignService().fields(in: savedMetadataDocument)
        guard savedMetadataFields.count == 1,
              savedMetadataFields.first?.id == metadataSignature.id,
              savedMetadataFields.first?.kind == .digitalSignature else {
            throw Failure("Final save did not retain the empty Signature Field")
        }
        try PDFFormDesignService().verifyFieldTree(
            savedMetadataFields,
            in: savedMetadataDocument
        )
        print(
            "Textbox, Dropdown, List Box and Digital Signature Field placement, " +
            "resize, deletion, Undo and final-save XMP repair passed."
        )
    }

    private static func pdfWithXMPMetadata() -> Data {
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:format>application/pdf</dc:format>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let startXRef = data.count
        data.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            data.append(contentsOf: String(format: "%010lld 00000 n \n", Int64(offset)).utf8)
        }
        data.append(contentsOf: (
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n" +
            "startxref\n\(startXRef)\n%%EOF\n"
        ).utf8)
        return data
    }

    private static func metadataContainsReadableXML(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return false }
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream),
              let stream,
              let decodedData = CGPDFStreamCopyData(stream, &format) else { return false }
        return String(data: decodedData as Data, encoding: .utf8)?.contains("<x:xmpmeta") == true
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

}
#endif
