import Foundation

nonisolated enum PDFFormFieldTreeError: LocalizedError {
    case invalidStructure
    case encryptedDocumentUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidStructure:
            "The PDF form field tree could not be registered safely. The original document has not been changed."
        case .encryptedDocumentUnsupported:
            "Creating form fields in this encrypted PDF is not supported. Save an unprotected copy first. The original document has not been changed."
        }
    }
}

/// PDFKit serializes new Widgets without registering them in /AcroForm/Fields.
/// Append only field dictionaries and the catalog; never rewrite page content.
/// This accepts PDFKit's classic-xref output, and fails closed on encryption or
/// unsupported structures. Foreign field roots and AcroForm resources survive.
nonisolated struct PDFFormFieldTreeWriter {
    func write(_ data: Data, fields: [PDFFormDesignField]) throws -> Data {
        let source = [UInt8](data)
        let xref = try FormCrossReference(source: source)
        guard xref.encryptionReference == nil else {
            throw PDFFormFieldTreeError.encryptedDocumentUnsupported
        }
        let resolver = FormObjectResolver(source: source, entries: xref.entries)
        let catalog = try resolver.object(xref.root).body
        let pages = try FormPageTreeReader(resolver: resolver).pageReferences(catalog: catalog)
        var objects: [FormPDFReference: [UInt8]] = [:]
        var next = xref.size
        func allocate() -> FormPDFReference {
            defer { next += 1 }
            return FormPDFReference(objectNumber: next, generation: 0)
        }
        func body(_ ref: FormPDFReference) throws -> [UInt8] {
            if let changed = objects[ref] { return changed }
            return try resolver.object(ref).body
        }
        func resolvedValue(_ key: String, _ dictionary: [UInt8]) throws -> [UInt8]? {
            if let ref = FormPDFDictionaryEditor.reference(named: key, in: dictionary) {
                return try body(ref)
            }
            return FormPDFDictionaryEditor.rawValue(named: key, in: dictionary)
        }
        func refs(_ key: String, _ dictionary: [UInt8]) throws -> [FormPDFReference] {
            guard let value = try resolvedValue(key, dictionary) else { return [] }
            return try FormPDFDictionaryEditor.references(in: value)
        }
        let oldForm = try resolvedValue("AcroForm", catalog) ?? Array("<< >>".utf8)
        var roots: [FormPDFReference] = []
        var visited = Set<FormPDFReference>()
        // Remove stale authored roots left behind when PDFKit removes Widgets.
        // Mixed foreign trees are retained, pruning only our identified nodes.
        func prune(_ ref: FormPDFReference, depth: Int) throws -> Bool {
            guard depth < 64, visited.count < 100_000, visited.insert(ref).inserted else {
                throw PDFFormFieldTreeError.invalidStructure
            }
            var dictionary = try body(ref)
            if Self.identifier(in: dictionary) != nil ||
                FormPDFDictionaryEditor.value(named: "PDFEditorFormGroup", in: dictionary) == "true" {
                return false
            }
            let children = try refs("Kids", dictionary)
            if !children.isEmpty {
                let kept = try children.filter { try prune($0, depth: depth + 1) }
                if kept.count != children.count {
                    if kept.isEmpty { return false }
                    dictionary = try Self.set("Kids", Self.array(kept), in: dictionary)
                    objects[ref] = dictionary
                }
            }
            return true
        }
        for root in try refs("Fields", oldForm) where !visited.contains(root) {
            if try prune(root, depth: 0) { roots.append(root) }
        }

        guard Set(fields.map(\.id)).count == fields.count else { throw PDFFormFieldTreeError.invalidStructure }
        let expected = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        var widgets: [UUID: FormPDFReference] = [:]
        for (pageIndex, pageRef) in pages.enumerated() {
            for ref in try refs("Annots", body(pageRef)) {
                let dictionary = try body(ref)
                guard FormPDFDictionaryEditor.name(named: "Subtype", in: dictionary) == "Widget" else { continue }
                if let id = Self.identifier(in: dictionary) {
                    guard expected[id]?.pageIndex == pageIndex, widgets.updateValue(ref, forKey: id) == nil else {
                        throw PDFFormFieldTreeError.invalidStructure
                    }
                } else if !visited.contains(ref) {
                    // A pre-existing standalone Widget may also lack /Fields.
                    // Follow its existing Parent chain; do not flatten foreign groups.
                    var root = ref
                    var ancestors = Set<FormPDFReference>()
                    while let parent = FormPDFDictionaryEditor.reference(named: "Parent", in: try body(root)) {
                        guard ancestors.count < 64, ancestors.insert(root).inserted else {
                            throw PDFFormFieldTreeError.invalidStructure
                        }
                        root = parent
                    }
                    if !roots.contains(root) { roots.append(root) }
                }
            }
        }
        guard Set(widgets.keys) == Set(expected.keys) else { throw PDFFormFieldTreeError.invalidStructure }

        // Empty text appearances have no font resources in PDFKit output.
        // Supply a portable default for subsequent filling in other readers.
        var form = oldForm
        if fields.contains(where: { $0.kind == .text || $0.kind.isChoice }) {
            var resources = try resolvedValue("DR", form) ?? Array("<< >>".utf8)
            var fonts = try resolvedValue("Font", resources) ?? Array("<< >>".utf8)
            let font = allocate()
            objects[font] = Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)
            var fontName = "PDFEditorFormFont"
            while FormPDFDictionaryEditor.rawValue(named: fontName, in: fonts) != nil { fontName += "X" }
            fonts = try Self.set(fontName, font.pdfSyntax, in: fonts)
            // Preserve raw bytes, including non-UTF8 strings in foreign resources.
            resources = try Self.setBytes("Font", fonts, in: resources)
            form = try Self.setBytes("DR", resources, in: form)
            for field in fields where field.kind == .text || field.kind.isChoice {
                let ref = widgets[field.id]!
                let appearance = "(/\(fontName) \(field.fontSize) Tf 0 g)"
                objects[ref] = try Self.set("DA", appearance, in: body(ref))
            }
        }
        for field in fields where field.kind != .radioButton {
            let ref = widgets[field.id]!
            var widget = try Self.set("Parent", nil, in: body(ref))
            if field.kind == .checkBox {
                widget = try Self.set("DV", "/" + (field.isDefaultSelected ? field.exportValue : "Off"), in: widget)
                widget = try Self.set("PDFEditorDefaultChoice", nil, in: widget)
            } else if field.kind.isChoice {
                let options = "[" + field.choices.map {
                    "[\(Self.pdfString($0)) \(Self.pdfString($0))]"
                }.joined(separator: " ") + "]"
                widget = try Self.set("FT", "/Ch", in: widget)
                widget = try Self.set("Ff", field.kind == .dropdown ? "131072" : "0", in: widget)
                widget = try Self.set("Opt", options, in: widget)
                widget = try Self.set("V", field.value.isEmpty ? nil : Self.pdfString(field.value), in: widget)
                // PDFKit treats an absent /DV as the current /V after reopen.
                // Preserve an intentionally empty default with an empty string.
                widget = try Self.set("DV", Self.pdfString(field.defaultValue), in: widget)
                widget = try Self.set("I", nil, in: widget)
            }
            objects[ref] = widget
            roots.append(ref)
        }
        for name in Set(fields.filter { $0.kind == .radioButton }.map(\.name)).sorted() {
            let group = fields.filter { $0.kind == .radioButton && $0.name == name }
            let parent = allocate()
            let kids = group.map { widgets[$0.id]! }
            let selected = group.first(where: \.isSelected)?.exportValue ?? "Off"
            let defaultChoice = group.first(where: \.isDefaultSelected)?.exportValue ?? "Off"
            objects[parent] = Array(("<< /FT /Btn /T \(Self.pdfString(name)) /Ff 32768 " +
                "/Kids \(Self.array(kids)) /V /\(selected) /DV /\(defaultChoice) /PDFEditorFormGroup true >>").utf8)
            for ref in kids {
                var widget = try body(ref)
                for key in ["T", "FT", "Ff", "V", "DV", "PDFEditorDefaultChoice"] { widget = try Self.set(key, nil, in: widget) }
                objects[ref] = try Self.set("Parent", parent.pdfSyntax, in: widget)
            }
            roots.append(parent)
        }
        form = try Self.set("Fields", Self.array(roots), in: form)
        let formRef = allocate()
        objects[formRef] = form
        objects[xref.root] = try Self.set("AcroForm", formRef.pdfSyntax, in: catalog)

        var output = data
        output.append(10)
        var offsets: [(FormPDFReference, Int)] = []
        for ref in objects.keys.sorted(by: { $0.objectNumber < $1.objectNumber }) {
            offsets.append((ref, output.count))
            output.append(contentsOf: "\(ref.objectNumber) \(ref.generation) obj\n".utf8)
            output.append(contentsOf: objects[ref]!)
            output.append(contentsOf: "\nendobj\n".utf8)
        }
        let start = output.count
        output.append(contentsOf: "xref\n".utf8)
        for (ref, offset) in offsets {
            guard offset < 10_000_000_000 else { throw PDFFormFieldTreeError.invalidStructure }
            output.append(contentsOf: "\(ref.objectNumber) 1\n".utf8)
            output.append(contentsOf: String(format: "%010lld %05d n \n", Int64(offset), ref.generation).utf8)
        }
        output.append(contentsOf: "trailer\n<< /Size \(next) /Root \(xref.root.pdfSyntax) /Prev \(xref.startXRef)".utf8)
        if let info = xref.infoValue {
            output.append(contentsOf: " /Info ".utf8)
            output.append(contentsOf: info)
        }
        if let id = xref.identifierValue {
            output.append(contentsOf: " /ID ".utf8)
            output.append(contentsOf: id)
        }
        output.append(contentsOf: " >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return output
    }

    private static func identifier(in dictionary: [UInt8]) -> UUID? {
        guard let raw = FormPDFDictionaryEditor.rawValue(named: "PDFEditorFormID", in: dictionary) else { return nil }
        // PDFKit writes our UUID marker as ASCII; accept UTF-16 hex as well.
        if raw.first == 40, raw.last == 41 {
            return UUID(uuidString: String(decoding: raw.dropFirst().dropLast(), as: UTF8.self))
        }
        if raw.first == 60, raw.last == 62 {
            let hex = raw.dropFirst().dropLast().filter { !$0.isFormPDFWhitespace }
            guard hex.count % 2 == 0 else { return nil }
            var bytes = Data()
            let digits = Array(hex)
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(byte)
            }
            return String(data: bytes, encoding: bytes.starts(with: [254, 255]) ? .utf16 : .utf8).flatMap(UUID.init(uuidString:))
        }
        return nil
    }

    private static func array(_ refs: [FormPDFReference]) -> String { "[" + refs.map(\.pdfSyntax).joined(separator: " ") + "]" }
    private static func pdfString(_ value: String) -> String {
        "<FEFF" + value.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }
    private static func set(_ key: String, _ value: String?, in dictionary: [UInt8]) throws -> [UInt8] {
        try setBytes(key, value.map { Array($0.utf8) }, in: dictionary)
    }
    private static func setBytes(_ key: String, _ value: [UInt8]?, in dictionary: [UInt8]) throws -> [UInt8] {
        guard dictionary.starts(with: [60, 60]), dictionary.suffix(2) == [62, 62] else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        var result = dictionary
        while let range = FormPDFDictionaryEditor.entryRange(named: key, in: result) { result.removeSubrange(range) }
        if let value { result.insert(contentsOf: Array(" /\(key) ".utf8) + value + [32], at: result.count - 2) }
        return result
    }
}
nonisolated private struct FormPDFReference: Hashable {
    let objectNumber: Int
    let generation: Int

    var pdfSyntax: String { "\(objectNumber) \(generation) R" }
}

