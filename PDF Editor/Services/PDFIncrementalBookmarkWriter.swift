import Foundation

enum PDFIncrementalBookmarkWriterError: Error, LocalizedError {
    case invalidCrossReference
    case invalidCatalog
    case invalidPageTree
    case encryptedDocumentUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidCrossReference:
            "The PDF bookmark change could not be written to this document structure."
        case .invalidCatalog:
            "The PDF catalog could not be updated safely."
        case .invalidPageTree:
            "The PDF page destinations could not be resolved safely."
        case .encryptedDocumentUnsupported:
            "Bookmarks cannot currently be changed in an encrypted PDF. Remove the password first."
        }
    }
}

/// Writes an outline as a PDF incremental revision. This follows the same
/// preservation strategy used by Stirling PDF's JPDFium bookmark editor: page
/// content is left byte-for-byte intact and only new outline objects plus a
/// revised Catalog object are appended.
struct PDFIncrementalBookmarkWriter {
    func write(
        sourceData: Data,
        bookmarks: [PDFBookmarkSnapshot]
    ) throws -> Data {
        let source = [UInt8](sourceData)
        let crossReference = try CrossReference(source: source)
        guard crossReference.encryptionReference == nil else {
            throw PDFIncrementalBookmarkWriterError.encryptedDocumentUnsupported
        }

        let resolver = ObjectResolver(source: source, entries: crossReference.entries)
        let catalog = try resolver.object(crossReference.root)
        let pageReferences = try PageTreeReader(resolver: resolver).pageReferences(
            catalog: catalog.body
        )

        let outlineRootNumber = crossReference.size
        var nextObjectNumber = outlineRootNumber + (bookmarks.isEmpty ? 0 : 1)
        let nodes = bookmarks.map {
            OutlineNode(snapshot: $0, nextObjectNumber: &nextObjectNumber)
        }

        let outlineReference: PDFReference? = nodes.isEmpty
            ? nil
            : PDFReference(objectNumber: outlineRootNumber, generation: 0)
        let revisedCatalog = try PDFDictionaryEditor.replacingReference(
            named: "Outlines",
            with: outlineReference,
            in: catalog.body
        )

        var output = sourceData
        if output.last.map({ !$0.isPDFWhitespace }) ?? false {
            output.append(0x0A)
        }

        var writtenEntries: [PDFReference: Int] = [:]
        appendObject(
            reference: crossReference.root,
            body: revisedCatalog,
            to: &output,
            entries: &writtenEntries
        )

        if let outlineReference {
            let rootBody = outlineRootBody(nodes: nodes, root: outlineReference)
            appendObject(
                reference: outlineReference,
                body: Array(rootBody.utf8),
                to: &output,
                entries: &writtenEntries
            )
            try appendOutlineObjects(
                nodes,
                parent: outlineReference,
                pageReferences: pageReferences,
                to: &output,
                entries: &writtenEntries
            )
        }

        let xrefOffset = output.count
        appendASCII("xref\n", to: &output)
        appendCrossReferenceEntries(writtenEntries, to: &output)

        let resultingSize = max(crossReference.size, nextObjectNumber)
        var trailer = "trailer\n<< /Size \(resultingSize)"
        trailer += " /Root \(crossReference.root.pdfSyntax)"
        trailer += " /Prev \(crossReference.startXRef)"
        if let info = crossReference.infoValue {
            trailer += " /Info \(info)"
        }
        if let identifier = crossReference.identifierValue {
            trailer += " /ID \(identifier)"
        }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        appendASCII(trailer, to: &output)
        return output
    }

