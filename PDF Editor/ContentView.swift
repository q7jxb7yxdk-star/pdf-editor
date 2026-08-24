import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var pendingMergeFilename = "受保護的 PDF"

    private let annotationService = PDFAnnotationService()
    private let ocrService = VisionOCRService()

    var body: some View {
        fileTransferView
            .onDisappear { ocrBatchTask?.cancel() }
    }

    private var editorRoot: some View {
        NavigationSplitView {
            pageSidebar
                .navigationTitle("頁面")
                .toolbar { pageToolbar }
        } detail: {
            documentView
        }
        .toolbar { editingToolbar }
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
        .alert("無法完成操作", isPresented: errorAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知錯誤")
        }
        .alert("數位簽章會失效", isPresented: $showsSignatureWarning) {
            Button("取消", role: .cancel) {}
            Button("仍要允許修改", role: .destructive) {
                document.authorizeDigitalSignatureInvalidation()
            }
        } message: {
            Text("此 PDF 含有數位簽章。任何內容或註解修改都會令現有簽章失效；確認後請重新執行剛才的操作。")
        }
        .alert("移除 PDF 密碼保護？", isPresented: $showsPasswordRemovalConfirmation) {
            Button("取消", role: .cancel) {}
            Button("儲存時移除", role: .destructive) {
                document.setRemovesPasswordProtectionOnSave(true)
            }
        } message: {
            Text("下一次儲存會建立不再需要密碼的 PDF。原檔只有在你儲存覆寫時才會被取代。")
        }
        .alert("新增文字", isPresented: $showsAddTextPrompt) {
            TextField("文字", text: $newText)
            Button("取消", role: .cancel) { newText = "" }
            Button("加入") { addText(newText) }
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("文字會加入目前頁面中央，之後可在 PDF 物件面板移動及修改。")
        }
        .alert("修改原有文字", isPresented: $showsSelectedTextPrompt) {
            TextField("文字", text: $selectedTextDraft)
            Button("取消", role: .cancel) {}
            Button("套用") {
                guard let selectedObject else { return }
                replaceText(selectedObject, text: selectedTextDraft)
            }
        } message: {
            Text("會先嘗試沿用原字型；缺字或需要複雜 shaping 時才使用 CoreText 替代層。")
        }
        .alert("已使用安全替代文字層", isPresented: Binding(
            get: { replacementNotice != nil },
            set: { if !$0 { replacementNotice = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(replacementNotice ?? "")
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
                    "需要密碼",
                    systemImage: "lock",
                    description: Text("輸入正確密碼後才會載入及編輯此 PDF。")
                )
                SecureField("PDF 密碼", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(unlockDocument)
                Button("解鎖", action: unlockDocument)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .padding()
        } else if document.pageCount == 0 {
            ContentUnavailableView(
                "空白 PDF",
                systemImage: "doc",
                description: Text("此文件沒有頁面。")
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
                onSetAnnotationBounds: setAnnotationBounds
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                apply(.insertBlankPage(at: document.pageCount, size: .a4), name: "新增頁面")
            } label: {
                Label("新增頁面", systemImage: "plus")
            }
            Button(role: .destructive) {
                guard let index = selectedPageIndex else { return }
                apply(.deletePage(at: index), name: "刪除頁面")
            } label: {
                Label("刪除頁面", systemImage: "trash")
            }
            .disabled(document.pageCount <= 1 || selectedPageIndex == nil)
        }
    }

    @ToolbarContentBuilder
    private var editingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("向左旋轉") { rotate(by: -90) }
                Button("向右旋轉") { rotate(by: 90) }
                Divider()
                Button("向前移一頁") { movePage(by: -1) }
                Button("向後移一頁") { movePage(by: 1) }
                Divider()
                Button("合併另一個 PDF…") { beginFileImport(.mergePDF) }
                Button("匯出目前頁面…") { exportSelectedPage() }
                Button("分割成每頁一個 PDF…") { splitEveryPage() }
            } label: {
                Label("頁面工具", systemImage: "rectangle.stack")
            }
            Menu {
                Button("檢視及修改原有物件…") { loadObjects() }
                Button("新增文字") { showsAddTextPrompt = true }
                Button("新增圖片…") { beginFileImport(.addImage) }
            } label: {
                Label("內容工具", systemImage: "textformat")
            }
            Button {
                objectEditingEnabled.toggle()
                annotationEditingEnabled = false
                selectedAnnotation = nil
                selectedObject = nil
                if objectEditingEnabled { loadCanvasObjects() }
            } label: {
                Label(
                    objectEditingEnabled ? "結束物件編輯" : "直接編輯物件",
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
                    annotationEditingEnabled ? "結束註解編輯" : "直接編輯註解",
                    systemImage: annotationEditingEnabled ? "pencil.line" : "pencil.tip.crop.circle"
                )
            }
            if annotationEditingEnabled, let selectedAnnotation {
                Menu {
                    Button("向左移 5 pt") { nudgeAnnotation(selectedAnnotation, dx: -5, dy: 0) }
                    Button("向右移 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 5, dy: 0) }
                    Button("向上移 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 0, dy: 5) }
                    Button("向下移 5 pt") { nudgeAnnotation(selectedAnnotation, dx: 0, dy: -5) }
                    Divider()
                    Button("放大 10%") { scaleAnnotation(selectedAnnotation, factor: 1.1) }
                    Button("縮小 10%") { scaleAnnotation(selectedAnnotation, factor: 0.9) }
                    Divider()
                    Button("編輯屬性…") { showsAnnotationInspector = true }
                    Button("刪除", role: .destructive) { deleteAnnotation(selectedAnnotation) }
                } label: {
                    Label("選取註解", systemImage: "square.dashed.inset.filled")
                }
            }
            if objectEditingEnabled, let selectedObject {
                Menu {
                    if selectedObject.kind == .text {
                        Button("修改文字…") {
                            selectedTextDraft = selectedObject.text ?? ""
                            showsSelectedTextPrompt = true
                        }
                    }
                    if selectedObject.kind == .image {
                        Button("替換圖片…") { beginImageReplacement(selectedObject) }
                    }
                    Divider()
                    Button("放大 10%") { scaleObject(selectedObject, factor: 1.1) }
                    Button("縮小 10%") { scaleObject(selectedObject, factor: 0.9) }
                    Button("向左旋轉 15°") { rotateObject(selectedObject, radians: .pi / 12) }
                    Button("向右旋轉 15°") { rotateObject(selectedObject, radians: -.pi / 12) }
                    Divider()
                    Button("移至最前") {
                        moveObject(selectedObject, destinationIndex: siblingCount(for: selectedObject) - 1)
                    }
                    Button("移至最後") { moveObject(selectedObject, destinationIndex: 0) }
                    Divider()
                    Button("刪除", role: .destructive) { deleteObject(selectedObject) }
                } label: {
                    Label("選取物件", systemImage: "square.dashed")
                }
            }
            Menu {
                TextField("註解文字", text: $annotationText)
                Button("新增文字註解") { addFreeText() }
                Button("新增便條") { addNote() }
                Button("標示選取文字") { addHighlight() }
                    .disabled(pdfSelection == nil)
                Button("手寫簽名…") { showsSignaturePad = true }
                Button("管理頁面註解…") { loadAnnotations() }
            } label: {
                Label("註解與簽名", systemImage: "pencil.and.scribble")
            }
            Menu {
                Button("辨識目前頁面", action: runOCR)
                    .disabled(selectedPage == nil)
                Button("辨識所有掃描頁面", action: runDocumentOCR)
                    .disabled(document.pageCount == 0)
            } label: {
                Label("OCR", systemImage: "viewfinder")
            }
            .disabled(isRunningOCR)
            if document.isEncrypted && !document.isLocked {
                Toggle(
                    "儲存時移除密碼",
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
                        "不需要 OCR",
                        systemImage: "text.cursor",
                        description: Text("此頁已有可選取的真實文字：\n\(text.prefix(300))")
                    )
                case let .recognized(observations):
                    List(observations.indices, id: \.self) { index in
                        let item = observations[index]
                        VStack(alignment: .leading) {
                            Text(item.text)
                            Text("信心度 \(item.confidence.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case nil:
                    ProgressView()
                }
            }
            .navigationTitle("OCR 結果")
            .toolbar {
                if let observations = recognizedOCRObservations, !observations.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("加入可搜尋文字層") {
                            addOCRTextLayer(observations)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsOCRResult = false }
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
        apply(.rotatePage(at: index, byDegrees: degrees), name: "旋轉頁面")
    }

    private func movePage(by offset: Int) {
        guard let index = selectedPageIndex else { return }
        let destination = index + offset
        guard (0..<document.pageCount).contains(destination) else { return }
        apply(.movePage(from: index, to: destination), name: "重新排列頁面")
        selectedPageIndex = destination
    }

    private func exportSelectedPage() {
        guard let index = selectedPageIndex else { return }
        do {
            let result = try document.apply(
                .split(ranges: [PDFPageRange(index, through: index)]),
                undoManager: nil,
                actionName: "分割 PDF"
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
                actionName: "分割 PDF"
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
                    name: "合併 PDF"
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
            actionName: "合併受保護 PDF"
        )
        self.pendingMergeData = nil
        pendingMergeFilename = "受保護的 PDF"
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
            replacementNotice = result.userMessage
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
            try document.mutateAnnotations(undoManager: undoManager, actionName: "新增文字註解") {
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
            try document.mutateAnnotations(undoManager: undoManager, actionName: "新增便條") {
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
            try document.mutateAnnotations(undoManager: undoManager, actionName: "標示文字") {
                _ = try annotationService.addHighlight(to: selection)
            }
            refreshAnnotationsIfNeeded()
        } catch { present(error) }
    }

    private func addSignature(_ strokes: [SignatureStroke]) {
        guard let page = selectedPage else { return }
        do {
            try document.mutateAnnotations(undoManager: undoManager, actionName: "新增簽名") {
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
                        Text("已檢查 \(ocrProgressCompleted)／\(ocrProgressTotal) 頁")
                            .foregroundStyle(.secondary)
                        Text("已有可選取真實文字的頁面會自動略過。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .navigationTitle("正在辨識掃描頁面")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", action: onCancelOCR)
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
                            pendingMergeFilename = "受保護的 PDF"
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
