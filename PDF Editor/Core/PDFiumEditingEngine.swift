import CoreGraphics
import CPDFiumBridge
import Foundation
import PDFKit

/// PDFium's runtime is process-wide, so even different document handles must
/// not enter its API concurrently. Document transactions and session entry
/// points share this recursive lock; private session helpers run under it.
nonisolated enum PDFiumAccess {
    static let lock = NSRecursiveLock()
}

nonisolated enum PDFPageObjectKind: Int32, Equatable, Sendable {
    case unknown = 0
    case text = 1
    case path = 2
    case image = 3
    case shading = 4
    case form = 5
}

nonisolated struct PDFObjectColor: Equatable, Sendable {
    let red: UInt32
    let green: UInt32
    let blue: UInt32
    let alpha: UInt32
}

nonisolated struct PDFPageObjectPath: Equatable, Hashable, Sendable {
    let indices: [Int32]

    var isNested: Bool { indices.count > 1 }
    var displayValue: String { indices.map(String.init).joined(separator: ".") }
}

nonisolated struct PDFPageObjectSnapshot: Equatable, Identifiable, Sendable {
    var id: String { "\(pageIndex):\(path.displayValue)" }
    var objectIndex: Int { Int(path.indices.last ?? 0) }
    var isNestedInForm: Bool { path.isNested }

    let pageIndex: Int
    let path: PDFPageObjectPath
    let kind: PDFPageObjectKind
    let bounds: CGRect
    let transform: CGAffineTransform
    let fillColor: PDFObjectColor
    let text: String?
    let fontName: String?
    let fontSize: CGFloat?
    let fontData: Data?
    let imagePixelSize: CGSize?

    func withFontData(_ fontData: Data?) -> PDFPageObjectSnapshot {
        PDFPageObjectSnapshot(
            pageIndex: pageIndex,
            path: path,
            kind: kind,
            bounds: bounds,
            transform: transform,
            fillColor: fillColor,
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            fontData: fontData,
            imagePixelSize: imagePixelSize
        )
    }
}

nonisolated struct PDFInvisibleTextItem: Equatable, Sendable {
    let text: String
    let bounds: CGRect
}

private extension CGAffineTransform {
    nonisolated var peDeterminant: CGFloat { a * d - b * c }

    nonisolated func isApproximatelyEqual(
        to other: CGAffineTransform,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        abs(a - other.a) < tolerance && abs(b - other.b) < tolerance &&
            abs(c - other.c) < tolerance && abs(d - other.d) < tolerance &&
            abs(tx - other.tx) < tolerance && abs(ty - other.ty) < tolerance
    }
}

nonisolated enum PDFTextReplacementResult: Equatable, Sendable {
    case preservedOriginalFont
    case usedCoreTextFallback(originalFontName: String?)
    case usedStyledCoreTextOverlay(originalFontName: String?)

    var userMessage: String? {
        switch self {
        case .preservedOriginalFont:
            nil
        case let .usedCoreTextFallback(originalFontName):
            if let originalFontName {
                "The original PDF font \(originalFontName) cannot safely render every required glyph or shaping rule. The original text was hidden and replaced with a searchable CoreText vector layer."
            } else {
                "The original PDF font cannot safely render this text. The original text was hidden and replaced with a searchable CoreText vector layer."
            }
        case .usedStyledCoreTextOverlay:
            "Bold or italic formatting was saved as a searchable CoreText vector layer."
        }
    }
}

nonisolated enum PDFObjectEditingError: Error, LocalizedError, Equatable, Sendable {
    case objectInspectionFailed
    case objectMutationFailed
    case unsupportedTextForStandardFont
    case invalidObjectType
    case imageMustBeJPEG
    case replacementVerificationFailed
    case shapingFallbackFailed
    case pageAppearanceWouldChange
    case invalidBitmapPayload

    var errorDescription: String? {
        switch self {
        case .objectInspectionFailed:
            "The PDF page object could not be inspected."
        case .objectMutationFailed:
            "The PDF page object could not be changed safely."
        case .unsupportedTextForStandardFont:
            "This text needs an embedded Unicode font. Standard PDF fonts only support a limited character set."
        case .invalidObjectType:
            "The selected PDF object does not support this operation."
        case .imageMustBeJPEG:
            "The current PDFium image importer requires JPEG data."
        case .replacementVerificationFailed:
            "The replacement did not round-trip through the original PDF font safely."
        case .shapingFallbackFailed:
            "The CoreText replacement could not be written back as a searchable PDF overlay."
        case .pageAppearanceWouldChange:
            "PDFium cannot write this edit as PDF page content without changing unrelated text or color resources. The text was not changed, and the original page was preserved."
        case .invalidBitmapPayload:
            "The decoded image bitmap is invalid or too large."
        }
    }
}

