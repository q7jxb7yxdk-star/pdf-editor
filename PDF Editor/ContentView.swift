import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
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

    @Environment(\.undoManager) private var environmentUndoManager

    @StateObject private var pendingTextEditStore = PendingTextEditStore()
    @State private var selectedPageIndex: Int? = 0
    @State private var pdfSelection: PDFSelection?
    @State private var highlightSelectionSnapshot: PDFSelection?
    @State private var highlightModeEnabled = false
    @State private var password = ""
    @State private var annotationText = ""
    @State private var errorMessage: String?
    @State private var pageObjects: [PDFPageObjectSnapshot] = []
    @State private var pageObjectCache: [Int: [PDFPageObjectSnapshot]] = [:]
    @State private var pageObjectCacheRevision = -1
    @State private var pageObjectLoadTask: Task<Void, Never>?
    @State private var selectedObject: PDFPageObjectSnapshot?
    private let objectEditingEnabled = true
    @State private var ocrResult: OCRPageResult?
    @State private var ocrBatchResult: OCRBatchResult?
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
    @State private var pendingManualSaveData: Data?
    @State private var saveURL: URL?
    @State private var isSaving = false
    @State private var pageAnnotations: [PDFAnnotationSnapshot] = []
    @State private var selectedAnnotation: PDFAnnotationSnapshot?
    private let annotationEditingEnabled = true
    @State private var newText = ""
    @State private var showsFileImporter = false
    @State private var fileImportPurpose: FileImportPurpose = .mergePDF
    @State private var imageReplacementTarget: PDFPageObjectSnapshot?
    @State private var showsObjectInspector = false
    @State private var showsSignaturePad = false
    @State private var showsOCRResult = false
    @State private var showsSignatureWarning = false
    @State private var showsPasswordRemovalConfirmation = false
    @State private var showsAddTextPrompt = false
    @State private var showsAnnotationInspector = false
    @State private var replacementNotice: String?
    @State private var pendingMergeData: Data?
    @State private var pendingMergeFilename = "Protected PDF"
    @State private var viewerMode: PDFViewerMode = .scrolling
    @State private var viewerCommand: PDFViewerCommand?
    @State private var unavailableTool: String?
    @State private var showsCommentPrompt = false
    @State private var showsCommentList = false
    @State private var commentEditorAnnotation: PDFAnnotationSnapshot?
    @State private var commentPlacementEnabled = false
    @State private var freehandDrawingEnabled = false
    @State private var pendingFreehandSelectionReference: PDFAnnotationReference?
    @State private var pendingCommentPlacement: PDFCommentPlacement?
    @State private var showsToolPanel = false
    @State private var showsPagePanel = false
    @State private var usesInlinePanels = false

    private let annotationService = PDFAnnotationService()
    private let ocrService = VisionOCRService()

    init(document: PDFEditorDocument, fileURL: URL?) {
        self.document = document
        _editorState = ObservedObject(wrappedValue: document.editorState)
        _saveURL = State(initialValue: fileURL)
    }

    private var undoManager: UndoManager? {
        environmentUndoManager
    }

    private var canSave: Bool {
        !isSaving && (
            editorState.hasUnsavedChanges || !pendingTextEditStore.edits.isEmpty || saveURL == nil
        )
    }

    var body: some View {
        fileTransferView
            .focusedValue(\.manualPDFSaveAction, saveDocument)
            .task {
                await document.prepareEditingSessionForInteraction()
            }
            .onDisappear {
                ocrBatchTask?.cancel()
                imageExportTask?.cancel()
                pageObjectLoadTask?.cancel()
            }
    }

    private var editorRoot: some View {
        GeometryReader { proxy in
            if proxy.size.width >= (showsCommentList ? 1180 : 900) {
                HStack(spacing: 0) {
                    if showsToolPanel {
                        toolSidebar
                            .frame(width: 270)
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
                    Divider()
                    rightPanel
                        .frame(width: 52)
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
                    Divider()
                    rightPanel
                        .frame(width: 52)
                }
                .onAppear { usesInlinePanels = false }
                .sheet(isPresented: $showsToolPanel) {
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
        .toolbar { adaptiveToolbar }
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
        .alert("Remove PDF Password Protection?", isPresented: $showsPasswordRemovalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove When Saving", role: .destructive) {
                document.setRemovesPasswordProtectionOnSave(true)
            }
        } message: {
            Text("The next save will create a PDF that no longer requires a password. The original is replaced only if you save over it.")
        }
        .alert("Add Text", isPresented: $showsAddTextPrompt) {
            TextField("Text", text: $newText)
            Button("Cancel", role: .cancel) { newText = "" }
            Button("Add") { addText(newText) }
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Text will be added to the center of the current page. You can move or edit it from the PDF Objects panel.")
        }
        .alert("Safe Replacement Text Layer Used", isPresented: Binding(
            get: { replacementNotice != nil },
            set: { if !$0 { replacementNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(replacementNotice ?? "")
        }
        .alert("Feature unavailable", isPresented: Binding(
            get: { unavailableTool != nil },
            set: { if !$0 { unavailableTool = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(unavailableTool ?? "This tool") is visible in the workspace, but its PDF processing workflow has not been implemented yet.")
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
        .sheet(isPresented: $showsSignaturePad) {
            SignaturePadView(onSave: addSignature)
        }
        .sheet(isPresented: $showsAnnotationInspector) {
            AnnotationInspectorView(
                annotations: pageAnnotations,
                selectedAnnotation: $selectedAnnotation,
                onApply: updateAnnotation,
                onDelete: deleteAnnotation
            )
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
            isPresented: Binding(
                get: { manualSaveExportDocument != nil },
                set: {
                    if !$0 {
                        manualSaveExportDocument = nil
                    }
                }
            ),
            document: manualSaveExportDocument,
            contentType: .pdf,
            defaultFilename: "Untitled"
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
                    objectEditingEnabled: objectEditingEnabled,
                    onTranslateObject: moveObject,
                    onSetObjectTransform: setObjectTransform,
                    annotations: pageAnnotations,
                    selectedAnnotation: $selectedAnnotation,
                    annotationEditingEnabled: annotationEditingEnabled,
                    onSetAnnotationBounds: setAnnotationBounds,
                    commentPlacementEnabled: commentPlacementEnabled,
                    onPlaceComment: selectCommentPlacement,
                    freehandDrawingEnabled: freehandDrawingEnabled,
                    onAddFreehand: addFreehandStroke,
                    onReplaceTextObject: replaceText,
                    onReplaceAnnotationText: replaceAnnotationText,
                    onUpdateAnnotation: updateAnnotation,
                    onDeleteAnnotation: deleteAnnotation,
                    onOpenObject: openObject,
                    onOpenAnnotation: openAnnotation,
                    viewerMode: viewerMode,
                    viewerCommand: viewerCommand
                )
                .ignoresSafeArea(.container, edges: .bottom)

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

                if freehandDrawingEnabled {
                    HStack(spacing: 12) {
                        Label(
                            "Draw anywhere on the PDF, then release to finish.",
                            systemImage: "pencil.and.outline"
                        )
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

    private var toolSidebar: some View {
        PDFToolSidebar(
            pageCount: document.pageCount,
            hasSelectedPage: selectedPageIndex != nil,
            onAction: handleToolAction
        )
    }

    private var rightPanel: some View {
        PDFRightPanel(
            viewerMode: $viewerMode,
            selectedPageIndex: $selectedPageIndex,
            pageCount: document.pageCount,
            isPagesPanelPresented: showsPagePanel,
            onTogglePages: togglePagePanel,
            onViewerCommand: { viewerCommand = PDFViewerCommand(action: $0) },
            onFullScreen: toggleFullScreen
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

    @ToolbarContentBuilder
    private var adaptiveToolbar: some ToolbarContent {
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
        }
        if !showsToolPanel {
            showsCommentList = false
        }
    }

    private func togglePagePanel() {
        withAnimation {
            showsPagePanel.toggle()
            if showsPagePanel {
                showsToolPanel = false
                showsCommentList = false
            }
        }
    }

    private func saveDocument() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            await Task.yield()
            do {
                try commitPendingTextEdits()
                let data = try document.dataForManualSave()
                if let saveURL {
                    try ManualPDFSaveCoordinator.write(data, to: saveURL)
                    document.markManuallySaved(data: data)
                    isSaving = false
                } else {
                    pendingManualSaveData = data
                    manualSaveExportDocument = PDFExportDocument(
                        data: data,
                        filename: "Untitled.pdf"
                    )
                }
            } catch {
                isSaving = false
                present(error)
            }
        }
    }

    private func commitPendingTextEdits() throws {
        let edits = pendingTextEditStore.edits.values.sorted {
            if $0.object.pageIndex != $1.object.pageIndex {
                return $0.object.pageIndex < $1.object.pageIndex
            }
            return $0.object.path.displayValue < $1.object.path.displayValue
        }
        for edit in edits {
            try commitTextReplacement(edit.object, text: edit.text, style: edit.style)
            pendingTextEditStore.removeCommittedEdit(objectID: edit.object.id)
        }
        pendingTextEditStore.removeUndoActions(using: undoManager)
    }

    private func finishManualSaveExport(_ result: Result<URL, Error>) {
        defer {
            manualSaveExportDocument = nil
            pendingManualSaveData = nil
            isSaving = false
        }

        switch result {
        case let .success(url):
            guard let pendingManualSaveData else { return }
            saveURL = url
            document.markManuallySaved(data: pendingManualSaveData)
        case let .failure(error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == CocoaError.userCancelled.rawValue) else {
                return
            }
            present(error)
        }
    }

    private func handleToolAction(_ action: PDFToolAction) {
        if action != .drawFreehand {
            freehandDrawingEnabled = false
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
            showsSignaturePad = true
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
        case .createSignTemplate:
            showUnavailable("Create e-sign template")
        case .createWebForm:
            showUnavailable("Create a web form")
        case .sendInBulk:
            showUnavailable("Send in bulk")
        case .addSignBranding:
            showUnavailable("Add e-sign branding")
        case .protectPDF:
            showUnavailable("Protect PDF")
        case .redactPDF:
            showUnavailable("Redact PDF")
        }
    }

    private func showUnavailable(_ tool: String) {
        unavailableTool = tool
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
                try commitPendingTextEdits()
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
        showUnavailable("Full screen")
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
                let prefetched = try await document.pageObjectsForDisplay(at: nextIndex)
                try Task.checkCancellation()
                guard editorState.revision == revision else { return }
                pageObjectCache[nextIndex] = prefetched
            } catch is CancellationError {
                return
            } catch {
                guard selectedPageIndex == index,
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

    private func commitTextReplacement(
        _ object: PDFPageObjectSnapshot,
        text: String,
        style: PDFTextStyle
    ) throws {
        do {
            let result = try document.replaceText(
                pageIndex: object.pageIndex,
                path: object.path,
                with: text,
                style: style,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            loadCanvasAnnotations()
            switch result {
            case let .usedCoreTextFallback(originalFontName):
                replacementNotice = if let originalFontName {
                    "The original font \(originalFontName) does not contain every required glyph or the text needs complex shaping. A searchable CoreText vector layer was used instead."
                } else {
                    "The original PDF font cannot safely render this text. A searchable CoreText vector layer was used instead."
                }
            case .usedStyledCoreTextOverlay:
                replacementNotice = "Bold or italic formatting was saved as searchable PDF text."
            case let .usedAppearanceSafeAnnotationFallback(originalFontName):
                replacementNotice = if let originalFontName {
                    "This page cannot safely regenerate its color resources. An editable FreeText layer replaced the \(originalFontName) text, and the original page colors were preserved."
                } else {
                    "This page cannot safely regenerate its color resources. An editable FreeText layer was used, and the original page colors were preserved."
                }
            case .preservedOriginalFont:
                replacementNotice = nil
            }
        } catch {
            throw error
        }
    }

    private func replaceAnnotationText(
        _ annotation: PDFAnnotationSnapshot,
        text: String
    ) {
        do {
            let fontSize = max(annotation.fontSize ?? annotation.bounds.height / 1.8, 6)
            var bounds = annotation.bounds
            bounds.size.width = max(
                bounds.width,
                fontSize * 0.72 * CGFloat(max(text.count, 1)) + fontSize
            )
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

    private func addSignature(_ strokes: [SignatureStroke]) {
        guard let page = selectedPage else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Add Signature") {
                let bounds = page.bounds(for: .cropBox)
                _ = try annotationService.addSignature(
                    strokes: strokes,
                    bounds: CGRect(x: bounds.midX - 100, y: bounds.midY - 40, width: 200, height: 80),
                    to: page
                )
            }
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
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
        guard let page = selectedPage else { return }
        isRunningOCR = true
        Task {
            defer { isRunningOCR = false }
            do {
                ocrResult = try await ocrService.recognizeText(on: page)
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

        ocrBatchTask = Task {
            defer {
                isRunningOCR = false
                showsOCRProgress = false
                ocrBatchTask = nil
            }
            do {
                let result = try await ocrService.recognizePages(
                    in: document.pdfDocument,
                    pageIndices: Array(0..<document.pageCount)
                ) { completed, total in
                    ocrProgressCompleted = completed
                    ocrProgressTotal = total
                }
                try Task.checkCancellation()
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
        guard let pageIndex = selectedPageIndex else { return }
        do {
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
