import Combine
import CoreGraphics
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

final class PDFEditorDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    final class EditorState: ObservableObject {
        @Published private(set) var revision = 0
        @Published private(set) var hasUnsavedChanges = false

        fileprivate func documentDidChange(markingUnsaved: Bool) {
            revision &+= 1
            if markingUnsaved {
                hasUnsavedChanges = true
            }
        }

        fileprivate func markSaved() {
            hasUnsavedChanges = false
        }
    }

    static let readableContentTypes: [UTType] = [.pdf]
    static let writableContentTypes: [UTType] = [.pdf]

    let editorState = EditorState()

    private(set) var pdfDocument: PDFDocument
    private(set) var removesPasswordProtectionOnSave = false

    private var editingSession: (any PDFEditingSession)?
    private var sourceData: Data
    private var persistedData: Data
    private var authorizedPassword: String?
    private var allowsInvalidatingDigitalSignatures = false

    var pageCount: Int {
        pdfDocument.pageCount
    }

    var isLocked: Bool {
        pdfDocument.isLocked
    }

    var isEncrypted: Bool {
        editingSession?.metadata.isEncrypted ?? pdfDocument.isEncrypted
    }

    var hasDigitalSignatures: Bool {
        (editingSession as? any PDFObjectEditingSession)?.hasDigitalSignatures == true
    }

    func authorizeDigitalSignatureInvalidation() {
        allowsInvalidatingDigitalSignatures = true
    }

    init() {
        let data = Self.makeBlankPDF()
        sourceData = data
        persistedData = data
        authorizedPassword = nil
        pdfDocument = PDFDocument(data: data) ?? PDFDocument()
        editingSession = try? PDFiumEditingEngine().makeSession(data: data, password: nil)
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let document = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        sourceData = data
        persistedData = data
        authorizedPassword = nil
        pdfDocument = document
        if !document.isLocked {
            editingSession = try? PDFiumEditingEngine().makeSession(data: data, password: nil)
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        persistedData
    }

    func fileWrapper(
        snapshot: Data,
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    func unlock(withPassword password: String) throws {
        let session = try PDFiumEditingEngine().makeSession(
            data: sourceData,
            password: password
        )
        editingSession = session
        authorizedPassword = password
        try refreshPDFKitDocument(markingUnsaved: false)
    }

    func setRemovesPasswordProtectionOnSave(_ removesProtection: Bool) {
        guard removesPasswordProtectionOnSave != removesProtection else { return }
        removesPasswordProtectionOnSave = removesProtection
        editorState.documentDidChange(markingUnsaved: true)
    }

    func dataForManualSave() throws -> Data {
        if let editingSession {
            return try editingSession.dataRepresentation(
                options: PDFExportOptions(
                    securityPolicy: removesPasswordProtectionOnSave
                        ? .removeAfterAuthorizedUnlock
                        : .preserve
                )
            )
        }

        guard let data = pdfDocument.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    func markManuallySaved(data: Data) {
        persistedData = data
        sourceData = data
        editorState.markSaved()
    }

    @discardableResult
    func apply(
        _ command: PDFEditingCommand,
        undoManager: UndoManager?,
        actionName: String
    ) throws -> PDFEditingCommandResult {
        if case .split = command {
            guard let editingSession else {
                throw PDFEditingError.documentLocked
            }
            return try editingSession.apply(command)
        }
        return try mutate(undoManager: undoManager, actionName: actionName) {
            guard let editingSession else {
                throw PDFEditingError.documentLocked
            }
            return try editingSession.apply(command)
        }
    }

    func pageObjects(at pageIndex: Int) throws -> [PDFPageObjectSnapshot] {
        guard let objectSession = editingSession as? any PDFObjectEditingSession else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        return try objectSession.objects(onPage: pageIndex)
    }

    func replaceText(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with text: String,
        undoManager: UndoManager?
    ) throws -> PDFTextReplacementResult {
        let object = try pageObjects(at: pageIndex).first { $0.path == path }
        guard let object else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        do {
            return try mutate(undoManager: undoManager, actionName: "Replace PDF Text") {
                guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                    throw PDFObjectEditingError.objectMutationFailed
                }
                return try objectSession.replaceText(
                    pageIndex: pageIndex,
                    path: path,
                    with: text,
                    fallbackFontData: try unicodeFontData()
                )
            }
        } catch PDFObjectEditingError.pageAppearanceWouldChange {
            let service = PDFAnnotationService()
            try mutateAnnotations(
                undoManager: undoManager,
                actionName: "Replace PDF Text Safely"
            ) {
                guard let page = pdfDocument.page(at: pageIndex) else {
                    throw PDFEditingError.invalidPageIndex(
                        index: pageIndex,
                        pageCount: pdfDocument.pageCount
                    )
                }
                _ = try service.addAppearanceSafeTextReplacement(
                    text: text,
                    replacing: object,
                    to: page
                )
            }
            return .usedAppearanceSafeAnnotationFallback(originalFontName: object.fontName)
        }
    }

    func translateObject(
        pageIndex: Int,
        path: PDFPageObjectPath,
        by offset: CGSize,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Move PDF Object") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.translateObject(
                pageIndex: pageIndex,
                path: path,
                by: offset
            )
        }
    }

    func setObjectTransform(
        pageIndex: Int,
        path: PDFPageObjectPath,
        transform: CGAffineTransform,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Transform PDF Object") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.setObjectTransform(
                pageIndex: pageIndex,
                path: path,
                transform: transform
            )
        }
    }

    func moveObject(
        pageIndex: Int,
        path: PDFPageObjectPath,
        to destinationIndex: Int,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Reorder PDF Object") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.moveObject(
                pageIndex: pageIndex,
                path: path,
                to: destinationIndex
            )
        }
    }

    func deleteObject(
        pageIndex: Int,
        path: PDFPageObjectPath,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Delete PDF Object") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.deleteObject(pageIndex: pageIndex, path: path)
        }
    }

    func addText(
        _ text: String,
        pageIndex: Int,
        origin: CGPoint,
        fontSize: CGFloat,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Add PDF Text") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            if text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
                try objectSession.addStandardText(
                    text,
                    pageIndex: pageIndex,
                    origin: origin,
                    fontName: "Helvetica",
                    fontSize: fontSize,
                    color: PDFObjectColor(red: 0, green: 0, blue: 0, alpha: 255)
                )
            } else {
                try objectSession.addEmbeddedTextObjects(
                    [PDFInvisibleTextItem(
                        text: text,
                        bounds: CGRect(
                            origin: origin,
                            size: CGSize(width: max(fontSize, 1), height: fontSize / 0.82)
                        )
                    )],
                    pageIndex: pageIndex,
                    fontData: try unicodeFontData(),
                    invisible: false
                )
            }
        }
    }

    func addJPEG(
        _ data: Data,
        pageIndex: Int,
        bounds: CGRect,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Add PDF Image") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.addJPEG(data, pageIndex: pageIndex, bounds: bounds)
        }
    }

    func addImage(
        _ payload: PDFBitmapPayload,
        pageIndex: Int,
        bounds: CGRect,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Add PDF Image") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.addBitmap(payload, pageIndex: pageIndex, bounds: bounds)
        }
    }

    func replaceImage(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with payload: PDFBitmapPayload,
        undoManager: UndoManager?
    ) throws {
        try mutate(undoManager: undoManager, actionName: "Replace PDF Image") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            try objectSession.replaceImage(
                pageIndex: pageIndex,
                path: path,
                with: payload
            )
        }
    }

    func addOCRTextLayer(
        _ observations: [OCRTextObservation],
        pageIndex: Int,
        undoManager: UndoManager?
    ) throws {
        try addOCRTextLayers(
            [OCRRecognizedPage(pageIndex: pageIndex, observations: observations)],
            undoManager: undoManager
        )
    }

    func addOCRTextLayers(
        _ recognizedPages: [OCRRecognizedPage],
        undoManager: UndoManager?
    ) throws {
        guard !recognizedPages.isEmpty else { return }
        var seenPageIndices = Set<Int>()
        for recognizedPage in recognizedPages {
            guard seenPageIndices.insert(recognizedPage.pageIndex).inserted,
                  let page = pdfDocument.page(at: recognizedPage.pageIndex) else {
                throw VisionOCRError.invalidPageIndex(recognizedPage.pageIndex)
            }
            guard page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                throw VisionOCRError.textLayerAlreadyExists
            }
        }

        try mutate(undoManager: undoManager, actionName: "新增 OCR 可搜尋文字層") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let fontData = try unicodeFontData()
            for recognizedPage in recognizedPages {
                let items = recognizedPage.observations.map {
                    PDFInvisibleTextItem(text: $0.text, bounds: $0.pageBounds)
                }
                guard !items.isEmpty else { continue }
                try objectSession.addEmbeddedTextObjects(
                    items,
                    pageIndex: recognizedPage.pageIndex,
                    fontData: fontData,
                    invisible: true
                )
            }
        }
    }

    private func unicodeFontData() throws -> Data {
        guard let fontURL = Bundle.main.url(
            forResource: "NotoSansCJKtc-Regular",
            withExtension: "otf"
        ) else {
            throw VisionOCRError.fontResourceMissing
        }
        return try Data(contentsOf: fontURL)
    }

    func mutateAnnotations(
        undoManager: UndoManager?,
        actionName: String,
        _ mutation: () throws -> Void
    ) throws {
        try mutate(
            undoManager: undoManager,
            actionName: actionName,
            refreshesPDFKitDocument: false
        ) {
            try mutation()
            guard let data = pdfDocument.dataRepresentation() else {
                throw PDFEditingError.exportFailed
            }
            editingSession = try makeVerifiedAnnotationSession(
                data: data,
                expected: allAnnotationSnapshots()
            )
        }
    }

    func annotationSnapshots(onPage pageIndex: Int) throws -> [PDFAnnotationSnapshot] {
        guard let page = pdfDocument.page(at: pageIndex) else {
            throw PDFAnnotationServiceError.annotationNotFound
        }
        var snapshots = PDFAnnotationService().snapshots(on: page, pageIndex: pageIndex)
        if let annotationSession = editingSession as? any PDFAnnotationEditingSession {
            for index in snapshots.indices {
                let reference = snapshots[index].reference
                if let color = try? annotationSession.annotationColor(
                    pageIndex: reference.pageIndex,
                    annotationIndex: reference.annotationIndex
                ) {
                    snapshots[index].color = color
                    if snapshots[index].fontColor != nil {
                        snapshots[index].fontColor?.alpha = color.alpha
                    }
                }
            }
        }
        return snapshots
    }

    @discardableResult
    func updateAnnotation(
        _ reference: PDFAnnotationReference,
        with update: PDFAnnotationUpdate,
        undoManager: UndoManager?
    ) throws -> PDFAnnotationSnapshot {
        let service = PDFAnnotationService()
        try mutate(
            undoManager: undoManager,
            actionName: "修改註解",
            refreshesPDFKitDocument: false
        ) {
            _ = try service.update(reference, with: update, in: pdfDocument)
            guard let data = pdfDocument.dataRepresentation(),
                  PDFDocument(data: data) != nil else {
                throw PDFEditingError.exportFailed
            }
            editingSession = try makeVerifiedAnnotationSession(
                data: data,
                expected: allAnnotationSnapshots(),
                colorOverrides: update.color.map { [reference: $0] } ?? [:]
            )
        }
        let resolved = try service.resolve(reference, in: pdfDocument)
        guard let snapshot = service.snapshots(
            on: resolved.page,
            pageIndex: reference.pageIndex
        ).first(where: { $0.reference == reference }) else {
            throw PDFAnnotationServiceError.annotationNotFound
        }
        return snapshot
    }

    func deleteAnnotation(
        _ reference: PDFAnnotationReference,
        undoManager: UndoManager?
    ) throws {
        let service = PDFAnnotationService()
        try mutateAnnotations(undoManager: undoManager, actionName: "刪除註解") {
            try service.remove(reference, from: pdfDocument)
        }
    }

    private func allAnnotationSnapshots() -> [PDFAnnotationSnapshot] {
        let service = PDFAnnotationService()
        return (0..<pdfDocument.pageCount).flatMap { pageIndex in
            guard let page = pdfDocument.page(at: pageIndex) else {
                return [PDFAnnotationSnapshot]()
            }
            return service.snapshots(on: page, pageIndex: pageIndex)
        }
    }

    private func makeVerifiedAnnotationSession(
        data: Data,
        expected: [PDFAnnotationSnapshot],
        colorOverrides: [PDFAnnotationReference: PDFAnnotationColor] = [:]
    ) throws -> any PDFEditingSession {
        let session = try PDFiumEditingEngine().makeSession(
            data: data,
            password: authorizedPassword
        )
        guard let annotationSession = session as? any PDFAnnotationEditingSession else {
            throw PDFObjectEditingError.objectMutationFailed
        }
        guard let serializedDocument = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }
        let service = PDFAnnotationService()
        let serializedAnnotations = Dictionary(uniqueKeysWithValues:
            (0..<serializedDocument.pageCount).flatMap { pageIndex in
                guard let page = serializedDocument.page(at: pageIndex) else {
                    return [(PDFAnnotationReference, PDFAnnotationSnapshot)]()
                }
                return service.snapshots(on: page, pageIndex: pageIndex).map {
                    ($0.reference, $0)
                }
            }
        )
        for (reference, color) in colorOverrides
        where serializedAnnotations[reference].map({
            !$0.hasAppearanceStream || $0.kind == .note
        }) == true {
            try annotationSession.setAnnotationColor(
                pageIndex: reference.pageIndex,
                annotationIndex: reference.annotationIndex,
                color: color
            )
        }
        for (reference, expectedColor) in colorOverrides {
            let actual = try annotationSession.annotationColor(
                pageIndex: reference.pageIndex,
                annotationIndex: reference.annotationIndex
            )
            guard abs(actual.red - expectedColor.red) < 0.01,
                  abs(actual.green - expectedColor.green) < 0.01,
                  abs(actual.blue - expectedColor.blue) < 0.01,
                  abs(actual.alpha - expectedColor.alpha) < 0.01 else {
                throw PDFAnnotationServiceError.roundTripVerificationFailed
            }
        }
        let verifiedData = try session.dataRepresentation(options: PDFExportOptions())
        guard let reopened = PDFDocument(data: verifiedData) else {
            throw PDFEditingError.invalidDocument
        }
        for annotation in expected {
            try service.verify(annotation, in: reopened)
        }
        return session
    }

    private func mutate<Result>(
        undoManager: UndoManager?,
        actionName: String,
        refreshesPDFKitDocument: Bool = true,
        _ mutation: () throws -> Result
    ) throws -> Result {
        if hasDigitalSignatures && !allowsInvalidatingDigitalSignatures {
            throw PDFEditingError.digitalSignatureConsentRequired
        }
        let previousData = try currentData()
        let result: Result
        do {
            result = try mutation()
            if refreshesPDFKitDocument {
                try refreshPDFKitDocument(markingUnsaved: true)
            } else {
                editorState.documentDidChange(markingUnsaved: true)
            }
        } catch {
            if let session = try? PDFiumEditingEngine().makeSession(
                data: previousData,
                password: authorizedPassword
            ) {
                editingSession = session
                sourceData = previousData
                try? refreshPDFKitDocument(markingUnsaved: false)
            }
            throw error
        }

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { document in
                document.restore(
                    data: previousData,
                    actionName: actionName,
                    undoManager: undoManager
                )
            }
            undoManager.setActionName(actionName)
        }
        return result
    }

    private func restore(
        data: Data,
        actionName: String,
        undoManager: UndoManager
    ) {
        guard let redoData = try? currentData(),
              let session = try? PDFiumEditingEngine().makeSession(
                  data: data,
                  password: authorizedPassword
              ) else {
            return
        }
        editingSession = session
        sourceData = data
        try? refreshPDFKitDocument(markingUnsaved: true)
        undoManager.registerUndo(withTarget: self) { document in
            document.restore(
                data: redoData,
                actionName: actionName,
                undoManager: undoManager
            )
        }
        undoManager.setActionName(actionName)
    }

    private func currentData() throws -> Data {
        if let editingSession {
            return try editingSession.dataRepresentation(options: PDFExportOptions())
        }
        guard let data = pdfDocument.dataRepresentation() else {
            throw PDFEditingError.exportFailed
        }
        return data
    }

    private func refreshPDFKitDocument(markingUnsaved: Bool) throws {
        let data = try currentData()
        guard let document = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }
        if document.isLocked {
            guard let authorizedPassword,
                  document.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        pdfDocument = document
        editorState.documentDidChange(markingUnsaved: markingUnsaved)
    }

    private static func makeBlankPDF() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