nonisolated protocol PDFObjectEditingSession: AnyObject {
    var hasDigitalSignatures: Bool { get }
    func objects(onPage pageIndex: Int) throws -> [PDFPageObjectSnapshot]
    func displayObjects(onPage pageIndex: Int) throws -> [PDFPageObjectSnapshot]
    func fontData(pageIndex: Int, path: PDFPageObjectPath) throws -> Data?
    func replaceText(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with text: String,
        style: PDFTextStyle,
        fallbackFontData: Data
    ) throws -> PDFTextReplacementResult
    func translateObject(pageIndex: Int, path: PDFPageObjectPath, by offset: CGSize) throws
    func setObjectTransform(
        pageIndex: Int,
        path: PDFPageObjectPath,
        transform: CGAffineTransform
    ) throws
    func moveObject(
        pageIndex: Int,
        path: PDFPageObjectPath,
        to destinationIndex: Int
    ) throws
    func deleteObject(pageIndex: Int, path: PDFPageObjectPath) throws
    func addStandardText(
        _ text: String,
        pageIndex: Int,
        origin: CGPoint,
        fontName: String,
        fontSize: CGFloat,
        color: PDFObjectColor
    ) throws
    func addJPEG(_ data: Data, pageIndex: Int, bounds: CGRect) throws
    func addBitmap(_ payload: PDFBitmapPayload, pageIndex: Int, bounds: CGRect) throws
    func replaceImage(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with payload: PDFBitmapPayload
    ) throws
    func addEmbeddedTextObjects(
        _ items: [PDFInvisibleTextItem],
        pageIndex: Int,
        fontData: Data,
        invisible: Bool
    ) throws
}

nonisolated protocol PDFAnnotationEditingSession: AnyObject {
    func setAnnotationColor(
        pageIndex: Int,
        annotationIndex: Int,
        color: PDFAnnotationColor
    ) throws
    func annotationColor(pageIndex: Int, annotationIndex: Int) throws -> PDFAnnotationColor
}

nonisolated final class PDFiumEditingEngine: PDFEditingEngine {
    func makeSession(data: Data, password: String? = nil) throws -> any PDFEditingSession {
        return try PDFiumEditingSession(originalData: data, password: password)
    }

    func openErrorCode(data: Data, password: String? = nil) -> UInt32? {
        return PDFiumEditingSession.openErrorCode(data: data, password: password)
    }
}

