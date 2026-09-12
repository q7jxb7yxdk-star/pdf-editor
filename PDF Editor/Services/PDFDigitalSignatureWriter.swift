import Foundation
import CoreGraphics
import CoreText

/// A deliberately bounded, append-only signer. PDFKit/PDFium must never serialize
/// the returned bytes. All offsets refer to the immutable input plus our revision.
nonisolated enum PDFDigitalSignatureWriter {
    private static let reservedCMSBytes = 32 * 1024

    static func preflight(data: Data, fieldID: UUID, fieldName: String) throws {
        _ = try SigningPDF(data: data, fieldID: fieldID, fieldName: fieldName)
    }

    static func sign(data: Data, fieldID: UUID, fieldName: String, identity: PDFSigningIdentity,
                     reason: String? = nil, signingDate: Date = Date()) async throws -> PDFDigitalSignatureResult {
        try Task.checkCancellation()
        let pdf = try SigningPDF(data: data, fieldID: fieldID, fieldName: fieldName)
        guard identity.summary.signerName.utf16.count <= 1024, (reason?.utf16.count ?? 0) <= 1024 else {
            throw PDFDigitalSignatureError.unsupportedDocument("the signing details are too long.")
        }
        let signatureRef = SigningPDFReference(number: pdf.size, generation: 0)
        let appearanceRef = SigningPDFReference(number: pdf.size + 1, generation: 0)
        let formRef = SigningPDFReference(number: pdf.size + 2, generation: 0)
        var field = pdf.field
        field["V"] = .reference(signatureRef)
        field["AP"] = .dictionary(["N": .reference(appearanceRef)])
        field["PDFEditorSigned"] = .atom("true")
        field["F"] = .number(String((field["F"]?.integer ?? 0) | 4))
        field.removeValue(forKey: "DV")
        var form = pdf.form
        form["SigFlags"] = .number("3")
        form.removeValue(forKey: "NeedAppearances")
        var catalog = pdf.catalog
        catalog["AcroForm"] = .reference(formRef)
        let appearance = try signatureAppearance(name: identity.summary.signerName, date: signingDate,
                                                width: pdf.width, height: pdf.height)
        var appearanceBody = SigningPDFValue.dictionary([
            "Type": .name("XObject"), "Subtype": .name("Form"), "FormType": .number("1"),
            "BBox": .array([.number("0"), .number("0"), .number(number(pdf.width)), .number(number(pdf.height))]),
            "Resources": .dictionary([:]), "Length": .number(String(appearance.count))
        ]).bytes
        appearanceBody += Array("\nstream\n".utf8) + appearance + Array("\nendstream".utf8)
        var output = [UInt8](data)
        output.append(10)
        var entries: [(SigningPDFReference, Int)] = []
        func appendObject(_ ref: SigningPDFReference, _ bytes: [UInt8]) {
            entries.append((ref, output.count))
            output += Array("\(ref.number) \(ref.generation) obj\n".utf8) + bytes + Array("\nendobj\n".utf8)
        }
        appendObject(pdf.root, SigningPDFValue.dictionary(catalog).bytes)
        appendObject(pdf.fieldRef, SigningPDFValue.dictionary(field).bytes)
        appendObject(formRef, SigningPDFValue.dictionary(form).bytes)
        appendObject(appearanceRef, appearanceBody)

        // Offsets are captured while writing, never found via a content search.
        entries.append((signatureRef, output.count))
        output += Array("\(signatureRef.number) 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange ".utf8)
        let byteRangeStart = output.count
        let placeholder = "[0 " + Array(repeating: String(repeating: "0", count: 12), count: 3).joined(separator: " ") + "]"
        output += Array(placeholder.utf8)
        output += Array(" /Contents ".utf8)
        let contentsStart = output.count
        output.append(60)
        output += Array(repeating: 48, count: reservedCMSBytes * 2)
        output.append(62)
        let contentsEnd = output.count
        output += Array(" /Name ".utf8) + SigningPDFValue.text(identity.summary.signerName).bytes
        output += Array(" /M ".utf8) + SigningPDFValue.string(Array(pdfDate(signingDate).utf8)).bytes
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            output += Array(" /Reason ".utf8) + SigningPDFValue.text(reason).bytes
        }
        output += Array(" >>\nendobj\n".utf8)
        let xrefOffset = output.count
        output += Array("xref\n".utf8)
        for (ref, offset) in entries.sorted(by: { $0.0.number < $1.0.number }) {
            guard offset < 10_000_000_000 else { throw PDFDigitalSignatureError.invalidStructure }
            output += Array("\(ref.number) 1\n".utf8)
            output += Array(String(format: "%010lld %05d n \n", Int64(offset), ref.generation).utf8)
        }
        var trailer: [String: SigningPDFValue] = [
            "Size": .number(String(pdf.size + 3)), "Root": .reference(pdf.root), "Prev": .number(String(pdf.startXRef))
        ]
        trailer["Info"] = pdf.trailer["Info"]
        trailer["ID"] = pdf.trailer["ID"]
        output += Array("trailer\n".utf8) + SigningPDFValue.dictionary(trailer).bytes
        output += Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        let rangeValues = [contentsStart, contentsEnd, output.count - contentsEnd]
        let rangeText = "[0 " + rangeValues.map { String(format: "%012lld", Int64($0)) }.joined(separator: " ") + "]"
        guard rangeText.utf8.count == placeholder.utf8.count else { throw PDFDigitalSignatureError.invalidStructure }
        output.replaceSubrange(byteRangeStart..<(byteRangeStart + placeholder.utf8.count), with: rangeText.utf8)
        var signedContent = Data(output[..<contentsStart])
        signedContent.append(contentsOf: output[contentsEnd...])
        let cms = try await PDFCMSService.sign(signedContent, identity: identity, signingDate: signingDate)
        try Task.checkCancellation()
        guard cms.count <= reservedCMSBytes else { throw PDFDigitalSignatureError.signatureTooLarge }
        let cmsHex = Array(cms.flatMap { String(format: "%02X", $0).utf8 })
        output.replaceSubrange((contentsStart + 1)..<(contentsStart + 1 + cmsHex.count), with: cmsHex)

        // Verify the bytes to be delivered, including the final dictionary and
        // the actual exclusion range, before the caller may write a signed copy.
        let final = Data(output)
        let finalFile = try SigningPDFFile(data: final)
        guard finalFile.root == pdf.root,
              try finalFile.object(pdf.fieldRef).dictionary?["V"]?.reference == signatureRef,
              let signature = try finalFile.object(signatureRef).dictionary,
              signature["ByteRange"]?.integers == [0] + rangeValues,
              let embedded = signature["Contents"]?.string,
              embedded.prefix(cms.count).elementsEqual(cms),
              embedded.dropFirst(cms.count).allSatisfy({ $0 == 0 }),
              final.prefix(data.count).elementsEqual(data) else {
            throw PDFDigitalSignatureError.signatureVerificationFailed
        }
        var deliveredContent = final.subdata(in: 0..<contentsStart)
        deliveredContent.append(final.subdata(in: contentsEnd..<final.count))
        guard deliveredContent == signedContent else { throw PDFDigitalSignatureError.signatureVerificationFailed }
        try await PDFCMSService.verify(cms, content: deliveredContent, identity: identity, signingDate: signingDate)
        return PDFDigitalSignatureResult(data: final, certificate: identity.summary, fieldID: fieldID,
                                         fieldName: fieldName, signedAt: signingDate)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func pdfDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "'D:'yyyyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    /// CoreText outlines preserve Unicode names without relying on reader fonts.
    /// This appearance makes no statement about public trust or revocation.
    private static func signatureAppearance(name: String, date: Date, width: Double, height: Double) throws -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        let lines = ["Digitally signed by", name, formatter.string(from: date)]
        let padding = min(6.0, height / 10)
        let usableWidth = width - padding * 2
        let rowHeight = (height - padding * 2) / 3
        let fontSize = min(11.0, rowHeight * 0.68)
        var commands = "q 0.96 0.98 1 rg 0 0 \(number(width)) \(number(height)) re f 0.35 0.45 0.6 RG 0.5 w 0.5 0.5 \(number(width - 1)) \(number(height - 1)) re S 0.08 0.12 0.18 rg\n"
        commands += "0 0 \(number(width)) \(number(height)) re W n\n"
        for (lineIndex, text) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let display = CTLineCreateTruncatedLine(line, usableWidth, .end, ellipsis) ?? line
            let baseline = height - padding - Double(lineIndex + 1) * rowHeight + rowHeight * 0.18
            for run in CTLineGetGlyphRuns(display) as! [CTRun] {
                let runAttributes = CTRunGetAttributes(run) as NSDictionary
                guard let runFont = runAttributes[kCTFontAttributeName] else { throw PDFDigitalSignatureError.invalidStructure }
                let glyphCount = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in 0..<glyphCount {
                    guard let path = CTFontCreatePathForGlyph(runFont as! CTFont, glyphs[index], nil) else { continue }
                    var transform = CTRunGetTextMatrix(run)
                    transform.tx += padding + positions[index].x
                    transform.ty += baseline + positions[index].y
                    guard let translated = path.copy(using: &transform) else { throw PDFDigitalSignatureError.invalidStructure }
                    var current = CGPoint.zero
                    var subpathStart = CGPoint.zero
                    translated.applyWithBlock { element in
                        let p = element.pointee.points
                        func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
                        switch element.pointee.type {
                        case .moveToPoint: commands += "\(point(p[0])) m\n"; current = p[0]; subpathStart = p[0]
                        case .addLineToPoint: commands += "\(point(p[0])) l\n"; current = p[0]
                        case .addQuadCurveToPoint:
                            let a = CGPoint(x: current.x + (p[0].x - current.x) * 2 / 3, y: current.y + (p[0].y - current.y) * 2 / 3)
                            let b = CGPoint(x: p[1].x + (p[0].x - p[1].x) * 2 / 3, y: p[1].y + (p[0].y - p[1].y) * 2 / 3)
                            commands += "\(point(a)) \(point(b)) \(point(p[1])) c\n"; current = p[1]
                        case .addCurveToPoint: commands += "\(point(p[0])) \(point(p[1])) \(point(p[2])) c\n"; current = p[2]
                        case .closeSubpath: commands += "h\n"; current = subpathStart
                        @unknown default: break
                        }
                    }
                    commands += "f\n"
                }
            }
        }
        return Array((commands + "Q\n").utf8)
    }
}

