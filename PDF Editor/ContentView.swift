import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

private struct DocumentTitleMenuDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableDocumentRenamingAfterDocumentGroupConfiguresTitle()
        }

        private func disableDocumentRenamingAfterDocumentGroupConfiguresTitle() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var viewControllers: [UIViewController] = []
                if let topViewController = self.navigationController?.topViewController {
                    viewControllers.append(topViewController)
                }

                var ancestor = self.parent
                while let viewController = ancestor {
                    if !viewControllers.contains(where: { $0 === viewController }) {
                        viewControllers.append(viewController)
                    }
                    ancestor = viewController.parent
                }

                for viewController in viewControllers {
                    let navigationItem = viewController.navigationItem
                    navigationItem.renameDelegate = nil
                    navigationItem.titleMenuProvider = nil
                    navigationItem.documentProperties = nil
                }
            }
        }
    }
}

#endif

#if os(macOS)
import AppKit

@MainActor
private final class PDFFormDesignFocusRecovery: ObservableObject {
    private weak var sourceWindow: NSWindow?
    private var subscriptions: [AnyCancellable] = []
    private var recoveryTask: Task<Void, Never>?
    private var isRestoring = false
    private var toolbarCursorMonitor: Any?
    private var toolbarCursorUpdateQueued = false

    func prepare(for window: NSWindow?) {
        cancel()
        sourceWindow = window
    }

    func restoreAfterDismissal() {
        guard let window = sourceWindow else { return }
        isRestoring = true
        subscriptions = [
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window),
            NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification, object: window),
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification, object: NSApp),
        ].map { publisher in
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.scheduleRecovery()
            }
        }
        scheduleRecovery()
    }

    func cancel() {
        finishRecovery()
        if let toolbarCursorMonitor {
            NSEvent.removeMonitor(toolbarCursorMonitor)
            self.toolbarCursorMonitor = nil
        }
        toolbarCursorUpdateQueued = false
        sourceWindow = nil
    }

    private func finishRecovery() {
        isRestoring = false
        recoveryTask?.cancel()
        recoveryTask = nil
        subscriptions.removeAll()
    }

    private func scheduleRecovery() {
        guard isRestoring else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            // Dismissal and key-window notifications can precede AppKit's
            // final responder/cursor update. Yield, then check the real state.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.restoreIfReady()
        }
    }

    private func restoreIfReady() {
        guard isRestoring, let window = sourceWindow,
              NSApp.isActive, window.isVisible, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        // Do not reactivate the sheet's text editor or make another window key.
        guard window.makeFirstResponder(nil) else { cancel(); return }
        window.resetCursorRects()
        // NSCursor is application-wide: only clear the stale I-beam when the
        // pointer is over this document, never over another window/application.
        if NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber {
            NSCursor.arrow.set()
        }
        finishRecovery()
        installToolbarCursorMonitor()
    }

    private func installToolbarCursorMonitor() {
        guard toolbarCursorMonitor == nil else { return }
        toolbarCursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .cursorUpdate]
        ) { [weak self] event in
            guard let self, let window = self.sourceWindow,
                  event.window === window,
                  event.locationInWindow.y >= window.contentLayoutRect.maxY,
                  !self.toolbarCursorUpdateQueued else { return event }
            self.toolbarCursorUpdateQueued = true
            // Local monitors run before normal dispatch. Correct the toolbar
            // cursor afterward rather than before PDFKit's normal cursor
            // handling. Always pass the original event through.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toolbarCursorUpdateQueued = false
                self.restoreToolbarCursorIfNeeded()
            }
            return event
        }
    }

    private func restoreToolbarCursorIfNeeded() {
        guard toolbarCursorMonitor != nil, let window = sourceWindow,
              NSApp.isActive, window.isKeyWindow, window.isVisible,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              window.toolbar?.isVisible == true,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        let point = window.mouseLocationOutsideOfEventStream
        // contentLayoutRect excludes the native titlebar/toolbar, including
        // with fullSizeContentView. Leave PDF text and resize borders alone.
        guard point.y >= window.contentLayoutRect.maxY,
              point.y < window.frame.height - 5,
              point.x > 5, point.x < window.frame.width - 5 else { return }
        if let editor = window.firstResponder as? NSTextView,
           editor.isEditable,
           editor.convert(editor.bounds, to: nil).contains(point) {
            return
        }
        NSCursor.arrow.set()
    }

    deinit {
        if let toolbarCursorMonitor {
            NSEvent.removeMonitor(toolbarCursorMonitor)
        }
    }
}
#endif

private enum FileImportPurpose: Equatable {
    case mergePDF
    case addImage
    case replaceImage

    var allowedContentTypes: [UTType] {
        switch self {
        case .mergePDF:
            [.pdf]
        case .addImage, .replaceImage:
            [.image]
        }
    }
}

private struct PDFCommentPlacement: Equatable {
    let pageIndex: Int
    let point: CGPoint
}

private struct PendingTextEdit {
    let object: PDFPageObjectSnapshot
    let text: String
    let style: PDFTextStyle
}

private struct PendingManualSave {
    let preparation: PDFManualSavePreparation
    let edits: [PendingTextEdit]
}

#if os(macOS)
private struct ManualSaveDestinationAdoption {
    let nativeDocument: NSDocument?
    let window: NSWindow?
    let previousDocumentURL: URL?
    let previousFileModificationDate: Date?
    let previousSaveURL: URL?
    let previousWindowTitle: String?
    let previousRepresentedURL: URL?
    let didAdoptNativeDocument: Bool
}
#endif

private enum ESignPlacement {
    case signature(SignatureLibraryTemplate)
    case mark(ESignMark)

    var normalizedStrokes: [[CGPoint]] {
        switch self {
        case let .signature(template): template.normalizedStrokes
        case let .mark(mark): mark.normalizedStrokes
        }
    }

    var preferredSize: CGSize {
        switch self {
        case .signature: SignaturePlacementGeometry.preferredSize
        case .mark: ESignMark.preferredSize
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .signature: 2
        case .mark: ESignMark.lineWidth
        }
    }

    var annotationPadding: CGFloat {
        switch self {
        case .signature: 2
        case .mark: ESignMark.annotationPadding
        }
    }

    var promptName: String {
        switch self {
        case let .signature(template): template.displayName ?? "the signature"
        case .mark(.checkmark): "a checkmark"
        case .mark(.crossmark): "a crossmark"
        }
    }

    var systemImage: String {
        switch self {
        case .signature: "signature"
        case .mark(.checkmark): "checkmark"
        case .mark(.crossmark): "xmark"
        }
    }

    var undoActionName: String {
        switch self {
        case .signature: "Add Signature"
        case .mark(.checkmark): "Add Checkmark"
        case .mark(.crossmark): "Add Crossmark"
        }
    }
}

@MainActor
private final class PendingTextEditStore: ObservableObject {
    @Published private(set) var edits: [String: PendingTextEdit] = [:]

    var stagedTextByObjectID: [String: PDFStagedTextEdit] {
        edits.mapValues { PDFStagedTextEdit(text: $0.text, style: $0.style) }
    }

    func set(
        object: PDFPageObjectSnapshot,
        text: String,
        style: PDFTextStyle,
        undoManager: UndoManager?
    ) {
        let objectID = object.id
        let previous = edits[objectID]
        let originalStyle = PDFTextStyle.inferred(fromFontName: object.fontName)
        let replacement = text == object.text && style == originalStyle
            ? nil
            : PendingTextEdit(object: object, text: text, style: style)
        guard previous?.text != replacement?.text || previous?.style != replacement?.style else {
            return
        }
        apply(replacement, objectID: objectID)
        registerUndo(
            restoring: previous,
            replacing: replacement,
            objectID: objectID,
            undoManager: undoManager
        )
    }

    func removeCommittedEdit(objectID: String) {
        edits.removeValue(forKey: objectID)
    }

    func removeUndoActions(using undoManager: UndoManager?) {
        undoManager?.removeAllActions(withTarget: self)
    }

    private func apply(_ edit: PendingTextEdit?, objectID: String) {
        if let edit {
            edits[objectID] = edit
        } else {
            edits.removeValue(forKey: objectID)
        }
    }

    private func registerUndo(
        restoring edit: PendingTextEdit?,
        replacing inverse: PendingTextEdit?,
        objectID: String,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            store.apply(edit, objectID: objectID)
            store.registerUndo(
                restoring: inverse,
                replacing: edit,
                objectID: objectID,
                undoManager: undoManager
            )
        }
        undoManager.setActionName("Edit PDF Text")
    }
}

struct ContentView: View {
    let document: PDFEditorDocument

    @ObservedObject private var editorState: PDFEditorDocument.EditorState

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#else
    @Environment(\.undoManager) private var environmentUndoManager
#endif

    @StateObject private var pendingTextEditStore = PendingTextEditStore()
    @State private var selectedPageIndex: Int? = 0
    @State private var pdfSelection: PDFSelection?
    @State private var highlightSelectionSnapshot: PDFSelection?
    @State private var highlightModeEnabled = false
    @State private var password = ""
    @State private var formDesignSession: PDFFormDesignSession?
    @State private var isOpeningFormDesign = false
    @State private var pendingFormDesignKindAfterTools: PDFFormDesignKind?
    @State private var formDesignPlacementKind: PDFFormDesignKind?
    @State private var formPlacementRequest: PDFFormPlacementRequest?
    @State private var selectedFormField: PDFFormDesignField?
    @State private var formPlacementPreparationID: UUID?
    @State private var radioPlacementGroupName = ""
    @State private var choicePlacementOptionsText = "Option 1\nOption 2\nOption 3"
#if os(macOS)
    @StateObject private var formDesignFocusRecovery = PDFFormDesignFocusRecovery()
#endif
    @State private var annotationText = ""
    @State private var errorMessage: String?
    @State private var pageObjects: [PDFPageObjectSnapshot] = []
    @State private var pageObjectCache: [Int: [PDFPageObjectSnapshot]] = [:]
    @State private var pageObjectCacheRevision = -1
    @State private var pageObjectLoadTask: Task<Void, Never>?
    @State private var selectedObject: PDFPageObjectSnapshot?
    private let objectEditingEnabled = true
    @State private var ocrResult: OCRPageResult?
    @State private var ocrRunContext: OCRRunContext?
    @State private var ocrBatchResult: OCRBatchResult?
    @State private var ocrBatchRunContext: OCRRunContext?
    @State private var ocrBatchTask: Task<Void, Never>?
    @State private var ocrProgressCompleted = 0
    @State private var ocrProgressTotal = 0
    @State private var isRunningOCR = false
    @State private var showsOCRProgress = false
    @State private var splitExportDocument: PDFExportDocument?
    @State private var showsSinglePageExporter = false
    @State private var showsImageExportOptions = false
    @State private var showsImageFileExporter = false
    @State private var imageExportDocuments: [ImageExportDocument] = []
    @State private var imageExportContentType: UTType = .png
    @State private var imageExportTask: Task<Void, Never>?
    @State private var imageExportProgressCompleted = 0
    @State private var imageExportProgressTotal = 0
    @State private var isExportingImages = false
    @State private var manualSaveExportDocument: PDFExportDocument?
    @State private var showsManualSaveExporter = false
    @State private var pendingManualSave: PendingManualSave?
    @State private var manualSaveDefaultFilename = "Untitled"
    @State private var saveURL: URL?
    @State private var didAdoptImportedDestination = false
    @State private var isAdoptingImportedDocument = false
    @State private var isSaving = false
    @State private var pageAnnotations: [PDFAnnotationSnapshot] = []
    @State private var selectedAnnotation: PDFAnnotationSnapshot?
    private let annotationEditingEnabled = true
    @State private var newText = ""
    @State private var showsFileImporter = false
    @State private var fileImportPurpose: FileImportPurpose = .mergePDF
    @State private var imageReplacementTarget: PDFPageObjectSnapshot?
    @State private var showsObjectInspector = false
    @StateObject private var signatureLibraryStore = SignatureLibraryStore()
#if os(macOS)
    @StateObject private var recentDocuments = RecentPDFDocuments()
#endif
    @State private var showsSignatureLibrary = false
    @State private var selectedESignPlacement: ESignPlacement?
    @State private var freeTextPlacementEnabled = false
    @State private var showsOCRResult = false
    @State private var showsSignatureWarning = false
    @State private var showsProtectPDF = false
    @State private var showsPasswordRemovalConfirmation = false
    @State private var showsAddTextPrompt = false
    @State private var showsAnnotationInspector = false
    @State private var pendingMergeData: Data?
    @State private var pendingMergeFilename = "Protected PDF"
    @State private var viewerMode: PDFViewerMode = .scrolling
    @State private var viewerCommand: PDFViewerCommand?
    @State private var showsCommentPrompt = false
    @State private var showsCommentList = false
    @State private var commentEditorAnnotation: PDFAnnotationSnapshot?
    @State private var commentPlacementEnabled = false
    @State private var freehandDrawingEnabled = false
    @State private var pendingFreehandSelectionReference: PDFAnnotationReference?
    @State private var pendingCommentPlacement: PDFCommentPlacement?
    @State private var showsToolPanel = true
    @State private var showsPagePanel = false
    @State private var showsBookmarkPanel = false
    @State private var bookmarks: [PDFBookmarkSnapshot] = []
    @State private var showsAddBookmarkPrompt = false
    @State private var bookmarkTitle = ""
    @State private var usesInlinePanels = false
#if os(iOS)
    @State private var showsDocumentFilename = true
#endif