nonisolated final class PDFiumEditingSession: PDFEditingSession, PDFObjectEditingSession,
    PDFAnnotationEditingSession {
    let originalData: Data

    private var handle: OpaquePointer
    private var authorizedPassword: String?

    init(originalData: Data, password: String?) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        // Access the once-initialized runtime only after acquiring the shared
        // lock, including when a session is constructed directly.
        _ = PDFiumRuntime.shared
        self.originalData = originalData
        authorizedPassword = password
        handle = try Self.open(data: originalData, password: password)
    }

    deinit {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        PEPDFDocumentClose(handle)
    }

    var metadata: PDFDocumentMetadata {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        let currentData = try? dataRepresentation(options: PDFExportOptions())
        let pdfKitDocument = currentData.flatMap(PDFDocument.init(data:))
        let attributes = pdfKitDocument?.documentAttributes ?? [:]
        let info = PDFDocumentInfo(
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
            creator: attributes[PDFDocumentAttribute.creatorAttribute] as? String,
            keywords: attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
            creationDate: attributes[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
        return PDFDocumentMetadata(
            pageCount: Int(PEPDFDocumentPageCount(handle)),
            isEncrypted: PEPDFDocumentIsEncrypted(handle),
            isLocked: false,
            documentInfo: info
        )
    }

    var hasDigitalSignatures: Bool {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        return PEPDFDocumentSignatureCount(handle) > 0
    }

    func unlock(withPassword password: String) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        let newHandle = try Self.open(data: originalData, password: password)
        PEPDFDocumentClose(handle)
        handle = newHandle
        authorizedPassword = password
    }

    func apply(_ command: PDFEditingCommand) throws -> PDFEditingCommandResult {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        switch command {
        case .setDocumentInfo:
            return try applyMetadataCommandWithPDFKit(command)

        case let .deletePage(index):
            try requirePageAssemblyPermission()
            try validatePageIndex(index)
            let previousCount = metadata.pageCount
            guard previousCount > 1 else {
                throw PDFEditingError.cannotDeleteLastPage
            }
            try mutateAndReopen {
                PEPDFDocumentDeletePage(handle, Int32(index))
            } verify: {
                metadata.pageCount == previousCount - 1
            }
            return .updated(metadata)

        case let .rotatePage(index, degrees):
            try requirePageAssemblyPermission()
            try validatePageIndex(index)
            guard degrees.isMultiple(of: 90),
                  let current = pageInfo(at: index) else {
                if !degrees.isMultiple(of: 90) {
                    throw PDFEditingError.invalidRotation(degrees: degrees)
                }
                throw PDFObjectEditingError.objectInspectionFailed
            }
            let delta = degrees / 90
            let expectedRotation = (Int(current.rotation) + delta % 4 + 4) % 4
            try mutateAndReopen {
                PEPDFDocumentSetPageRotation(
                    handle,
                    Int32(index),
                    Int32(expectedRotation)
                )
            } verify: {
                pageInfo(at: index)?.rotation == Int32(expectedRotation)
            }
            return .updated(metadata)

        case let .movePage(sourceIndex, destinationIndex):
            try requirePageAssemblyPermission()
            try validatePageIndex(sourceIndex)
            try validatePageIndex(destinationIndex)
            guard sourceIndex != destinationIndex else {
                return .updated(metadata)
            }
            let pageCount = metadata.pageCount
            let indices = [Int32(sourceIndex)]
            try mutateAndReopen {
                indices.withUnsafeBufferPointer {
                    PEPDFDocumentMovePages(
                        handle,
                        $0.baseAddress,
                        $0.count,
                        Int32(destinationIndex)
                    )
                }
            } verify: {
                metadata.pageCount == pageCount
            }
            return .updated(metadata)

        case let .reorderPages(order):
            try requirePageAssemblyPermission()
            try validatePageOrder(order)
            guard order != Array(0..<metadata.pageCount) else {
                return .updated(metadata)
            }
            let indices = order.map(Int32.init)
            let pageCount = metadata.pageCount
            try mutateAndReopen {
                indices.withUnsafeBufferPointer {
                    PEPDFDocumentMovePages(
                        handle,
                        $0.baseAddress,
                        $0.count,
                        0
                    )
                }
            } verify: {
                metadata.pageCount == pageCount
            }
            return .updated(metadata)

        case let .merge(sourceData, password, index):
            try requirePageAssemblyPermission()
            try validateInsertionIndex(index)
            let sourcePageCount = try pageCount(
                data: sourceData,
                password: password,
                invalidPasswordError: .sourceDocumentLocked,
                invalidDocumentError: .sourceDocumentInvalid
            )
            let previousCount = metadata.pageCount
            try mutateAndReopen(subsetNewFontsAfterMutation: false) {
                var errorCode: UInt32 = 0
                let importPages: (UnsafePointer<CChar>?) -> Bool = { password in
                    sourceData.withUnsafeBytes { bytes in
                        PEPDFDocumentImportPages(
                            self.handle,
                            bytes.bindMemory(to: UInt8.self).baseAddress,
                            bytes.count,
                            password,
                            Int32(index),
                            &errorCode
                        )
                    }
                }
                if let password {
                    return password.withCString(importPages)
                }
                return importPages(nil)
            } verify: {
                metadata.pageCount == previousCount + sourcePageCount
            }
            return .updated(metadata)

        case let .split(ranges):
            let validatedRanges = try validatePageRanges(ranges)
            let documents = try validatedRanges.map { range in
                let indices = (range.lowerBound...range.upperBound).map(Int32.init)
                let data = try copyPages(indices)
                let expectedCount = range.upperBound - range.lowerBound + 1
                guard try pageCount(
                    data: data,
                    password: nil,
                    invalidPasswordError: .invalidPassword,
                    invalidDocumentError: .invalidDocument
                ) == expectedCount else {
                    throw PDFEditingError.exportFailed
                }
                return data
            }
            return .split(documents: documents)
        }
    }

    func dataRepresentation(options: PDFExportOptions = PDFExportOptions()) throws -> Data {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        return try dataRepresentation(options: options, subsetNewFonts: true)
    }

    private func dataRepresentation(
        options: PDFExportOptions,
        subsetNewFonts: Bool
    ) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let removeSecurity = options.securityPolicy == .removeAfterAuthorizedUnlock
        guard PEPDFDocumentCopyData(
            handle,
            removeSecurity,
            subsetNewFonts,
            &bytes,
            &length
        ), let bytes else {
            throw PDFEditingError.exportFailed
        }
        defer { PEPDFFree(bytes) }

        let data = Data(bytes: bytes, count: length)
        if removeSecurity, PDFDocument(data: data)?.isEncrypted != false {
            throw PDFEditingError.passwordRemovalFailed
        }
        return data
    }

    func setAnnotationColor(
        pageIndex: Int,
        annotationIndex: Int,
        color: PDFAnnotationColor
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        let component: (CGFloat) -> UInt32 = { value in
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        guard PEPDFAnnotationSetColor(
            handle,
            Int32(pageIndex),
            Int32(annotationIndex),
            component(color.red),
            component(color.green),
            component(color.blue),
            component(color.alpha)
        ) else {
            throw PDFObjectEditingError.objectMutationFailed
        }
    }

    func annotationColor(
        pageIndex: Int,
        annotationIndex: Int
    ) throws -> PDFAnnotationColor {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        guard PEPDFAnnotationGetColor(
            handle,
            Int32(pageIndex),
            Int32(annotationIndex),
            &red,
            &green,
            &blue,
            &alpha
        ) else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        return PDFAnnotationColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    func objects(onPage pageIndex: Int) throws -> [PDFPageObjectSnapshot] {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        let count = Int(PEPDFPageObjectCountRecursive(handle, Int32(pageIndex)))
        return try (0..<count).map { flatIndex in
            try object(
                onPage: pageIndex,
                path: copyPath(pageIndex: pageIndex, flatIndex: flatIndex)
            )
        }
    }

    func displayObjects(onPage pageIndex: Int) throws -> [PDFPageObjectSnapshot] {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        var pathIndices: UnsafeMutablePointer<Int32>?
        var pathOffsets: UnsafeMutablePointer<Int32>?
        var infos: UnsafeMutablePointer<PEPDFObjectInfo>?
        var objectCount = 0
        var pathIndexCount = 0
        guard PEPDFPageObjectCopyDisplayList(
            handle,
            Int32(pageIndex),
            &pathIndices,
            &pathOffsets,
            &infos,
            &objectCount,
            &pathIndexCount
        ) else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        guard objectCount > 0 else { return [] }
        guard let pathIndices, let pathOffsets, let infos else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        defer {
            PEPDFFree(pathIndices)
            PEPDFFree(pathOffsets)
            PEPDFFree(infos)
        }
        guard pathOffsets[objectCount] == Int32(pathIndexCount) else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        return try (0..<objectCount).map { index in
            let start = Int(pathOffsets[index])
            let end = Int(pathOffsets[index + 1])
            guard start >= 0, end > start, end <= pathIndexCount else {
                throw PDFObjectEditingError.objectInspectionFailed
            }
            let path = PDFPageObjectPath(
                indices: Array(
                    UnsafeBufferPointer(
                        start: pathIndices.advanced(by: start),
                        count: end - start
                    )
                )
            )
            return snapshot(
                pageIndex: pageIndex,
                path: path,
                info: infos[index],
                includesTextMetadata: false
            )
        }
    }

    func fontData(pageIndex: Int, path: PDFPageObjectPath) throws -> Data? {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        let object = try object(onPage: pageIndex, path: path)
        guard object.kind == .text else {
            throw PDFObjectEditingError.invalidObjectType
        }
        return copyFontData(pageIndex: pageIndex, path: path)
    }

    func replaceText(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with text: String,
        style: PDFTextStyle,
        fallbackFontData: Data
    ) throws -> PDFTextReplacementResult {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        let object = try object(onPage: pageIndex, path: path)
        guard object.kind == .text else {
            throw PDFObjectEditingError.invalidObjectType
        }
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        let originalFontData = copyFontData(pageIndex: pageIndex, path: path)
        let shapingService = CoreTextShapingService()
        let analysis = shapingService.analyze(text: text, fontData: originalFontData)
        let originalStyle = PDFTextStyle.inferred(fromFontName: object.fontName)
        let styleChanged = style != originalStyle

        if !styleChanged && analysis.coversAllCharacters && !analysis.requiresAdvancedShaping {
            do {
                guard try replaceTextDirectly(pageIndex: pageIndex, path: path, text: text) else {
                    throw PDFObjectEditingError.replacementVerificationFailed
                }
                let updatedData = try dataRepresentation(options: PDFExportOptions())
                guard PDFPageResourceIntegrityService.preservesPageResources(
                    from: beforeData,
                    to: updatedData,
                    pageIndex: pageIndex
                ) else {
                    throw PDFObjectEditingError.pageAppearanceWouldChange
                }
                try replaceHandle(with: updatedData, password: authorizedPassword)
                guard copyText(pageIndex: pageIndex, path: path)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw PDFObjectEditingError.replacementVerificationFailed
                }
                return .preservedOriginalFont
            } catch PDFObjectEditingError.pageAppearanceWouldChange {
                try replaceHandle(with: beforeData, password: authorizedPassword)
                throw PDFObjectEditingError.pageAppearanceWouldChange
            } catch {
                try replaceHandle(with: beforeData, password: authorizedPassword)
            }
        }

        do {
            let pageBounds = try mediaBox(pageIndex: pageIndex, data: beforeData)
            let overlayData = try shapingService.makeOverlayPDF(
                text: text,
                pageBounds: pageBounds,
                textTransform: object.transform,
                fontSize: object.fontSize ?? max(object.bounds.height, 12),
                color: object.fillColor,
                style: style,
                preferredFontData: analysis.coversAllCharacters ? originalFontData : nil,
                fallbackFontData: fallbackFontData
            )

            let actualText = Array(text.utf16)
            guard setTextInvisible(pageIndex: pageIndex, path: path),
                  try replaceTextDirectly(pageIndex: pageIndex, path: path, text: " "),
                  overlayData.withUnsafeBytes({ bytes in
                      actualText.withUnsafeBufferPointer { textBuffer in
                          PEPDFPageImportOverlayWithActualText(
                              handle,
                              Int32(pageIndex),
                              bytes.bindMemory(to: UInt8.self).baseAddress,
                              bytes.count,
                              textBuffer.baseAddress,
                              textBuffer.count
                          )
                      }
                  }) else {
                throw PDFObjectEditingError.shapingFallbackFailed
            }

            let updatedData = try dataRepresentation(options: PDFExportOptions())
            guard PDFPageResourceIntegrityService.preservesPageResources(
                from: beforeData,
                to: updatedData,
                pageIndex: pageIndex
            ) else {
                throw PDFObjectEditingError.pageAppearanceWouldChange
            }
            try replaceHandle(with: updatedData, password: authorizedPassword)
            guard try containsSemanticText(
                text,
                pageIndex: pageIndex,
                data: updatedData
            ) else {
                throw PDFObjectEditingError.replacementVerificationFailed
            }
            return styleChanged
                ? .usedStyledCoreTextOverlay(originalFontName: object.fontName)
                : .usedCoreTextFallback(originalFontName: object.fontName)
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func translateObject(pageIndex: Int, path: PDFPageObjectPath, by offset: CGSize) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        let beforeObject = try object(onPage: pageIndex, path: path)
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        do {
            let success = path.indices.withUnsafeBufferPointer {
                PEPDFPageObjectTranslateAtPath(
                    handle,
                    Int32(pageIndex),
                    $0.baseAddress,
                    $0.count,
                    Float(offset.width),
                    Float(offset.height)
                )
            }
            guard success else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            let afterObject = try object(onPage: pageIndex, path: path)
            guard abs(afterObject.bounds.minX - beforeObject.bounds.minX - offset.width) < 0.1,
                  abs(afterObject.bounds.minY - beforeObject.bounds.minY - offset.height) < 0.1 else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func setObjectTransform(
        pageIndex: Int,
        path: PDFPageObjectPath,
        transform: CGAffineTransform
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        _ = try object(onPage: pageIndex, path: path)
        guard transform.a.isFinite, transform.b.isFinite,
              transform.c.isFinite, transform.d.isFinite,
              transform.tx.isFinite, transform.ty.isFinite,
              abs(transform.peDeterminant) > 0.000001 else {
            throw PDFObjectEditingError.objectMutationFailed
        }
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        do {
            let success = path.indices.withUnsafeBufferPointer {
                PEPDFPageObjectSetTransformAtPath(
                    handle, Int32(pageIndex), $0.baseAddress, $0.count,
                    Float(transform.a), Float(transform.b),
                    Float(transform.c), Float(transform.d),
                    Float(transform.tx), Float(transform.ty)
                )
            }
            guard success else { throw PDFObjectEditingError.objectMutationFailed }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            let actual = try object(onPage: pageIndex, path: path).transform
            guard actual.isApproximatelyEqual(to: transform) else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func moveObject(
        pageIndex: Int,
        path: PDFPageObjectPath,
        to destinationIndex: Int
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        guard destinationIndex >= 0, !path.indices.isEmpty else {
            throw PDFObjectEditingError.objectMutationFailed
        }
        let beforeObject = try object(onPage: pageIndex, path: path)
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        var destinationPath = path.indices
        destinationPath[destinationPath.count - 1] = Int32(destinationIndex)
        let movedPath = PDFPageObjectPath(indices: destinationPath)
        do {
            let success = path.indices.withUnsafeBufferPointer {
                PEPDFPageObjectMoveToIndexAtPath(
                    handle, Int32(pageIndex), $0.baseAddress, $0.count,
                    Int32(destinationIndex)
                )
            }
            guard success else { throw PDFObjectEditingError.objectMutationFailed }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            let moved = try object(onPage: pageIndex, path: movedPath)
            guard moved.kind == beforeObject.kind,
                  moved.transform.isApproximatelyEqual(to: beforeObject.transform),
                  moved.text == beforeObject.text,
                  moved.imagePixelSize == beforeObject.imagePixelSize else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func deleteObject(pageIndex: Int, path: PDFPageObjectPath) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        _ = try object(onPage: pageIndex, path: path)
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        let beforeCount = PEPDFPageObjectCountRecursive(handle, Int32(pageIndex))
        do {
            let success = path.indices.withUnsafeBufferPointer {
                PEPDFPageObjectDeleteAtPath(
                    handle,
                    Int32(pageIndex),
                    $0.baseAddress,
                    $0.count
                )
            }
            guard success else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            guard PEPDFPageObjectCountRecursive(handle, Int32(pageIndex)) < beforeCount else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func addStandardText(
        _ text: String,
        pageIndex: Int,
        origin: CGPoint,
        fontName: String = "Helvetica",
        fontSize: CGFloat,
        color: PDFObjectColor
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        guard text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else {
            throw PDFObjectEditingError.unsupportedTextForStandardFont
        }
        let utf16 = Array(text.utf16)
        let success = utf16.withUnsafeBufferPointer { textBuffer in
            fontName.withCString { fontName in
                PEPDFPageAddStandardText(
                    handle,
                    Int32(pageIndex),
                    textBuffer.baseAddress,
                    textBuffer.count,
                    fontName,
                    Float(fontSize),
                    Float(origin.x),
                    Float(origin.y),
                    color.red,
                    color.green,
                    color.blue,
                    color.alpha
                )
            }
        }
        guard success else {
            throw PDFObjectEditingError.objectMutationFailed
        }
    }

    func addJPEG(_ data: Data, pageIndex: Int, bounds: CGRect) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        guard data.starts(with: [0xFF, 0xD8]) else {
            throw PDFObjectEditingError.imageMustBeJPEG
        }
        let success = data.withUnsafeBytes { bytes in
            PEPDFPageAddJPEG(
                handle,
                Int32(pageIndex),
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                Float(bounds.minX),
                Float(bounds.minY),
                Float(bounds.width),
                Float(bounds.height)
            )
        }
        guard success else {
            throw PDFObjectEditingError.objectMutationFailed
        }
    }

    func addBitmap(_ payload: PDFBitmapPayload, pageIndex: Int, bounds: CGRect) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        try validate(payload: payload)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw PDFObjectEditingError.objectMutationFailed
        }
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        let beforeCount = Int(PEPDFPageObjectCount(handle, Int32(pageIndex)))
        do {
            let success = payload.data.withUnsafeBytes { bytes in
                PEPDFPageAddBitmapBGRA(
                    handle, Int32(pageIndex),
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    Int32(payload.pixelWidth), Int32(payload.pixelHeight),
                    Int32(payload.bytesPerRow), Float(bounds.minX), Float(bounds.minY),
                    Float(bounds.width), Float(bounds.height)
                )
            }
            guard success else { throw PDFObjectEditingError.objectMutationFailed }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            guard Int(PEPDFPageObjectCount(handle, Int32(pageIndex))) == beforeCount + 1 else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let added = try object(
                onPage: pageIndex,
                path: PDFPageObjectPath(indices: [Int32(beforeCount)])
            )
            guard added.kind == .image,
                  added.imagePixelSize == CGSize(
                      width: payload.pixelWidth,
                      height: payload.pixelHeight
                  ) else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func replaceImage(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with payload: PDFBitmapPayload
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        let beforeObject = try object(onPage: pageIndex, path: path)
        guard beforeObject.kind == .image else {
            throw PDFObjectEditingError.invalidObjectType
        }
        try validate(payload: payload)
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        do {
            let success = payload.data.withUnsafeBytes { bytes in
                path.indices.withUnsafeBufferPointer { pathBuffer in
                    PEPDFPageObjectReplaceBitmapBGRAAtPath(
                        handle, Int32(pageIndex), pathBuffer.baseAddress, pathBuffer.count,
                        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        Int32(payload.pixelWidth), Int32(payload.pixelHeight),
                        Int32(payload.bytesPerRow)
                    )
                }
            }
            guard success else { throw PDFObjectEditingError.objectMutationFailed }
            let updatedData = try dataRepresentation(options: PDFExportOptions())
            try replaceHandle(with: updatedData, password: authorizedPassword)
            let afterObject = try object(onPage: pageIndex, path: path)
            guard afterObject.kind == .image,
                  afterObject.transform.isApproximatelyEqual(to: beforeObject.transform),
                  afterObject.imagePixelSize == CGSize(
                      width: payload.pixelWidth,
                      height: payload.pixelHeight
                  ) else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    func addEmbeddedTextObjects(
        _ items: [PDFInvisibleTextItem],
        pageIndex: Int,
        fontData: Data,
        invisible: Bool
    ) throws {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        try validatePageIndex(pageIndex)
        guard !items.isEmpty else { return }

        let font = fontData.withUnsafeBytes { bytes in
            PEPDFFontCreateEmbedded(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard let font else {
            throw PDFObjectEditingError.objectMutationFailed
        }
        defer { PEPDFFontClose(font) }

        for item in items {
            let utf16 = Array(item.text.utf16)
            let fontSize = max(4, item.bounds.height * 0.82)
            let success = utf16.withUnsafeBufferPointer { textBuffer in
                PEPDFPageAddEmbeddedText(
                    handle,
                    font,
                    Int32(pageIndex),
                    textBuffer.baseAddress,
                    textBuffer.count,
                    Float(fontSize),
                    Float(item.bounds.minX),
                    Float(item.bounds.minY),
                    invisible
                )
            }
            guard success else {
                throw PDFObjectEditingError.objectMutationFailed
            }
        }
    }

    private func applyMetadataCommandWithPDFKit(
        _ command: PDFEditingCommand
    ) throws -> PDFEditingCommandResult {
        let currentData = try dataRepresentation(options: PDFExportOptions())
        let pageSession = try PDFKitEditingEngine().makeSession(
            data: currentData,
            password: authorizedPassword
        )
        let result = try pageSession.apply(command)
        guard case .updated = result else {
            return result
        }
        let updatedData = try pageSession.dataRepresentation(options: PDFExportOptions())
        try replaceHandle(with: updatedData, password: authorizedPassword)
        return .updated(metadata)
    }

    private func mutateAndReopen(
        subsetNewFontsAfterMutation: Bool = true,
        _ mutation: () -> Bool,
        verify: () throws -> Bool
    ) throws {
        let beforeData = try dataRepresentation(options: PDFExportOptions())
        do {
            guard mutation() else {
                throw PDFEditingError.pageMutationFailed
            }
            let updatedData = try dataRepresentation(
                options: PDFExportOptions(),
                subsetNewFonts: subsetNewFontsAfterMutation
            )
            try replaceHandle(with: updatedData, password: authorizedPassword)
            guard try verify() else {
                throw PDFEditingError.pageMutationFailed
            }
        } catch {
            try? replaceHandle(with: beforeData, password: authorizedPassword)
            throw error
        }
    }

    private func pageInfo(at pageIndex: Int) -> PEPDFPageInfo? {
        var info = PEPDFPageInfo()
        guard PEPDFPageInfoAtIndex(
            handle,
            Int32(pageIndex),
            &info
        ) else {
            return nil
        }
        return info
    }

    private func copyPages(_ indices: [Int32]) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let success = indices.withUnsafeBufferPointer {
            PEPDFDocumentCopyPages(
                handle,
                $0.baseAddress,
                $0.count,
                &bytes,
                &length
            )
        }
        guard success, let bytes else {
            throw PDFEditingError.exportFailed
        }
        defer { PEPDFFree(bytes) }
        return Data(bytes: bytes, count: length)
    }

    private func pageCount(
        data: Data,
        password: String?,
        invalidPasswordError: PDFEditingError,
        invalidDocumentError: PDFEditingError
    ) throws -> Int {
        do {
            let document = try Self.open(data: data, password: password)
            defer { PEPDFDocumentClose(document) }
            return Int(PEPDFDocumentPageCount(document))
        } catch PDFEditingError.invalidPassword {
            throw invalidPasswordError
        } catch {
            throw invalidDocumentError
        }
    }

    private func requirePageAssemblyPermission() throws {
        let permissions = PEPDFDocumentPermissions(handle)
        guard permissions & 0x400 != 0 else {
            throw PDFEditingError.documentPermissionDenied(
                operation: "page assembly"
            )
        }
    }

    private func validateInsertionIndex(_ index: Int) throws {
        let pageCount = metadata.pageCount
        guard (0...pageCount).contains(index) else {
            throw PDFEditingError.invalidInsertionIndex(
                index: index,
                pageCount: pageCount
            )
        }
    }

    private func validatePageOrder(_ order: [Int]) throws {
        let pageCount = metadata.pageCount
        guard order.count == pageCount else {
            throw PDFEditingError.invalidPageOrder(
                expectedPageCount: pageCount,
                actualPageCount: order.count
            )
        }
        var seen = Set<Int>()
        for index in order {
            try validatePageIndex(index)
            guard seen.insert(index).inserted else {
                throw PDFEditingError.duplicatePageIndex(index: index)
            }
        }
    }

    private func validatePageRanges(
        _ ranges: [PDFPageRange]
    ) throws -> [PDFPageRange] {
        guard !ranges.isEmpty else { return [] }
        let pageCount = metadata.pageCount
        var covered = Set<Int>()
        for range in ranges {
            guard range.lowerBound >= 0,
                  range.upperBound >= range.lowerBound,
                  range.upperBound < pageCount else {
                throw PDFEditingError.invalidPageRange(
                    lowerBound: range.lowerBound,
                    upperBound: range.upperBound,
                    pageCount: pageCount
                )
            }
            for index in range.lowerBound...range.upperBound {
                guard covered.insert(index).inserted else {
                    throw PDFEditingError.overlappingPageRange(range)
                }
            }
        }
        return ranges
    }

    private func object(
        onPage pageIndex: Int,
        path: PDFPageObjectPath,
        includesTextMetadata: Bool = true
    ) throws -> PDFPageObjectSnapshot {
        try validatePageIndex(pageIndex)
        var info = PEPDFObjectInfo()
        let success = path.indices.withUnsafeBufferPointer {
            PEPDFPageObjectInfoAtPath(
                handle,
                Int32(pageIndex),
                $0.baseAddress,
                $0.count,
                &info
            )
        }
        guard success else {
            throw PDFObjectEditingError.objectInspectionFailed
        }

        return snapshot(
            pageIndex: pageIndex,
            path: path,
            info: info,
            includesTextMetadata: includesTextMetadata
        )
    }

    private func snapshot(
        pageIndex: Int,
        path: PDFPageObjectPath,
        info: PEPDFObjectInfo,
        includesTextMetadata: Bool
    ) -> PDFPageObjectSnapshot {
        let kind = PDFPageObjectKind(rawValue: info.type) ?? .unknown
        return PDFPageObjectSnapshot(
            pageIndex: pageIndex,
            path: path,
            kind: kind,
            bounds: CGRect(
                x: CGFloat(info.left),
                y: CGFloat(info.bottom),
                width: CGFloat(info.right - info.left),
                height: CGFloat(info.top - info.bottom)
            ),
            transform: CGAffineTransform(
                a: CGFloat(info.matrixA),
                b: CGFloat(info.matrixB),
                c: CGFloat(info.matrixC),
                d: CGFloat(info.matrixD),
                tx: CGFloat(info.matrixE),
                ty: CGFloat(info.matrixF)
            ),
            fillColor: PDFObjectColor(
                red: info.fillRed,
                green: info.fillGreen,
                blue: info.fillBlue,
                alpha: info.fillAlpha
            ),
            text: kind == .text && includesTextMetadata
                ? copyText(pageIndex: pageIndex, path: path)
                : nil,
            fontName: kind == .text && includesTextMetadata
                ? copyFontName(pageIndex: pageIndex, path: path)
                : nil,
            fontSize: kind == .text ? CGFloat(info.fontSize) : nil,
            fontData: nil,
            imagePixelSize: kind == .image
                ? CGSize(width: Int(info.imagePixelWidth), height: Int(info.imagePixelHeight))
                : nil
        )
    }

    private func validate(payload: PDFBitmapPayload) throws {
        guard payload.pixelWidth > 0, payload.pixelHeight > 0,
              payload.pixelWidth <= Int(Int32.max) / 4,
              payload.pixelHeight <= Int(Int32.max),
              payload.bytesPerRow >= payload.pixelWidth * 4,
              payload.bytesPerRow <= Int(Int32.max),
              payload.pixelHeight <= Int.max / payload.bytesPerRow,
              payload.data.count >= payload.pixelHeight * payload.bytesPerRow else {
            throw PDFObjectEditingError.invalidBitmapPayload
        }
    }

    private func copyText(pageIndex: Int, path: PDFPageObjectPath) -> String? {
        var text: UnsafeMutablePointer<UInt16>?
        var length = 0
        let success = path.indices.withUnsafeBufferPointer {
            PEPDFPageObjectCopyTextAtPath(
                handle,
                Int32(pageIndex),
                $0.baseAddress,
                $0.count,
                &text,
                &length
            )
        }
        guard success, let text else {
            return nil
        }
        defer { PEPDFFree(text) }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }

    private func copyFontName(pageIndex: Int, path: PDFPageObjectPath) -> String? {
        var name: UnsafeMutablePointer<CChar>?
        var length = 0
        let success = path.indices.withUnsafeBufferPointer {
            PEPDFPageObjectCopyFontNameAtPath(
                handle,
                Int32(pageIndex),
                $0.baseAddress,
                $0.count,
                &name,
                &length
            )
        }
        guard success, let name else {
            return nil
        }
        defer { PEPDFFree(name) }
        let bytes = UnsafeRawBufferPointer(start: name, count: length)
            .bindMemory(to: UInt8.self)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func copyFontData(pageIndex: Int, path: PDFPageObjectPath) -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let success = path.indices.withUnsafeBufferPointer {
            PEPDFPageObjectCopyFontDataAtPath(
                handle,
                Int32(pageIndex),
                $0.baseAddress,
                $0.count,
                &bytes,
                &length
            )
        }
        guard success, let bytes else { return nil }
        defer { PEPDFFree(bytes) }
        return Data(bytes: bytes, count: length)
    }

    private func replaceTextDirectly(
        pageIndex: Int,
        path: PDFPageObjectPath,
        text: String
    ) throws -> Bool {
        let utf16 = Array(text.utf16)
        let success = path.indices.withUnsafeBufferPointer { pathBuffer in
            utf16.withUnsafeBufferPointer { textBuffer in
                PEPDFPageObjectReplaceTextAtPath(
                    handle,
                    Int32(pageIndex),
                    pathBuffer.baseAddress,
                    pathBuffer.count,
                    textBuffer.baseAddress,
                    textBuffer.count
                )
            }
        }
        if !success, PEPDFDocumentLastMutationRejectedForAppearance(handle) {
            throw PDFObjectEditingError.pageAppearanceWouldChange
        }
        return success
    }

    private func setTextInvisible(
        pageIndex: Int,
        path: PDFPageObjectPath
    ) -> Bool {
        path.indices.withUnsafeBufferPointer {
            PEPDFPageObjectSetInvisibleAtPath(
                handle,
                Int32(pageIndex),
                $0.baseAddress,
                $0.count
            )
        }
    }

    private func mediaBox(pageIndex: Int, data: Data) throws -> CGRect {
        let document = try pdfKitDocument(data: data)
        guard let page = document.page(at: pageIndex) else {
            throw PDFEditingError.invalidPageIndex(
                index: pageIndex,
                pageCount: document.pageCount
            )
        }
        return page.bounds(for: .mediaBox)
    }

    private func containsSemanticText(
        _ text: String,
        pageIndex: Int,
        data: Data
    ) throws -> Bool {
        let document = try pdfKitDocument(data: data)
        guard let page = document.page(at: pageIndex) else {
            throw PDFEditingError.invalidPageIndex(
                index: pageIndex,
                pageCount: document.pageCount
            )
        }
        let searchTerms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if page.string?.contains(text) == true ||
            !document.findString(text, withOptions: []).isEmpty ||
            (!searchTerms.isEmpty && searchTerms.allSatisfy {
                !document.findString($0, withOptions: []).isEmpty
            }) {
            return true
        }
        return try objects(onPage: pageIndex).contains { object in
            object.text?.contains(text) == true
        }
    }

    private func pdfKitDocument(data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }
        if document.isLocked {
            guard let authorizedPassword,
                  document.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        return document
    }

    private func copyPath(pageIndex: Int, flatIndex: Int) throws -> PDFPageObjectPath {
        var indices: UnsafeMutablePointer<Int32>?
        var length = 0
        guard PEPDFPageObjectCopyPath(
            handle,
            Int32(pageIndex),
            Int32(flatIndex),
            &indices,
            &length
        ), let indices else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        defer { PEPDFFree(indices) }
        return PDFPageObjectPath(
            indices: Array(UnsafeBufferPointer(start: indices, count: length))
        )
    }

    private func validatePageIndex(_ pageIndex: Int) throws {
        let pageCount = Int(PEPDFDocumentPageCount(handle))
        guard (0..<pageCount).contains(pageIndex) else {
            throw PDFEditingError.invalidPageIndex(index: pageIndex, pageCount: pageCount)
        }
    }

    private func replaceHandle(with data: Data, password: String?) throws {
        let newHandle = try Self.open(data: data, password: password)
        PEPDFDocumentClose(handle)
        handle = newHandle
    }

    private static func open(data: Data, password: String?) throws -> OpaquePointer {
        let result = createHandle(data: data, password: password)
        guard let handle = result.handle else {
            if result.errorCode == 4 {
                throw PDFEditingError.invalidPassword
            }
            throw PDFEditingError.invalidDocument
        }
        return handle
    }

    fileprivate static func openErrorCode(
        data: Data,
        password: String?
    ) -> UInt32? {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        _ = PDFiumRuntime.shared
        let result = createHandle(data: data, password: password)
        guard let handle = result.handle else { return result.errorCode }
        PEPDFDocumentClose(handle)
        return nil
    }

    private static func createHandle(
        data: Data,
        password: String?
    ) -> (handle: OpaquePointer?, errorCode: UInt32) {
        var errorCode: UInt32 = 0
        let handle = data.withUnsafeBytes { bytes -> OpaquePointer? in
            guard let address = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            if let password {
                return password.withCString { password in
                    PEPDFDocumentCreate(address, bytes.count, password, &errorCode)
                }
            }
            return PEPDFDocumentCreate(address, bytes.count, nil, &errorCode)
        }
        return (handle, errorCode)
    }
}

nonisolated private final class PDFiumRuntime: @unchecked Sendable {
    static let shared = PDFiumRuntime()

    private init() {
        // All shared-instance lookups occur while PDFiumAccess.lock is held.
        PEPDFLibraryInitialize()
    }

    deinit {
        PDFiumAccess.lock.lock()
        defer { PDFiumAccess.lock.unlock() }
        PEPDFLibraryDestroy()
    }
}
