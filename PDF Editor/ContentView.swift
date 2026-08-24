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

struct ContentView: View {
    @ObservedObject var document: PDFEditorDocument

    @Environment(\.undoManager) private var undoManager
    @State private var selectedPageIndex: Int? = 0
    @State private var pdfSelection: PDFSelection?
    @State private var password = ""
    @State private var annotationText = ""
    @State private var errorMessage: String?
    @State private var pageObjects: [PDFPageObjectSnapshot] = []
    @State private var selectedObject: PDFPageObjectSnapshot?
    @State private var objectEditingEnabled = false
    @State private var ocrResult: OCRPageResult?
    @State private var ocrBatchResult: OCRBatchResult?
    @State private var ocrBatchTask: Task<Void, Never>?
    @State private var ocrProgressCompleted = 0
    @State private var ocrProgressTotal = 0
    @State private var isRunningOCR = false
    @State private var showsOCRProgress = false
    @State private var splitExportDocument: PDFExportDocument?
    @State private var splitExportDocuments: [PDFExportDocument] = []
    @State private var pageAnnotations: [PDFAnnotationSnapshot] = []
    @State private var selectedAnnotation: PDFAnnotationSnapshot?
    @State private var annotationEditingEnabled = false
    @State private var newText = ""
    @State private var selectedTextDraft = ""
    @State private var showsFileImporter = false
    @State private var fileImportPurpose: FileImportPurpose = .mergePDF
    @State private var imageReplacementTarget: PDFPageObjectSnapshot?
    @State private var showsObjectInspector = false
    @State private var showsSignaturePad = false
    @State private var showsOCRResult = false
    @State private var showsSignatureWarning = false
    @State private var showsPasswordRemovalConfirmation = false
    @State private var showsAddTextPrompt = false
    @State private var showsSelectedTextPrompt = false
    @State private var showsAnnotationInspector = false
    @State private var replacementNotice: String?
    @State private var pendingMergeData: Data?
    @State private var pendingMergeFilename = "Protected PDF"
    @State private var viewerMode: PDFViewerMode = .scrolling
    @State private var viewerCommand: PDFViewerCommand?
    @State private var unavailableTool: String?
    @State private var showsCommentPrompt = false
    @State private var showsToolPanel = false
    @State private var showsViewPanel = false

    private let annotationService = PDFAnnotationService()
    private let ocrService = VisionOCRService()

    var body: some View {
        fileTransferView
            .onDisappear { ocrBatchTask?.cancel() }
    }