nonisolated private struct FormPDFIndirectObject {
    let reference: FormPDFReference
    let body: [UInt8]
}

nonisolated private struct FormCrossReference {
    let entries: [Int: (offset: Int, generation: Int)]
    let root: FormPDFReference
    let size: Int
    let startXRef: Int
    let infoValue: [UInt8]?
    let identifierValue: [UInt8]?
    let encryptionReference: FormPDFReference?

    init(source: [UInt8]) throws {
        guard let startXRef = Self.lastStartXRef(in: source),
              source.indices.contains(startXRef) else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        self.startXRef = startXRef
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var visitedOffsets = Set<Int>()
        var offset: Int? = startXRef
        var latestTrailer: [UInt8]?
        while let currentOffset = offset {
            guard visitedOffsets.insert(currentOffset).inserted else {
                throw PDFFormFieldTreeError.invalidStructure
            }
            let section = try Self.parseSection(source: source, offset: currentOffset)
            guard FormPDFDictionaryEditor.rawValue(named: "XRefStm", in: section.trailer) == nil else {
                throw PDFFormFieldTreeError.invalidStructure
            }
            if FormPDFDictionaryEditor.rawValue(named: "Encrypt", in: section.trailer) != nil {
                throw PDFFormFieldTreeError.encryptedDocumentUnsupported
            }
            if latestTrailer == nil { latestTrailer = section.trailer }
            for (objectNumber, entry) in section.entries where entries[objectNumber] == nil {
                entries[objectNumber] = entry
            }
            offset = FormPDFDictionaryEditor.integer(named: "Prev", in: section.trailer)
        }
        self.entries = entries

        guard let trailer = latestTrailer,
              let root = FormPDFDictionaryEditor.reference(named: "Root", in: trailer),
              let size = FormPDFDictionaryEditor.integer(named: "Size", in: trailer) else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        self.root = root
        guard size > 0, size < Int.max - source.count,
              size > (entries.keys.max() ?? 0),
              FormPDFDictionaryEditor.rawValue(named: "XRefStm", in: trailer) == nil else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        self.size = size
        infoValue = FormPDFDictionaryEditor.rawValue(named: "Info", in: trailer)
        identifierValue = FormPDFDictionaryEditor.rawValue(named: "ID", in: trailer)
        encryptionReference = FormPDFDictionaryEditor.reference(named: "Encrypt", in: trailer)
    }

    private static func parseSection(
        source: [UInt8],
        offset: Int
    ) throws -> (
        entries: [Int: (offset: Int, generation: Int)],
        trailer: [UInt8]
    ) {
        guard source.indices.contains(offset) else { throw PDFFormFieldTreeError.invalidStructure }
        var scanner = FormPDFByteScanner(bytes: source, index: offset)
        guard scanner.readToken() == "xref" else {
            // PDFKit's full serialization produces a classic xref table.
            // Do not guess offsets for compressed/hybrid cross-reference data.
            throw PDFFormFieldTreeError.invalidStructure
        }
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        while true {
            guard let token = scanner.readToken() else {
                throw PDFFormFieldTreeError.invalidStructure
            }
            if token == "trailer" { break }
            guard let firstObject = Int(token),
                  let countToken = scanner.readToken(),
                  let count = Int(countToken), firstObject >= 0, count >= 0,
                  count <= source.count / 6, firstObject <= Int.max - count else {
                throw PDFFormFieldTreeError.invalidStructure
            }
            for objectNumber in firstObject..<(firstObject + count) {
                guard let offsetToken = scanner.readToken(),
                      let generationToken = scanner.readToken(),
                      let state = scanner.readToken(),
                      let entryOffset = Int(offsetToken),
                      let generation = Int(generationToken), (0...65535).contains(generation),
                      entryOffset >= 0, state == "n" || state == "f" else {
                    throw PDFFormFieldTreeError.invalidStructure
                }
                // Keep free-entry tombstones so older revisions cannot revive them.
                entries[objectNumber] = (state == "n" ? entryOffset : -1, generation)
            }
        }
        guard let trailer = scanner.readCompoundValue() else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        return (entries, trailer)
    }

    private static func lastStartXRef(in source: [UInt8]) -> Int? {
        let marker = Array("startxref".utf8)
        guard let markerIndex = source.lastFormRange(of: marker)?.lowerBound else { return nil }
        var scanner = FormPDFByteScanner(bytes: source, index: markerIndex + marker.count)
        return scanner.readToken().flatMap(Int.init)
    }
}

