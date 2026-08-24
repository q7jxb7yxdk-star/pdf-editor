import PDFKit
import SwiftUI

enum PDFToolAction {
    case addComment
    case editComments
    case highlight
    case drawFreehand
    case eraseDrawing
    case deletePage
    case extractPage
    case movePageEarlier
    case movePageLater
    case rotateLeft
    case rotateRight
    case insertPage
    case cropPage
    case numberPages
    case combineFiles
    case splitPDF
    case compressPDF
    case exportWord
    case exportExcel
    case exportPowerPoint
    case exportImage
    case fillAndSign
    case requestSignatures
    case addSignature
    case createSignTemplate
    case createWebForm
    case sendInBulk
    case addSignBranding
    case protectPDF
    case redactPDF
}

struct PDFToolSidebar: View {
    let pageCount: Int
    let hasSelectedPage: Bool
    let hasTextSelection: Bool
    let onAction: (PDFToolAction) -> Void

    @State private var expandedSections: Set<String> = ["Edit text", "Edit pages"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.tint)
                Text("All tools")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    section("Edit text") {
                        tool("Add a comment", icon: "note.text.badge.plus", action: .addComment)
                        tool(
                            "Edit comment",
                            icon: "text.bubble",
                            action: .editComments,
                            enabled: hasSelectedPage
                        )
                        tool("Highlight", icon: "highlighter", action: .highlight, enabled: hasTextSelection)
                        tool("Draw freehand", icon: "pencil.and.outline", action: .drawFreehand)
                        tool("Erase a drawing", icon: "eraser", action: .eraseDrawing)
                    }

                    section("Edit pages") {
                        tool("Delete", icon: "trash", action: .deletePage, enabled: pageCount > 1 && hasSelectedPage)
                        tool("Extract", icon: "doc.badge.arrow.up", action: .extractPage, enabled: hasSelectedPage)
                        menuTool("Reorder", icon: "rectangle.2.swap") {
                            Button("Move page earlier") { onAction(.movePageEarlier) }
                            Button("Move page later") { onAction(.movePageLater) }
                        }
                        menuTool("Rotate", icon: "rotate.right") {
                            Button("Rotate left") { onAction(.rotateLeft) }
                            Button("Rotate right") { onAction(.rotateRight) }
                        }
                        tool("Insert", icon: "doc.badge.plus", action: .insertPage)
                        tool("Crop", icon: "crop", action: .cropPage, enabled: hasSelectedPage)
                        tool("Number Pages", icon: "number.square", action: .numberPages)
                    }

                    section("Organize a PDF") {
                        tool("Combine files", icon: "doc.on.doc", action: .combineFiles)
                        tool("Split a PDF", icon: "square.split.2x1", action: .splitPDF, enabled: pageCount > 0)
                        tool("Compress PDF", icon: "arrow.down.right.and.arrow.up.left", action: .compressPDF)
                    }

                    section("Export PDF to") {
                        tool("Microsoft Word", icon: "doc.text", action: .exportWord)
                        tool("Microsoft Excel", icon: "tablecells", action: .exportExcel)
                        tool("Microsoft PowerPoint", icon: "rectangle.on.rectangle", action: .exportPowerPoint)
                        tool("Image format", icon: "photo", action: .exportImage)
                    }

                    section("E-sign") {
                        tool("Fill & Sign", icon: "pencil.and.scribble", action: .fillAndSign)
                        tool("Request e-signatures", icon: "paperplane", action: .requestSignatures)
                        tool("Add a signature", icon: "signature", action: .addSignature)
                        tool("Create e-sign template", icon: "doc.badge.gearshape", action: .createSignTemplate)
                        tool("Create a web form", icon: "network", action: .createWebForm)
                        tool("Send in bulk", icon: "person.3", action: .sendInBulk)
                        tool("Add e-sign branding", icon: "paintpalette", action: .addSignBranding)
                    }