    private func appendOutlineObjects(
        _ nodes: [OutlineNode],
        parent: PDFReference,
        pageReferences: [PDFReference],
        to output: inout Data,
        entries: inout [PDFReference: Int]
    ) throws {
        for (index, node) in nodes.enumerated() {
            var fields = [
                "/Title \(pdfString(node.snapshot.title))",
                "/Parent \(parent.pdfSyntax)",
            ]
            if index > 0 {
                fields.append("/Prev \(nodes[index - 1].reference.pdfSyntax)")
            }
            if index + 1 < nodes.count {
                fields.append("/Next \(nodes[index + 1].reference.pdfSyntax)")
            }
            if let first = node.children.first, let last = node.children.last {
                fields.append("/First \(first.reference.pdfSyntax)")
                fields.append("/Last \(last.reference.pdfSyntax)")
                fields.append("/Count \(node.descendantCount)")
            }
            if let pageIndex = node.snapshot.pageIndex {
                guard pageReferences.indices.contains(pageIndex) else {
                    throw PDFIncrementalBookmarkWriterError.invalidPageTree
                }
                fields.append("/Dest [\(pageReferences[pageIndex].pdfSyntax) /Fit]")
            }
            appendObject(
                reference: node.reference,
                body: Array("<< \(fields.joined(separator: " ")) >>".utf8),
                to: &output,
                entries: &entries
            )
            try appendOutlineObjects(
                node.children,
                parent: node.reference,
                pageReferences: pageReferences,
                to: &output,
                entries: &entries
            )
        }
    }

    private func outlineRootBody(nodes: [OutlineNode], root: PDFReference) -> String {
        guard let first = nodes.first, let last = nodes.last else {
            return "<< /Type /Outlines >>"
        }
        let count = nodes.reduce(0) { $0 + 1 + $1.descendantCount }
        return "<< /Type /Outlines /First \(first.reference.pdfSyntax) " +
            "/Last \(last.reference.pdfSyntax) /Count \(count) >>"
    }

    private func appendObject(
        reference: PDFReference,
        body: [UInt8],
        to output: inout Data,
        entries: inout [PDFReference: Int]
    ) {
        entries[reference] = output.count
        appendASCII("\(reference.objectNumber) \(reference.generation) obj\n", to: &output)
        output.append(contentsOf: body)
        appendASCII("\nendobj\n", to: &output)
    }

    private func appendCrossReferenceEntries(
        _ entries: [PDFReference: Int],
        to output: inout Data
    ) {
        let sorted = entries.sorted {
            $0.key.objectNumber < $1.key.objectNumber
        }
        var index = 0
        while index < sorted.count {
            let start = index
            var end = index + 1
            while end < sorted.count,
                  sorted[end].key.objectNumber == sorted[end - 1].key.objectNumber + 1 {
                end += 1
            }
            appendASCII(
                "\(sorted[start].key.objectNumber) \(end - start)\n",
                to: &output
            )
            for entry in sorted[start..<end] {
                appendASCII(
                    String(
                        format: "%010d %05d n \n",
                        entry.value,
                        entry.key.generation
                    ),
                    to: &output
                )
            }
            index = end
        }
    }

    private func pdfString(_ value: String) -> String {
        var bytes: [UInt8] = [0xFE, 0xFF]
        for codeUnit in value.utf16 {
            bytes.append(UInt8(codeUnit >> 8))
            bytes.append(UInt8(codeUnit & 0xFF))
        }
        return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    private func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }
}

private final class OutlineNode {
    let snapshot: PDFBookmarkSnapshot
    let reference: PDFReference
    let children: [OutlineNode]

    init(snapshot: PDFBookmarkSnapshot, nextObjectNumber: inout Int) {
        self.snapshot = snapshot
        reference = PDFReference(objectNumber: nextObjectNumber, generation: 0)
        nextObjectNumber += 1
        children = snapshot.children.map {
            OutlineNode(snapshot: $0, nextObjectNumber: &nextObjectNumber)
        }
    }

    var descendantCount: Int {
        children.reduce(0) { $0 + 1 + $1.descendantCount }
    }
}

private struct PDFReference: Hashable {
    let objectNumber: Int
    let generation: Int

    var pdfSyntax: String { "\(objectNumber) \(generation) R" }
}

private struct PDFIndirectObject {
    let reference: PDFReference
    let body: [UInt8]
}

private struct CrossReference {
    let entries: [Int: (offset: Int, generation: Int)]
    let root: PDFReference
    let size: Int
    let startXRef: Int
    let infoValue: String?
    let identifierValue: String?
    let encryptionReference: PDFReference?