nonisolated private struct SigningPDF {
    let root: SigningPDFReference
    let fieldRef: SigningPDFReference
    let catalog: [String: SigningPDFValue]
    let form: [String: SigningPDFValue]
    let field: [String: SigningPDFValue]
    let trailer: [String: SigningPDFValue]
    let size: Int
    let startXRef: Int
    let width: Double
    let height: Double

    init(data: Data, fieldID: UUID, fieldName: String) throws {
        let file = try SigningPDFFile(data: data)
        root = file.root; trailer = file.trailer; size = file.size; startXRef = file.startXRef
        guard let catalog = try file.object(root).dictionary,
              catalog["Type"]?.name == "Catalog", catalog["Perms"] == nil,
              let formValue = catalog["AcroForm"],
              let form = try file.resolve(formValue).dictionary, form["XFA"] == nil,
              let fieldsValue = form["Fields"],
              let roots = try file.resolve(fieldsValue).array else {
            throw PDFDigitalSignatureError.unsupportedDocument("its form structure or document permissions are unsupported.")
        }
        self.catalog = catalog; self.form = form
        // Check every live object's parsed dictionaries. Names such as
        // /Byte#52ange cannot bypass this check, and stream bytes are not guessed.
        for (number, entry) in file.entries where entry.offset >= 0 {
            let value = try file.object(SigningPDFReference(number: number, generation: entry.generation))
            try Self.rejectSignaturesAndTransforms(value)
        }
        var seen = Set<SigningPDFReference>()
        var match: (SigningPDFReference, [String: SigningPDFValue])?
        var nameCount = 0
        func visit(_ value: SigningPDFValue, inheritedType: String?, depth: Int) throws {
            guard depth < 64, seen.count < 100_000, let ref = value.reference,
                  seen.insert(ref).inserted, let dictionary = try file.object(ref).dictionary else {
                throw PDFDigitalSignatureError.invalidStructure
            }
            let type = dictionary["FT"]?.name ?? inheritedType
            let name = dictionary["T"]?.text
            if name == fieldName { nameCount += 1 }
            if let marker = dictionary["PDFEditorFormID"]?.text, UUID(uuidString: marker) == fieldID {
                guard match == nil, name == fieldName, type == "Sig", dictionary["Subtype"]?.name == "Widget",
                      dictionary["Parent"] == nil, dictionary["Kids"] == nil,
                      dictionary["V"] == nil || dictionary["V"]?.isNull == true,
                      dictionary["DV"] == nil || dictionary["DV"]?.isNull == true,
                      dictionary["SV"] == nil, dictionary["Lock"] == nil,
                      dictionary["A"] == nil, dictionary["AA"] == nil,
                      dictionary["Ff"] == nil || dictionary["Ff"]?.integer != nil,
                      dictionary["F"] == nil || dictionary["F"]?.integer != nil,
                      (dictionary["Ff"]?.integer ?? 0) >= 0, (dictionary["F"]?.integer ?? 0) >= 0,
                      ((dictionary["F"]?.integer ?? 0) & 35) == 0,
                      ((dictionary["Ff"]?.integer ?? 0) & 1) == 0 else {
                    throw PDFDigitalSignatureError.fieldNotEligible
                }
                match = (ref, dictionary)
            }
            if type == "Sig", let value = dictionary["V"], !value.isNull {
                throw PDFDigitalSignatureError.alreadySigned
            }
            if let children = dictionary["Kids"] {
                guard let kids = try file.resolve(children).array else { throw PDFDigitalSignatureError.invalidStructure }
                for kid in kids { try visit(kid, inheritedType: type, depth: depth + 1) }
            }
        }
        for value in roots { try visit(value, inheritedType: nil, depth: 0) }
        guard let (targetRef, target) = match, nameCount == 1,
              let rect = target["Rect"]?.array, rect.count == 4,
              let x1 = rect[0].double, let y1 = rect[1].double, let x2 = rect[2].double, let y2 = rect[3].double,
              (72...10000).contains(x2 - x1), (24...10000).contains(y2 - y1),
              let pageRoot = catalog["Pages"]?.reference else { throw PDFDigitalSignatureError.fieldNotEligible }
        var pagesSeen = Set<SigningPDFReference>()
        var placements = 0
        func page(_ ref: SigningPDFReference, depth: Int) throws {
            guard depth < 64, pagesSeen.count < 100_000, pagesSeen.insert(ref).inserted,
                  let body = try file.object(ref).dictionary else { throw PDFDigitalSignatureError.invalidStructure }
            if body["Type"]?.name == "Pages" {
                guard let value = body["Kids"], let kids = try file.resolve(value).array else { throw PDFDigitalSignatureError.invalidStructure }
                for kid in kids {
                    guard let child = kid.reference else { throw PDFDigitalSignatureError.invalidStructure }
                    try page(child, depth: depth + 1)
                }
            } else if body["Type"]?.name == "Page" {
                if let value = body["Annots"] {
                    guard let annots = try file.resolve(value).array else { throw PDFDigitalSignatureError.invalidStructure }
                    for annotation in annots {
                        guard let annotationRef = annotation.reference, let dictionary = try file.object(annotationRef).dictionary else {
                            throw PDFDigitalSignatureError.invalidStructure
                        }
                        let sameID = dictionary["PDFEditorFormID"]?.text.flatMap(UUID.init(uuidString:)) == fieldID
                        if annotationRef == targetRef {
                            guard sameID, target["P"] == nil || target["P"]?.reference == ref else {
                                throw PDFDigitalSignatureError.fieldNotEligible
                            }
                            placements += 1
                        } else if sameID || dictionary["T"]?.text == fieldName {
                            throw PDFDigitalSignatureError.fieldNotEligible
                        }
                    }
                }
            } else { throw PDFDigitalSignatureError.invalidStructure }
        }
        try page(pageRoot, depth: 0)
        guard placements == 1 else { throw PDFDigitalSignatureError.fieldNotEligible }
        fieldRef = targetRef; field = target; width = x2 - x1; height = y2 - y1
    }

    private static func rejectSignaturesAndTransforms(_ value: SigningPDFValue) throws {
        switch value {
        case .dictionary(let dictionary):
            if dictionary["ByteRange"] != nil || dictionary["Type"]?.name == "Sig" {
                throw PDFDigitalSignatureError.alreadySigned
            }
            if dictionary["DocMDP"] != nil || dictionary["FieldMDP"] != nil ||
                ["DocMDP", "FieldMDP"].contains(dictionary["TransformMethod"]?.name ?? "") {
                throw PDFDigitalSignatureError.unsupportedDocument("certification and field-lock transforms are not supported.")
            }
            for child in dictionary.values { try rejectSignaturesAndTransforms(child) }
        case .array(let values): for child in values { try rejectSignaturesAndTransforms(child) }
        default: break
        }
    }
}

