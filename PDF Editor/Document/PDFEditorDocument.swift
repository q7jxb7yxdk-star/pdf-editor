import Combine
import CoreGraphics
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated private struct PreparedPDFEditingSession: @unchecked Sendable {
    let session: any PDFEditingSession
}

nonisolated private struct PreparedPDFAnnotationSession: @unchecked Sendable {
    let session: any PDFAnnotationEditingSession
}

final class PDFEditorDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    private static let pdfiumAccessLock = NSRecursiveLock()

    final class EditorState: ObservableObject {
        @Published private(set) var revision = 0
        @Published private(set) var hasUnsavedChanges = false
        @Published private(set) var annotationColorUpdate: PDFAnnotationColorUpdateEvent?
        @Published private(set) var annotationBackgroundFailure:
            PDFAnnotationBackgroundFailureEvent?

        private var annotationColorGeneration = 0
        private var annotationFailureGeneration = 0

        fileprivate func documentDidChange(markingUnsaved: Bool) {
            revision &+= 1
            if markingUnsaved {
                hasUnsavedChanges = true
            }
        }

        fileprivate func markSaved() {
            hasUnsavedChanges = false
        }

        fileprivate func annotationColorDidChange(
            reference: PDFAnnotationReference,
            color: PDFAnnotationColor
        ) {
            hasUnsavedChanges = true
            annotationColorGeneration &+= 1
            annotationColorUpdate = PDFAnnotationColorUpdateEvent(
                generation: annotationColorGeneration,
                reference: reference,
                color: color
            )
        }

        fileprivate func annotationBackgroundDidFail(_ error: Error) {
            annotationFailureGeneration &+= 1
            annotationBackgroundFailure = PDFAnnotationBackgroundFailureEvent(
                generation: annotationFailureGeneration,
                message: error.localizedDescription,
                requiresDigitalSignatureConsent:
                    (error as? PDFEditingError) == .digitalSignatureConsentRequired
            )
        }
    }

    static let readableContentTypes: [UTType] = [.pdf]
    static let writableContentTypes: [UTType] = [.pdf]

    let editorState = EditorState()

    private(set) var pdfDocument: PDFDocument
    private(set) var removesPasswordProtectionOnSave = false

    private var editingSession: (any PDFEditingSession)?
    private var interactionPreparationTask: Task<PreparedPDFEditingSession, Error>?
    private var interactionPreparationRevision = 0
    private var interactionPreparationID = 0
    private var commentColorSyncGeneration = 0
    private var pendingCommentColorSyncs: [PDFAnnotationReference: Int] = [:]
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
        pdfDocument.isEncrypted
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
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
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
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
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

    func prepareManualSave(
        applying replacements: [PDFManualTextReplacement]
    ) async throws -> PDFManualSavePreparation {
        if hasDigitalSignatures && !allowsInvalidatingDigitalSignatures &&
            !replacements.isEmpty {
            throw PDFEditingError.digitalSignatureConsentRequired
        }

        let startingRevision = editorState.revision
        let sourceSnapshot = sourceData
        let password = authorizedPassword
        let session = editingSession.map { PreparedPDFEditingSession(session: $0) }
        let fallbackFontData = try unicodeFontData()
        let exportOptions = PDFExportOptions(
            securityPolicy: removesPasswordProtectionOnSave
                ? .removeAfterAuthorizedUnlock
                : .preserve
        )

        let preparation = try await Task.detached(priority: .userInitiated) {
            try Self.pdfiumAccessLock.withLock {
                let originalData: Data
                if let session {
                    originalData = try session.session.dataRepresentation(
                        options: PDFExportOptions()
                    )
                } else {
                    originalData = sourceSnapshot
                }
                return try PDFManualSavePreparationService.prepare(
                    originalData: originalData,
                    password: password,
                    replacements: replacements,
                    fallbackFontData: fallbackFontData,
                    exportOptions: exportOptions
                )
            }
        }.value

        guard editorState.revision == startingRevision else {
            throw PDFEditingError.pageMutationFailed
        }
        return preparation
    }

    func installPreparedManualSave(
        _ preparation: PDFManualSavePreparation,
        markingUnsaved: Bool,
        undoManager: UndoManager?
    ) throws {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        let preparedSession = try PDFiumEditingEngine().makeSession(
            data: preparation.data,
            password: removesPasswordProtectionOnSave ? nil : authorizedPassword
        )
        guard let preparedDocument = PDFDocument(data: preparation.data) else {
            throw PDFEditingError.invalidDocument
        }
        if preparedDocument.isLocked {
            guard let authorizedPassword,
                  preparedDocument.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        editingSession = preparedSession
        sourceData = preparation.data
        synchronizePresentationPages(with: preparedDocument)
        publishDocumentChangeAfterViewUpdate(markingUnsaved: markingUnsaved)

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { document in
                document.restore(
                    data: preparation.originalData,
                    actionName: "Replace PDF Text",
                    undoManager: undoManager
                )
            }
            undoManager.setActionName("Replace PDF Text")
        }
    }

    func markManuallySaved(
        data: Data,
        updatesFileDocumentSnapshot: Bool
    ) {
        if updatesFileDocumentSnapshot {
            persistedData = data
        }
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
            Self.pdfiumAccessLock.lock()
            defer { Self.pdfiumAccessLock.unlock() }
            let editingSession = try prepareEditingSessionIfNeeded()
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
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        guard let objectSession = try prepareEditingSessionIfNeeded()
            as? any PDFObjectEditingSession else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        return try objectSession.objects(onPage: pageIndex)
    }

    /// Inspects an immutable document snapshot on a private PDFium handle so page
    /// rendering and scrolling never wait for object enumeration on the main thread.
    func pageObjectsForDisplay(at pageIndex: Int) async throws -> [PDFPageObjectSnapshot] {
        let data = sourceData
        let password = authorizedPassword
        let inspectionTask = Task.detached(priority: .userInitiated) {
            try Self.inspectPageObjects(
                data: data,
                password: password,
                pageIndex: pageIndex
            )
        }
        return try await withTaskCancellationHandler(operation: {
            try await inspectionTask.value
        }, onCancel: {
            inspectionTask.cancel()
        })
    }

    /// Opens the immutable source snapshot away from the main actor so the first
    /// interactive annotation edit does not pay PDFium's document-open cost.
    func prepareEditingSessionForInteraction() async {
        guard editingSession == nil, !pdfDocument.isLocked else { return }
        _ = try? await preparedEditingSessionForInteraction()
    }

    private func preparedEditingSessionForInteraction() async throws
        -> any PDFEditingSession {
        if let editingSession { return editingSession }

        let preparationTask: Task<PreparedPDFEditingSession, Error>
        let preparationRevision: Int
        let preparationID: Int
        if let existing = interactionPreparationTask {
            preparationTask = existing
            preparationRevision = interactionPreparationRevision
            preparationID = interactionPreparationID
        } else {
            let data = sourceData
            let password = authorizedPassword
            preparationRevision = editorState.revision
            interactionPreparationRevision = preparationRevision
            interactionPreparationID &+= 1
            preparationID = interactionPreparationID
            preparationTask = Task.detached(priority: .userInitiated) {
                try Self.prepareEditingSession(data: data, password: password)
            }
            interactionPreparationTask = preparationTask
        }

        do {
            let prepared = try await preparationTask.value
            if interactionPreparationID == preparationID {
                interactionPreparationTask = nil
            }
            if let editingSession { return editingSession }
            guard editorState.revision == preparationRevision else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            editingSession = prepared.session
            return prepared.session
        } catch {
            if interactionPreparationID == preparationID {
                interactionPreparationTask = nil
            }
            throw error
        }
    }

    nonisolated private static func prepareEditingSession(
        data: Data,
        password: String?
    ) throws -> PreparedPDFEditingSession {
        pdfiumAccessLock.lock()
        defer { pdfiumAccessLock.unlock() }
        return PreparedPDFEditingSession(
            session: try PDFiumEditingEngine().makeSession(
                data: data,
                password: password
            )
        )
    }

    nonisolated private static func inspectPageObjects(
        data: Data,
        password: String?,
        pageIndex: Int
    ) throws -> [PDFPageObjectSnapshot] {
        try acquirePDFiumAccessLockForDisplay()
        defer { pdfiumAccessLock.unlock() }
        try Task.checkCancellation()
        let session = try PDFiumEditingEngine().makeSession(
            data: data,
            password: password
        )
        guard let objectSession = session as? any PDFObjectEditingSession else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        let objects = try objectSession.displayObjects(onPage: pageIndex)
        try Task.checkCancellation()
        return objects
    }

    /// Waits for the shared PDFium runtime without pinning cancelled display work
    /// behind an older page scan. This synchronous helper is called only from the
    /// detached inspector, so acquisition and release stay on the same thread.
    nonisolated private static func acquirePDFiumAccessLockForDisplay() throws {
        while !pdfiumAccessLock.try() {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.001)
        }
        if Task.isCancelled {
            pdfiumAccessLock.unlock()
            throw CancellationError()
        }
    }

    func replaceText(
        pageIndex: Int,
        path: PDFPageObjectPath,
        with text: String,
        style: PDFTextStyle,
        undoManager: UndoManager?
    ) throws -> PDFTextReplacementResult {
        let pageObjects = try pageObjects(at: pageIndex)
        guard pageObjects.contains(where: { $0.path == path }) else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        if PDFPageResourceIntegrityService.preventsSafePageContentRegeneration(
            data: sourceData,
            pageIndex: pageIndex
        ) {
            throw PDFObjectEditingError.pageAppearanceWouldChange
        }
        return try mutate(undoManager: undoManager, actionName: "Replace PDF Text") {
            guard let objectSession = editingSession as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            return try objectSession.replaceText(
                pageIndex: pageIndex,
                path: path,
                with: text,
                style: style,
                fallbackFontData: try unicodeFontData()
            )
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
        guard let annotationSession = editingSession as? any PDFAnnotationEditingSession,
              Self.pdfiumAccessLock.try() else {
            return snapshots
        }
        defer { Self.pdfiumAccessLock.unlock() }
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
        return snapshots
    }

    @discardableResult
    func updateAnnotation(
        _ reference: PDFAnnotationReference,
        with update: PDFAnnotationUpdate,
        undoManager: UndoManager?
    ) throws -> PDFAnnotationSnapshot {
        let service = PDFAnnotationService()
        let current = try annotationSnapshot(reference)
        let effectiveUpdate = update.changes(from: current)
        guard !effectiveUpdate.isEmpty else { return current }

        // A note color change is supported directly by both live document models.
        // Keep it in memory so Apply does not serialize and reopen the entire PDF.
        if current.kind == .note,
           let color = effectiveUpdate.color,
           effectiveUpdate.bounds == nil,
           effectiveUpdate.contents == nil,
           effectiveUpdate.fontColor == nil,
           effectiveUpdate.fontSize == nil,
           effectiveUpdate.lineWidth == nil {
            if editingSession == nil {
                return try stageCommentColorWhilePreparingSession(
                    reference,
                    current: current,
                    color: color,
                    undoManager: undoManager
                )
            }
            return try updateCommentColor(
                reference,
                current: current,
                color: color,
                undoManager: undoManager
            )
        }

        let updated = try mutate(
            undoManager: undoManager,
            actionName: "修改註解",
            refreshesPDFKitDocument: false
        ) {
            let updated = try service.update(
                reference,
                with: effectiveUpdate,
                in: pdfDocument
            )
            guard let data = pdfDocument.dataRepresentation(),
                  PDFDocument(data: data) != nil else {
                throw PDFEditingError.exportFailed
            }
            editingSession = try makeVerifiedAnnotationSession(
                data: data,
                expected: [updated],
                colorOverrides: effectiveUpdate.color.map { [reference: $0] } ?? [:]
            )
            return updated
        }
        return updated
    }

    private func stageCommentColorWhilePreparingSession(
        _ reference: PDFAnnotationReference,
        current: PDFAnnotationSnapshot,
        color: PDFAnnotationColor,
        undoManager: UndoManager?
    ) throws -> PDFAnnotationSnapshot {
        var updated = try PDFAnnotationService().update(
            reference,
            with: PDFAnnotationUpdate(color: color),
            in: pdfDocument
        )
        updated.color = color
        editorState.annotationColorDidChange(reference: reference, color: color)

        commentColorSyncGeneration &+= 1
        let generation = commentColorSyncGeneration
        pendingCommentColorSyncs[reference] = generation
        Task { @MainActor [weak self] in
            await self?.finishStagedCommentColor(
                reference,
                current: current,
                color: color,
                generation: generation
            )
        }

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { document in
                _ = try? document.updateAnnotation(
                    reference,
                    with: PDFAnnotationUpdate(color: current.color),
                    undoManager: undoManager
                )
            }
            undoManager.setActionName("修改註解")
        }
        return updated
    }

    @MainActor
    private func finishStagedCommentColor(
        _ reference: PDFAnnotationReference,
        current: PDFAnnotationSnapshot,
        color: PDFAnnotationColor,
        generation: Int
    ) async {
        var annotationSessionForRollback: PreparedPDFAnnotationSession?
        do {
            let session = try await preparedEditingSessionForInteraction()
            guard pendingCommentColorSyncs[reference] == generation else { return }
            if (session as? any PDFObjectEditingSession)?.hasDigitalSignatures == true,
               !allowsInvalidatingDigitalSignatures {
                throw PDFEditingError.digitalSignatureConsentRequired
            }
            guard let annotationSession = session as? any PDFAnnotationEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let preparedAnnotationSession = PreparedPDFAnnotationSession(
                session: annotationSession
            )
            annotationSessionForRollback = preparedAnnotationSession
            let actual = try Self.synchronizeCommentColor(
                session: preparedAnnotationSession,
                reference: reference,
                color: color
            )
            guard abs(actual.red - color.red) < 0.01,
                  abs(actual.green - color.green) < 0.01,
                  abs(actual.blue - color.blue) < 0.01,
                  abs(actual.alpha - color.alpha) < 0.01 else {
                throw PDFAnnotationServiceError.roundTripVerificationFailed
            }
            guard pendingCommentColorSyncs[reference] == generation else { return }
            pendingCommentColorSyncs[reference] = nil
            if actual != color {
                editorState.annotationColorDidChange(reference: reference, color: actual)
            }
        } catch {
            guard pendingCommentColorSyncs[reference] == generation else { return }
            pendingCommentColorSyncs[reference] = nil
            if let annotationSessionForRollback {
                Self.rollbackCommentColor(
                    session: annotationSessionForRollback,
                    reference: reference,
                    color: current.color
                )
            }
            _ = try? PDFAnnotationService().update(
                reference,
                with: PDFAnnotationUpdate(color: current.color),
                in: pdfDocument
            )
            editorState.annotationColorDidChange(
                reference: reference,
                color: current.color
            )
            editorState.annotationBackgroundDidFail(error)
        }
    }

    nonisolated private static func synchronizeCommentColor(
        session: PreparedPDFAnnotationSession,
        reference: PDFAnnotationReference,
        color: PDFAnnotationColor
    ) throws -> PDFAnnotationColor {
        pdfiumAccessLock.lock()
        defer { pdfiumAccessLock.unlock() }
        try session.session.setAnnotationColor(
            pageIndex: reference.pageIndex,
            annotationIndex: reference.annotationIndex,
            color: color
        )
        return try session.session.annotationColor(
            pageIndex: reference.pageIndex,
            annotationIndex: reference.annotationIndex
        )
    }

    nonisolated private static func rollbackCommentColor(
        session: PreparedPDFAnnotationSession,
        reference: PDFAnnotationReference,
        color: PDFAnnotationColor
    ) {
        pdfiumAccessLock.lock()
        defer { pdfiumAccessLock.unlock() }
        try? session.session.setAnnotationColor(
            pageIndex: reference.pageIndex,
            annotationIndex: reference.annotationIndex,
            color: color
        )
    }

    private func updateCommentColor(
        _ reference: PDFAnnotationReference,
        current: PDFAnnotationSnapshot,
        color: PDFAnnotationColor,
        undoManager: UndoManager?
    ) throws -> PDFAnnotationSnapshot {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }

        let session = try prepareEditingSessionIfNeeded()
        if hasDigitalSignatures && !allowsInvalidatingDigitalSignatures {
            throw PDFEditingError.digitalSignatureConsentRequired
        }
        guard let annotationSession = session as? any PDFAnnotationEditingSession else {
            throw PDFObjectEditingError.objectMutationFailed
        }

        let service = PDFAnnotationService()
        var changedPDFium = false
        var changedPDFKit = false
        do {
            try annotationSession.setAnnotationColor(
                pageIndex: reference.pageIndex,
                annotationIndex: reference.annotationIndex,
                color: color
            )
            changedPDFium = true
            var updated = try service.update(
                reference,
                with: PDFAnnotationUpdate(color: color),
                in: pdfDocument
            )
            changedPDFKit = true

            let actual = try annotationSession.annotationColor(
                pageIndex: reference.pageIndex,
                annotationIndex: reference.annotationIndex
            )
            guard abs(actual.red - color.red) < 0.01,
                  abs(actual.green - color.green) < 0.01,
                  abs(actual.blue - color.blue) < 0.01,
                  abs(actual.alpha - color.alpha) < 0.01 else {
                throw PDFAnnotationServiceError.roundTripVerificationFailed
            }
            updated.color = actual
            editorState.annotationColorDidChange(reference: reference, color: actual)

            if let undoManager {
                undoManager.registerUndo(withTarget: self) { document in
                    _ = try? document.updateAnnotation(
                        reference,
                        with: PDFAnnotationUpdate(color: current.color),
                        undoManager: undoManager
                    )
                }
                undoManager.setActionName("修改註解")
            }
            return updated
        } catch {
            if changedPDFKit {
                _ = try? service.update(
                    reference,
                    with: PDFAnnotationUpdate(color: current.color),
                    in: pdfDocument
                )
            }
            if changedPDFium {
                try? annotationSession.setAnnotationColor(
                    pageIndex: reference.pageIndex,
                    annotationIndex: reference.annotationIndex,
                    color: current.color
                )
            }
            throw error
        }
    }

    private func annotationSnapshot(
        _ reference: PDFAnnotationReference
    ) throws -> PDFAnnotationSnapshot {
        var snapshot = try PDFAnnotationService().snapshot(
            for: reference,
            in: pdfDocument
        )
        guard let annotationSession = editingSession as? any PDFAnnotationEditingSession,
              Self.pdfiumAccessLock.try() else {
            return snapshot
        }
        defer { Self.pdfiumAccessLock.unlock() }
        if let color = try? annotationSession.annotationColor(
            pageIndex: reference.pageIndex,
            annotationIndex: reference.annotationIndex
        ) {
            snapshot.color = color
            if snapshot.fontColor != nil {
                snapshot.fontColor?.alpha = color.alpha
            }
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
        let relevantReferences = Set(expected.map(\.reference))
            .union(colorOverrides.keys)
        let referencesByPage = Dictionary(
            grouping: relevantReferences,
            by: \.pageIndex
        )
        var serializedAnnotations: [PDFAnnotationReference: PDFAnnotationSnapshot] = [:]
        for (pageIndex, references) in referencesByPage {
            guard let page = serializedDocument.page(at: pageIndex) else { continue }
            let references = Set(references)
            for snapshot in service.snapshots(on: page, pageIndex: pageIndex)
            where references.contains(snapshot.reference) {
                serializedAnnotations[snapshot.reference] = snapshot
            }
        }
        for (reference, color) in colorOverrides
        where serializedAnnotations[reference].map({
            !$0.hasAppearanceStream || $0.kind == .note || $0.kind == .highlight
        }) == true {
            try annotationSession.setAnnotationColor(
                pageIndex: reference.pageIndex,
                annotationIndex: reference.annotationIndex,
                color: color
            )
        }
        for (reference, expectedColor) in colorOverrides {
            let actual: PDFAnnotationColor
            if let serialized = serializedAnnotations[reference],
               serialized.kind == .ink,
               serialized.hasAppearanceStream {
                // PDFium's annotation color API intentionally fails when an
                // appearance stream is present. Ink keeps its PDFKit-generated
                // appearance, so verify the serialized annotation dictionary.
                actual = serialized.color
            } else {
                actual = try annotationSession.annotationColor(
                    pageIndex: reference.pageIndex,
                    annotationIndex: reference.annotationIndex
                )
            }
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
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        _ = try prepareEditingSessionIfNeeded()
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
                publishDocumentChangeAfterViewUpdate(markingUnsaved: true)
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
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
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

    @discardableResult
    private func prepareEditingSessionIfNeeded() throws -> any PDFEditingSession {
        if let editingSession {
            return editingSession
        }
        guard !pdfDocument.isLocked else {
            throw PDFEditingError.documentLocked
        }
        let session = try PDFiumEditingEngine().makeSession(
            data: sourceData,
            password: authorizedPassword
        )
        editingSession = session
        return session
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
        if pdfDocument.isLocked {
            pdfDocument = document
        } else {
            synchronizePresentationPages(with: document)
        }
        sourceData = data
        publishDocumentChangeAfterViewUpdate(markingUnsaved: markingUnsaved)
    }

    private func publishDocumentChangeAfterViewUpdate(markingUnsaved: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.editorState.documentDidChange(markingUnsaved: markingUnsaved)
        }
    }

    private func synchronizePresentationPages(with document: PDFDocument) {
        let replacementPages = (0..<document.pageCount).compactMap {
            document.page(at: $0)
        }

        for (index, page) in replacementPages.enumerated() {
            if index < pdfDocument.pageCount {
                pdfDocument.insert(page, at: index)
                pdfDocument.removePage(at: index + 1)
            } else {
                pdfDocument.insert(page, at: index)
            }
        }

        while pdfDocument.pageCount > replacementPages.count {
            pdfDocument.removePage(at: pdfDocument.pageCount - 1)
        }

        pdfDocument.documentAttributes = document.documentAttributes
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