    private var editorRoot: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 900 {
                HStack(spacing: 0) {
                    toolSidebar
                        .frame(width: 270)
                    Divider()
                    documentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    rightPanel
                        .frame(width: 220)
                }
            } else {
                documentView
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
                    .sheet(isPresented: $showsViewPanel) {
                        NavigationStack {
                            rightPanel
                                .navigationTitle("View")
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { showsViewPanel = false }
                                    }
                                }
                        }
                        .frame(minWidth: 280, minHeight: 520)
                    }
            }
        }
        .toolbar { adaptiveToolbar }
        .onChange(of: document.pageCount, initial: true) { _, pageCount in
            guard pageCount > 0 else {
                selectedPageIndex = nil
                return
            }
            if let selectedPageIndex, selectedPageIndex < pageCount { return }
            selectedPageIndex = 0
        }
        .onChange(of: selectedPageIndex) { _, _ in
            selectedObject = nil
            selectedAnnotation = nil
            if objectEditingEnabled { loadCanvasObjects() }
            if annotationEditingEnabled { loadCanvasAnnotations() }
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
        .alert("Edit Existing Text", isPresented: $showsSelectedTextPrompt) {
            TextField("Text", text: $selectedTextDraft)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                guard let selectedObject else { return }
                replaceText(selectedObject, text: selectedTextDraft)
            }
        } message: {
            Text("The editor first tries to preserve the original font. A CoreText replacement layer is used only for missing glyphs or complex shaping.")
        }
        .alert("Safe Replacement Text Layer Used", isPresented: Binding(
            get: { replacementNotice != nil },
            set: { if !$0 { replacementNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(replacementNotice ?? "")
        }
        .alert("Add a comment", isPresented: $showsCommentPrompt) {
            TextField("Comment", text: $annotationText)
            Button("Cancel", role: .cancel) { annotationText = "" }
            Button("Add") { addNote() }
                .disabled(annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The comment will be placed near the center of the current page.")
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
        .sheet(isPresented: $showsOCRResult) { ocrResultView }
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
                get: { splitExportDocument != nil },
                set: { if !$0 { splitExportDocument = nil } }
            ),
            document: splitExportDocument,
            contentType: .pdf,
            defaultFilename: "PDF Split"
        ) { result in
            if case let .failure(error) = result { present(error) }
            splitExportDocument = nil
        }
        .fileExporter(
            isPresented: Binding(
                get: { !splitExportDocuments.isEmpty },
                set: { if !$0 { splitExportDocuments = [] } }
            ),
            documents: splitExportDocuments,
            contentType: .pdf
        ) { result in
            if case let .failure(error) = result { present(error) }
            splitExportDocuments = []
        }
    }

    private var pageSidebar: some View {
        List(selection: $selectedPageIndex) {
            ForEach(0..<document.pageCount, id: \.self) { index in
                if let page = document.pdfDocument.page(at: index) {
                    PageThumbnailView(page: page, pageNumber: index + 1).tag(index)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 240)
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
            PDFKitView(
                document: document.pdfDocument,
                selectedPageIndex: $selectedPageIndex,
                selection: $pdfSelection,
                objects: pageObjects,
                selectedObject: $selectedObject,
                objectEditingEnabled: objectEditingEnabled,
                onTranslateObject: moveObject,
                onSetObjectTransform: setObjectTransform,
                annotations: pageAnnotations,
                selectedAnnotation: $selectedAnnotation,
                annotationEditingEnabled: annotationEditingEnabled,
                onSetAnnotationBounds: setAnnotationBounds,
                viewerMode: viewerMode,
                viewerCommand: viewerCommand
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var toolSidebar: some View {
        PDFToolSidebar(
            pageCount: document.pageCount,
            hasSelectedPage: selectedPageIndex != nil,
            hasTextSelection: pdfSelection != nil,
            onAction: handleToolAction
        )
    }

    private var rightPanel: some View {
        PDFRightPanel(
            page: selectedPage,
            pageCount: document.pageCount,
            selectedPageIndex: $selectedPageIndex,
            viewerMode: $viewerMode,
            onViewerCommand: { viewerCommand = PDFViewerCommand(action: $0) },
            onAddComment: { showsCommentPrompt = true },
            onFullScreen: toggleFullScreen
        )
    }

    @ToolbarContentBuilder
    private var adaptiveToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showsToolPanel = true } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            Button { showsViewPanel = true } label: {
                Label("View", systemImage: "sidebar.right")
            }
            Button {
                objectEditingEnabled.toggle()
                annotationEditingEnabled = false
                selectedAnnotation = nil
                selectedObject = nil
                if objectEditingEnabled { loadCanvasObjects() }
            } label: {
                Label(
                    objectEditingEnabled ? "Finish object editing" : "Edit PDF objects",
                    systemImage: objectEditingEnabled ? "cursorarrow.rays" : "cursorarrow.click"
                )
            }
            Button {
                annotationEditingEnabled.toggle()
                objectEditingEnabled = false
                selectedObject = nil
                selectedAnnotation = nil
                if annotationEditingEnabled { loadCanvasAnnotations() }
            } label: {
                Label(
                    annotationEditingEnabled ? "Finish annotation editing" : "Edit annotations",
                    systemImage: annotationEditingEnabled ? "pencil.line" : "pencil.tip.crop.circle"
                )
            }
            Menu {
                Button("Recognize current page", action: runOCR)
                    .disabled(selectedPage == nil)
                Button("Recognize all scanned pages", action: runDocumentOCR)
                    .disabled(document.pageCount == 0)
            } label: {
                Label("OCR", systemImage: "viewfinder")
            }
            .disabled(isRunningOCR)
        }
    }

    private func handleToolAction(_ action: PDFToolAction) {
        switch action {
        case .addComment:
            showsCommentPrompt = true
        case .highlight:
            addHighlight()
        case .deletePage:
            guard let index = selectedPageIndex else { return }
            apply(.deletePage(at: index), name: "Delete Page")
        case .extractPage:
            exportSelectedPage()
        case .movePageEarlier:
            movePage(by: -1)
        case .movePageLater:
            movePage(by: 1)
        case .rotateLeft:
            rotate(by: -90)
        case .rotateRight:
            rotate(by: 90)
        case .insertPage:
            let insertionIndex = min((selectedPageIndex ?? document.pageCount - 1) + 1, document.pageCount)
            apply(.insertBlankPage(at: insertionIndex, size: .a4), name: "Insert Page")
            selectedPageIndex = insertionIndex
        case .combineFiles:
            beginFileImport(.mergePDF)
        case .splitPDF:
            splitEveryPage()
        case .fillAndSign, .addSignature:
            showsSignaturePad = true
        case .drawFreehand:
            showsSignaturePad = true
        case .eraseDrawing:
            loadAnnotations()
        case .cropPage:
            showUnavailable("Crop")
        case .numberPages:
            showUnavailable("Number Pages")
        case .compressPDF:
            showUnavailable("Compress PDF")
        case .exportWord:
            showUnavailable("Microsoft Word export")
        case .exportExcel:
            showUnavailable("Microsoft Excel export")
        case .exportPowerPoint:
            showUnavailable("Microsoft PowerPoint export")
        case .exportImage:
            showUnavailable("Image format export")
        case .requestSignatures:
            showUnavailable("Request e-signatures")
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

    private func toggleFullScreen() {
#if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
#else
        showUnavailable("Full screen")
#endif
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                apply(.insertBlankPage(at: document.pageCount, size: .a4), name: "Insert Page")
            } label: {
                Label("Insert Page", systemImage: "plus")
            }
            Button(role: .destructive) {
                guard let index = selectedPageIndex else { return }
                apply(.deletePage(at: index), name: "Delete Page")
            } label: {
                Label("Delete Page", systemImage: "trash")
            }
            .disabled(document.pageCount <= 1 || selectedPageIndex == nil)
        }
    }

    @ToolbarContentBuilder
    private var editingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Rotate Left") { rotate(by: -90) }
                Button("Rotate Right") { rotate(by: 90) }
                Divider()
                Button("Move Page Earlier") { movePage(by: -1) }
                Button("Move Page Later") { movePage(by: 1) }
                Divider()
                Button("Combine Another PDF…") { beginFileImport(.mergePDF) }
                Button("Extract Current Page…") { exportSelectedPage() }
                Button("Split into Individual Pages…") { splitEveryPage() }
            } label: {
                Label("Page Tools", systemImage: "rectangle.stack")
            }
            Menu {
                Button("Inspect and Edit Existing Objects…") { loadObjects() }
                Button("Add Text") { showsAddTextPrompt = true }
                Button("Add Image…") { beginFileImport(.addImage) }
            } label: {
                Label("Content Tools", systemImage: "textformat")
            }
            Button {
                objectEditingEnabled.toggle()
                annotationEditingEnabled = false
                selectedAnnotation = nil
                selectedObject = nil
                if objectEditingEnabled { loadCanvasObjects() }
            } label: {
                Label(
                    objectEditingEnabled ? "Finish Object Editing" : "Edit Objects Directly",
                    systemImage: objectEditingEnabled ? "cursorarrow.rays" : "cursorarrow.click"
                )
            }
            Button {
                annotationEditingEnabled.toggle()
                objectEditingEnabled = false
                selectedObject = nil
                selectedAnnotation = nil
                if annotationEditingEnabled { loadCanvasAnnotations() }
            } label: {
                Label(
                    annotationEditingEnabled ? "Finish Annotation Editing" : "Edit Annotations Directly",
                    systemImage: annotationEditingEnabled ? "pencil.line" : "pencil.tip.crop.circle"
                )
            }
            if annotationEditingEnabled, let selectedAnnotation {
                Menu {
                    Button("Move Left 5 pt") { nudgeAnnotation(selectedAnnotation, dx: -5, dy: 0) }
                    Button("Move Right 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 5, dy: 0) }
                    Button("Move Up 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 0, dy: 5) }
                    Button("Move Down 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 0, dy: -5) }
                    Divider()
                    Button("Enlarge 10%") { scaleAnnotation(selectedAnnotation, factor: 1.1) }
                    Button("Reduce 10%") { scaleAnnotation(selectedAnnotation, factor: 0.9) }
                    Divider()
                    Button("Edit Properties…") { showsAnnotationInspector = true }
                    Button("Delete", role: .destructive) { deleteAnnotation(selectedAnnotation) }
                } label: {
                    Label("Selected Annotation", systemImage: "square.dashed.inset.filled")
                }
            }
            if objectEditingEnabled, let selectedObject {
                Menu {
                    if selectedObject.kind == .text {
                        Button("Edit Text…") {
                            selectedTextDraft = selectedObject.text ?? ""
                            showsSelectedTextPrompt = true
                        }
                    }
                    if selectedObject.kind == .image {
                        Button("Replace Image…") { beginImageReplacement(selectedObject) }
                    }
                    Divider()
                    Button("Enlarge 10%") { scaleObject(selectedObject, factor: 1.1) }
                    Button("Reduce 10%") { scaleObject(selectedObject, factor: 0.9) }
                    Button("Rotate Left 15°") { rotateObject(selectedObject, radians: .pi / 12) }
                    Button("Rotate Right 15°") { rotateObject(selectedObject, radians: -.pi / 12) }
                    Divider()
                    Button("Bring to Front") {
                        moveObject(selectedObject, destinationIndex: siblingCount(for: selectedObject) - 1)
                    }
                    Button("Send to Back") { moveObject(selectedObject, destinationIndex: 0) }
                    Divider()
                    Button("Delete", role: .destructive) { deleteObject(selectedObject) }
                } label: {
                    Label("Selected Object", systemImage: "square.dashed")
                }
            }
            Menu {
                TextField("Annotation text", text: $annotationText)
                Button("Add Text Annotation") { addFreeText() }
                Button("Add Comment") { addNote() }
                Button("Highlight Selected Text") { addHighlight() }
                    .disabled(pdfSelection == nil)
                Button("Handwritten Signature…") { showsSignaturePad = true }
                Button("Manage Page Annotations…") { loadAnnotations() }
            } label: {
                Label("Annotations and Signatures", systemImage: "pencil.and.scribble")
            }
            Menu {
                Button("Recognize Current Page", action: runOCR)
                    .disabled(selectedPage == nil)
                Button("Recognize All Scanned Pages", action: runDocumentOCR)
                    .disabled(document.pageCount == 0)
            } label: {
                Label("OCR", systemImage: "viewfinder")
            }
            .disabled(isRunningOCR)
            if document.isEncrypted && !document.isLocked {
                Toggle(
                    "Remove Password When Saving",
                    isOn: Binding(
                        get: { document.removesPasswordProtectionOnSave },
                        set: { newValue in
                            if newValue {
                                showsPasswordRemovalConfirmation = true
                            } else {
                                document.setRemovesPasswordProtectionOnSave(false)
                            }
                        }
                    )
                )
            }
        }
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

    private func apply(_ command: PDFEditingCommand, name: String) {
        do {
            _ = try document.apply(command, undoManager: undoManager, actionName: name)
        } catch { present(error) }
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

    private func exportSelectedPage() {
        guard let index = selectedPageIndex else { return }
        do {
            let result = try document.apply(
                .split(ranges: [PDFPageRange(index, through: index)]),
                undoManager: nil,
                actionName: "Split PDF"
            )
            guard case let .split(documents) = result, let data = documents.first else { return }
            splitExportDocument = PDFExportDocument(data: data, filename: "Page \(index + 1).pdf")
        } catch { present(error) }
    }

    private func splitEveryPage() {
        guard document.pageCount > 0 else { return }
        do {
            let ranges = (0..<document.pageCount).map { PDFPageRange($0, through: $0) }
            let result = try document.apply(
                .split(ranges: ranges),
                undoManager: nil,
                actionName: "Split PDF"
            )
            guard case let .split(documents) = result else { return }
            splitExportDocuments = documents.enumerated().map {
                PDFExportDocument(data: $0.element, filename: "Page \($0.offset + 1).pdf")
            }
        } catch { present(error) }
    }

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
        do {
            pageObjects = try document.pageObjects(at: index)
            showsObjectInspector = true
        } catch { present(error) }
    }

    private func loadCanvasObjects() {
        guard let index = selectedPageIndex else {
            pageObjects = []
            return
        }
        do {
            pageObjects = try document.pageObjects(at: index)
        } catch { present(error) }
    }

    private func replaceText(_ object: PDFPageObjectSnapshot, text: String) {
        do {
            let result = try document.replaceText(
                pageIndex: object.pageIndex,
                path: object.path,
                with: text,
                undoManager: undoManager
            )
            pageObjects = try document.pageObjects(at: object.pageIndex)
            if case let .usedCoreTextFallback(originalFontName) = result {
                replacementNotice = if let originalFontName {
                    "The original font \(originalFontName) does not contain every required glyph or the text needs complex shaping. A searchable CoreText vector layer was used instead."
                } else {
                    "The original PDF font cannot safely render this text. A searchable CoreText vector layer was used instead."
                }
            } else {
                replacementNotice = nil
            }
        } catch { present(error) }
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

    private func addNote() {
        guard let page = selectedPage else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Add Comment") {
                let bounds = page.bounds(for: .cropBox)
                _ = try annotationService.addNote(
                    text: annotationText,
                    at: CGPoint(x: bounds.midX, y: bounds.midY),
                    to: page
                )
            }
            annotationText = ""
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
    }

    private func addHighlight() {
        guard let selection = pdfSelection else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "Highlight Text") {
                _ = try annotationService.addHighlight(to: selection)
            }
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
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
        if annotationEditingEnabled || showsAnnotationInspector { loadCanvasAnnotations() }
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
            loadCanvasAnnotations()
        } catch { present(error) }
    }

    private func setAnnotationBounds(_ annotation: PDFAnnotationSnapshot, bounds: CGRect) {
        updateAnnotation(annotation, update: .bounds(bounds))
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