nonisolated private struct SigningPDFReference: Hashable {
    let number: Int
    let generation: Int
}

nonisolated private indirect enum SigningPDFValue {
    case dictionary([String: SigningPDFValue]), array([SigningPDFValue]), name(String), string([UInt8])
    case number(String), reference(SigningPDFReference), atom(String)

    var dictionary: [String: SigningPDFValue]? { if case .dictionary(let value) = self { value } else { nil } }
    var array: [SigningPDFValue]? { if case .array(let value) = self { value } else { nil } }
    var name: String? { if case .name(let value) = self { value } else { nil } }
    var reference: SigningPDFReference? { if case .reference(let value) = self { value } else { nil } }
    var string: [UInt8]? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    var double: Double? {
        guard case .number(let value) = self, let number = Double(value), number.isFinite else { return nil }
        return number
    }
    var integers: [Int]? {
        guard let array else { return nil }
        let numbers = array.compactMap(\.integer)
        return numbers.count == array.count ? numbers : nil
    }
    var isNull: Bool { if case .atom("null") = self { true } else { false } }
    var text: String? {
        guard let string else { return nil }
        if string.starts(with: [254, 255]) { return String(data: Data(string.dropFirst(2)), encoding: .utf16BigEndian) }
        // App-authored IDs and field names are ASCII or Unicode strings.
        return String(bytes: string, encoding: .utf8) ?? String(bytes: string, encoding: .isoLatin1)
    }
    static func text(_ value: String) -> Self {
        .string([254, 255] + value.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] })
    }
    var bytes: [UInt8] {
        switch self {
        case .dictionary(let dictionary):
            return Array("<< ".utf8) + dictionary.keys.sorted().flatMap {
                Self.name($0).bytes + [32] + dictionary[$0]!.bytes + [32]
            } + Array(">>".utf8)
        case .array(let array): return [91, 32] + array.flatMap { $0.bytes + [32] } + [93]
        case .name(let name):
            return [47] + name.utf8.flatMap { byte in
                (33...126).contains(byte) && !SigningPDFScanner.delimiters.contains(byte) && byte != 35
                    ? [byte] : Array(String(format: "#%02X", byte).utf8)
            }
        case .string(let bytes): return [60] + bytes.flatMap { Array(String(format: "%02X", $0).utf8) } + [62]
        case .number(let string), .atom(let string): return Array(string.utf8)
        case .reference(let ref): return Array("\(ref.number) \(ref.generation) R".utf8)
        }
    }
}