nonisolated private struct FormObjectResolver {
    let source: [UInt8]
    let entries: [Int: (offset: Int, generation: Int)]

    func object(_ reference: FormPDFReference) throws -> FormPDFIndirectObject {
        guard let entry = entries[reference.objectNumber],
              entry.generation == reference.generation,
              source.indices.contains(entry.offset) else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        var scanner = FormPDFByteScanner(bytes: source, index: entry.offset)
        guard scanner.readToken() == String(reference.objectNumber),
              scanner.readToken() == String(reference.generation),
              scanner.readToken() == "obj",
              let body = scanner.readCompoundValue() else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        return FormPDFIndirectObject(reference: reference, body: body)
    }
}

nonisolated private struct FormPageTreeReader {
    let resolver: FormObjectResolver

    func pageReferences(catalog: [UInt8]) throws -> [FormPDFReference] {
        guard let pages = FormPDFDictionaryEditor.reference(named: "Pages", in: catalog) else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        var visited = Set<FormPDFReference>()
        return try collectPages(pages, visited: &visited, depth: 0)
    }

    private func collectPages(
        _ reference: FormPDFReference,
        visited: inout Set<FormPDFReference>, depth: Int
    ) throws -> [FormPDFReference] {
        guard depth < 64, visited.count < 100_000, visited.insert(reference).inserted else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        let object = try resolver.object(reference)
        if FormPDFDictionaryEditor.name(named: "Type", in: object.body) == "Page" {
            return [reference]
        }
        guard FormPDFDictionaryEditor.name(named: "Type", in: object.body) == "Pages",
              let kidsValue = FormPDFDictionaryEditor.rawValue(named: "Kids", in: object.body) else {
            throw PDFFormFieldTreeError.invalidStructure
        }
        let array: [UInt8]
        if let ref = FormPDFDictionaryEditor.reference(named: "Kids", in: object.body) {
            array = try resolver.object(ref).body
        } else { array = kidsValue }
        let kids = try FormPDFDictionaryEditor.references(in: array)
        return try kids.flatMap { try collectPages($0, visited: &visited, depth: depth + 1) }
    }
}

