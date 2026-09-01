import Foundation
import CoreGraphics
import PDFKit
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum PDFFormDesignError: LocalizedError {
    case invalidField(String)
    case documentChanged
    case permissionDenied
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .invalidField(reason): reason
        case .documentChanged:
            "The PDF changed while the form designer was open. Close it and reopen the designer before applying changes."
        case .permissionDenied:
            "This PDF does not permit creating or changing form fields."
        case .verificationFailed:
            "The form design could not be saved and verified safely. The original document has not been changed."
        }
    }
}

nonisolated struct PDFFormDesignService {
    // Only fields authored here are rebuilt. Foreign Widgets, actions, field
    // hierarchies and signatures remain outside the designer's editing scope.
    private let identifierKey = PDFAnnotationKey(rawValue: "/PDFEditorFormID")

    func fields(in document: PDFDocument) -> [PDFFormDesignField] {
        let buttonDefaults = buttonDefaultChoices(in: document)
        return (0..<document.pageCount).flatMap { pageIndex in
            document.page(at: pageIndex)?.annotations.compactMap { annotation in
                guard annotation.type == "Widget",
                      let rawID = annotation.value(forAnnotationKey: identifierKey) as? String,
                      let id = UUID(uuidString: rawID) else { return nil }
                let kind: PDFFormDesignKind
                if annotation.widgetFieldType == .text {
                    kind = .text
                } else if annotation.widgetFieldType == .button,
                          annotation.widgetControlType == .checkBoxControl {
                    kind = .checkBox
                } else if annotation.widgetFieldType == .button,
                          annotation.widgetControlType == .radioButtonControl {
                    kind = .radioButton
                } else { return nil }
                let export = kind == .text ? "Yes" : annotation.buttonWidgetStateString
                return PDFFormDesignField(
                    id: id, pageIndex: pageIndex, kind: kind,
                    name: annotation.fieldName ?? "", bounds: annotation.bounds,
                    value: kind == .text ? annotation.widgetStringValue ?? "" : "",
                    defaultValue: kind == .text ? annotation.widgetDefaultStringValue ?? "" : "",
                    fontSize: kind == .text ? annotation.font?.pointSize ?? 12 : 12,
                    isMultiline: kind == .text && annotation.isMultiline,
                    exportValue: kind == .text ? "Yes" : export,
                    isSelected: kind != .text && annotation.buttonWidgetState == .onState,
                    isDefaultSelected: kind != .text && (
                        annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/PDFEditorDefaultChoice")) as? String
                        ?? buttonDefaults[id] ?? annotation.widgetDefaultStringValue
                    ) == export
                )
            } ?? []
        }
    }

    func nextPlacementName(for kind: PDFFormDesignKind, in document: PDFDocument) -> String {
        let prefix = kind == .text ? "Text" : kind == .checkBox ? "Checkbox" : "Radio"
        let names = (0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap { $0.type == "Widget" ? $0.fieldName : nil } ?? []
        }
        var number = 1
        while names.contains(where: {
            let candidate = "\(prefix)\(number)"
            return $0 == candidate || $0.hasPrefix(candidate + ".") || candidate.hasPrefix($0 + ".")
        }) { number += 1 }
        return "\(prefix)\(number)"
    }

    /// Builds exactly one real field. Radio options share a name, while each
    /// option gets a distinct export value. Imported fields remain protected.
    func fieldForPlacement(
        kind: PDFFormDesignKind, pageIndex: Int, bounds: CGRect,
        radioGroupName: String?, in document: PDFDocument
    ) throws -> PDFFormDesignField {
        let existing = fields(in: document)
        let name = kind == .radioButton
            ? radioGroupName ?? nextPlacementName(for: kind, in: document)
            : nextPlacementName(for: kind, in: document)
        var field = PDFFormDesignField(pageIndex: pageIndex, kind: kind, name: name, bounds: bounds)
        if kind == .radioButton {
            let used = Set(existing.filter { $0.name == name }.map(\.exportValue))
            var number = 1
            while used.contains("Option\(number)") { number += 1 }
            field.exportValue = "Option\(number)"
        }
        try validate(existing + [field], in: document)
        return field
    }

    func removeDesignedFields(from document: PDFDocument) {
        let identifiers = Set(fields(in: document).map(\.id))
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let value = annotation.value(forAnnotationKey: identifierKey) as? String,
                   let id = UUID(uuidString: value), identifiers.contains(id) {
                    page.removeAnnotation(annotation)
                }
            }
        }
    }

    func validate(_ fields: [PDFFormDesignField], in document: PDFDocument) throws {
        guard Set(fields.map(\.id)).count == fields.count else {
            throw PDFFormDesignError.invalidField("Duplicate field identifiers.")
        }
        let ownedIDs = Set(self.fields(in: document).map(\.id))
        let foreignNames = Set((0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap { annotation -> String? in
                guard annotation.type == "Widget" else { return nil }
                if let value = annotation.value(forAnnotationKey: identifierKey) as? String,
                   let id = UUID(uuidString: value), ownedIDs.contains(id) { return nil }
                return annotation.fieldName
            } ?? []
        })
        for field in fields {
            guard !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.name == field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !field.name.contains("."), !field.name.contains("\0") else {
                throw PDFFormDesignError.invalidField("Enter a field name without leading/trailing spaces, periods or null characters.")
            }
            guard !foreignNames.contains(where: {
                $0 == field.name || $0.hasPrefix(field.name + ".") || field.name.hasPrefix($0 + ".")
            }) else {
                throw PDFFormDesignError.invalidField("The name \"\(field.name)\" is already used by an existing form field.")
            }
            guard let page = document.page(at: field.pageIndex),
                  [field.bounds.minX, field.bounds.minY, field.bounds.width, field.bounds.height,
                   field.fontSize].allSatisfy(\.isFinite),
                  field.bounds.width >= field.kind.minimumDimension,
                  field.bounds.height >= field.kind.minimumDimension,
                  page.bounds(for: .cropBox).insetBy(dx: -0.01, dy: -0.01).contains(field.bounds),
                  (6...72).contains(field.fontSize) else {
                throw PDFFormDesignError.invalidField(
                    "Keep text fields at least 12 points wide and high, buttons at least 11 points, and every field inside its page with a 6–72 point font."
                )
            }
            if field.kind != .text {
                // A PDF button's on-state is a Name. Keep export values portable
                // and reserve Off for the unchecked state.
                guard !field.exportValue.isEmpty, field.exportValue != "Off",
                      field.exportValue.utf8.allSatisfy({
                          (65...90).contains($0) || (97...122).contains($0) ||
                          (48...57).contains($0) || $0 == 95 || $0 == 45
                      }) else {
                    throw PDFFormDesignError.invalidField("Button export values must use letters A–Z, numbers, underscores or hyphens, and cannot be Off.")
                }
            }
        }
        for (name, group) in Dictionary(grouping: fields, by: \.name) {
            if group.count > 1 {
                guard group.allSatisfy({ $0.kind == .radioButton }),
                      Set(group.map(\.exportValue)).count == group.count else {
                    throw PDFFormDesignError.invalidField("Use unique names, or use one group name with distinct export values for radio buttons: \(name).")
                }
            }
            if group.first?.kind == .radioButton {
                guard group.filter(\.isSelected).count <= 1,
                      group.filter(\.isDefaultSelected).count <= 1 else {
                    throw PDFFormDesignError.invalidField("Radio group \"\(name)\" allows at most one selected/default option.")
                }
            }
        }
    }

    func replaceFields(_ fields: [PDFFormDesignField], in document: PDFDocument) throws {
        try preparePresentationUpdate(fields, in: document).apply()
    }

    /// Prepare everything that can fail before touching the displayed pages.
    /// The caller commits this only after the independent PDF passes its full
    /// serialization/field-tree checks. This updates Widgets, never page content
    /// or PDFDocument identity, so PDFView can retain its rendered page tiles.
    func preparePresentationUpdate(
        _ fields: [PDFFormDesignField], in document: PDFDocument
    ) throws -> PresentationUpdate {
        try validate(fields, in: document)
        let ownedIDs = Set(self.fields(in: document).map(\.id))
        var removals: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let rawID = annotation.value(forAnnotationKey: identifierKey) as? String,
                   let id = UUID(uuidString: rawID), ownedIDs.contains(id) {
                    removals.append((page, annotation))
                }
            }
        }
        var additions: [(page: PDFPage, annotation: PDFAnnotation)] = []
        var selectedButtons: [PDFAnnotation] = []
        for field in fields {
            guard let page = document.page(at: field.pageIndex) else {
                throw PDFFormDesignError.verificationFailed
            }
            let annotation = makeAnnotation(for: field, allFields: fields)
            if field.kind != .text && field.isSelected { selectedButtons.append(annotation) }
            additions.append((page, annotation))
        }
        return PresentationUpdate(
            removals: removals, additions: additions,
            selectedButtons: selectedButtons,
            boundsUpdates: [], fontUpdates: []
        )
    }

    /// A resize can retain the live Widget object. PDFKit may leave the removed
    /// Widget's border layer behind when an annotation is replaced at a new
    /// rectangle, even if the page's annotation cache is explicitly refreshed.
    /// Require every non-geometry property to match before using this path.
    func prepareBoundsUpdate(
        for field: PDFFormDesignField, in document: PDFDocument
    ) throws -> PresentationUpdate {
        let currentFields = fields(in: document)
        guard let index = currentFields.firstIndex(where: { $0.id == field.id }) else {
            throw PDFFormDesignError.documentChanged
        }
        var expectedCurrent = field
        expectedCurrent.bounds = currentFields[index].bounds
        guard expectedCurrent == currentFields[index] else {
            throw PDFFormDesignError.documentChanged
        }
        var updatedFields = currentFields
        updatedFields[index] = field
        try validate(updatedFields, in: document)

        let page = document.page(at: field.pageIndex)
        let annotation = page?.annotations.first { annotation in
            guard annotation.type == "Widget",
                  let rawID = annotation.value(forAnnotationKey: identifierKey) as? String else {
                return false
            }
            return UUID(uuidString: rawID) == field.id
        }
        guard let annotation else { throw PDFFormDesignError.documentChanged }
        return PresentationUpdate(
            removals: [], additions: [], selectedButtons: [],
            boundsUpdates: [(annotation: annotation, bounds: field.bounds)],
            fontUpdates: []
        )
    }

    /// Preserve the live text Widget while changing its font and fitted bounds. The caller
    /// still serializes and verifies the complete canonical candidate before
    /// applying this prepared presentation update.
    func prepareFontSizeUpdate(
        for field: PDFFormDesignField, in document: PDFDocument
    ) throws -> PresentationUpdate {
        let currentFields = fields(in: document)
        guard field.kind == .text,
              let index = currentFields.firstIndex(where: { $0.id == field.id }) else {
            throw PDFFormDesignError.documentChanged
        }
        var expectedCurrent = field
        expectedCurrent.fontSize = currentFields[index].fontSize
        expectedCurrent.bounds = currentFields[index].bounds
        guard expectedCurrent == currentFields[index] else {
            throw PDFFormDesignError.documentChanged
        }
        var updatedFields = currentFields
        updatedFields[index] = field
        try validate(updatedFields, in: document)
        guard let annotation = authoredAnnotation(for: field.id, in: document) else {
            throw PDFFormDesignError.documentChanged
        }
        return PresentationUpdate(
            removals: [], additions: [], selectedButtons: [],
            boundsUpdates: [(annotation: annotation, bounds: field.bounds)],
            fontUpdates: [(annotation: annotation, size: field.fontSize)]
        )
    }

    /// Delete exactly one app-authored Widget without replacing its siblings.
    func prepareDeletion(
        of field: PDFFormDesignField, in document: PDFDocument
    ) throws -> PresentationUpdate {
        let currentFields = fields(in: document)
        guard currentFields.contains(field),
              let annotation = authoredAnnotation(for: field.id, in: document),
              let page = annotation.page else {
            throw PDFFormDesignError.documentChanged
        }
        let remainingFields = currentFields.filter { $0.id != field.id }
        try validate(remainingFields, in: document)
        return PresentationUpdate(
            removals: [(page: page, annotation: annotation)], additions: [],
            selectedButtons: [], boundsUpdates: [], fontUpdates: []
        )
    }

    /// Restore one verified authored field without rebuilding the PDFDocument
    /// or any sibling Widgets. Used by the dedicated field-deletion Undo path.
    func prepareAddition(
        of field: PDFFormDesignField,
        reusing retainedAnnotation: PDFAnnotation? = nil,
        in document: PDFDocument
    ) throws -> PresentationUpdate {
        let currentFields = fields(in: document)
        guard !currentFields.contains(where: { $0.id == field.id }),
              let page = document.page(at: field.pageIndex) else {
            throw PDFFormDesignError.documentChanged
        }
        let updatedFields = currentFields + [field]
        try validate(updatedFields, in: document)
        let annotation: PDFAnnotation
        if let retainedAnnotation {
            guard retainedAnnotation.page == nil,
                  retainedAnnotation.type == "Widget",
                  let rawID = retainedAnnotation.value(
                    forAnnotationKey: identifierKey
                  ) as? String,
                  UUID(uuidString: rawID) == field.id else {
                throw PDFFormDesignError.documentChanged
            }
            annotation = retainedAnnotation
            configure(annotation, for: field, allFields: updatedFields)
        } else {
            annotation = makeAnnotation(for: field, allFields: updatedFields)
        }
        return PresentationUpdate(
            removals: [], additions: [(page: page, annotation: annotation)],
            selectedButtons: field.kind != .text && field.isSelected ? [annotation] : [],
            boundsUpdates: [], fontUpdates: []
        )
    }

    private func makeAnnotation(
        for field: PDFFormDesignField, allFields: [PDFFormDesignField]
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: field.bounds, forType: .widget, withProperties: nil
        )
        configure(annotation, for: field, allFields: allFields)
        return annotation
    }

    private func configure(
        _ annotation: PDFAnnotation,
        for field: PDFFormDesignField,
        allFields: [PDFFormDesignField]
    ) {
        annotation.bounds = field.bounds
        annotation.setValue(field.id.uuidString, forAnnotationKey: identifierKey)
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.backgroundColor = .white
        annotation.color = .black
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        if field.kind == .text {
            annotation.widgetFieldType = .text
#if os(macOS)
            annotation.font = NSFont.systemFont(ofSize: field.fontSize)
#else
            annotation.font = UIFont.systemFont(ofSize: field.fontSize)
#endif
            annotation.fontColor = .black
            annotation.isMultiline = field.isMultiline
            annotation.widgetStringValue = field.value
            annotation.widgetDefaultStringValue = field.defaultValue
        } else {
            annotation.widgetFieldType = .button
            annotation.widgetControlType = field.kind == .checkBox
                ? .checkBoxControl : .radioButtonControl
            annotation.buttonWidgetStateString = field.exportValue
            annotation.buttonWidgetState = .offState
            if field.kind == .radioButton {
                annotation.allowsToggleToOff = true
                annotation.radiosInUnison = false
            }
            let defaultOption = allFields.first {
                $0.name == field.name && $0.isDefaultSelected
            }?.exportValue ?? "Off"
            // PDFKit only implements widgetDefaultStringValue for text.
            // Carry button defaults until the canonical writer emits /DV Names.
            annotation.setValue(
                defaultOption,
                forAnnotationKey: PDFAnnotationKey(rawValue: "/PDFEditorDefaultChoice")
            )
        }
        // Setting the type resets PDFKit's name to text0/button0. Name last.
        annotation.fieldName = field.name
    }

    func authoredAnnotation(
        for id: UUID, in document: PDFDocument
    ) -> PDFAnnotation? {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let annotation = page.annotations.first(where: { annotation in
                guard annotation.type == "Widget",
                      let rawID = annotation.value(forAnnotationKey: identifierKey) as? String else {
                    return false
                }
                return UUID(uuidString: rawID) == id
            }) {
                return annotation
            }
        }
        return nil
    }

    struct PresentationUpdate {
        fileprivate let removals: [(page: PDFPage, annotation: PDFAnnotation)]
        fileprivate let additions: [(page: PDFPage, annotation: PDFAnnotation)]
        fileprivate let selectedButtons: [PDFAnnotation]
        fileprivate let boundsUpdates: [(annotation: PDFAnnotation, bounds: CGRect)]
        fileprivate let fontUpdates: [(annotation: PDFAnnotation, size: CGFloat)]

        /// Use immediately, on the same executor as preparation. All pages and
        /// annotations are already resolved; committing cannot throw midway.
        func apply() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            // Preserve Widget identity for geometry-only changes. Replacing the
            // object can leave PDFKit's old black border layer on screen.
            for item in boundsUpdates { item.annotation.bounds = item.bounds }
            for item in fontUpdates {
#if os(macOS)
                item.annotation.font = NSFont.systemFont(ofSize: item.size)
#else
                item.annotation.font = UIFont.systemFont(ofSize: item.size)
#endif
            }
            for item in removals { item.page.removeAnnotation(item.annotation) }
            // Match the verified candidate's ordering: foreign annotations stay
            // in place, then authored Widgets appear in the supplied field order.
            // Form value snapshots use page/annotation indices as references.
            for item in additions { item.page.addAnnotation(item.annotation) }
            // Restore selections only after all members are attached. Adding an
            // unchecked radio sibling must not reset the selected option.
            for annotation in selectedButtons { annotation.buttonWidgetState = .onState }
        }
    }

    /// Repair PDFKit's serialized field registration before accepting a mutation.
    /// Already-canonical PDFs (including encrypted ones) need no byte changes.
    func registeredData(_ data: Data, fields: [PDFFormDesignField], password: String? = nil) throws -> Data {
        if let document = PDFDocument(data: data) {
            if document.isLocked, let password { _ = document.unlock(withPassword: password) }
            if !document.isLocked,
               (try? verify(fields, in: document)) != nil,
               (try? verifyFieldTree(fields, in: document)) != nil {
                return data
            }
        }
        let registered = try PDFFormFieldTreeWriter().write(data, fields: fields)
        guard let reopened = PDFDocument(data: registered) else { throw PDFFormDesignError.verificationFailed }
        try verify(fields, in: reopened)
        try verifyFieldTree(fields, in: reopened)
        return registered
    }

    func verify(_ expected: [PDFFormDesignField], in document: PDFDocument) throws {
        let actual = fields(in: document)
        guard actual.count == expected.count,
              Set(actual.map(\.id)).count == actual.count else {
            throw PDFFormDesignError.verificationFailed
        }
        for field in expected {
            guard let found = actual.first(where: { $0.id == field.id }),
                  found.pageIndex == field.pageIndex, found.kind == field.kind,
                  found.name == field.name,
                  abs(found.bounds.minX - field.bounds.minX) < 0.05,
                  abs(found.bounds.minY - field.bounds.minY) < 0.05,
                  abs(found.bounds.width - field.bounds.width) < 0.05,
                  abs(found.bounds.height - field.bounds.height) < 0.05 else {
                throw PDFFormDesignError.verificationFailed
            }
            if field.kind == .text {
                guard found.value == field.value, found.defaultValue == field.defaultValue,
                      found.isMultiline == field.isMultiline,
                      abs(found.fontSize - field.fontSize) < 0.05 else {
                    throw PDFFormDesignError.verificationFailed
                }
            } else {
                guard found.exportValue == field.exportValue,
                      found.isSelected == field.isSelected,
                      found.isDefaultSelected == field.isDefaultSelected else {
                    throw PDFFormDesignError.verificationFailed
                }
            }
        }
        if !expected.isEmpty { try verifyFieldTree(expected, in: document) }
    }

    /// A page Widget alone is insufficient: it must also belong to /Fields.
    /// Radio options must resolve to a single terminal field, not independent
    /// fields that happen to have the same name. Also catches orphaned deleted
    /// managed fields still referenced by the catalog.
    func verifyFieldTree(_ expected: [PDFFormDesignField], in document: PDFDocument) throws {
        guard let reference = document.documentRef, let catalog = reference.catalog else {
            throw PDFFormDesignError.verificationFailed
        }
        var acroForm: CGPDFDictionaryRef?
        var roots: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
              CGPDFDictionaryGetArray(acroForm, "Fields", &roots), let roots else {
            if expected.isEmpty { return }
            throw PDFFormDesignError.verificationFailed
        }
        var registered: [UUID: (name: String, terminal: UInt, type: String, flags: Int)] = [:]
        var visited = Set<UInt>()
        func walk(_ dictionary: CGPDFDictionaryRef, name: String, terminal: UInt?,
                  type: String, flags: Int, depth: Int) throws {
            let identity = UInt(bitPattern: dictionary.rawValue)
            guard depth < 64, visited.count < 100_000, visited.insert(identity).inserted else {
                throw PDFFormDesignError.verificationFailed
            }
            let partialName = pdfString("T", in: dictionary)
            let fullName = partialName.map { name.isEmpty ? $0 : name + "." + $0 } ?? name
            let fieldIdentity = partialName != nil ? identity : terminal ?? identity
            let fieldType = pdfName("FT", in: dictionary) ?? type
            var rawFlags: CGPDFInteger = 0
            let fieldFlags = CGPDFDictionaryGetInteger(dictionary, "Ff", &rawFlags) ? Int(rawFlags) : flags
            if let rawID = pdfString("PDFEditorFormID", in: dictionary), let id = UUID(uuidString: rawID) {
                guard registered[id] == nil else { throw PDFFormDesignError.verificationFailed }
                registered[id] = (fullName, fieldIdentity, fieldType, fieldFlags)
            }
            var children: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Kids", &children), let children {
                for index in 0..<CGPDFArrayGetCount(children) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(children, index, &child), let child else {
                        throw PDFFormDesignError.verificationFailed
                    }
                    try walk(child, name: fullName, terminal: fieldIdentity, type: fieldType,
                             flags: fieldFlags, depth: depth + 1)
                }
            }
        }
        for index in 0..<CGPDFArrayGetCount(roots) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(roots, index, &field), let field else {
                throw PDFFormDesignError.verificationFailed
            }
            try walk(field, name: "", terminal: nil, type: "", flags: 0, depth: 0)
        }
        guard Set(registered.keys) == Set(expected.map(\.id)) else {
            throw PDFFormDesignError.verificationFailed
        }
        for field in expected {
            guard let record = registered[field.id], record.name == field.name,
                  record.type == (field.kind == .text ? "Tx" : "Btn"),
                  field.kind == .text || ((record.flags & (1 << 15)) != 0) == (field.kind == .radioButton),
                  field.kind == .text || record.flags & (1 << 16) == 0 else {
                throw PDFFormDesignError.verificationFailed
            }
        }
        for group in Dictionary(grouping: expected.filter { $0.kind == .radioButton }, by: \.name).values {
            guard Set(group.compactMap { registered[$0.id]?.terminal }).count == 1 else {
                throw PDFFormDesignError.verificationFailed
            }
        }
    }

    private func buttonDefaultChoices(in document: PDFDocument) -> [UUID: String] {
        var result: [UUID: String] = [:]
        // Retained documents can contain pages refreshed from newer bytes.
        // Read each actual page's dictionary, not the document's original tree.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef,
                  let dictionary = page.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var widget: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &widget), let widget,
                      let rawID = pdfString("PDFEditorFormID", in: widget), let id = UUID(uuidString: rawID) else { continue }
                var current: CGPDFDictionaryRef? = widget
                var visited = Set<UInt>()
                while let node = current, visited.count < 64,
                      visited.insert(UInt(bitPattern: node.rawValue)).inserted {
                    if let value = pdfName("DV", in: node) ?? pdfString("DV", in: node) {
                        result[id] = value
                        break
                    }
                    var parent: CGPDFDictionaryRef?
                    current = CGPDFDictionaryGetDictionary(node, "Parent", &parent) ? parent : nil
                }
            }
        }
        return result
    }

    private func pdfString(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value,
              let text = CGPDFStringCopyTextString(value) else { return nil }
        return text as String
    }

    private func pdfName(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