/// Strict classic-xref reader used only by the signing boundary. Duplicate keys,
/// duplicate xref entries, cycles, unsupported names and ambiguous syntax fail.
nonisolated private final class SigningPDFFile {
    let bytes: [UInt8]
    let entries: [Int: (offset: Int, generation: Int)]
    let trailer: [String: SigningPDFValue]
    let root: SigningPDFReference
    let size: Int
    let startXRef: Int
    private var cache: [SigningPDFReference: SigningPDFValue] = [:]
    private var resolving = Set<SigningPDFReference>()

    init(data: Data) throws {
        guard data.count <= 256 * 1024 * 1024, data.starts(with: Array("%PDF-".utf8)) else {
            throw PDFDigitalSignatureError.unsupportedDocument("the file must be a PDF no larger than 256 MB.")
        }
        bytes = Array(data)
        let tailStart = max(0, bytes.count - 2048)
        let tail = Data(bytes[tailStart...])
        guard let marker = tail.range(of: Data("startxref".utf8), options: .backwards) else { throw PDFDigitalSignatureError.invalidStructure }
        var ending = SigningPDFScanner(bytes: bytes, index: tailStart + marker.upperBound)
        guard let offset = Int(try ending.token()), bytes.indices.contains(offset) else { throw PDFDigitalSignatureError.invalidStructure }
        // No trailing revision or payload may be omitted from the selected xref.
        ending.whitespaceOnly()
        guard ending.consume(Array("%%EOF".utf8)) else { throw PDFDigitalSignatureError.invalidStructure }
        ending.whitespaceOnly()
        guard ending.index == bytes.count else { throw PDFDigitalSignatureError.invalidStructure }
        startXRef = offset
        var next: Int? = offset
        var offsets = Set<Int>()
        var allEntries: [Int: (offset: Int, generation: Int)] = [:]
        var newest: [String: SigningPDFValue]?
        while let offset = next {
            guard offsets.count < 128, offsets.insert(offset).inserted, bytes.indices.contains(offset) else {
                throw PDFDigitalSignatureError.invalidStructure
            }
            var scanner = SigningPDFScanner(bytes: bytes, index: offset)
            guard try scanner.token() == "xref" else {
                throw PDFDigitalSignatureError.unsupportedDocument("cross-reference streams and hybrid PDFs are not supported.")
            }
            var revisionEntries = Set<Int>()
            while true {
                let first = try scanner.token()
                if first == "trailer" { break }
                guard let start = Int(first), let count = Int(try scanner.token()), start >= 0, count >= 0,
                      count <= 100_000, start < Int.max - count, revisionEntries.count + count <= 100_000 else {
                    throw PDFDigitalSignatureError.invalidStructure
                }
                for number in start..<(start + count) {
                    guard revisionEntries.insert(number).inserted,
                          let entryOffset = Int(try scanner.token()), entryOffset >= 0,
                          let generation = Int(try scanner.token()), (0...65535).contains(generation) else {
                        throw PDFDigitalSignatureError.invalidStructure
                    }
                    let state = try scanner.token()
                    guard state == "n" || state == "f", state == "f" || bytes.indices.contains(entryOffset) else {
                        throw PDFDigitalSignatureError.invalidStructure
                    }
                    if allEntries[number] == nil { allEntries[number] = (state == "n" ? entryOffset : -1, generation) }
                }
            }
            guard let trailer = try scanner.value().dictionary, trailer["Encrypt"] == nil, trailer["XRefStm"] == nil else {
                throw PDFDigitalSignatureError.unsupportedDocument("encrypted and hybrid PDFs are not supported.")
            }
            if newest == nil { newest = trailer }
            if let prev = trailer["Prev"] {
                guard let previous = prev.integer, previous >= 0, previous < offset else { throw PDFDigitalSignatureError.invalidStructure }
                next = previous
            } else { next = nil }
        }
        guard allEntries.count <= 100_000, let newest, let root = newest["Root"]?.reference,
              let size = newest["Size"]?.integer, size > (allEntries.keys.max() ?? 0), size < Int.max - 3 else {
            throw PDFDigitalSignatureError.invalidStructure
        }
        self.entries = allEntries; self.trailer = newest; self.root = root; self.size = size
    }

    func resolve(_ value: SigningPDFValue) throws -> SigningPDFValue {
        if let ref = value.reference { return try object(ref) }
        return value
    }

    func object(_ ref: SigningPDFReference) throws -> SigningPDFValue {
        if let cached = cache[ref] { return cached }
        guard resolving.count < 64, resolving.insert(ref).inserted,
              let entry = entries[ref.number], entry.generation == ref.generation, entry.offset >= 0 else {
            throw PDFDigitalSignatureError.invalidStructure
        }
        defer { resolving.remove(ref) }
        var scanner = SigningPDFScanner(bytes: bytes, index: entry.offset)
        guard try scanner.token() == String(ref.number), try scanner.token() == String(ref.generation),
              try scanner.token() == "obj" else { throw PDFDigitalSignatureError.invalidStructure }
        let value = try scanner.value()
        let ending = try scanner.token()
        if ending == "stream" {
            guard let lengthValue = value.dictionary?["Length"], let length = try resolve(lengthValue).integer,
                  length >= 0, scanner.index < bytes.count else { throw PDFDigitalSignatureError.invalidStructure }
            if scanner.consume([13]) { _ = scanner.consume([10]) }
            else { guard scanner.consume([10]) else { throw PDFDigitalSignatureError.invalidStructure } }
            guard scanner.index <= bytes.count - length else { throw PDFDigitalSignatureError.invalidStructure }
            scanner.index += length
            guard try scanner.token() == "endstream", try scanner.token() == "endobj" else {
                throw PDFDigitalSignatureError.invalidStructure
            }
        } else if ending != "endobj" { throw PDFDigitalSignatureError.invalidStructure }
        cache[ref] = value
        return value
    }
}