    private let annotationService = PDFAnnotationService()
    private let ocrService = VisionOCRService()
    private let documentFileURL: URL?
#if os(macOS)
    private let nativeDocumentReference: PDFEditorNativeDocumentReference?
#endif

#if os(macOS)
    init(
        document: PDFEditorDocument,
        fileURL: URL?,
        nativeDocumentReference: PDFEditorNativeDocumentReference? = nil
    ) {
        self.document = document
        documentFileURL = fileURL
        self.nativeDocumentReference = nativeDocumentReference
        _editorState = ObservedObject(wrappedValue: document.editorState)
        _saveURL = State(initialValue: fileURL)
    }
#else
    init(document: PDFEditorDocument, fileURL: URL?) {
        self.document = document
        documentFileURL = fileURL
        _editorState = ObservedObject(wrappedValue: document.editorState)
        _saveURL = State(initialValue: fileURL)
        _showsToolPanel = State(
            initialValue: UIDevice.current.userInterfaceIdiom != .phone
        )
    }
#endif

    private var undoManager: UndoManager? {
#if os(iOS)
        editorState.undoManager
#else
        environmentUndoManager
#endif
    }

    private var canSave: Bool {
        !isSaving && !isAdoptingImportedDocument && (
            editorState.hasUnsavedChanges || !pendingTextEditStore.edits.isEmpty || saveURL == nil
        )
    }

    var body: some View {
        fileTransferView
            .focusedValue(\.manualPDFSaveAction, saveDocument)
            .focusedValue(\.manualPDFSaveAsAction, saveDocumentAs)
#if os(iOS)
            .task(id: documentFileURL) {
                await adoptImportedDocumentIfNeeded()
            }
            .task {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    showsDocumentFilename = false
                }
            }
#endif
            .task {
                // A newly opened macOS document can be moved into a tab while
                // this task is awaiting PDFium preparation. Load the outline
                // first so cancellation during that transition cannot leave
                // the Bookmark rows and their edit controls empty until the
                // user switches tabs.
                loadBookmarks()
                await document.prepareEditingSessionForInteraction()
                guard !Task.isCancelled else { return }
                loadBookmarks()
            }
#if os(macOS)
            .onAppear {
                configureNativeDocumentSaving()
                synchronizeNativeDocumentEditedState()
            }
            .onChange(of: editorState.hasUnsavedChanges) {
                synchronizeNativeDocumentEditedState()
            }
            .onChange(of: pendingTextEditStore.edits.isEmpty) {
                synchronizeNativeDocumentEditedState()
            }
#endif
            .onDisappear {
                cancelFormFieldPlacement()
                ocrBatchTask?.cancel()
                imageExportTask?.cancel()
                pageObjectLoadTask?.cancel()
#if os(macOS)
                formDesignFocusRecovery.cancel()
                nativeDocumentReference?.document?.prepareSave = nil
                nativeDocumentReference?.document?.saveActivityDidChange = nil
#endif
            }
    }

    private var editorRoot: some View {
        GeometryReader { proxy in
            if proxy.size.width >= (showsCommentList ? 1180 : 900) {
                HStack(spacing: 0) {
                    if showsToolPanel {
                        toolSidebar
                            .frame(width: 200)
                        Divider()
                    }
                    if showsCommentList {
                        commentList
                            .frame(width: 320)
                        Divider()
                    }
                    documentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsPagePanel {
                        Divider()
                        pageSidebar
                            .frame(width: 180)
                    }
                    if showsBookmarkPanel {
                        Divider()
                        bookmarkSidebar
                            .frame(width: 260)
                    }
                    if !usesPhoneViewerControls {
                        Divider()
                        rightPanel
                            .frame(width: 52)
                    }
                }
                .onAppear { usesInlinePanels = true }
                .onDisappear { usesInlinePanels = false }
            } else {
                HStack(spacing: 0) {
                    documentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsPagePanel {
                        Divider()
                        pageSidebar
                            .frame(
                                width: min(180, max(160, proxy.size.width * 0.45))
                            )
                    }
                    if showsBookmarkPanel {
                        Divider()
                        bookmarkSidebar
                            .frame(
                                width: min(260, max(220, proxy.size.width * 0.55))
                            )
                    }
                    if !usesPhoneViewerControls {
                        Divider()
                        rightPanel
                            .frame(width: 52)
                    }
                }
                .onAppear { usesInlinePanels = false }
                .sheet(isPresented: $showsToolPanel, onDismiss: {
                    if let kind = pendingFormDesignKindAfterTools {
                        pendingFormDesignKindAfterTools = nil
                        beginFormFieldPlacement(kind)
                    }
                }) {
                    NavigationStack {
                        toolSidebar
                            .navigationTitle("Tools")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showsToolPanel = false }
                                }
                            }
                    }
                    .frame(minWidth: 300, minHeight: 560)
                }
                .sheet(isPresented: $showsCommentList) {
                    commentList
                        .frame(minWidth: 360, minHeight: 520)
                }
            }
        }
#if os(iOS)
        .overlay(alignment: .trailing) {
            if usesPhoneViewerControls {
                PDFPhoneViewerControls { onInteraction, onPageNumberFocusChange in
                    makeRightPanel(
                        onInteraction: onInteraction,
                        onPageNumberFocusChange: onPageNumberFocusChange
                    )
                }
            }
        }
        .overlay(alignment: .top) {
            if horizontalSizeClass == .compact, showsDocumentFilename {
                Text(suggestedSaveFilename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // DocumentGroup configures the Rename action after SwiftUI toolbar
        // modifiers. Clear that document-specific menu once it has finished.
        .background(DocumentTitleMenuDisabler())
        .toolbar(removing: .title)
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .principal) {
                    compactScrollableToolbar
                }
            } else {
                adaptiveToolbar
            }
        }
#endif
#if os(macOS)
        .toolbar {
            adaptiveToolbar
        }
