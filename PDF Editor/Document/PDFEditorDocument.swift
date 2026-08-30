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

    // Use the session layer's lock as well as its transaction boundary. A
    // separate document lock would not protect UI queries or session deinit.
    private static let pdfiumAccessLock = PDFiumAccess.lock

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
    private(set) var pendingPasswordProtection: String?

    private var editingSession: (any PDFEditingSession)?
    private var interactionPreparationTask: Task<PreparedPDFEditingSession, Error>?
    private var interactionPreparationRevision = 0
    private var interactionPreparationID = 0
    private var commentColorSyncGeneration = 0
    private var pendingCommentColorSyncs: [PDFAnnotationReference: Int] = [:]
    private var sourceData: Data
    private var persistedData: Data
    private var authorizedPassword: String?
    private var presentationPassword: String?
    private var allowsInvalidatingDigitalSignatures = false

    private let bookmarkService = PDFBookmarkService()
    private let incrementalBookmarkWriter = PDFIncrementalBookmarkWriter()

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
        if (editingSession as? any PDFObjectEditingSession)?.hasDigitalSignatures == true {
            return true
        }
        // A signature widget may be an empty form field. /ByteRange identifies
        // an applied signature without blocking otherwise unsigned forms.
        return sourceData.range(of: Data("/ByteRange".utf8)) != nil
    }

    var requiresDigitalSignatureConsent: Bool {
        hasDigitalSignatures && !allowsInvalidatingDigitalSignatures
    }

    func bookmarkSnapshots() -> [PDFBookmarkSnapshot] {
        bookmarkService.snapshots(in: pdfDocument)
    }

    func addBookmark(
        title: String,
        pageIndex: Int,
        undoManager: UndoManager?
    ) throws {
        try mutateBookmarks(undoManager: undoManager, actionName: "Add Bookmark") {
            try bookmarkService.addBookmark(
                title: title,
                pageIndex: pageIndex,
                to: $0
            )
        }
    }

    func renameBookmark(
        at path: PDFBookmarkPath,
        title: String,
        undoManager: UndoManager?
    ) throws {
        try mutateBookmarks(undoManager: undoManager, actionName: "Rename Bookmark") {
            try bookmarkService.renameBookmark(at: path, title: title, in: $0)
        }
    }

    func deleteBookmark(
        at path: PDFBookmarkPath,
        undoManager: UndoManager?
    ) throws {
        try mutateBookmarks(undoManager: undoManager, actionName: "Delete Bookmark") {
            try bookmarkService.deleteBookmark(at: path, in: $0)
        }
    }

    func authorizeDigitalSignatureInvalidation() {
        allowsInvalidatingDigitalSignatures = true
    }

    init() {
        let data = Self.makeBlankPDF()
        sourceData = data
        persistedData = data
        authorizedPassword = nil
        presentationPassword = nil
        pdfDocument = PDFDocument(data: data) ?? PDFDocument()
    }

    init(data: Data) throws {
        guard let document = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        sourceData = data
        persistedData = data
        authorizedPassword = nil
        presentationPassword = nil
        pdfDocument = document
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let document = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        sourceData = data
        persistedData = data
        authorizedPassword = nil
        presentationPassword = nil
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
        presentationPassword = password
        try refreshPDFKitDocument(markingUnsaved: false)
    }

    func setRemovesPasswordProtectionOnSave(_ removesProtection: Bool) {
        guard removesPasswordProtectionOnSave != removesProtection ||
                (removesProtection && pendingPasswordProtection != nil) else { return }
        removesPasswordProtectionOnSave = removesProtection
        if removesProtection {
            pendingPasswordProtection = nil
        }
        editorState.documentDidChange(markingUnsaved: true)
    }

    func setPasswordProtectionOnSave(_ password: String) {
        guard !password.isEmpty,
              pendingPasswordProtection != password ||
                removesPasswordProtectionOnSave else { return }
        pendingPasswordProtection = password
        removesPasswordProtectionOnSave = false
        editorState.documentDidChange(markingUnsaved: true)
    }

    func dataForManualSave() throws -> Data {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        if let editingSession {
            let data = try editingSession.dataRepresentation(
                options: PDFExportOptions(
                    securityPolicy: removesPasswordProtectionOnSave
                        ? .removeAfterAuthorizedUnlock
                        : .preserve
                )
            )
            if let pendingPasswordProtection {
                return try PDFPasswordProtectionService.protect(
                    data: data,
                    sourcePassword: authorizedPassword,
                    newPassword: pendingPasswordProtection
                )
            }
            return data
        }

        guard let data = pdfDocument.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let pendingPasswordProtection {
            return try PDFPasswordProtectionService.protect(
                data: data,
                sourcePassword: authorizedPassword,
                newPassword: pendingPasswordProtection
            )
        }
        return data
    }

    func prepareManualSave(
        applying replacements: [PDFManualTextReplacement]
    ) async throws -> PDFManualSavePreparation {
        if requiresDigitalSignatureConsent &&
            (!replacements.isEmpty || pendingPasswordProtection != nil ||
                removesPasswordProtectionOnSave) {
            throw PDFEditingError.digitalSignatureConsentRequired
        }

        let startingRevision = editorState.revision
        let sourceSnapshot = sourceData
        let password = authorizedPassword
        let protectionPassword = pendingPasswordProtection
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
                    exportOptions: exportOptions,
                    protectionPassword: protectionPassword
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
            password: preparation.openingPassword
        )
        guard let preparedDocument = PDFDocument(data: preparation.data) else {
            throw PDFEditingError.invalidDocument
        }
        if preparedDocument.isLocked {
            guard let openingPassword = preparation.openingPassword,
                  preparedDocument.unlock(withPassword: openingPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        editingSession = preparedSession
        authorizedPassword = preparation.openingPassword
        pendingPasswordProtection = nil
        removesPasswordProtectionOnSave = false
        sourceData = preparation.data
        if !preparation.isSecurityOnlyPresentationUpdate {
            synchronizePresentationPages(with: preparedDocument)
        }
        publishDocumentChangeAfterViewUpdate(markingUnsaved: markingUnsaved)

        if !preparation.replacementResults.isEmpty, let undoManager {
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

    func stageManualSaveSnapshot(_ data: Data) -> Data {
        let previousData = persistedData
        persistedData = data
        return previousData
    }

    func restoreManualSaveSnapshot(_ data: Data) {
        persistedData = data
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
            guard interactionPreparationID == preparationID else {
                throw PDFObjectEditingError.objectMutationFailed
            }
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
            guard let presentationData = pdfDocument.dataRepresentation() else {
                throw PDFEditingError.exportFailed
            }
            let data = try normalizePresentationSecurity(presentationData)
            editingSession = try makeVerifiedAnnotationSession(
                data: data,
                expected: allAnnotationSnapshots()
            )
        }
    }

    func synchronizeAcroFormChangesIfNeeded(undoManager: UndoManager?) throws {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }

        let service = PDFAcroFormService()
        guard service.hasAcroFormFields(in: pdfDocument) else { return }
        let currentFields = service.snapshots(in: pdfDocument)
        let previousData: Data
        if let editingSession {
            previousData = try editingSession.dataRepresentation(
                options: PDFExportOptions()
            )
        } else {
            // PDFKit may support an interactive form even when PDFium rejects
            // the source PDF. Compare against the last accepted bytes instead
            // of forcing PDFium preparation or serializing the edited view.
            previousData = sourceData
        }
        guard let previousDocument = PDFDocument(data: previousData) else {
            throw PDFAcroFormError.serializationFailed
        }
        if previousDocument.isLocked {
            guard let authorizedPassword,
                  previousDocument.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        guard service.hasValueChanges(
            from: service.snapshots(in: previousDocument),
            to: currentFields
        ) else { return }

        if hasDigitalSignatures && !allowsInvalidatingDigitalSignatures {
            throw PDFEditingError.digitalSignatureConsentRequired
        }
        guard let presentationData = pdfDocument.dataRepresentation() else {
            throw PDFAcroFormError.serializationFailed
        }
        let normalizedData = try normalizePresentationSecurity(presentationData)
        try service.verify(
            currentFields,
            in: normalizedData,
            password: authorizedPassword
        )
        guard let verifiedDocument = PDFDocument(data: normalizedData) else {
            throw PDFAcroFormError.serializationFailed
        }
        if verifiedDocument.isLocked {
            guard let authorizedPassword,
                  verifiedDocument.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        let expectedEncryption = previousDocument.isEncrypted
        guard verifiedDocument.pageCount == previousDocument.pageCount,
              verifiedDocument.isEncrypted == expectedEncryption,
              bookmarkRoundTripPreservesPages(
                  from: previousData,
                  workingDocument: previousDocument,
                  to: normalizedData,
                  verifiedDocument: verifiedDocument,
                  checksPageResources: !expectedEncryption
              ) else {
            throw PDFAcroFormError.serializationFailed
        }

        let verifiedSession = acroFormSessionIfRoundTripSafe(
            data: normalizedData,
            expectedFields: currentFields,
            sourceDocument: verifiedDocument
        )
        invalidateInteractionPreparation()
        editingSession = verifiedSession
        sourceData = normalizedData
        // The displayed PDFDocument already contains the committed field
        // value. Replacing its identity here makes PDFView reload and resets
        // the user's scroll position after every form edit.
        publishDocumentChangeAfterViewUpdate(markingUnsaved: true)

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { document in
                document.restorePDFKitCompatibleMutation(
                    data: previousData,
                    actionName: "填寫 PDF 表單",
                    undoManager: undoManager
                )
            }
            undoManager.setActionName("填寫 PDF 表單")
        }
    }

    private func acroFormSessionIfRoundTripSafe(
        data: Data,
        expectedFields: [PDFAcroFormFieldSnapshot],
        sourceDocument: PDFDocument
    ) -> (any PDFEditingSession)? {
        let service = PDFAcroFormService()
        guard let session = try? PDFiumEditingEngine().makeSession(
            data: data,
            password: authorizedPassword
        ),
        let exportedData = try? session.dataRepresentation(
            options: PDFExportOptions()
        ),
        let exportedDocument = PDFDocument(data: exportedData) else {
            return nil
        }
        if exportedDocument.isLocked {
            guard let authorizedPassword,
                  exportedDocument.unlock(withPassword: authorizedPassword) else {
                return nil
            }
        }
        guard (try? service.verify(
            expectedFields,
            in: exportedData,
            password: authorizedPassword
        )) != nil,
        bookmarkRoundTripPreservesPages(
            from: data,
            workingDocument: sourceDocument,
            to: exportedData,
            verifiedDocument: exportedDocument,
            checksPageResources: !sourceDocument.isEncrypted
        ) else {
            return nil
        }
        return session
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
            guard let presentationData = pdfDocument.dataRepresentation(),
                  PDFDocument(data: presentationData) != nil else {
                throw PDFEditingError.exportFailed
            }
            let data = try normalizePresentationSecurity(presentationData)
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
        if serializedDocument.isLocked {
            guard let authorizedPassword,
                  serializedDocument.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
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
        if reopened.isLocked {
            guard let authorizedPassword,
                  reopened.unlock(withPassword: authorizedPassword) else {
                throw PDFEditingError.invalidPassword
            }
        }
        for annotation in expected {
            try service.verify(annotation, in: reopened)
        }
        return session
    }

    private func normalizePresentationSecurity(_ data: Data) throws -> Data {
        guard let presentationDocument = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }
        let presentationIsEncrypted = presentationDocument.isEncrypted
        let activeIsEncrypted = editingSession?.metadata.isEncrypted ??
            pdfDocument.isEncrypted

        if activeIsEncrypted {
            guard let authorizedPassword else {
                throw PDFEditingError.invalidPassword
            }
            if presentationIsEncrypted,
               presentationPassword == authorizedPassword {
                return data
            }
            return try PDFPasswordProtectionService.protect(
                data: data,
                sourcePassword: presentationIsEncrypted
                    ? presentationPassword
                    : nil,
                newPassword: authorizedPassword
            )
        }

        guard presentationIsEncrypted else { return data }
        let session = try PDFiumEditingEngine().makeSession(
            data: data,
            password: presentationPassword
        )
        return try session.dataRepresentation(
            options: PDFExportOptions(
                securityPolicy: .removeAfterAuthorizedUnlock
            )
        )
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

    private func mutateBookmarks(
        undoManager: UndoManager?,
        actionName: String,
        _ mutation: (PDFDocument) throws -> Void
    ) throws {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        let activeSession = editingSession ?? (try? prepareEditingSessionIfNeeded())
        if hasDigitalSignatures && !allowsInvalidatingDigitalSignatures {
            throw PDFEditingError.digitalSignatureConsentRequired
        }

        let previousData: Data
        if let activeSession {
            do {
                previousData = try activeSession.dataRepresentation(
                    options: PDFExportOptions()
                )
            } catch PDFEditingError.invalidDocument {
                throw PDFBookmarkMutationError.sourcePDFiumExportFailed
            } catch PDFEditingError.exportFailed {
                throw PDFBookmarkMutationError.sourcePDFiumExportFailed
            }
        } else {
            // Bookmark updates are incremental and do not require PDFium to
            // rewrite page content. Preserve the exact bytes accepted by
            // PDFKit when PDFium cannot open an otherwise readable PDF.
            previousData = sourceData
        }
        guard let workingDocument = PDFDocument(data: previousData) else {
            throw PDFBookmarkMutationError.sourcePDFKitOpenFailed
        }
        let expectedPageCount = workingDocument.pageCount
        let expectedEncryption = workingDocument.isEncrypted
        guard !expectedEncryption else {
            throw PDFIncrementalBookmarkWriterError.encryptedDocumentUnsupported
        }
        try unlockForBookmarkEditing(workingDocument)
        try mutation(workingDocument)
        let expectedBookmarks = bookmarkService.snapshots(in: workingDocument)
        let formService = PDFAcroFormService()
        let expectedFields = formService.snapshots(in: workingDocument)
        let annotationService = PDFAnnotationService()
        let expectedAnnotations = (0..<expectedPageCount).flatMap { pageIndex in
            workingDocument.page(at: pageIndex).map {
                annotationService.snapshots(on: $0, pageIndex: pageIndex)
            } ?? []
        }
        var serializedData = try incrementalBookmarkWriter.write(
            sourceData: previousData,
            bookmarks: expectedBookmarks
        )
        var candidateStage = PDFBookmarkDataStage.incremental
        func diagnostics(
            for data: Data?,
            stage: PDFBookmarkDataStage
        ) -> PDFBookmarkDataDiagnostics {
            PDFBookmarkDataDiagnostics(
                stage: stage,
                sourceByteCount: previousData.count,
                candidateByteCount: data?.count,
                expectedFieldCount: expectedFields.count
            )
        }

        let verifiedSession: (any PDFEditingSession)?
        do {
            verifiedSession = try PDFiumEditingEngine().makeSession(
                data: serializedData,
                password: authorizedPassword
            )
        } catch PDFEditingError.invalidDocument {
            if activeSession == nil {
                verifiedSession = nil
            } else {
                let code = PDFiumEditingEngine().openErrorCode(
                    data: serializedData,
                    password: authorizedPassword
                )
                // Only retry a format rejection. Never relax verification for
                // passwords, security handlers or other PDFium failures.
                guard code == 3 else {
                    throw PDFBookmarkMutationError.updatedPDFiumOpenFailed(
                        code: code,
                        diagnostics: diagnostics(for: serializedData, stage: .incremental)
                    )
                }
                guard let rewrittenData = workingDocument.dataRepresentation() else {
                    throw PDFBookmarkMutationError.fallbackRewriteFailed(
                        diagnostics: diagnostics(for: nil, stage: .rewrite)
                    )
                }
                do {
                    verifiedSession = try PDFiumEditingEngine().makeSession(
                        data: rewrittenData,
                        password: authorizedPassword
                    )
                } catch {
                    // Report the fallback's stage and error, not the rejected
                    // incremental candidate's error code.
                    let failure = PDFBookmarkMutationError.updatedPDFiumOpenFailed(
                        code: PDFiumEditingEngine().openErrorCode(
                            data: rewrittenData,
                            password: authorizedPassword
                        ),
                        diagnostics: diagnostics(for: rewrittenData, stage: .rewrite)
                    )
#if DEBUG
                    throw bookmarkFailureWithDebugSnapshots(
                        failure,
                        source: previousData,
                        incremental: serializedData,
                        rewritten: rewrittenData
                    )
#else
                    throw failure
#endif
                }
                serializedData = rewrittenData
                candidateStage = .rewrite
            }
        } catch PDFEditingError.invalidPassword {
            if activeSession == nil {
                verifiedSession = nil
            } else {
                let code = PDFiumEditingEngine().openErrorCode(
                    data: serializedData,
                    password: authorizedPassword
                )
                throw PDFBookmarkMutationError.updatedPDFiumOpenFailed(
                    code: code,
                    diagnostics: diagnostics(for: serializedData, stage: .incremental)
                )
            }
        }
        if let verifiedMetadata = verifiedSession?.metadata {
            guard verifiedMetadata.pageCount == expectedPageCount,
                  verifiedMetadata.isEncrypted == expectedEncryption else {
                throw PDFBookmarkServiceError.roundTripVerificationFailed
            }
        }
        func verifyCandidate(_ data: Data, stage: PDFBookmarkDataStage) throws -> PDFDocument {
            guard let candidate = PDFDocument(data: data) else {
                throw PDFBookmarkMutationError.updatedPDFKitOpenFailed(
                    diagnostics: diagnostics(for: data, stage: stage)
                )
            }
            try unlockForBookmarkEditing(candidate)
            guard candidate.isEncrypted == expectedEncryption,
                  bookmarkService.snapshots(in: candidate) == expectedBookmarks,
                  candidate.pageCount == expectedPageCount,
                  formService.snapshots(in: candidate).count == expectedFields.count,
                  bookmarkRoundTripPreservesPages(
                      from: previousData,
                      workingDocument: workingDocument,
                      to: data,
                      verifiedDocument: candidate,
                      checksPageResources: !expectedEncryption
                  ) else {
                throw PDFBookmarkServiceError.roundTripVerificationFailed
            }
            try formService.verify(expectedFields, in: data, password: authorizedPassword)
            for annotation in expectedAnnotations {
                try annotationService.verify(annotation, in: candidate)
            }
            return candidate
        }
        let verifiedData = serializedData
        let verifiedDocument = try verifyCandidate(verifiedData, stage: candidateStage)
        if let verifiedSession {
            // Save later serializes this session; reopening alone does not
            // prove that export preserves the outline or interactive fields.
            let exportStage: PDFBookmarkDataStage = candidateStage == .rewrite
                ? .exportAfterRewrite : .exportAfterIncremental
            let exportedData: Data
            do {
                exportedData = try verifiedSession.dataRepresentation(options: PDFExportOptions())
            } catch PDFEditingError.exportFailed {
                throw PDFBookmarkMutationError.updatedPDFiumExportFailed(
                    diagnostics: diagnostics(for: nil, stage: exportStage)
                )
            }
            _ = try verifyCandidate(exportedData, stage: exportStage)
        }

        // Bookmark-only changes must not replace PDFView's document or pages:
        // doing so tears down its rendered content and causes a black flash.
        // Rebind verified destinations to the existing presentation pages.
        try bookmarkService.synchronizeOutline(from: verifiedDocument, to: pdfDocument)
        invalidateInteractionPreparation()
        editingSession = verifiedSession
        sourceData = verifiedData
        publishDocumentChangeAfterViewUpdate(markingUnsaved: true)

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { document in
                document.restorePDFKitCompatibleMutation(
                    data: previousData,
                    actionName: actionName,
                    undoManager: undoManager,
                    bookmarksOnly: true
                )
            }
            undoManager.setActionName(actionName)
        }
    }

#if DEBUG
    /// User-approved, local-only capture of the exact rejected bytes. Do not
    /// reserialize them: the source is already a PDFium export in this path.
    /// These PDFs contain document contents and filled form values.
    private func bookmarkFailureWithDebugSnapshots(
        _ failure: PDFBookmarkMutationError,
        source: Data,
        incremental: Data,
        rewritten: Data
    ) -> Error {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "PDFEditor-BookmarkFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        let snapshots: [(String, Data)] = [
            ("01-source-pdfium-export.pdf", source),
            ("02-incremental-bookmarks.pdf", incremental),
            ("03-pdfkit-fallback-rewrite.pdf", rewritten),
        ]
        var directoryCreated = false
        var savedCount = 0
        let captureDescription: String
        do {
            // Each failure owns a new private directory; never touch the
            // original PDF, earlier captures, or a shared fixed filename.
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directoryCreated = true
            for (filename, data) in snapshots {
                let url = directory.appendingPathComponent(filename)
                try data.write(to: url, options: .withoutOverwriting)
                savedCount += 1
            }
            captureDescription = "Debug PDF snapshots saved (3/3): \(directory.path)"
        } catch {
            // Capture is diagnostic only. Preserve the original bookmark
            // failure even if storage is unavailable; keep any partial files.
            captureDescription = directoryCreated
                ? "Debug PDF snapshot capture incomplete (\(savedCount)/3): \(directory.path)"
                : "Debug PDF snapshot capture failed; no snapshot directory was created."
        }
        return NSError(
            domain: "PDFEditor.BookmarkDebugSnapshots",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: failure.localizedDescription + "\n\n" +
                    captureDescription +
                    "\nSnapshots contain PDF contents and filled form values. They are local only and may be removed by the system.",
                NSUnderlyingErrorKey: failure,
            ]
        )
    }