nonisolated private struct SigningPDFScanner {
    static let delimiters: Set<UInt8> = [40, 41, 60, 62, 91, 93, 123, 125, 47, 37]
    static let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
    let bytes: [UInt8]
    var index: Int = 0

    mutating func whitespaceOnly() { while index < bytes.count, Self.whitespace.contains(bytes[index]) { index += 1 } }
    mutating func skip() {
        while index < bytes.count {
            whitespaceOnly()
            guard index < bytes.count, bytes[index] == 37 else { return }
            while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
        }
    }
    mutating func consume(_ token: [UInt8]) -> Bool {
        guard index <= bytes.count - token.count, bytes[index..<(index + token.count)].elementsEqual(token) else { return false }
        index += token.count; return true
    }
    mutating func token() throws -> String {
        skip()
        guard index < bytes.count else { throw PDFDigitalSignatureError.invalidStructure }
        let start = index
        if consume([60, 60]) || consume([62, 62]) {} else if Self.delimiters.contains(bytes[index]) { index += 1 }
        else { while index < bytes.count, !Self.whitespace.contains(bytes[index]), !Self.delimiters.contains(bytes[index]) { index += 1 } }
        guard let result = String(bytes: bytes[start..<index], encoding: .ascii) else { throw PDFDigitalSignatureError.invalidStructure }
        return result
    }
    mutating func value(depth: Int = 0) throws -> SigningPDFValue {
        guard depth < 64 else { throw PDFDigitalSignatureError.invalidStructure }
        skip()
        if consume([60, 60]) {
            var dictionary: [String: SigningPDFValue] = [:]
            while true {
                skip()
                if consume([62, 62]) { return .dictionary(dictionary) }
                guard consume([47]), dictionary.count < 100_000 else { throw PDFDigitalSignatureError.invalidStructure }
                let key = try name()
                guard dictionary[key] == nil else { throw PDFDigitalSignatureError.invalidStructure }
                dictionary[key] = try value(depth: depth + 1)
            }
        }
        if consume([91]) {
            var array: [SigningPDFValue] = []
            while true {
                skip()
                if consume([93]) { return .array(array) }
                guard array.count < 100_000 else { throw PDFDigitalSignatureError.invalidStructure }
                array.append(try value(depth: depth + 1))
            }
        }
        if consume([47]) { return .name(try name()) }
        if consume([60]) {
            var digits: [UInt8] = []
            while true {
                guard index < bytes.count else { throw PDFDigitalSignatureError.invalidStructure }
                let byte = bytes[index]; index += 1
                if byte == 62 { break }
                if Self.whitespace.contains(byte) { continue }
                guard let digit = hex(byte) else { throw PDFDigitalSignatureError.invalidStructure }
                digits.append(digit)
            }
            if !digits.count.isMultiple(of: 2) { digits.append(0) }
            return .string(stride(from: 0, to: digits.count, by: 2).map { digits[$0] * 16 + digits[$0 + 1] })
        }
        if consume([40]) {
            var output: [UInt8] = []; var balance = 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 {
                    guard index < bytes.count else { throw PDFDigitalSignatureError.invalidStructure }
                    let escaped = bytes[index]; index += 1
                    if escaped == 13 { _ = consume([10]); continue }
                    if escaped == 10 { continue }
                    if (48...55).contains(escaped) {
                        var octal = Int(escaped - 48)
                        for _ in 0..<2 where index < bytes.count && (48...55).contains(bytes[index]) {
                            octal = octal * 8 + Int(bytes[index] - 48); index += 1
                        }
                        output.append(UInt8(octal & 255))
                    } else { output.append([110: 10, 114: 13, 116: 9, 98: 8, 102: 12][escaped] ?? escaped) }
                } else if byte == 40 { balance += 1; output.append(byte) }
                else if byte == 41 { balance -= 1; if balance == 0 { return .string(output) }; output.append(byte) }
                else if byte == 13 { _ = consume([10]); output.append(10) }
                else { output.append(byte) }
            }
            throw PDFDigitalSignatureError.invalidStructure
        }
        let first = try token()
        if ["true", "false", "null"].contains(first) { return .atom(first) }
        guard !first.isEmpty, first.utf8.allSatisfy({ (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }),
              let numeric = Double(first), numeric.isFinite else { throw PDFDigitalSignatureError.invalidStructure }
        let saved = index
        if let number = Int(first), number > 0,
           let second = try? token(), let generation = Int(second), (0...65535).contains(generation),
           let third = try? token(), third == "R" {
            return .reference(SigningPDFReference(number: number, generation: generation))
        }
        index = saved
        return .number(first)
    }
    private mutating func name() throws -> String {
        var result: [UInt8] = []
        while index < bytes.count, !Self.whitespace.contains(bytes[index]), !Self.delimiters.contains(bytes[index]) {
            let byte = bytes[index]; index += 1
            if byte == 35 {
                guard index + 1 < bytes.count, let a = hex(bytes[index]), let b = hex(bytes[index + 1]) else {
                    throw PDFDigitalSignatureError.invalidStructure
                }
                result.append(a * 16 + b); index += 2
            } else { result.append(byte) }
        }
        guard let string = String(bytes: result, encoding: .ascii) else { throw PDFDigitalSignatureError.invalidStructure }
        return string
    }
    private func hex(_ byte: UInt8) -> UInt8? {
        if (48...57).contains(byte) { return byte - 48 }
        if (65...70).contains(byte) { return byte - 55 }
        if (97...102).contains(byte) { return byte - 87 }
        return nil
    }
}