#endif
        .onChange(of: isSaving) { _, saving in
            if saving { cancelFormFieldPlacement() }
        }
        .onChange(of: isRunningOCR) { _, running in
            if running { cancelFormFieldPlacement() }
        }
        .onChange(of: document.pageCount, initial: true) { _, pageCount in
            guard pageCount > 0 else {
                selectedPageIndex = nil
                return
            }
            if let selectedPageIndex, selectedPageIndex < pageCount {
                loadCanvasObjects()
                loadCanvasAnnotations()
                return
            }
            selectedPageIndex = 0
        }
        .onChange(of: selectedPageIndex) { _, pageIndex in
            let pendingFreehandReference = pendingFreehandSelectionReference
            highlightSelectionSnapshot = nil
            highlightModeEnabled = false
            selectedObject = nil
            selectedAnnotation = nil
            if selectedFormField?.pageIndex != pageIndex { selectedFormField = nil }
            loadCanvasObjects()
            loadCanvasAnnotations()
            if let pageIndex, let pendingFreehandReference,
               pendingFreehandReference.pageIndex == pageIndex {
                selectedAnnotation = pageAnnotations.first {
                    $0.reference == pendingFreehandReference
                }
                pendingFreehandSelectionReference = nil
            }
        }
        .onChange(of: editorState.revision) { _, _ in
            pageObjectCache.removeAll()
            pageObjectCacheRevision = editorState.revision
            loadCanvasObjects()
            loadCanvasAnnotations()
            loadBookmarks()
        }
        .onChange(of: editorState.annotationColorUpdate) { _, event in
            guard let event else { return }
            if let index = pageAnnotations.firstIndex(where: {
                $0.reference == event.reference
            }) {
                pageAnnotations[index].color = event.color
            }
            if selectedAnnotation?.reference == event.reference {
                selectedAnnotation?.color = event.color
            }
            if commentEditorAnnotation?.reference == event.reference {
                commentEditorAnnotation?.color = event.color
            }
        }
        .onChange(of: editorState.annotationBackgroundFailure) { _, event in
            guard let event else { return }
            if event.requiresDigitalSignatureConsent {
                showsSignatureWarning = true
            } else {
                errorMessage = event.message
            }
        }
    }

    private var presentedEditor: some View {
        editorRoot
        .alert("Unable to Complete Operation", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Digital Signatures Will Become Invalid", isPresented: $showsSignatureWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Allow Editing", role: .destructive) {
                document.authorizeDigitalSignatureInvalidation()
            }
        } message: {
            Text("This PDF contains digital signatures. Editing content or annotations will invalidate them. Confirm, then repeat the operation.")
        }
        .alert("Remove PDF Password?", isPresented: $showsPasswordRemovalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove When Saving", role: .destructive) {
                document.setRemovesPasswordProtectionOnSave(true)
                if !usesInlinePanels {
                    showsToolPanel = false
                }
            }
        } message: {
            Text("The next Save or Save As will create a PDF that no longer requires a password.")
        }
        .alert("Add Text", isPresented: $showsAddTextPrompt) {
            TextField("Text", text: $newText)
            Button("Cancel", role: .cancel) { newText = "" }
            Button("Add") { addText(newText) }
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Text will be added to the center of the current page. You can move or edit it from the PDF Objects panel.")
        }
        .alert("Add Bookmark", isPresented: $showsAddBookmarkPrompt) {
            TextField("Bookmark name", text: $bookmarkTitle)
            Button("Cancel", role: .cancel) { bookmarkTitle = "" }
            Button("Add", action: addBookmark)
                .disabled(bookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The bookmark will point to the current page and be saved inside the PDF.")
        }
        .sheet(isPresented: $showsObjectInspector) {
            PageObjectInspectorView(
                objects: $pageObjects,
                onReplaceText: replaceText,
                onReplaceImage: { object in
                    beginImageReplacement(object)
                },
                onMove: moveObject,
                onMoveToIndex: moveObject,
                onDelete: deleteObject
            )
        }
        .sheet(isPresented: $showsSignatureLibrary) {
            SignatureLibraryView(
                store: signatureLibraryStore,
                onSelect: beginSignaturePlacement
            )
        }
        .sheet(isPresented: $showsAnnotationInspector) {
            AnnotationInspectorView(
                annotations: pageAnnotations,
                selectedAnnotation: $selectedAnnotation,
                onApply: updateAnnotation,
                onDelete: deleteAnnotation
            )
        }
        .sheet(item: $formDesignSession, onDismiss: formDesignDidDismiss) { session in
            PDFFormDesignerView(session: session, initialPlacementKind: formDesignPlacementKind) { fields in
                try document.applyFormDesign(fields, session: session, undoManager: undoManager)
                formDesignSession = nil
            } onCancel: {
                formDesignSession = nil
            }
        }
#if os(iOS)
        .sheet(item: $commentEditorAnnotation) { annotation in
            PDFCommentEditor(
                annotation: annotation,
                onApply: { updateAnnotation(annotation, update: $0) },
                onDelete: { deleteAnnotation(annotation) },
                onDismiss: { commentEditorAnnotation = nil },
                onHoverChanged: { _ in }
            )
        }
#endif
        .sheet(isPresented: $showsCommentPrompt, onDismiss: cancelCommentPlacement) {
            PDFAddCommentView(
                text: $annotationText,
                onAdd: { addNote(at: pendingCommentPlacement) },
                onCancel: cancelCommentPlacement
            )
        }
        .sheet(isPresented: $showsOCRResult) { ocrResultView }
        .sheet(isPresented: $showsImageExportOptions) {
            PDFImageExportOptionsView(
                hasCurrentPage: selectedPageIndex != nil,
                pageCount: document.pageCount,
                onExport: startImageExport
            )
        }
        .sheet(isPresented: $showsProtectPDF) {
            PDFProtectView(
                onProtect: { password in
                    document.setPasswordProtectionOnSave(password)
                    showsProtectPDF = false
                },
                onCancel: { showsProtectPDF = false }
            )
        }
        .sheet(isPresented: $isExportingImages) {
            NavigationStack {
                VStack(spacing: 18) {
                    ProgressView(
                        value: Double(imageExportProgressCompleted),
                        total: Double(max(imageExportProgressTotal, 1))
                    )
                    Text("Exported \(imageExportProgressCompleted) of \(imageExportProgressTotal) pages")
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .navigationTitle("Exporting Images")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { imageExportTask?.cancel() }
                    }
                }
            }
            .frame(minWidth: 400, minHeight: 200)
            .interactiveDismissDisabled()
        }
        .modifier(
            PhaseFiveWorkflowModifier(
                ocrBatchResult: $ocrBatchResult,
                showsOCRProgress: $showsOCRProgress,
                ocrProgressCompleted: ocrProgressCompleted,
                ocrProgressTotal: ocrProgressTotal,
                pendingMergeData: $pendingMergeData,
                pendingMergeFilename: $pendingMergeFilename,
                onCancelOCR: { ocrBatchTask?.cancel() },
                onAddOCRTextLayers: addOCRTextLayers,
                onMergeProtectedPDF: mergePendingPDF
            )
        )
    }

    private var fileTransferView: some View {
        presentedEditor
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: fileImportPurpose.allowedContentTypes
        ) {
            handleFileImport($0)
        }
        .fileExporter(
            isPresented: $showsManualSaveExporter,
            document: manualSaveExportDocument,
            contentType: .pdf,
            defaultFilename: manualSaveDefaultFilename
        ) { result in
            finishManualSaveExport(result)
        }
        .fileExporter(
            isPresented: $showsSinglePageExporter,
            document: splitExportDocument,
            contentType: .pdf,
            defaultFilename: "PDF Split"
        ) { result in
            if case let .failure(error) = result { present(error) }
            splitExportDocument = nil
        }
        .fileExporter(
            isPresented: $showsImageFileExporter,
            documents: imageExportDocuments,
            contentType: imageExportContentType
        ) { result in
            if case let .failure(error) = result,
               !Self.isUserCancellation(error) {
                present(error)
            }
            imageExportDocuments = []
        }
    }

    private var pageSidebar: some View {
        PDFPagesPanel(
            document: document.pdfDocument,
            selectedPageIndex: $selectedPageIndex,
            onMove: reorderPages,
            onExtract: exportPage,
            onRotate: rotatePage,
            onDelete: deletePage,
            onClose: { showsPagePanel = false }
        )
    }

    private var bookmarkSidebar: some View {
        PDFBookmarksPanel(
            bookmarks: bookmarks,
            selectedPageIndex: selectedPageIndex,
            onNavigate: { selectedPageIndex = $0 },
            onAdd: beginAddingBookmark,
            onRename: renameBookmark,
            onDelete: deleteBookmark,
            onClose: { showsBookmarkPanel = false }
        )
    }

    @ViewBuilder
    private var documentView: some View {
        if document.isLocked {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Password Required",
                    systemImage: "lock",
                    description: Text("Enter the correct password to load and edit this PDF.")
                )
                SecureField("PDF password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(unlockDocument)
                Button("Unlock", action: unlockDocument)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .padding()
        } else if document.pageCount == 0 {
            ContentUnavailableView(
                "Empty PDF",
                systemImage: "doc",
                description: Text("This document has no pages.")
            )
        } else {
            ZStack(alignment: .top) {
                PDFKitView(
                    document: document.pdfDocument,
                    selectedPageIndex: $selectedPageIndex,
                    selection: $pdfSelection,
                    objects: pageObjects,
                    stagedTextByObjectID: pendingTextEditStore.stagedTextByObjectID,
                    selectedObject: $selectedObject,
                    objectEditingEnabled: objectEditingEnabled && formPlacementRequest == nil,
                    onTranslateObject: moveObject,
                    onSetObjectTransform: setObjectTransform,
                    annotations: pageAnnotations,
                    selectedAnnotation: $selectedAnnotation,
                    annotationEditingEnabled: annotationEditingEnabled && formPlacementRequest == nil,
                    onSetAnnotationBounds: setAnnotationBounds,
                    selectedFormField: $selectedFormField,
                    onSetFormFieldBounds: setFormFieldBounds,
                    onSetFormFieldFontSize: setFormFieldFontSize,
                    onDeleteFormField: deleteFormField,
                    commentPlacementEnabled: commentPlacementEnabled,
                    onPlaceComment: selectCommentPlacement,
                    freeTextPlacementEnabled: freeTextPlacementEnabled,
                    onPlaceFreeText: addPlacedFreeText,
                    onCancelFreeTextPlacement: cancelFreeTextPlacement,
                    signaturePlacementEnabled: selectedESignPlacement != nil,
                    signaturePlacementStrokes: selectedESignPlacement?.normalizedStrokes,
                    signaturePlacementSize: selectedESignPlacement?.preferredSize
                        ?? SignaturePlacementGeometry.preferredSize,
                    signaturePlacementLineWidth: selectedESignPlacement?.lineWidth ?? 2,
                    onPlaceSignature: placeSelectedESign,
                    freehandDrawingEnabled: freehandDrawingEnabled,
                    onAddFreehand: addFreehandStroke,
                    onReplaceTextObject: replaceText,
                    onReplaceAnnotationText: replaceAnnotationText,
                    onUpdateAnnotation: updateAnnotation,
                    onDeleteAnnotation: deleteAnnotation,
                    onOpenObject: openObject,
                    onOpenAnnotation: openAnnotation,
                    onAcroFormChange: synchronizeAcroFormChanges,
                    viewerMode: viewerMode,
                    viewerCommand: viewerCommand,
                    formPlacement: formPlacementConfiguration
                )
                .ignoresSafeArea(.container, edges: .bottom)

                if let request = formPlacementRequest {
                    formPlacementPrompt(for: request)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                if commentPlacementEnabled {
                    HStack(spacing: 12) {
                        Label(
                            "Click a location in the PDF to add a comment",
                            systemImage: "note.text.badge.plus"
                        )
                        Button("Cancel", action: cancelCommentPlacement)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .shadow(radius: 4, y: 2)
                }

                if let selectedESignPlacement {
                    HStack(spacing: 12) {
                        Label(
                            "Click a location in the PDF to add \(selectedESignPlacement.promptName)",
                            systemImage: selectedESignPlacement.systemImage
                        )
                        Button("Cancel", action: cancelESignPlacement)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .shadow(radius: 4, y: 2)
                }

                if freeTextPlacementEnabled {
                    HStack(spacing: 12) {
                        Label(
                            "Click anywhere in the PDF to add a multiline text box",
                            systemImage: "character.cursor.ibeam"
                        )
                        Button("Cancel", action: cancelFreeTextPlacement)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .shadow(radius: 4, y: 2)
                }

                if freehandDrawingEnabled {
                    HStack(spacing: 12) {
#if os(macOS)
                        Label(
                            "Draw on the PDF, or hold Shift and click another point for a straight line.",
                            systemImage: "pencil.and.outline"
                        )
#else
                        Label(
                            "Draw anywhere on the PDF, then release to finish.",
                            systemImage: "pencil.and.outline"
                        )
#endif
                        Button("Cancel") {
                            freehandDrawingEnabled = false
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .shadow(radius: 4, y: 2)
                }

                if highlightModeEnabled {
                    HStack(spacing: 12) {
                        Label(
                            "Select PDF text, then apply the highlight.",
                            systemImage: "highlighter"
                        )
                        Button("Apply Highlight", action: addHighlight)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(activeHighlightSelection == nil)
                        Button("Cancel", action: cancelHighlightMode)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .shadow(radius: 4, y: 2)
                }
            }
        }
    }

#if os(macOS)
    private var toolSidebar: some View {
        PDFToolSidebar(
            pageCount: document.pageCount,
            hasSelectedPage: selectedPageIndex != nil,
            isEncrypted: document.isEncrypted,
            isLocked: document.isLocked,
            removesPasswordProtectionOnSave:
                document.removesPasswordProtectionOnSave,
            canDesignForm: !isSaving && !isRunningOCR && !isOpeningFormDesign && formPlacementPreparationID == nil,
            recentDocumentURLs: Array(recentDocuments.urls.prefix(5)),
            onOpenRecentDocument: recentDocuments.open,
            onClearRecentDocuments: recentDocuments.clear,
            onRefreshRecentDocuments: recentDocuments.refresh,
            onAction: handleToolAction
        )
    }
#else
    private var toolSidebar: some View {
        PDFToolSidebar(
            pageCount: document.pageCount,
            hasSelectedPage: selectedPageIndex != nil,
            isEncrypted: document.isEncrypted,
            isLocked: document.isLocked,
            removesPasswordProtectionOnSave:
                document.removesPasswordProtectionOnSave,
            canDesignForm: !isSaving && !isRunningOCR && !isOpeningFormDesign && formPlacementPreparationID == nil,
            onAction: handleToolAction
        )
    }
#endif

    private var usesPhoneViewerControls: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    private var rightPanel: some View {
        makeRightPanel()
    }

    private func makeRightPanel(
        onInteraction: @escaping () -> Void = {},
        onPageNumberFocusChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        PDFRightPanel(
            viewerMode: $viewerMode,
            selectedPageIndex: $selectedPageIndex,
            pageCount: document.pageCount,
            isPagesPanelPresented: showsPagePanel,
            isBookmarksPanelPresented: showsBookmarkPanel,
            onTogglePages: togglePagePanel,
            onToggleBookmarks: toggleBookmarkPanel,
            onViewerCommand: { viewerCommand = PDFViewerCommand(action: $0) },
            onFullScreen: toggleFullScreen,
            onInteraction: onInteraction,
            onPageNumberFocusChange: onPageNumberFocusChange
        )
    }

    private var commentList: some View {
        PDFCommentList(
            annotations: pageAnnotations,
            pageNumber: selectedPageIndex.map { $0 + 1 },
            selectedAnnotation: $selectedAnnotation,
            onApply: updateAnnotation,
            onDelete: deleteAnnotation,
            onClose: { showsCommentList = false }
        )
    }

#if os(iOS)
    private var compactScrollableToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button(action: saveDocument) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .accessibilityLabel("Save")

                Button(action: saveDocumentAs) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel("Save As")

                Button {
                    undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!(undoManager?.canUndo ?? false))
                .accessibilityLabel("Undo")

                Button {
                    undoManager?.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!(undoManager?.canRedo ?? false))
                .accessibilityLabel("Redo")

                Button { toggleToolPanel() } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tools")

                Menu {
                    Button("Recognize current page", action: runOCR)
                        .disabled(selectedPage == nil)
                    Button("Recognize all scanned pages", action: runDocumentOCR)
                        .disabled(document.pageCount == 0)
                } label: {
                    Image(systemName: "viewfinder")
                        .frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .disabled(isRunningOCR)
                .accessibilityLabel("OCR")
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
#endif

    @ToolbarContentBuilder
    private var adaptiveToolbar: some ToolbarContent {
#if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button(action: openDocument) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open")
            .accessibilityLabel("Open")
        }
        .sharedBackgroundVisibility(.hidden)
#endif
        ToolbarItem(placement: .navigation) {
            Button(action: saveDocument) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .help("Save")
            .accessibilityLabel("Save")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Button(action: saveDocumentAs) {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .help("Save As")
            .accessibilityLabel("Save As")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Button {
                undoManager?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!(undoManager?.canUndo ?? false))
            .help("Undo")
            .accessibilityLabel("Undo")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Button {
                undoManager?.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!(undoManager?.canRedo ?? false))
            .help("Redo")
            .accessibilityLabel("Redo")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Button { toggleToolPanel() } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .buttonStyle(.plain)
            .help("Tools")
            .accessibilityLabel("Tools")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Recognize current page", action: runOCR)
                    .disabled(selectedPage == nil)
                Button("Recognize all scanned pages", action: runDocumentOCR)
                    .disabled(document.pageCount == 0)
            } label: {
                Image(systemName: "viewfinder")
            }
            .menuStyle(.borderlessButton)
            .disabled(isRunningOCR)
            .help("OCR")
            .accessibilityLabel("OCR")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func beginFormDesign(placing kind: PDFFormDesignKind? = nil) {
        cancelFormFieldPlacement()
        guard !isOpeningFormDesign, formDesignSession == nil,
              !isSaving, !isRunningOCR, !document.isLocked, document.pageCount > 0 else { return }
        // End native field editing before taking the isolated design snapshot.
#if os(macOS)
        let formDesignHostWindow = nativeDocumentReference?.document?.windowControllers.first?.window
            ?? NSApp.keyWindow
        guard formDesignHostWindow?.makeFirstResponder(nil) != false else { return }
#else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
        cancelCommentPlacement()
        cancelESignPlacement()
        cancelFreeTextPlacement()
        freehandDrawingEnabled = false
        highlightModeEnabled = false
        selectedAnnotation = nil
        selectedObject = nil
        isOpeningFormDesign = true
        Task { @MainActor in
            defer { isOpeningFormDesign = false }
            // Let native edit-completion callbacks settle before cloning bytes.
            await Task.yield()
            guard pendingTextEditStore.edits.isEmpty else {
                errorMessage = "Save or undo pending PDF text edits before opening the form designer."
                return
            }
            do {
                let session = try document.makeFormDesignSession(
                    initialPageIndex: selectedPageIndex ?? 0, undoManager: undoManager
                )
#if os(macOS)
                formDesignFocusRecovery.prepare(for: formDesignHostWindow)
#endif
                formDesignPlacementKind = kind
                formDesignSession = session
            } catch { present(error) }
        }
    }

    private var formPlacementConfiguration: PDFFormPlacementConfiguration? {
        guard let request = formPlacementRequest else { return nil }
        return PDFFormPlacementConfiguration(
            request: request,
            defaultSize: request.kind.placementSize(
                choices: request.kind.isChoice ? choicePlacementOptions : []
            ),
            onPlace: { source, pageIndex, bounds in
                placeFormField(request, source: source, pageIndex: pageIndex, bounds: bounds)
            },
            onCancel: cancelFormFieldPlacement
        )
    }

    private func formPlacementPrompt(for request: PDFFormPlacementRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Click or drag to add \(request.kind.title)", systemImage: request.kind.symbol)
                    .font(.callout)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelFormFieldPlacement)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            if request.kind == .radioButton {
                HStack {
                    Text("Group Name")
                    TextField("Radio group", text: $radioPlacementGroupName)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Use the same group for related options, or enter a new group name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if request.kind.isChoice {
                TextEditor(text: $choicePlacementOptionsText)
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.35))
                    }
                    .accessibilityLabel("Options, one per line")
                Text("Enter one Dropdown or List Box option per line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
    }

    private func beginFormFieldPlacement(_ kind: PDFFormDesignKind) {
        cancelFormFieldPlacement()
        guard formDesignSession == nil, !isOpeningFormDesign,
              !isSaving, !isRunningOCR, !document.isLocked, document.pageCount > 0 else { return }
#if os(macOS)
        let window = nativeDocumentReference?.document?.windowControllers.first?.window ?? NSApp.keyWindow
        guard window?.makeFirstResponder(nil) != false else { return }
        formDesignFocusRecovery.cancel()
#else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
        cancelCommentPlacement()
        cancelESignPlacement()
        cancelFreeTextPlacement()
        freehandDrawingEnabled = false
        highlightModeEnabled = false
        selectedAnnotation = nil
        selectedObject = nil
        selectedFormField = nil
        pdfSelection = nil
        let request = PDFFormPlacementRequest(kind: kind)
        let source = document.pdfDocument
        formPlacementPreparationID = request.id
        Task { @MainActor in
            defer {
                if formPlacementPreparationID == request.id { formPlacementPreparationID = nil }
            }
            // Let native edit completion publish pending text before the check.
            await Task.yield()
            guard formPlacementPreparationID == request.id, source === document.pdfDocument,
                  !isSaving, !isRunningOCR else { return }
            guard pendingTextEditStore.edits.isEmpty else {
                errorMessage = "Save or undo pending PDF text edits before adding form fields."
                return
            }
            do {
                _ = try document.makeFormDesignSession(initialPageIndex: selectedPageIndex ?? 0, undoManager: undoManager)
                if kind == .radioButton, radioPlacementGroupName.isEmpty {
                    radioPlacementGroupName = PDFFormDesignService().nextPlacementName(for: kind, in: document.pdfDocument)
                }
                formPlacementRequest = request
            } catch { present(error) }
        }
    }

    private func cancelFormFieldPlacement() {
        formPlacementPreparationID = nil
        formPlacementRequest = nil
        pendingFormDesignKindAfterTools = nil
    }

    private func placeFormField(
        _ request: PDFFormPlacementRequest, source: PDFDocument,
        pageIndex: Int, bounds: CGRect
    ) {
        guard formPlacementRequest?.id == request.id, source === document.pdfDocument,
              !isSaving, !isRunningOCR else { return }
        // A completed gesture ends placement even if verification rejects it.
        // The live document is unchanged on failure; a new tool click can retry.
        cancelFormFieldPlacement()
        do {
            let field = try document.addPlacedFormField(
                kind: request.kind, pageIndex: pageIndex, bounds: bounds,
                radioGroupName: request.kind == .radioButton ? radioPlacementGroupName : nil,
                choiceOptions: request.kind.isChoice ? choicePlacementOptions : [],
                undoManager: undoManager
            )
            if request.kind == .radioButton { radioPlacementGroupName = field.name }
            // Keep the viewport's current page. In continuous/two-page mode,
            // the clicked page can differ; assigning it would navigate/scroll
            // PDFView even though its document and pages were retained.
        } catch { present(error) }
    }

    private var choicePlacementOptions: [String] {
        choicePlacementOptionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func formDesignDidDismiss() {
        formDesignPlacementKind = nil
        pendingFormDesignKindAfterTools = nil
#if os(macOS)
        formDesignFocusRecovery.restoreAfterDismissal()
#endif
    }

#if os(macOS)
    private func openDocument() {
        NSDocumentController.shared.openDocument(nil)
    }
#endif

    private func toggleToolPanel() {
        let willShow = !showsToolPanel
        if willShow {
            highlightSelectionSnapshot = validHighlightSelection(pdfSelection)?
                .copy() as? PDFSelection
        } else {
            highlightSelectionSnapshot = nil
        }
        showsToolPanel = willShow
        if willShow {
            showsPagePanel = false
            showsBookmarkPanel = false
        }
        if !showsToolPanel {
            showsCommentList = false
        }
    }

    private func togglePagePanel() {
        showsPagePanel.toggle()
        if showsPagePanel {
            showsToolPanel = false
            showsCommentList = false
            showsBookmarkPanel = false
        }
    }

    private func toggleBookmarkPanel() {
        showsBookmarkPanel.toggle()
        if showsBookmarkPanel {
            showsToolPanel = false
            showsCommentList = false
            showsPagePanel = false
            loadBookmarks()
        }
    }

    private func loadBookmarks() {
        bookmarks = document.bookmarkSnapshots()
    }

    private func beginAddingBookmark() {
        guard let selectedPageIndex else { return }
        bookmarkTitle = "Page \(selectedPageIndex + 1)"
        showsAddBookmarkPrompt = true
    }

    private func addBookmark() {
        guard let selectedPageIndex else { return }
        do {
            try document.addBookmark(
                title: bookmarkTitle,
                pageIndex: selectedPageIndex,
                undoManager: undoManager
            )
            bookmarkTitle = ""
            loadBookmarks()
        } catch {
            presentBookmarkError(error)
        }
    }

    private func renameBookmark(_ bookmark: PDFBookmarkSnapshot, title: String) -> Bool {
        do {
            try document.renameBookmark(
                at: bookmark.path,
                title: title,
                undoManager: undoManager
            )
            loadBookmarks()
            return true
        } catch {
            presentBookmarkError(error)
            return false
        }
    }

    private func deleteBookmark(_ bookmark: PDFBookmarkSnapshot) {
        do {
            try document.deleteBookmark(
                at: bookmark.path,
                undoManager: undoManager
            )
            loadBookmarks()
        } catch {
            presentBookmarkError(error)
        }
    }

    private func presentBookmarkError(_ error: Error) {
        if let editingError = error as? PDFEditingError,
           editingError == .digitalSignatureConsentRequired {
            showsSignatureWarning = true
        } else {
            present(error)
        }
    }

    private func saveDocument() {
        performSave(choosingNewDestination: false)
    }

    private func saveDocumentAs() {
        performSave(choosingNewDestination: true)
    }

    private func performSave(choosingNewDestination: Bool) {
        guard !isSaving else { return }
#if os(macOS)
        if let nativeDocument = nativeDocumentReference?.document {
            if choosingNewDestination || nativeDocument.fileURL == nil {
                nativeDocument.saveAs(nil)
            } else {
                nativeDocument.save(nil)
            }
            return
        }
#endif
        do {
            try document.synchronizeAcroFormChangesIfNeeded(undoManager: undoManager)
        } catch {
            present(error)
            return
        }
        isSaving = true
#if os(macOS)
        if choosingNewDestination || saveURL == nil {
            presentManualSavePanel(filename: "\(suggestedSaveFilename).pdf")
            return
        }
#endif
        Task { @MainActor in
            await Task.yield()
            do {
                let pendingSave = try await preparePendingManualSave()
                let data = pendingSave.preparation.data
                if let saveURL, !choosingNewDestination {
#if os(macOS)
                    try await writeExistingDocument(data, to: saveURL)
#else
                    try ManualPDFSaveCoordinator.write(data, to: saveURL)
#endif
                    try await finishSuccessfulManualSave(
                        pendingSave,
                        at: saveURL,
                        didAdoptDestination: didAdoptImportedDestination
                    )
                    isSaving = false
                } else {
                    let defaultFilename = suggestedSaveFilename
                    manualSaveDefaultFilename = defaultFilename
#if os(macOS)
                    // The macOS new-destination path returns before starting
                    // this task, after presenting NSSavePanel immediately.
                    isSaving = false
#else
                    pendingManualSave = pendingSave
                    manualSaveExportDocument = PDFExportDocument(
                        data: data,
                        filename: "\(defaultFilename).pdf"
                    )
                    Task { @MainActor in
                        await Task.yield()
                        guard manualSaveExportDocument != nil else { return }
                        showsManualSaveExporter = true
                    }
#endif
                }
            } catch {
                isSaving = false
                present(error)
            }
        }
    }

#if os(iOS)
    private func adoptImportedDocumentIfNeeded() async {
        guard let documentFileURL else { return }
        isAdoptingImportedDocument = true
        defer { isAdoptingImportedDocument = false }
        do {
            // A shared document's initial URL can precede DocumentGroup's
            // completed import URL. Debounce so a URL change cancels this
            // task before choosing a destination from transient file state.
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            let data = try document.snapshot(contentType: .pdf)
            let destinationURL = try await Task.detached(priority: .userInitiated) {
                try ManualPDFSaveCoordinator.adoptImportedDocumentIfNeeded(
                    from: documentFileURL,
                    data: data
                )
            }.value
            guard !Task.isCancelled else { return }
            if let destinationURL {
                saveURL = destinationURL
                didAdoptImportedDestination = true
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }
#endif

#if os(macOS)
    private func configureNativeDocumentSaving() {
        guard let nativeDocument = nativeDocumentReference?.document else { return }
        nativeDocument.prepareSave = {
            try await prepareNativeDocumentSave()
        }
        nativeDocument.saveActivityDidChange = { saving in
            isSaving = saving
        }
    }

    private func prepareNativeDocumentSave() async throws
        -> PDFEditorNativeSavePreparation {
        try document.synchronizeAcroFormChangesIfNeeded(undoManager: undoManager)
        // AcroForm synchronization publishes its revision on the next main-queue
        // turn after PDFKit has committed the field editor. Let that publication
        // settle before the background save candidate captures its revision.
        await Task.yield()
        let pendingSave = try await preparePendingManualSave()
        return PDFEditorNativeSavePreparation(
            data: pendingSave.preparation.data
        ) { url in
            try await finishSuccessfulManualSave(
                pendingSave,
                at: url,
                didAdoptDestination: true
            )
            synchronizeNativeDocumentEditedState()
        }
    }

    private func synchronizeNativeDocumentEditedState() {
        nativeDocumentReference?.document?.synchronizeEditedState(
            editorState.hasUnsavedChanges || !pendingTextEditStore.edits.isEmpty
        )
    }
#endif

    private var suggestedSaveFilename: String {
        guard let saveURL else { return "Untitled" }
        let filename = saveURL.deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "Untitled" : filename
    }

#if os(macOS)
    private func writeExistingDocument(_ data: Data, to url: URL) async throws {
        let documentController = NSDocumentController.shared
        let targetURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let windowDocument = NSApp.keyWindow?.windowController?.document
        let matchingWindowDocument = windowDocument.flatMap { candidate in
            candidate.fileURL?.standardizedFileURL.resolvingSymlinksInPath() ==
                targetURL ? candidate : nil
        }
        guard let nativeDocument = matchingWindowDocument ??
                documentController.document(for: url) else {
            try ManualPDFSaveCoordinator.write(data, to: url)
            return
        }

        let previousSnapshot = document.stageManualSaveSnapshot(data)
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                nativeDocument.save(
                    to: url,
                    ofType: nativeDocument.fileType ?? UTType.pdf.identifier,
                    for: .saveOperation
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            document.restoreManualSaveSnapshot(previousSnapshot)
            throw error
        }
    }

    private func presentManualSavePanel(filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let presentingWindow = NSApp.keyWindow
        let preparationTask = Task { @MainActor in
            let pendingSave = try await preparePendingManualSave()
            try Task.checkCancellation()
            return pendingSave
        }

        let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                preparationTask.cancel()
                isSaving = false
                return
            }
            let destinationAdoption = beginDocumentDestinationAdoption(
                url,
                in: presentingWindow
            )
            Task { @MainActor in
                do {
                    let pendingSave = try await preparationTask.value
                    try ManualPDFSaveCoordinator.write(
                        pendingSave.preparation.data,
                        to: url
                    )
                    completeDocumentDestinationAdoption(
                        destinationAdoption,
                        at: url
                    )
                    try await finishSuccessfulManualSave(
                        pendingSave,
                        at: url,
                        didAdoptDestination:
                            destinationAdoption.didAdoptNativeDocument
                    )
                } catch {
                    rollbackDocumentDestinationAdoption(destinationAdoption)
                    present(error)
                }
                isSaving = false
            }
        }

        if let presentingWindow {
            panel.beginSheetModal(
                for: presentingWindow,
                completionHandler: completionHandler
            )
        } else {
            panel.begin(completionHandler: completionHandler)
        }
    }

    private func beginDocumentDestinationAdoption(
        _ url: URL,
        in window: NSWindow?
    ) -> ManualSaveDestinationAdoption {
        let documentController = NSDocumentController.shared
        let nativeDocument =
            window?.windowController?.document as? NSDocument ??
            saveURL.flatMap { documentController.document(for: $0) } ??
            documentController.currentDocument

        let previousDocumentURL = nativeDocument?.fileURL
        let previousFileModificationDate = nativeDocument?.fileModificationDate
        let previousSaveURL = saveURL
        let previousWindowTitle = window?.title
        let previousRepresentedURL = window?.representedURL

        saveURL = url
        nativeDocument?.fileURL = url
        let didAdoptNativeDocument = nativeDocument?.fileURL?
            .standardizedFileURL.resolvingSymlinksInPath() ==
            url.standardizedFileURL.resolvingSymlinksInPath()

        let adoption = ManualSaveDestinationAdoption(
            nativeDocument: nativeDocument,
            window: window,
            previousDocumentURL: previousDocumentURL,
            previousFileModificationDate: previousFileModificationDate,
            previousSaveURL: previousSaveURL,
            previousWindowTitle: previousWindowTitle,
            previousRepresentedURL: previousRepresentedURL,
            didAdoptNativeDocument: didAdoptNativeDocument
        )

        synchronizeDocumentDestination(
            window: window,
            url: url,
            title: url.lastPathComponent
        )
        return adoption
    }

    private func completeDocumentDestinationAdoption(
        _ adoption: ManualSaveDestinationAdoption,
        at url: URL
    ) {
        guard let nativeDocument = adoption.nativeDocument else { return }
        if let modificationDate = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate {
            nativeDocument.fileModificationDate = modificationDate
        }
    }

    private func rollbackDocumentDestinationAdoption(
        _ adoption: ManualSaveDestinationAdoption
    ) {
        saveURL = adoption.previousSaveURL
        adoption.nativeDocument?.fileURL = adoption.previousDocumentURL
        adoption.nativeDocument?.fileModificationDate =
            adoption.previousFileModificationDate

        if let window = adoption.window {
            window.windowController?.synchronizeWindowTitleWithDocumentName()
            window.representedURL = adoption.previousRepresentedURL
            let previousWindowTitle = adoption.previousWindowTitle ??
                adoption.previousDocumentURL?.lastPathComponent ??
                "Untitled"
            window.title = previousWindowTitle
            NSApp.changeWindowsItem(
                window,
                title: previousWindowTitle,
                filename: adoption.previousRepresentedURL != nil
            )
        }
    }

    private func synchronizeDocumentDestination(
        window: NSWindow?,
        url: URL,
        title: String
    ) {
        window?.windowController?.synchronizeWindowTitleWithDocumentName()
        guard let window else { return }
        window.representedURL = url
        window.title = title
        NSApp.changeWindowsItem(window, title: title, filename: true)
    }
#endif

    @discardableResult
    private func commitPendingTextEdits() async throws -> Data {
        let pendingSave = try await preparePendingManualSave()
        try await installPreparedTextEdits(pendingSave, markingUnsaved: true)
        return pendingSave.preparation.data
    }

    private func preparePendingManualSave() async throws -> PendingManualSave {
        let edits = pendingTextEditStore.edits.values.sorted {
            if $0.object.pageIndex != $1.object.pageIndex {
                return $0.object.pageIndex < $1.object.pageIndex
            }
            return $0.object.path.displayValue < $1.object.path.displayValue
        }
        let preparation = try await document.prepareManualSave(
            applying: edits.map {
                PDFManualTextReplacement(
                    object: $0.object,
                    text: $0.text,
                    style: $0.style
                )
            }
        )
        return PendingManualSave(preparation: preparation, edits: edits)
    }

    private func installPreparedTextEdits(
        _ pendingSave: PendingManualSave,
        markingUnsaved: Bool
    ) async throws {
        let edits = pendingSave.edits
        if pendingSave.preparation.requiresInstallation {
            try document.installPreparedManualSave(
                pendingSave.preparation,
                markingUnsaved: markingUnsaved,
                undoManager: undoManager
            )
        }
        for edit in edits {
            pendingTextEditStore.removeCommittedEdit(objectID: edit.object.id)
        }
        pendingTextEditStore.removeUndoActions(using: undoManager)
        if !edits.isEmpty {
            pageObjectCache.removeAll()
            pageObjects = []
            selectedObject = nil
            loadCanvasAnnotations()
            await Task.yield()
            loadCanvasObjects()
        }
    }

    private func finishSuccessfulManualSave(
        _ pendingSave: PendingManualSave,
        at url: URL,
        didAdoptDestination: Bool = false
    ) async throws {
        saveURL = url
        try await installPreparedTextEdits(pendingSave, markingUnsaved: false)
        document.markManuallySaved(
            data: pendingSave.preparation.data,
            updatesFileDocumentSnapshot:
                ManualPDFSaveDestinationPolicy.updatesReferenceSnapshot(
                    originalURL: documentFileURL,
                    targetURL: url,
                    didAdoptDestination: didAdoptDestination
                )
        )
    }

    private func finishManualSaveExport(_ result: Result<URL, Error>) {
        func clearExportState() {
            showsManualSaveExporter = false
            manualSaveExportDocument = nil
            pendingManualSave = nil
            isSaving = false
        }

        switch result {
        case let .success(url):
            guard let pendingManualSave else {
                clearExportState()
                return
            }
            Task { @MainActor in
                defer { clearExportState() }
                do {
                    try await finishSuccessfulManualSave(pendingManualSave, at: url)
                } catch {
                    present(error)
                }
            }
        case let .failure(error):
            defer { clearExportState() }
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == CocoaError.userCancelled.rawValue) else {
                return
            }
            present(error)
        }
    }

    private func handleToolAction(_ action: PDFToolAction) {
        cancelFormFieldPlacement()
        if action != .drawFreehand {
            freehandDrawingEnabled = false
        }
        if !action.isESignAction {
            cancelESignPlacement()
        }
        if action != .fillFormFields {
            cancelFreeTextPlacement()
        }
        switch action {
        case .addComment:
            beginCommentPlacement()
        case .editComments:
            selectedObject = nil
            loadCanvasAnnotations()
            if !usesInlinePanels {
                showsToolPanel = false
            }
            showsCommentList = true
        case .highlight:
            if !usesInlinePanels {
                showsToolPanel = false
            }
            beginHighlight()
        case .deletePage:
            guard let index = selectedPageIndex else { return }
            apply(.deletePage(at: index), name: "Delete Page")
        case .movePageEarlier:
            movePage(by: -1)
        case .movePageLater:
            movePage(by: 1)
        case .rotateLeft:
            rotate(by: -90)
        case .rotateRight:
            rotate(by: 90)
        case .combineFiles:
            beginFileImport(.mergePDF)
        case .addSignature:
            cancelESignPlacement()
            cancelCommentPlacement()
            cancelHighlightMode()
            selectedObject = nil
            selectedAnnotation = nil
            showsSignatureLibrary = true
        case .addCheckmark:
            beginESignPlacement(.mark(.checkmark))
        case .addCrossmark:
            beginESignPlacement(.mark(.crossmark))
        case .fillFormFields:
            beginFreeTextPlacement()
        case let .designForm(kind):
            if !usesInlinePanels && showsToolPanel {
                pendingFormDesignKindAfterTools = kind
                showsToolPanel = false
            } else {
                beginFormFieldPlacement(kind)
            }
        case .drawFreehand:
            commentPlacementEnabled = false
            highlightModeEnabled = false
            selectedObject = nil
            selectedAnnotation = nil
            freehandDrawingEnabled = true
            if !usesInlinePanels {
                showsToolPanel = false
            }
        case .exportImage:
            beginImageExport()
        case .protectPDF:
            beginPasswordProtection()
        case .removePassword:
            beginPasswordRemoval()
        }
    }

    private func beginPasswordProtection() {
        guard !document.isLocked else {
            present(PDFEditingError.documentLocked)
            return
        }
        guard !document.requiresDigitalSignatureConsent else {
            showsSignatureWarning = true
            return
        }
        if !usesInlinePanels {
            showsToolPanel = false
        }
        showsProtectPDF = true
    }

    private func beginPasswordRemoval() {
        guard document.isEncrypted else { return }
        guard !document.isLocked else {
            present(PDFEditingError.documentLocked)
            return
        }
        guard !document.requiresDigitalSignatureConsent else {
            showsSignatureWarning = true
            return
        }
        showsPasswordRemovalConfirmation = true
    }

    private func beginImageExport() {
        guard document.pageCount > 0 else {
            present(PDFPageImageExportError.noPages)
            return
        }
        guard !document.isLocked else {
            present(PDFEditingError.documentLocked)
            return
        }
        if !usesInlinePanels {
            showsToolPanel = false
        }
        Task { @MainActor in
            await Task.yield()
            showsImageExportOptions = true
        }
    }

    private func startImageExport(
        format: PDFPageImageFormat,
        dpi: PDFPageImageDPI,
        pageScope: PDFImageExportPageScope
    ) {
        guard imageExportTask == nil else { return }
        let pageIndices: [Int]
        switch pageScope {
        case .currentPage:
            guard let selectedPageIndex else { return }
            pageIndices = [selectedPageIndex]
        case .allPages:
            pageIndices = Array(0..<document.pageCount)
        }

        imageExportProgressCompleted = 0
        imageExportProgressTotal = pageIndices.count
        imageExportTask = Task { @MainActor in
            await Task.yield()
            isExportingImages = true
            do {
                _ = try await commitPendingTextEdits()
                let outputs = try await PDFPageImageExporter().exportPages(
                    in: document.pdfDocument,
                    pageIndices: pageIndices,
                    options: PDFPageImageExportOptions(format: format, dpi: dpi)
                ) { completed, total in
                    imageExportProgressCompleted = completed
                    imageExportProgressTotal = total
                }
                try Task.checkCancellation()
                imageExportContentType = format.contentType
                imageExportDocuments = outputs.map(ImageExportDocument.init)
                isExportingImages = false
                imageExportTask = nil
                await Task.yield()
                showsImageFileExporter = !imageExportDocuments.isEmpty
            } catch is CancellationError {
                finishImageExport()
            } catch {
                finishImageExport()
                present(error)
            }
        }
    }

    private func finishImageExport() {
        isExportingImages = false
        imageExportTask = nil
        imageExportDocuments = []
        imageExportProgressCompleted = 0
        imageExportProgressTotal = 0
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.userCancelled.rawValue
    }

    private func toggleFullScreen() {
#if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
#else
        errorMessage = "Full screen is unavailable on this platform."
#endif
    }

    private var selectedPage: PDFPage? {
        guard let selectedPageIndex else { return nil }
        return document.pdfDocument.page(at: selectedPageIndex)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    @ViewBuilder
    private var ocrResultView: some View {
        NavigationStack {
            Group {
                switch ocrResult {
                case let .existingText(text):
                    ContentUnavailableView(
                        "OCR Not Needed",
                        systemImage: "text.cursor",
                        description: Text("This page already contains selectable text:\n\(text.prefix(300))")
                    )
                case let .recognized(observations):
                    List(observations.indices, id: \.self) { index in
                        let item = observations[index]
                        VStack(alignment: .leading) {
                            Text(item.text)
                            Text("Confidence \(item.confidence.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case nil:
                    ProgressView()
                }
            }
            .navigationTitle("OCR Results")
            .toolbar {
                if let observations = recognizedOCRObservations, !observations.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Searchable Text Layer") {
                            addOCRTextLayer(observations)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsOCRResult = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var recognizedOCRObservations: [OCRTextObservation]? {
        guard case let .recognized(observations) = ocrResult else { return nil }
        return observations
    }

    @discardableResult
    private func apply(_ command: PDFEditingCommand, name: String) -> Bool {
        do {
            _ = try document.apply(command, undoManager: undoManager, actionName: name)
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func unlockDocument() {
        guard !password.isEmpty else { return }
        do {
            try document.unlock(withPassword: password)
            password = ""
        } catch { present(error) }
    }

    private func rotate(by degrees: Int) {
        guard let index = selectedPageIndex else { return }
        apply(.rotatePage(at: index, byDegrees: degrees), name: "Rotate Page")
    }

    private func movePage(by offset: Int) {
        guard let index = selectedPageIndex else { return }
        let destination = index + offset
        guard (0..<document.pageCount).contains(destination) else { return }
        apply(.movePage(from: index, to: destination), name: "Reorder Page")
        selectedPageIndex = destination
    }

    private func reorderPages(from source: IndexSet, to destination: Int) {
        var order = Array(0..<document.pageCount)
        let selectedSourceIndex = selectedPageIndex
        order.move(fromOffsets: source, toOffset: destination)
        guard apply(.reorderPages(order), name: "Reorder Pages") else { return }
        if let selectedSourceIndex {
            selectedPageIndex = order.firstIndex(of: selectedSourceIndex)
        }
    }

    private func rotatePage(at index: Int, by degrees: Int) {
        guard (0..<document.pageCount).contains(index) else { return }
        selectedPageIndex = index
        apply(.rotatePage(at: index, byDegrees: degrees), name: "Rotate Page")
    }

    private func deletePage(at index: Int) {
        guard document.pageCount > 1, (0..<document.pageCount).contains(index) else { return }
        let previousSelection = selectedPageIndex
        guard apply(.deletePage(at: index), name: "Delete Page") else { return }
        switch previousSelection {
        case index:
            selectedPageIndex = min(index, document.pageCount - 1)
        case let selected? where selected > index:
            selectedPageIndex = selected - 1
        default:
            break
        }
    }

    private func exportPage(at index: Int) {
        guard (0..<document.pageCount).contains(index) else { return }
        do {
            let result = try document.apply(
                .split(ranges: [PDFPageRange(index, through: index)]),
                undoManager: nil,
                actionName: "Split PDF"
            )
            guard case let .split(documents) = result, let data = documents.first else { return }
            let filename = "Page \(index + 1).pdf"
#if os(macOS)
            presentSinglePageSavePanel(data: data, filename: filename)
#else
            splitExportDocument = PDFExportDocument(data: data, filename: filename)
            Task { @MainActor in
                await Task.yield()
                guard splitExportDocument != nil else { return }
                showsSinglePageExporter = true
            }
#endif
        } catch { present(error) }
    }

#if os(macOS)
    private func presentSinglePageSavePanel(data: Data, filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true

        let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                present(error)
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            panel.begin(completionHandler: completionHandler)
        }
    }
#endif

    private func importPDFForMerge(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let sourceDocument = PDFDocument(data: data) else {
                throw PDFEditingError.sourceDocumentInvalid
            }
            if sourceDocument.isLocked {
                pendingMergeData = data
                pendingMergeFilename = url.lastPathComponent
            } else {
                apply(
                    .merge(documentData: data, password: nil, at: document.pageCount),
                    name: "Combine PDF"
                )
            }
        } catch { present(error) }
    }

    private func beginFileImport(_ purpose: FileImportPurpose) {
        fileImportPurpose = purpose
        if !usesInlinePanels && showsToolPanel {
            showsToolPanel = false
            Task { @MainActor in
                await Task.yield()
                showsFileImporter = true
            }
            return
        }
        showsFileImporter = true
    }

    private func beginImageReplacement(_ object: PDFPageObjectSnapshot) {
        imageReplacementTarget = object
        beginFileImport(.replaceImage)
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        if case let .failure(error) = result,
           (error as? CocoaError)?.code == .userCancelled {
            if fileImportPurpose == .replaceImage {
                imageReplacementTarget = nil
            }
            return
        }

        switch fileImportPurpose {
        case .mergePDF:
            importPDFForMerge(result)
        case .addImage:
            importImage(result)
        case .replaceImage:
            replaceImage(result)
        }
    }

    private func mergePendingPDF(password: String) throws {
        guard let pendingMergeData else {
            throw PDFEditingError.sourceDocumentInvalid
        }
        _ = try document.apply(
            .merge(
                documentData: pendingMergeData,
                password: password,
                at: document.pageCount
            ),
            undoManager: undoManager,
            actionName: "Combine Protected PDF"
        )
        self.pendingMergeData = nil
        pendingMergeFilename = "Protected PDF"
    }

    private func loadObjects() {
        guard let index = selectedPageIndex else { return }
        pageObjectLoadTask?.cancel()
        do {
            let objects = try document.pageObjects(at: index)
            pageObjectCache[index] = objects
            pageObjects = objects
        } catch {
            present(error)
        }
        showsObjectInspector = true
    }

    private func loadCanvasObjects() {
        pageObjectLoadTask?.cancel()
        guard !document.isLocked else {
            pageObjects = []
            return
        }
        guard let index = selectedPageIndex else {
            pageObjects = []
            return
        }
        let revision = editorState.revision
        if pageObjectCacheRevision != revision {
            pageObjectCache.removeAll()
            pageObjectCacheRevision = revision
        }
        let cachedObjects = pageObjectCache[index]
        pageObjects = cachedObjects ?? []

        pageObjectLoadTask = Task { @MainActor in
            var isPrefetching = false
            do {
                if cachedObjects == nil {
                    let objects = try await document.pageObjectsForDisplay(at: index)
                    try Task.checkCancellation()
                    guard selectedPageIndex == index,
                          editorState.revision == revision else { return }
                    pageObjectCache[index] = objects
                    pageObjects = objects
                }

                try Task.checkCancellation()
                guard selectedPageIndex == index,
                      editorState.revision == revision else { return }
                let nextIndex = index + 1
                guard nextIndex < document.pageCount,
                      pageObjectCache[nextIndex] == nil else { return }
                isPrefetching = true
                let prefetched = try await document.pageObjectsForDisplay(at: nextIndex)
                try Task.checkCancellation()
                guard editorState.revision == revision else { return }
                pageObjectCache[nextIndex] = prefetched
            } catch is CancellationError {
                return
            } catch let error as PDFObjectEditingError
                where error == .objectInspectionFailed {
                guard !isPrefetching,
                      selectedPageIndex == index,
                      editorState.revision == revision else { return }
                pageObjectCache[index] = []
                pageObjects = []
            } catch let error as PDFEditingError
                where error == .invalidDocument {
                // PDFKit can display some PDFs that PDFium cannot inspect. A
                // passive canvas scan must not make the document appear to
                // have failed to open; explicit object editing still reports
                // the PDFium error through loadObjects().
                guard !isPrefetching,
                      selectedPageIndex == index,
                      editorState.revision == revision else { return }
                pageObjectCache[index] = []
                pageObjects = []
            } catch {
                // Failure while prefetching the next page is not an error on
                // the page currently shown to the user.
                guard !isPrefetching,
                      selectedPageIndex == index,
                      editorState.revision == revision else { return }
                present(error)
            }
        }
    }

    private func replaceText(
        _ object: PDFPageObjectSnapshot,
        text: String,
        style: PDFTextStyle
    ) {
        pendingTextEditStore.set(
            object: object,
            text: text,
            style: style,
            undoManager: undoManager
        )
    }

    private func replaceAnnotationText(
        _ annotation: PDFAnnotationSnapshot,
        text: String,
        bounds: CGRect
    ) {
        do {
            selectedAnnotation = try document.updateAnnotation(
                annotation.reference,
                with: PDFAnnotationUpdate(
                    bounds: bounds,
                    contents: text,
                    color: nil,
                    fontColor: nil,
                    fontSize: nil,
                    lineWidth: nil
                ),
                undoManager: undoManager
            )
            loadCanvasAnnotations()
        } catch {
            present(error)
        }
    }

    private func moveObject(_ object: PDFPageObjectSnapshot, offset: CGSize) {
        do {
            try document.translateObject(
                pageIndex: object.pageIndex,
                path: object.path,
                by: offset,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            selectedObject = pageObjects.first { $0.path == object.path }
        } catch { present(error) }
    }

    private func setObjectTransform(
        _ object: PDFPageObjectSnapshot,
        transform: CGAffineTransform
    ) {
        do {
            try document.setObjectTransform(
                pageIndex: object.pageIndex,
                path: object.path,
                transform: transform,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            selectedObject = pageObjects.first { $0.path == object.path }
        } catch { present(error) }
    }

    private func scaleObject(_ object: PDFPageObjectSnapshot, factor: CGFloat) {
        let center = CGPoint(x: object.bounds.midX, y: object.bounds.midY)
        let operation = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -center.x, y: -center.y)
        setObjectTransform(
            object,
            transform: object.transform.concatenating(operation)
        )
    }

    private func rotateObject(_ object: PDFPageObjectSnapshot, radians: CGFloat) {
        let center = CGPoint(x: object.bounds.midX, y: object.bounds.midY)
        let operation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        setObjectTransform(
            object,
            transform: object.transform.concatenating(operation)
        )
    }

    private func siblingCount(for object: PDFPageObjectSnapshot) -> Int {
        let parent = object.path.indices.dropLast()
        return pageObjects.count {
            $0.pageIndex == object.pageIndex && $0.path.indices.dropLast() == parent
        }
    }

    private func deleteObject(_ object: PDFPageObjectSnapshot) {
        do {
            try document.deleteObject(
                pageIndex: object.pageIndex,
                path: object.path,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            selectedObject = nil
        } catch { present(error) }
    }

    private func addText(_ text: String) {
        guard let index = selectedPageIndex, let page = selectedPage else { return }
        let bounds = page.bounds(for: .cropBox)
        do {
            try document.addText(
                text,
                pageIndex: index,
                origin: CGPoint(x: bounds.midX - 40, y: bounds.midY),
                fontSize: 18,
                undoManager: undoManager
            )
            newText = ""
        } catch { present(error) }
    }

    private func importImage(_ result: Result<URL, Error>) {
        guard let index = selectedPageIndex, let page = selectedPage else { return }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let source = try Data(contentsOf: url)
            guard let payload = PlatformImageConverter.bitmapPayload(from: source) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let pageBounds = page.bounds(for: .cropBox)
            let maxSize = CGSize(width: 200, height: 200)
            let size: CGSize
            if payload.aspectRatio >= 1 {
                size = CGSize(width: maxSize.width, height: maxSize.width / payload.aspectRatio)
            } else {
                size = CGSize(width: maxSize.height * payload.aspectRatio, height: maxSize.height)
            }
            let bounds = CGRect(
                x: pageBounds.midX - size.width / 2,
                y: pageBounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            try document.addImage(
                payload,
                pageIndex: index,
                bounds: bounds,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: index)
        } catch { present(error) }
    }

    private func replaceImage(_ result: Result<URL, Error>) {
        guard let target = imageReplacementTarget else { return }
        defer { imageReplacementTarget = nil }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let source = try Data(contentsOf: url)
            guard let payload = PlatformImageConverter.bitmapPayload(from: source) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try document.replaceImage(
                pageIndex: target.pageIndex,
                path: target.path,
                with: payload,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: target.pageIndex)
        } catch { present(error) }
    }

    private func moveObject(_ object: PDFPageObjectSnapshot, destinationIndex: Int) {
        do {
            try document.moveObject(
                pageIndex: object.pageIndex,
                path: object.path,
                to: destinationIndex,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            var movedIndices = object.path.indices
            movedIndices[movedIndices.count - 1] = Int32(destinationIndex)
            let movedPath = PDFPageObjectPath(indices: movedIndices)
            selectedObject = pageObjects.first { $0.path == movedPath }
        } catch { present(error) }
    }

    private func addFreeText() {
        guard let page = selectedPage else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Add Text Annotation") {
                let bounds = page.bounds(for: .cropBox)
                _ = try annotationService.addFreeText(
                    text: annotationText,
                    bounds: CGRect(x: bounds.midX - 100, y: bounds.midY, width: 200, height: 60),
                    to: page
                )
            }
            annotationText = ""
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
    }

    private func beginCommentPlacement() {
        cancelFormFieldPlacement()
        guard document.pageCount > 0 else { return }
        cancelHighlightMode()
        selectedObject = nil
        selectedAnnotation = nil
        annotationText = ""
        pendingCommentPlacement = nil
        commentPlacementEnabled = true
        if !usesInlinePanels {
            showsToolPanel = false
        }
    }

    private func selectCommentPlacement(pageIndex: Int, point: CGPoint) {
        pendingCommentPlacement = PDFCommentPlacement(pageIndex: pageIndex, point: point)
        selectedPageIndex = pageIndex
        commentPlacementEnabled = false
        showsCommentPrompt = true
    }

    private func cancelCommentPlacement() {
        commentPlacementEnabled = false
        pendingCommentPlacement = nil
        annotationText = ""
    }

    private func openAnnotation(_ annotation: PDFAnnotationSnapshot) {
        guard annotation.kind == .note else { return }
        commentPlacementEnabled = false
        pendingCommentPlacement = nil
        selectedAnnotation = annotation
#if os(iOS)
        commentEditorAnnotation = annotation
#endif
    }

    private func openObject(_ object: PDFPageObjectSnapshot) {
        selectedObject = object
        switch object.kind {
        case .image:
            beginImageReplacement(object)
        case .text, .path, .form, .shading, .unknown:
            break
        }
    }

    private func addNote(at placement: PDFCommentPlacement?) {
        guard let placement,
              let page = document.pdfDocument.page(at: placement.pageIndex) else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Add Comment") {
                _ = try annotationService.addNote(
                    text: annotationText,
                    at: placement.point,
                    to: page
                )
            }
            selectedPageIndex = placement.pageIndex
            annotationText = ""
            pendingCommentPlacement = nil
            commentPlacementEnabled = false
            refreshAnnotationsIfNeeded()
        } catch {
            pendingCommentPlacement = nil
            commentPlacementEnabled = false
            present(error)
        }
    }

    private func beginHighlight() {
        cancelFormFieldPlacement()
        cancelCommentPlacement()
        guard activeHighlightSelection != nil else {
            highlightModeEnabled = true
            return
        }
        addHighlight()
    }

    private func addHighlight() {
        guard let selection = activeHighlightSelection else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Highlight Text") {
                _ = try annotationService.addHighlight(to: selection)
            }
            highlightSelectionSnapshot = nil
            highlightModeEnabled = false
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
    }

    private func cancelHighlightMode() {
        highlightModeEnabled = false
        highlightSelectionSnapshot = nil
    }

    private var activeHighlightSelection: PDFSelection? {
        validHighlightSelection(pdfSelection) ??
            validHighlightSelection(highlightSelectionSnapshot)
    }

    private func validHighlightSelection(_ selection: PDFSelection?) -> PDFSelection? {
        guard let selection,
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.pages.contains(where: { !selection.bounds(for: $0).isEmpty }) else {
            return nil
        }
        return selection
    }

    private func beginSignaturePlacement(_ template: SignatureLibraryTemplate) {
        beginESignPlacement(.signature(template))
    }

    private func beginESignPlacement(_ placement: ESignPlacement) {
        cancelFormFieldPlacement()
        showsSignatureLibrary = false
        cancelFreeTextPlacement()
        cancelCommentPlacement()
        cancelHighlightMode()
        selectedObject = nil
        selectedAnnotation = nil
        selectedESignPlacement = placement
        if !usesInlinePanels {
            showsToolPanel = false
        }
    }

    private func cancelESignPlacement() {
        selectedESignPlacement = nil
    }

    private func beginFreeTextPlacement() {
        cancelFormFieldPlacement()
        guard !document.requiresDigitalSignatureConsent else {
            showsSignatureWarning = true
            return
        }
        showsSignatureLibrary = false
        cancelESignPlacement()
        cancelCommentPlacement()
        cancelHighlightMode()
        freehandDrawingEnabled = false
        selectedObject = nil
        selectedAnnotation = nil
        freeTextPlacementEnabled = true
        if !usesInlinePanels {
            showsToolPanel = false
        }
    }

    private func cancelFreeTextPlacement() {
        freeTextPlacementEnabled = false
    }

    private func addPlacedFreeText(
        pageIndex: Int,
        bounds: CGRect,
        text: String,
        color: PDFAnnotationColor,
        fontSize: CGFloat
    ) {
        guard let page = document.pdfDocument.page(at: pageIndex) else { return }
        var newReference: PDFAnnotationReference?
        do {
            try document.mutateAnnotations(
                undoManager: undoManager,
                actionName: "Add Form Text"
            ) {
                let annotation = try annotationService.addFreeText(
                    text: text,
                    bounds: bounds,
                    fontSize: fontSize,
                    to: page
                )
                annotation.fontColor = PlatformColor(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: color.alpha
                )
                guard let annotationIndex = page.annotations.firstIndex(where: {
                    $0 === annotation
                }) else {
                    throw PDFAnnotationServiceError.annotationNotFound
                }
                newReference = PDFAnnotationReference(
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex
                )
            }
            freeTextPlacementEnabled = false
            selectedPageIndex = pageIndex
            loadCanvasAnnotations()
            if let newReference {
                selectedAnnotation = pageAnnotations.first {
                    $0.reference == newReference
                }
            }
        } catch {
            present(error)
        }
    }

    private func placeSelectedESign(pageIndex: Int, point: CGPoint) {
        guard let placement = selectedESignPlacement,
              let page = document.pdfDocument.page(at: pageIndex) else { return }
        var newReference: PDFAnnotationReference?
        do {
            try document.mutateAnnotations(
                undoManager: undoManager,
                actionName: placement.undoActionName
            ) {
                let annotation = try annotationService.addSignature(
                    strokes: placement.normalizedStrokes.map(SignatureStroke.init(points:)),
                    bounds: eSignBounds(
                        centeredAt: point,
                        preferredSize: placement.preferredSize,
                        on: page
                    ),
                    lineWidth: placement.lineWidth,
                    minimumPadding: placement.annotationPadding,
                    to: page
                )
                guard let annotationIndex = page.annotations.firstIndex(where: {
                    $0 === annotation
                }) else {
                    throw PDFAnnotationServiceError.annotationNotFound
                }
                newReference = PDFAnnotationReference(
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex
                )
            }
            guard let newReference else {
                throw PDFAnnotationServiceError.annotationNotFound
            }
            selectedESignPlacement = nil
            selectedPageIndex = pageIndex
            loadCanvasAnnotations()
            selectedAnnotation = pageAnnotations.first { $0.reference == newReference }
        } catch { present(error) }
    }

    private func eSignBounds(
        centeredAt point: CGPoint,
        preferredSize: CGSize,
        on page: PDFPage
    ) -> CGRect {
        SignaturePlacementGeometry.bounds(
            centeredAt: point,
            pageBounds: page.bounds(for: .cropBox),
            preferredSize: preferredSize
        )
    }

    private func addFreehandStroke(pageIndex: Int, points: [CGPoint]) {
        guard let page = document.pdfDocument.page(at: pageIndex) else { return }
        var newReference: PDFAnnotationReference?
        do {
            try document.mutateAnnotations(
                undoManager: undoManager,
                actionName: "Draw Freehand"
            ) {
                let annotation = try annotationService.addInkStroke(
                    points: points,
                    color: .red,
                    to: page
                )
                guard let annotationIndex = page.annotations.firstIndex(where: {
                    $0 === annotation
                }) else {
                    throw PDFAnnotationServiceError.annotationNotFound
                }
                newReference = PDFAnnotationReference(
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex
                )
            }
            guard let createdReference = newReference else {
                throw PDFAnnotationServiceError.annotationNotFound
            }
            freehandDrawingEnabled = false
            if selectedPageIndex == pageIndex {
                loadCanvasAnnotations()
                selectedAnnotation = pageAnnotations.first {
                    $0.reference == createdReference
                }
            } else {
                pendingFreehandSelectionReference = createdReference
                selectedPageIndex = pageIndex
            }
        } catch {
            present(error)
        }
    }

    private func loadAnnotations() {
        loadCanvasAnnotations()
        showsAnnotationInspector = true
    }

    private func loadCanvasAnnotations() {
        guard let pageIndex = selectedPageIndex else {
            pageAnnotations = []
            selectedAnnotation = nil
            return
        }
        do {
            pageAnnotations = try document.annotationSnapshots(onPage: pageIndex)
            if let reference = selectedAnnotation?.reference {
                selectedAnnotation = pageAnnotations.first { $0.reference == reference }
            }
        } catch { present(error) }
    }

    private func refreshAnnotationsIfNeeded() {
        loadCanvasAnnotations()
    }

    private func synchronizeAcroFormChanges() {
        do {
            try document.synchronizeAcroFormChangesIfNeeded(undoManager: undoManager)
        } catch {
            present(error)
        }
    }

    private func updateAnnotation(
        _ annotation: PDFAnnotationSnapshot,
        update: PDFAnnotationUpdate
    ) {
        do {
            selectedAnnotation = try document.updateAnnotation(
                annotation.reference,
                with: update,
                undoManager: undoManager
            )
        } catch { present(error) }
    }

    private func setFormFieldBounds(_ field: PDFFormDesignField, bounds: CGRect) {
        do {
            selectedFormField = try document.resizeAuthoredFormField(
                id: field.id, bounds: bounds, undoManager: undoManager
            )
        } catch { present(error) }
    }

    private func setFormFieldFontSize(
        _ field: PDFFormDesignField, fontSize: CGFloat
    ) {
        guard field.kind == .text || field.kind.isChoice,
              abs(field.fontSize - fontSize) > 0.01 else { return }
        do {
            selectedFormField = try document.setAuthoredFormFieldFontSize(
                id: field.id, fontSize: fontSize, undoManager: undoManager
            )
        } catch { present(error) }
    }

    private func deleteFormField(_ field: PDFFormDesignField) {
        do {
            try document.deleteAuthoredFormField(
                id: field.id, undoManager: undoManager
            )
            selectedFormField = nil
        } catch { present(error) }
    }

    private func setAnnotationBounds(_ annotation: PDFAnnotationSnapshot, bounds: CGRect) {
        updateAnnotation(
            annotation,
            update: .bounds(clampedAnnotationBounds(bounds, pageIndex: annotation.reference.pageIndex))
        )
    }

    private func clampedAnnotationBounds(_ bounds: CGRect, pageIndex: Int) -> CGRect {
        guard let page = document.pdfDocument.page(at: pageIndex) else { return bounds }
        let pageBounds = page.bounds(for: .cropBox).standardized
        let standardized = bounds.standardized
        let maximumX = max(pageBounds.minX, pageBounds.maxX - standardized.width)
        let maximumY = max(pageBounds.minY, pageBounds.maxY - standardized.height)
        return CGRect(
            x: min(max(standardized.minX, pageBounds.minX), maximumX),
            y: min(max(standardized.minY, pageBounds.minY), maximumY),
            width: standardized.width,
            height: standardized.height
        )
    }

    private func nudgeAnnotation(
        _ annotation: PDFAnnotationSnapshot,
        dx: CGFloat,
        dy: CGFloat
    ) {
        setAnnotationBounds(annotation, bounds: annotation.bounds.offsetBy(dx: dx, dy: dy))
    }

    private func scaleAnnotation(_ annotation: PDFAnnotationSnapshot, factor: CGFloat) {
        let bounds = annotation.bounds
        let resized = CGRect(
            x: bounds.midX - bounds.width * factor / 2,
            y: bounds.midY - bounds.height * factor / 2,
            width: bounds.width * factor,
            height: bounds.height * factor
        )
        setAnnotationBounds(annotation, bounds: resized)
    }

    private func deleteAnnotation(_ annotation: PDFAnnotationSnapshot) {
        do {
            try document.deleteAnnotation(annotation.reference, undoManager: undoManager)
            selectedAnnotation = nil
            loadCanvasAnnotations()
        } catch { present(error) }
    }

    private func runOCR() {
        guard let pageIndex = selectedPageIndex,
              let page = document.pdfDocument.page(at: pageIndex) else { return }
        let context = OCRRunContext(
            pageIndex: pageIndex,
            documentRevision: editorState.revision
        )
        ocrRunContext = context
        isRunningOCR = true
        Task {
            defer { isRunningOCR = false }
            do {
                let result = try await ocrService.recognizeText(on: page)
                guard context.isCurrent(documentRevision: editorState.revision) else {
                    throw VisionOCRError.documentChanged
                }
                ocrResult = result
                showsOCRResult = true
            } catch { present(error) }
        }
    }

    private func runDocumentOCR() {
        guard document.pageCount > 0 else { return }
        ocrBatchTask?.cancel()
        ocrProgressCompleted = 0
        ocrProgressTotal = document.pageCount
        isRunningOCR = true
        showsOCRProgress = true
        let context = OCRRunContext(
            pageIndices: Array(0..<document.pageCount),
            documentRevision: editorState.revision
        )
        ocrBatchRunContext = context

        ocrBatchTask = Task {
            defer {
                isRunningOCR = false
                showsOCRProgress = false
                ocrBatchTask = nil
            }
            do {
                let result = try await ocrService.recognizePages(
                    in: document.pdfDocument,
                    pageIndices: context.pageIndices
                ) { completed, total in
                    ocrProgressCompleted = completed
                    ocrProgressTotal = total
                }
                try Task.checkCancellation()
                guard context.isCurrent(documentRevision: editorState.revision) else {
                    throw VisionOCRError.documentChanged
                }
                showsOCRProgress = false
                await Task.yield()
                ocrBatchResult = result
            } catch is CancellationError {
                // Cancellation leaves the PDF untouched because text layers are added only after review.
            } catch {
                present(error)
            }
        }
    }

    private func addOCRTextLayer(_ observations: [OCRTextObservation]) {
        do {
            guard let context = ocrRunContext,
                  let pageIndex = context.singlePageIndex else { return }
            guard context.isCurrent(documentRevision: editorState.revision) else {
                throw VisionOCRError.documentChanged
            }
            try document.addOCRTextLayer(
                observations,
                pageIndex: pageIndex,
                undoManager: undoManager
            )
            showsOCRResult = false
        } catch {
            present(error)
        }
    }

    private func addOCRTextLayers(_ result: OCRBatchResult) {
        do {
            guard let context = ocrBatchRunContext else { return }
            guard context.isCurrent(documentRevision: editorState.revision) else {
                throw VisionOCRError.documentChanged
            }
            try document.addOCRTextLayers(
                result.recognizedPages,
                undoManager: undoManager
            )
            ocrBatchResult = nil
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        if let editingError = error as? PDFEditingError,
           editingError == .digitalSignatureConsentRequired {
            showsSignatureWarning = true
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PhaseFiveWorkflowModifier: ViewModifier {
    @Binding var ocrBatchResult: OCRBatchResult?
    @Binding var showsOCRProgress: Bool
    let ocrProgressCompleted: Int
    let ocrProgressTotal: Int
    @Binding var pendingMergeData: Data?
    @Binding var pendingMergeFilename: String
    let onCancelOCR: () -> Void
    let onAddOCRTextLayers: (OCRBatchResult) -> Void
    let onMergeProtectedPDF: (String) throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsOCRProgress) {
                NavigationStack {
                    VStack(spacing: 18) {
                        ProgressView(
                            value: Double(ocrProgressCompleted),
                            total: Double(max(ocrProgressTotal, 1))
                        )
                        Text("Checked \(ocrProgressCompleted) of \(ocrProgressTotal) pages")
                            .foregroundStyle(.secondary)
                        Text("Pages that already contain selectable text are skipped automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .navigationTitle("Recognizing Scanned Pages")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancelOCR)
                        }
                    }
                }
                .frame(minWidth: 400, minHeight: 220)
                .interactiveDismissDisabled()
            }
            .sheet(
                isPresented: Binding(
                    get: { ocrBatchResult != nil },
                    set: { if !$0 { ocrBatchResult = nil } }
                )
            ) {
                if let ocrBatchResult {
                    OCRBatchResultView(result: ocrBatchResult) {
                        onAddOCRTextLayers(ocrBatchResult)
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { pendingMergeData != nil },
                    set: {
                        if !$0 {
                            pendingMergeData = nil
                            pendingMergeFilename = "Protected PDF"
                        }
                    }
                )
            ) {
                ProtectedPDFMergeView(filename: pendingMergeFilename) { password in
                    try onMergeProtectedPDF(password)
                }
            }
    }
}