nonisolated private enum FormPDFDictionaryEditor {
    static func reference(named name: String, in dictionary: [UInt8]) -> FormPDFReference? {
        guard let raw = rawValue(named: name, in: dictionary) else { return nil }
        var scanner = FormPDFByteScanner(bytes: raw)
        guard let object = scanner.readToken().flatMap(Int.init),
              let generation = scanner.readToken().flatMap(Int.init),
              scanner.readToken() == "R" else { return nil }
        return FormPDFReference(objectNumber: object, generation: generation)
    }

    static func integer(named name: String, in dictionary: [UInt8]) -> Int? {
        rawValue(named: name, in: dictionary).flatMap {
            var scanner = FormPDFByteScanner(bytes: $0)
            return scanner.readToken().flatMap(Int.init)
        }
    }

    static func name(named name: String, in dictionary: [UInt8]) -> String? {
        guard let raw = rawValue(named: name, in: dictionary) else { return nil }
        var scanner = FormPDFByteScanner(bytes: raw)
        guard let token = scanner.readToken(), token.first == "/" else { return nil }
        return String(token.dropFirst())
    }

    static func value(named name: String, in dictionary: [UInt8]) -> String? {
        rawValue(named: name, in: dictionary).map {
            String(bytes: $0, encoding: .isoLatin1) ?? ""
        }
    }

    static func rawValue(named name: String, in dictionary: [UInt8]) -> [UInt8]? {
        guard let range = entryRange(named: name, in: dictionary) else { return nil }
        var scanner = FormPDFByteScanner(bytes: dictionary, index: range.lowerBound)
        guard scanner.readToken() == "/\(name)" else { return nil }
        scanner.skipWhitespaceAndComments()
        let valueStart = scanner.index
        guard let valueEnd = scanner.consumeValue() else { return nil }
        return Array(dictionary[valueStart..<valueEnd])
    }

    static func references(in value: [UInt8]) throws -> [FormPDFReference] {
        var scanner = FormPDFByteScanner(bytes: value)
        guard scanner.readToken() == "[" else { throw PDFFormFieldTreeError.invalidStructure }
        var result: [FormPDFReference] = []
        while let first = scanner.readToken() {
            if first == "]" {
                guard scanner.readToken() == nil else { throw PDFFormFieldTreeError.invalidStructure }
                return result
            }
            guard let object = Int(first), object > 0,
                  let generation = scanner.readToken().flatMap(Int.init), (0...65535).contains(generation),
                  scanner.readToken() == "R" else { throw PDFFormFieldTreeError.invalidStructure }
            result.append(FormPDFReference(objectNumber: object, generation: generation))
        }
        throw PDFFormFieldTreeError.invalidStructure
    }

    static func entryRange(named name: String, in dictionary: [UInt8]) -> Range<Int>? {
        var scanner = FormPDFByteScanner(bytes: dictionary)
        guard scanner.readToken() == "<<" else { return nil }
        while true {
            scanner.skipWhitespaceAndComments()
            let keyStart = scanner.index
            guard let key = scanner.readToken(), key != ">>" else { return nil }
            scanner.skipWhitespaceAndComments()
            guard let valueEnd = scanner.consumeValue() else { return nil }
            if key == "/\(name)" {
                return keyStart..<valueEnd
            }
        }
    }
}

