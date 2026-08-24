import PDFKit
import SwiftUI

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
                    SecureField("PDF 密碼", text: $password)
                        .onSubmit(merge)
                } header: {
                    Text(filename)
                } footer: {
                    Text("密碼只用於本次匯入，不會儲存。")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("合併受保護 PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解鎖並合併", action: merge)
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
                LabeledContent("辨識頁面", value: "\(result.recognizedPageCount)")
                LabeledContent("文字區塊", value: "\(result.recognizedItemCount)")
                LabeledContent("略過真實文字頁", value: "\(result.skippedTextPageIndices.count)")
                LabeledContent("沒有辨識結果", value: "\(result.emptyPageIndices.count)")

                if !result.recognizedPages.isEmpty {
                    Section("將加入可搜尋文字層") {
                        ForEach(result.recognizedPages) { page in
                            Text("第 \(page.pageIndex + 1) 頁 · \(page.observations.count) 個文字區塊")
                        }
                    }
                }
            }
            .navigationTitle("整份文件 OCR 結果")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if !result.recognizedPages.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("加入可搜尋文字層") {
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
                            "文字",
                            text: Binding(
                                get: { replacementText[object.id] ?? object.text ?? "" },
                                set: { replacementText[object.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("套用文字修改") {
                            onReplaceText(
                                object,
                                replacementText[object.id] ?? object.text ?? ""
                            )
                        }
                    }

                    if object.kind == .image {
                        Button("替換圖片…") { onReplaceImage(object) }
                    }

                    HStack {
                        Button("←") { onMove(object, CGSize(width: -5, height: 0)) }
                        Button("→") { onMove(object, CGSize(width: 5, height: 0)) }
                        Button("↑") { onMove(object, CGSize(width: 0, height: 5)) }
                        Button("↓") { onMove(object, CGSize(width: 0, height: -5)) }
                        Menu("層級") {
                            Button("移至最前") {
                                onMoveToIndex(object, siblingCount(for: object) - 1)
                            }
                            Button("移至最後") { onMoveToIndex(object, 0) }
                        }
                        .disabled(siblingCount(for: object) < 2)
                        Spacer()
                        Button("刪除", role: .destructive) { onDelete(object) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("PDF 物件")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func objectTitle(_ object: PDFPageObjectSnapshot) -> String {
        let type: String
        switch object.kind {
        case .text: type = "文字"
        case .image: type = "圖片"
        case .path: type = "向量路徑"
        case .form: type = "表單物件"
        case .shading: type = "漸層"
        case .unknown: type = "未知物件"
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
            .navigationTitle("手寫簽名")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") { strokes.removeAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 PDF") {
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
                    ContentUnavailableView("此頁沒有註解", systemImage: "note.text")
                }
            }
            .navigationTitle("頁面註解")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(annotation.kind.displayName, systemImage: iconName)
                    .font(.headline)
                Spacer()
                Button(isSelected ? "已選取" : "在頁面選取", action: onSelect)
                    .buttonStyle(.bordered)
                    .disabled(isSelected)
            }

            if annotation.kind == .note || annotation.kind == .freeText {
                TextField("內容", text: $contents, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Text("顏色")
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

            HStack {
                Text("透明度")
                Slider(value: $opacity, in: 0.05...1)
                Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                    .frame(width: 44, alignment: .trailing)
            }

            if annotation.kind == .freeText {
                Stepper("字級 \(Int(fontSize)) pt", value: $fontSize, in: 6...144)
            }
            if annotation.kind == .ink {
                Stepper("線寬 \(lineWidth.formatted(.number.precision(.fractionLength(1)))) pt", value: $lineWidth, in: 0.5...24, step: 0.5)
            }

            if annotation.hasAppearanceStream {
                Label("此註解含固定外觀；只允許移動、縮放及修改內容。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("套用") {
                    onApply(PDFAnnotationUpdate(
                        contents: contents,
                        color: annotation.hasAppearanceStream ? nil : color.withAlpha(CGFloat(opacity)),
                        fontColor: annotation.kind == .freeText && !annotation.hasAppearanceStream
                            ? color.withAlpha(CGFloat(opacity))
                            : nil,
                        fontSize: annotation.kind == .freeText && !annotation.hasAppearanceStream
                            ? CGFloat(fontSize)
                            : nil,
                        lineWidth: annotation.kind == .ink && !annotation.hasAppearanceStream
                            ? CGFloat(lineWidth)
                            : nil
                    ))
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("刪除", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, 6)
    }

    private var colorPresets: [PDFAnnotationColor] { [.yellow, .red, .blue, .black] }

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