#endif

    private func restorePDFKitCompatibleMutation(
        data: Data,
        actionName: String,
        undoManager: UndoManager,
        bookmarksOnly: Bool = false
    ) {
        Self.pdfiumAccessLock.lock()
        defer { Self.pdfiumAccessLock.unlock() }
        let redoData = sourceData
        guard let restoredDocument = PDFDocument(data: data),
              (try? unlockForBookmarkEditing(restoredDocument)) != nil else {
            return
        }
        let restoredSession = try? PDFiumEditingEngine().makeSession(
            data: data,
            password: authorizedPassword
        )
        if bookmarksOnly {
            guard (try? bookmarkService.synchronizeOutline(
                from: restoredDocument,
                to: pdfDocument
            )) != nil else { return }
        } else {
            // AcroForm undo uses this helper too and must still restore its
            // page annotations and field values, not just the outline.
            pdfDocument = restoredDocument
        }
        invalidateInteractionPreparation()
        editingSession = restoredSession
        sourceData = data
        publishDocumentChangeAfterViewUpdate(markingUnsaved: true)
        undoManager.registerUndo(withTarget: self) { document in
            document.restorePDFKitCompatibleMutation(
                data: redoData,
                actionName: actionName,
                undoManager: undoManager,
                bookmarksOnly: bookmarksOnly
            )
        }
        undoManager.setActionName(actionName)
    }

    private func invalidateInteractionPreparation() {
        interactionPreparationTask?.cancel()
        interactionPreparationTask = nil
        interactionPreparationID &+= 1
    }

    private func unlockForBookmarkEditing(_ document: PDFDocument) throws {
        guard document.isLocked else { return }
        guard let authorizedPassword,
              document.unlock(withPassword: authorizedPassword) else {
            throw PDFEditingError.invalidPassword
        }
    }

    private func bookmarkRoundTripPreservesPages(
        from previousData: Data,
        workingDocument: PDFDocument,
        to verifiedData: Data,
        verifiedDocument: PDFDocument,
        checksPageResources: Bool
    ) -> Bool {
        guard workingDocument.pageCount == verifiedDocument.pageCount else {
            return false
        }
        for pageIndex in 0..<workingDocument.pageCount {
            guard (!checksPageResources ||
                PDFPageResourceIntegrityService.preservesPageResources(
                    from: previousData,
                    to: verifiedData,
                    pageIndex: pageIndex
                )),
            let before = workingDocument.page(at: pageIndex),
            let after = verifiedDocument.page(at: pageIndex),
            before.rotation == after.rotation,
            approximatelyEqual(
                before.bounds(for: .mediaBox),
                after.bounds(for: .mediaBox)
            ),
            approximatelyEqual(
                before.bounds(for: .cropBox),
                after.bounds(for: .cropBox)
            ),
            before.annotations.count == after.annotations.count else {
                return false
            }
        }
        return true
    }

    private func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        accuracy: CGFloat = 0.01
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= accuracy &&
            abs(lhs.minY - rhs.minY) <= accuracy &&
            abs(lhs.width - rhs.width) <= accuracy &&
            abs(lhs.height - rhs.height) <= accuracy
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
        pdfDocument.outlineRoot = document.outlineRoot
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