    init(source: [UInt8]) throws {
        guard let startXRef = Self.lastStartXRef(in: source),
              source.indices.contains(startXRef) else {
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        self.startXRef = startXRef
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var visitedOffsets = Set<Int>()
        var offset: Int? = startXRef
        var latestTrailer: [UInt8]?
        while let currentOffset = offset {
            guard visitedOffsets.insert(currentOffset).inserted else {
                throw PDFIncrementalBookmarkWriterError.invalidCrossReference
            }
            let section = try Self.parseSection(source: source, offset: currentOffset)
            if latestTrailer == nil { latestTrailer = section.trailer }
            for (objectNumber, entry) in section.entries where entries[objectNumber] == nil {
                entries[objectNumber] = entry
            }
            offset = PDFDictionaryEditor.integer(named: "Prev", in: section.trailer)
        }
        self.entries = entries

        guard let trailer = latestTrailer,
              let root = PDFDictionaryEditor.reference(named: "Root", in: trailer),
              let size = PDFDictionaryEditor.integer(named: "Size", in: trailer) else {
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        self.root = root
        self.size = size
        infoValue = PDFDictionaryEditor.value(named: "Info", in: trailer)
        identifierValue = PDFDictionaryEditor.value(named: "ID", in: trailer)
        encryptionReference = PDFDictionaryEditor.reference(named: "Encrypt", in: trailer)
    }

    private static func parseSection(
        source: [UInt8],
        offset: Int
    ) throws -> (
        entries: [Int: (offset: Int, generation: Int)],
        trailer: [UInt8]
    ) {
        var scanner = PDFByteScanner(bytes: source, index: offset)
        guard scanner.readToken() == "xref" else {
            // Current document bytes are normalized by PDFium with
            // FPDF_NO_INCREMENTAL, which produces a classic xref table.
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        while true {
            guard let token = scanner.readToken() else {
                throw PDFIncrementalBookmarkWriterError.invalidCrossReference
            }
            if token == "trailer" { break }
            guard let firstObject = Int(token),
                  let countToken = scanner.readToken(),
                  let count = Int(countToken), count >= 0 else {
                throw PDFIncrementalBookmarkWriterError.invalidCrossReference
            }
            for objectNumber in firstObject..<(firstObject + count) {
                guard let offsetToken = scanner.readToken(),
                      let generationToken = scanner.readToken(),
                      let state = scanner.readToken(),
                      let entryOffset = Int(offsetToken),
                      let generation = Int(generationToken) else {
                    throw PDFIncrementalBookmarkWriterError.invalidCrossReference
                }
                if state == "n" {
                    entries[objectNumber] = (entryOffset, generation)
                }
            }
        }
        guard let trailer = scanner.readCompoundValue() else {
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        return (entries, trailer)
    }

    private static func lastStartXRef(in source: [UInt8]) -> Int? {
        let marker = Array("startxref".utf8)
        guard let markerIndex = source.lastRange(of: marker)?.lowerBound else { return nil }
        var scanner = PDFByteScanner(bytes: source, index: markerIndex + marker.count)
        return scanner.readToken().flatMap(Int.init)
    }
}

private struct ObjectResolver {
    let source: [UInt8]
    let entries: [Int: (offset: Int, generation: Int)]

    func object(_ reference: PDFReference) throws -> PDFIndirectObject {
        guard let entry = entries[reference.objectNumber],
              entry.generation == reference.generation,
              source.indices.contains(entry.offset) else {
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        var scanner = PDFByteScanner(bytes: source, index: entry.offset)
        guard scanner.readToken() == String(reference.objectNumber),
              scanner.readToken() == String(reference.generation),
              scanner.readToken() == "obj",
              let body = scanner.readCompoundValue() else {
            throw PDFIncrementalBookmarkWriterError.invalidCrossReference
        }
        return PDFIndirectObject(reference: reference, body: body)
    }
}

private struct PageTreeReader {
    let resolver: ObjectResolver

    func pageReferences(catalog: [UInt8]) throws -> [PDFReference] {
        guard let pages = PDFDictionaryEditor.reference(named: "Pages", in: catalog) else {
            throw PDFIncrementalBookmarkWriterError.invalidCatalog
        }
        var visited = Set<PDFReference>()
        return try collectPages(pages, visited: &visited)
    }

    private func collectPages(
        _ reference: PDFReference,
        visited: inout Set<PDFReference>
    ) throws -> [PDFReference] {
        guard visited.insert(reference).inserted else {
            throw PDFIncrementalBookmarkWriterError.invalidPageTree
        }
        let object = try resolver.object(reference)
        if PDFDictionaryEditor.name(named: "Type", in: object.body) == "Page" {
            return [reference]
        }
        guard PDFDictionaryEditor.name(named: "Type", in: object.body) == "Pages",
              let kidsValue = PDFDictionaryEditor.rawValue(named: "Kids", in: object.body) else {
            throw PDFIncrementalBookmarkWriterError.invalidPageTree
        }
        let kids = PDFDictionaryEditor.references(in: kidsValue)
        guard !kids.isEmpty else { return [] }
        return try kids.flatMap { try collectPages($0, visited: &visited) }
    }
}

private enum PDFDictionaryEditor {
    static func replacingReference(
        named name: String,
        with reference: PDFReference?,
        in dictionary: [UInt8]
    ) throws -> [UInt8] {
        guard dictionary.starts(with: Array("<<".utf8)),
              dictionary.suffix(2) == Array(">>".utf8) else {
            throw PDFIncrementalBookmarkWriterError.invalidCatalog
        }
        var result = dictionary
        if let range = entryRange(named: name, in: result) {
            result.removeSubrange(range)
        }
        if let reference {
            result.insert(contentsOf: Array(" /\(name) \(reference.pdfSyntax) ".utf8), at: result.count - 2)
        }
        return result
    }

    static func reference(named name: String, in dictionary: [UInt8]) -> PDFReference? {
        guard let raw = rawValue(named: name, in: dictionary) else { return nil }
        var scanner = PDFByteScanner(bytes: raw)
        guard let object = scanner.readToken().flatMap(Int.init),
              let generation = scanner.readToken().flatMap(Int.init),
              scanner.readToken() == "R" else { return nil }
        return PDFReference(objectNumber: object, generation: generation)
    }

    static func integer(named name: String, in dictionary: [UInt8]) -> Int? {
        rawValue(named: name, in: dictionary).flatMap {
            var scanner = PDFByteScanner(bytes: $0)
            return scanner.readToken().flatMap(Int.init)
        }
    }

    static func name(named name: String, in dictionary: [UInt8]) -> String? {
        guard let raw = rawValue(named: name, in: dictionary) else { return nil }
        var scanner = PDFByteScanner(bytes: raw)
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
        var scanner = PDFByteScanner(bytes: dictionary, index: range.lowerBound)
        guard scanner.readToken() == "/\(name)" else { return nil }
        scanner.skipWhitespaceAndComments()
        let valueStart = scanner.index
        guard let valueEnd = scanner.consumeValue() else { return nil }
        return Array(dictionary[valueStart..<valueEnd])
    }

    static func references(in value: [UInt8]) -> [PDFReference] {
        var scanner = PDFByteScanner(bytes: value)
        guard scanner.readToken() == "[" else { return [] }
        var result: [PDFReference] = []
        while let first = scanner.readToken(), first != "]" {
            guard let object = Int(first),
                  let generation = scanner.readToken().flatMap(Int.init),
                  scanner.readToken() == "R" else { return [] }
            result.append(PDFReference(objectNumber: object, generation: generation))
        }
        return result
    }

    private static func entryRange(named name: String, in dictionary: [UInt8]) -> Range<Int>? {
        var scanner = PDFByteScanner(bytes: dictionary)
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

private struct PDFByteScanner {
    let bytes: [UInt8]
    var index: Int = 0

    mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            if bytes[index].isPDFWhitespace {
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
                  !bytes[index].isPDFWhitespace,
                  !bytes[index].isPDFDelimiter {
                index += 1
            }
        } else if bytes[index].isPDFDelimiter {
            index += 1
        } else {
            while index < bytes.count,
                  !bytes[index].isPDFWhitespace,
                  !bytes[index].isPDFDelimiter {
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
    var isPDFWhitespace: Bool {
        self == 0 || self == 9 || self == 10 || self == 12 || self == 13 || self == 32
    }

    var isPDFDelimiter: Bool {
        switch self {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            true
        default:
            false
        }
    }
}

private extension Array where Element == UInt8 {
    func lastRange(of needle: [UInt8]) -> Range<Int>? {
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