nonisolated private struct FormPDFByteScanner {
    let bytes: [UInt8]
    var index: Int = 0
    private var nestingDepth = 0

    init(bytes: [UInt8], index: Int = 0) { self.bytes = bytes; self.index = index }

    mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            if bytes[index].isFormPDFWhitespace {
                index += 1
            } else if bytes[index] == 0x25 {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    index += 1
                }
            } else {
                break
            }
        }
    }

    mutating func readToken() -> String? {
        skipWhitespaceAndComments()
        guard index < bytes.count else { return nil }
        let start = index
        if bytes[index] == 0x3C, index + 1 < bytes.count, bytes[index + 1] == 0x3C {
            index += 2
        } else if bytes[index] == 0x3E, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
            index += 2
        } else if bytes[index] == 0x2F {
            index += 1
            while index < bytes.count,
                  !bytes[index].isFormPDFWhitespace,
                  !bytes[index].isFormPDFDelimiter {
                index += 1
            }
        } else if bytes[index].isFormPDFDelimiter {
            index += 1
        } else {
            while index < bytes.count,
                  !bytes[index].isFormPDFWhitespace,
                  !bytes[index].isFormPDFDelimiter {
                index += 1
            }
        }
        return String(bytes: bytes[start..<index], encoding: .isoLatin1)
    }

    mutating func readCompoundValue() -> [UInt8]? {
        skipWhitespaceAndComments()
        let start = index
        guard let end = consumeValue() else { return nil }
        return Array(bytes[start..<end])
    }

    mutating func consumeValue() -> Int? {
        skipWhitespaceAndComments()
        guard index < bytes.count else { return nil }
        if bytes[index] == 0x28 { return consumeLiteralString() }
        if bytes[index] == 0x3C {
            if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                return consumeContainer(open: [0x3C, 0x3C], close: [0x3E, 0x3E])
            }
            return consumeHexString()
        }
        if bytes[index] == 0x5B {
            return consumeContainer(open: [0x5B], close: [0x5D])
        }

        guard let first = readToken() else { return nil }
        if Int(first) != nil {
            let saved = index
            if let second = readToken(), Int(second) != nil, readToken() == "R" {
                return index
            }
            index = saved
        }
        return index
    }

    private mutating func consumeLiteralString() -> Int? {
        var depth = 0
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29 {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private mutating func consumeHexString() -> Int? {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x3E { return index }
        }
        return nil
    }

    private mutating func consumeContainer(open: [UInt8], close: [UInt8]) -> Int? {
        guard nestingDepth < 64 else { return nil }
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        index += open.count
        while index < bytes.count {
            skipWhitespaceAndComments()
            if bytes[index...].starts(with: close) {
                index += close.count
                return index
            }
            guard consumeValue() != nil else { return nil }
        }
        return nil
    }
}

private extension UInt8 {
    nonisolated var isFormPDFWhitespace: Bool {
        self == 0 || self == 9 || self == 10 || self == 12 || self == 13 || self == 32
    }

    nonisolated var isFormPDFDelimiter: Bool {
        switch self {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            true
        default:
            false
        }
    }
}

private extension Array where Element == UInt8 {
    nonisolated func lastFormRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        var index = count - needle.count
        while true {
            if self[index..<(index + needle.count)].elementsEqual(needle) {
                return index..<(index + needle.count)
            }
            if index == 0 { return nil }
            index -= 1
        }
    }
}