                    section("Secure PDF") {
                        tool("Protect PDF", icon: "lock", action: .protectPDF)
                        tool("Redact PDF", icon: "rectangle.fill", action: .redactPDF)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .background(.background)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = Binding(
            get: { expandedSections.contains(title) },
            set: { expanded in
                if expanded { expandedSections.insert(title) }
                else { expandedSections.remove(title) }
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(spacing: 2) { content() }
                .padding(.top, 6)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tool(
        _ title: String,
        icon: String,
        action: PDFToolAction,
        enabled: Bool = true
    ) -> some View {
        Button { onAction(action) } label: {
            ToolRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func menuTool<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Menu(content: content) {
            ToolRowLabel(title: title, icon: icon, showsDisclosure: true)
        }
        .menuStyle(.borderlessButton)
        .disabled(!hasSelectedPage)
    }
}

struct PDFCommentList: View {
    let annotations: [PDFAnnotationSnapshot]
    let pageNumber: Int?
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let onApply: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDelete: (PDFAnnotationSnapshot) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comment List")
                        .font(.headline)
                    if let pageNumber {
                        Text("Page \(pageNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Comment List")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            List(annotations) { annotation in
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: selectedAnnotation?.reference == annotation.reference,
                    onSelect: { selectedAnnotation = annotation },
                    onApply: { onApply(annotation, $0) },
                    onDelete: { onDelete(annotation) }
                )
            }
            .listStyle(.inset)
            .overlay {
                if annotations.isEmpty {
                    ContentUnavailableView(
                        "No comments on this page",
                        systemImage: "text.bubble"
                    )
                }
            }
        }
        .background(.background)
    }
}

private struct ToolRowLabel: View {
    let title: String
    let icon: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 6)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

struct PDFRightPanel: View {
    let page: PDFPage?
    let pageCount: Int
    @Binding var selectedPageIndex: Int?
    @Binding var viewerMode: PDFViewerMode
    let onViewerCommand: (PDFViewerCommand.Action) -> Void
    let onAddComment: () -> Void
    let onFullScreen: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onAddComment) {
                    Label("Add a comment", systemImage: "note.text.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Page")
                        .font(.headline)
                    if let page, let selectedPageIndex {
                        PageThumbnailView(page: page, pageNumber: selectedPageIndex + 1)
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("No page", systemImage: "doc")
                            .frame(height: 150)
                    }
                    HStack {
                        Button {
                            guard let index = selectedPageIndex, index > 0 else { return }
                            selectedPageIndex = index - 1
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled((selectedPageIndex ?? 0) <= 0)
                        Spacer()
                        Text(pageCounter)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            guard let index = selectedPageIndex, index + 1 < pageCount else { return }
                            selectedPageIndex = index + 1
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled((selectedPageIndex ?? pageCount) + 1 >= pageCount)
                    }
                    .buttonStyle(.borderless)
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Zoom")
                        .font(.headline)
                        .padding(.bottom, 5)
                    modeButton("Single-page view", icon: "doc", mode: .singlePage)
                    modeButton("Two-page view", icon: "book.pages", mode: .twoPage)
                    modeButton("View with scrolling", icon: "scroll", mode: .scrolling)
                    commandButton("Fit one page", icon: "arrow.up.left.and.arrow.down.right", action: .fitPage)
                    commandButton("Fit to width", icon: "arrow.left.and.right", action: .fitWidth)
                    Button(action: onFullScreen) {
                        ToolRowLabel(title: "Full screen", icon: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    commandButton("Zoom in", icon: "plus.magnifyingglass", action: .zoomIn)
                    commandButton("Zoom out", icon: "minus.magnifyingglass", action: .zoomOut)
                }
            }
            .padding(16)
        }
        .background(.background)
    }

    private var pageCounter: String {
        guard let selectedPageIndex else { return "0 / \(pageCount)" }
        return "\(selectedPageIndex + 1) / \(pageCount)"
    }

    private func modeButton(_ title: String, icon: String, mode: PDFViewerMode) -> some View {
        Button { viewerMode = mode } label: {
            HStack {
                ToolRowLabel(title: title, icon: icon)
                if viewerMode == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func commandButton(
        _ title: String,
        icon: String,
        action: PDFViewerCommand.Action
    ) -> some View {
        Button { onViewerCommand(action) } label: {
            ToolRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }
}

struct ProtectedPDFMergeView: View {
    let filename: String
    let onMerge: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PDF password", text: $password)
                        .onSubmit(merge)
                } header: {
                    Text(filename)
                } footer: {
                    Text("The password is used only for this import and is not stored.")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Combine Protected PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock and Combine", action: merge)
                        .disabled(password.isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 220)
    }

    private func merge() {
        guard !password.isEmpty else { return }
        do {
            try onMerge(password)
            password = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            password = ""
        }
    }
}

struct OCRBatchResultView: View {
    let result: OCRBatchResult
    let onAddTextLayers: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Recognized pages", value: "\(result.recognizedPageCount)")
                LabeledContent("Text blocks", value: "\(result.recognizedItemCount)")
                LabeledContent("Skipped text pages", value: "\(result.skippedTextPageIndices.count)")
                LabeledContent("No recognition result", value: "\(result.emptyPageIndices.count)")

                if !result.recognizedPages.isEmpty {
                    Section("Searchable text layers to add") {
                        ForEach(result.recognizedPages) { page in
                            Text("Page \(page.pageIndex + 1) · \(page.observations.count) text blocks")
                        }
                    }
                }
            }
            .navigationTitle("Document OCR Results")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !result.recognizedPages.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add Searchable Text Layers") {
                            onAddTextLayers()
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}

struct PageObjectInspectorView: View {
    @Binding var objects: [PDFPageObjectSnapshot]
    let onReplaceText: (PDFPageObjectSnapshot, String) -> Void
    let onReplaceImage: (PDFPageObjectSnapshot) -> Void
    let onMove: (PDFPageObjectSnapshot, CGSize) -> Void
    let onMoveToIndex: (PDFPageObjectSnapshot, Int) -> Void
    let onDelete: (PDFPageObjectSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replacementText: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List(objects) { object in
                VStack(alignment: .leading, spacing: 8) {
                    Text(objectTitle(object))
                        .font(.headline)
                    Text(boundsDescription(object.bounds))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if object.kind == .text {
                        TextField(
                            "Text",
                            text: Binding(
                                get: { replacementText[object.id] ?? object.text ?? "" },
                                set: { replacementText[object.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Apply Text Change") {
                            onReplaceText(
                                object,
                                replacementText[object.id] ?? object.text ?? ""
                            )
                        }
                    }

                    if object.kind == .image {
                        Button("Replace Image…") { onReplaceImage(object) }
                    }

                    HStack {
                        Button("←") { onMove(object, CGSize(width: -5, height: 0)) }
                        Button("→") { onMove(object, CGSize(width: 5, height: 0)) }
                        Button("↑") { onMove(object, CGSize(width: 0, height: 5)) }
                        Button("↓") { onMove(object, CGSize(width: 0, height: -5)) }
                        Menu("Layer") {
                            Button("Bring to Front") {
                                onMoveToIndex(object, siblingCount(for: object) - 1)
                            }
                            Button("Send to Back") { onMoveToIndex(object, 0) }
                        }
                        .disabled(siblingCount(for: object) < 2)
                        Spacer()
                        Button("Delete", role: .destructive) { onDelete(object) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("PDF Objects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func objectTitle(_ object: PDFPageObjectSnapshot) -> String {
        let type: String
        switch object.kind {
        case .text: type = "Text"
        case .image: type = "Image"
        case .path: type = "Vector Path"
        case .form: type = "Form Object"
        case .shading: type = "Gradient"
        case .unknown: type = "Unknown Object"
        }
        if let fontName = object.fontName, let fontSize = object.fontSize {
            let nesting = object.isNestedInForm ? " · Form \(object.path.displayValue)" : ""
            return "\(type) · \(fontName) · \(fontSize.formatted()) pt\(nesting)"
        }
        return object.isNestedInForm ? "\(type) · Form \(object.path.displayValue)" : type
    }

    private func boundsDescription(_ bounds: CGRect) -> String {
        "x \(Int(bounds.minX)), y \(Int(bounds.minY)), w \(Int(bounds.width)), h \(Int(bounds.height))"
    }

    private func siblingCount(for object: PDFPageObjectSnapshot) -> Int {
        let parent = object.path.indices.dropLast()
        return objects.count {
            $0.pageIndex == object.pageIndex && $0.path.indices.dropLast() == parent
        }
    }
}

struct SignaturePadView: View {
    let onSave: ([SignatureStroke]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Canvas { context, size in
                    for stroke in strokes + (currentStroke.isEmpty ? [] : [currentStroke]) {
                        guard let first = stroke.first else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.primary), lineWidth: 2)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            currentStroke.append(
                                CGPoint(
                                    x: min(max(value.location.x / max(proxy.size.width, 1), 0), 1),
                                    y: min(max(value.location.y / max(proxy.size.height, 1), 0), 1)
                                )
                            )
                        }
                        .onEnded { _ in
                            if currentStroke.count > 1 { strokes.append(currentStroke) }
                            currentStroke.removeAll()
                        }
                )
                .padding()
            }
            .navigationTitle("Handwritten Signature")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { strokes.removeAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to PDF") {
                        onSave(strokes.map(SignatureStroke.init(points:)))
                        dismiss()
                    }
                    .disabled(strokes.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

struct AnnotationInspectorView: View {
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let onApply: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDelete: (PDFAnnotationSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(annotations) { annotation in
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: selectedAnnotation?.reference == annotation.reference,
                    onSelect: { selectedAnnotation = annotation },
                    onApply: { onApply(annotation, $0) },
                    onDelete: { onDelete(annotation) }
                )
            }
            .overlay {
                if annotations.isEmpty {
                    ContentUnavailableView("No annotations on this page", systemImage: "note.text")
                }
            }
            .navigationTitle("Page Annotations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

struct PDFCommentEditor: View {
    let annotation: PDFAnnotationSnapshot
    let onApply: (PDFAnnotationUpdate) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: true,
                    onSelect: {},
                    onApply: onApply,
                    onDelete: {
                        onDelete()
                        dismiss()
                    }
                )
                .padding()
            }
            .navigationTitle("Comment Editor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

private struct AnnotationEditorRow: View {
    let annotation: PDFAnnotationSnapshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onApply: (PDFAnnotationUpdate) -> Void
    let onDelete: () -> Void

    @State private var contents: String
    @State private var color: PDFAnnotationColor
    @State private var opacity: Double
    @State private var fontSize: Double
    @State private var lineWidth: Double

    init(
        annotation: PDFAnnotationSnapshot,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onApply: @escaping (PDFAnnotationUpdate) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onApply = onApply
        self.onDelete = onDelete
        _contents = State(initialValue: annotation.contents)
        _color = State(initialValue: annotation.color)
        _opacity = State(initialValue: Double(annotation.color.alpha))
        _fontSize = State(initialValue: Double(annotation.fontSize ?? 16))
        _lineWidth = State(initialValue: Double(annotation.lineWidth))
    }

    private var supportsStyleChanges: Bool {
        !annotation.hasAppearanceStream || annotation.kind == .note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(annotationTitle, systemImage: iconName)
                    .font(.headline)
                Spacer()
                Button(isSelected ? "Selected" : "Select on Page", action: onSelect)
                    .buttonStyle(.bordered)
                    .disabled(isSelected)
            }

            if annotation.kind == .note || annotation.kind == .freeText {
                TextField("Contents", text: $contents, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Text("Color")
                ForEach(colorPresets.indices, id: \.self) { index in
                    let preset = colorPresets[index]
                    Button {
                        color = preset.withAlpha(CGFloat(opacity))
                    } label: {
                        Circle()
                            .fill(swiftUIColor(preset))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if approximatelySameRGB(color, preset) {
                                    Circle().stroke(.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(!supportsStyleChanges)

            HStack {
                Text("Opacity")
                Slider(value: $opacity, in: 0.05...1)
                Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!supportsStyleChanges)

            if annotation.kind == .freeText {
                Stepper("Font size \(Int(fontSize)) pt", value: $fontSize, in: 6...144)
            }
            if annotation.kind == .ink {
                Stepper("Line width \(lineWidth.formatted(.number.precision(.fractionLength(1)))) pt", value: $lineWidth, in: 0.5...24, step: 0.5)
            }

            if !supportsStyleChanges {
                Label("This annotation has a fixed appearance. Only moving, resizing, and content changes are allowed.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Apply") {
                    onApply(PDFAnnotationUpdate(
                        contents: contents,
                        color: supportsStyleChanges ? color.withAlpha(CGFloat(opacity)) : nil,
                        fontColor: annotation.kind == .freeText && supportsStyleChanges
                            ? color.withAlpha(CGFloat(opacity))
                            : nil,
                        fontSize: annotation.kind == .freeText && supportsStyleChanges
                            ? CGFloat(fontSize)
                            : nil,
                        lineWidth: annotation.kind == .ink && supportsStyleChanges
                            ? CGFloat(lineWidth)
                            : nil
                    ))
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, 6)
    }

    private var colorPresets: [PDFAnnotationColor] { [.yellow, .red, .blue, .black] }

    private var annotationTitle: String {
        switch annotation.kind {
        case .note: "Comment"
        case .freeText: "Free Text"
        case .highlight: "Highlight"
        case .ink: "Signature / Ink"
        case .other: "Annotation"
        }
    }

    private var iconName: String {
        switch annotation.kind {
        case .note: "note.text"
        case .freeText: "textformat"
        case .highlight: "highlighter"
        case .ink: "signature"
        case .other: "square.and.pencil"
        }
    }

    private func swiftUIColor(_ color: PDFAnnotationColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func approximatelySameRGB(
        _ lhs: PDFAnnotationColor,
        _ rhs: PDFAnnotationColor
    ) -> Bool {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue) < 0.1
    }
}
