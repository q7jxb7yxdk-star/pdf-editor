import PDFKit
import SwiftUI

/// An isolated design workspace. Native PDFKit controls remain responsible for
/// filling after Apply; this preview never intercepts the main viewer's gestures.
struct PDFFormDesignerView: View {
    let session: PDFFormDesignSession
    let onApply: ([PDFFormDesignField]) throws -> Void
    let onCancel: () -> Void

    @State private var fields: [PDFFormDesignField]
    @State private var pageIndex: Int
    @State private var selectedID: UUID?
    @State private var placementKind: PDFFormDesignKind?
    @State private var undoHistory: [[PDFFormDesignField]] = []
    @State private var redoHistory: [[PDFFormDesignField]] = []
    @State private var preview: Image?
    @State private var zoom = 1.0
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false

    init(session: PDFFormDesignSession,
         initialPlacementKind: PDFFormDesignKind? = nil,
         onApply: @escaping ([PDFFormDesignField]) throws -> Void,
         onCancel: @escaping () -> Void) {
        self.session = session
        self.onApply = onApply
        self.onCancel = onCancel
        _fields = State(initialValue: session.fields)
        _pageIndex = State(initialValue: session.initialPageIndex)
        _placementKind = State(initialValue: initialPlacementKind)
    }

    private var selectedField: PDFFormDesignField? {
        fields.first { $0.id == selectedID }
    }

    private var validationMessage: String? {
        do {
            try PDFFormDesignService().validate(fields, in: session.sourceDocument)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                GeometryReader { proxy in
                    if proxy.size.width >= 720 {
                        HStack(spacing: 0) {
                            canvas
                            Divider()
                            inspector.frame(width: 270)
                        }
                    } else {
                        VStack(spacing: 0) {
                            canvas
                            Divider()
                            inspector.frame(height: min(280, proxy.size.height * 0.48))
                        }
                    }
                }
                if let message = errorMessage ?? validationMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }
            .navigationTitle("Acroform")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if fields == session.fields { onCancel() }
                        else { confirmsDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do { try onApply(fields) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(fields == session.fields || validationMessage != nil)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 760, idealWidth: 1050, minHeight: 620, idealHeight: 760)
#endif
        .interactiveDismissDisabled(fields != session.fields)
        .confirmationDialog("Discard form design changes?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive, action: onCancel)
            Button("Keep Editing", role: .cancel) {}
        }
        .onChange(of: pageIndex, initial: true) { _, _ in
            selectedID = nil
            reloadPreview()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(PDFFormDesignKind.allCases) { kind in
                        Button(kind.title, systemImage: kind.symbol) {
                            placementKind = kind
                            selectedID = nil
                        }
                    }
                } label: { Label("Add Field", systemImage: "plus") }
                Spacer()
                Button {
                    guard let previous = undoHistory.popLast() else { return }
                    redoHistory.append(fields)
                    fields = previous
                    errorMessage = nil
                } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoHistory.isEmpty)
                .help("Undo design change")
                .accessibilityLabel("Undo design change")
                Button {
                    guard let next = redoHistory.popLast() else { return }
                    undoHistory.append(fields)
                    fields = next
                    errorMessage = nil
                } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoHistory.isEmpty)
                .help("Redo design change")
                .accessibilityLabel("Redo design change")
            }
            HStack {
                Picker("Page", selection: $pageIndex) {
                    ForEach(0..<session.previewDocument.pageCount, id: \.self) { index in
                        Text("\(index + 1)").tag(index)
                    }
                }.frame(maxWidth: 160)
                Spacer()
                Image(systemName: "magnifyingglass")
                Slider(value: $zoom, in: 0.5...2).frame(maxWidth: 140)
                    .accessibilityLabel("Preview zoom")
            }
            if let placementKind {
                HStack {
                    Text("Click or tap the page to add: \(placementKind.title)")
                    Spacer()
                    Button("Cancel") { self.placementKind = nil }
                }.font(.caption)
            } else {
                Text("Select a field to move it. Drag its corner to resize. Apply returns to filling mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            if let page = session.previewDocument.page(at: pageIndex) {
                let geometry = PDFFormPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
                let size = geometry.displaySize
                let scale = max(0.05, min((proxy.size.width - 32) / max(size.width, 1),
                                         (proxy.size.height - 32) / max(size.height, 1))) * zoom
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color.white
                        if let preview {
                            preview.resizable().frame(width: size.width * scale, height: size.height * scale)
                                .allowsHitTesting(false)
                        }
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { event in
                                if let kind = placementKind {
                                    let point = CGPoint(x: event.location.x / scale, y: event.location.y / scale)
                                        .applying(geometry.transform.inverted())
                                    addField(kind, at: point, geometry: geometry)
                                } else { selectedID = nil }
                            })
                        ForEach(fields.filter { $0.pageIndex == pageIndex }) { field in
                            PDFFormDesignOverlay(
                                field: field,
                                rect: field.bounds.applying(geometry.transform),
                                scale: scale, selected: selectedID == field.id,
                                onSelect: { selectedID = field.id; placementKind = nil },
                                onChangeBounds: { displayBounds in
                                    var changed = field
                                    changed.bounds = geometry.clamped(
                                        displayBounds.applying(geometry.transform.inverted()),
                                        minimumDimension: field.kind.minimumDimension
                                    )
                                    update(changed)
                                }
                            )
                            .allowsHitTesting(placementKind == nil)
                        }
                    }
                    .frame(width: size.width * scale, height: size.height * scale)
                    .shadow(radius: 3)
                    .padding(16)
                }
                .background(Color.secondary.opacity(0.1))
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let field = selectedField {
                    Label(field.kind.title, systemImage: field.kind.symbol).font(.headline)
                    TextField(field.kind == .radioButton ? "Group name" : "Field name",
                              text: binding(field, \.name))
                    if field.kind == .radioButton {
                        Text("Changing the group name renames all its options.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if field.kind == .text {
                        TextField("Current text", text: binding(field, \.value), axis: .vertical)
                        TextField("Default text", text: binding(field, \.defaultValue), axis: .vertical)
                        Toggle("Multiline", isOn: binding(field, \.isMultiline))
                        Stepper("Font: \(Int(field.fontSize)) pt", value: binding(field, \.fontSize), in: 6...72)
                    } else {
                        TextField("Export value", text: binding(field, \.exportValue))
                        Toggle("Selected", isOn: binding(field, \.isSelected))
                        Toggle("Selected by default", isOn: binding(field, \.isDefaultSelected))
                        Text("Export values: A–Z, a–z, 0–9, underscore or hyphen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Position and size (PDF points)").font(.caption)
                    dimension("X", field: field, keyPath: \.origin.x)
                    dimension("Y", field: field, keyPath: \.origin.y)
                    dimension("Width", field: field, keyPath: \.size.width)
                    dimension("Height", field: field, keyPath: \.size.height)
                    if field.kind == .radioButton {
                        Button("Add Option to Group") { addRadioOption(to: field) }
                    }
                    Button(deleteTitle(field), role: .destructive) { delete(field) }
                } else {
                    Text("Form Fields").font(.headline)
                    Text("Add a field, then click or tap the page. Radio Button creates a group with two options.")
                        .font(.callout)
                }
                Divider()
                Text("Fields on this page").font(.headline)
                ForEach(fields.filter { $0.pageIndex == pageIndex }) { field in
                    Button {
                        selectedID = field.id
                        placementKind = nil
                    } label: {
                        Label(field.kind == .radioButton ? "\(field.name): \(field.exportValue)" : field.name,
                              systemImage: field.kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Only fields created by this designer can be changed here. Other existing fields are preserved and remain fillable in the main viewer.")
                    .font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).padding(14)
        }
    }

    private func binding<Value>(_ field: PDFFormDesignField,
                                _ keyPath: WritableKeyPath<PDFFormDesignField, Value>) -> Binding<Value> {
        Binding(get: { (fields.first { $0.id == field.id } ?? field)[keyPath: keyPath] },
                set: { value in
                    guard var current = fields.first(where: { $0.id == field.id }) else { return }
                    current[keyPath: keyPath] = value
                    update(current)
                })
    }

    private func dimension(_ title: String, field: PDFFormDesignField,
                           keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            TextField(title, value: Binding<Double>(
                get: { Double((fields.first { $0.id == field.id } ?? field).bounds[keyPath: keyPath]) },
                set: { value in
                    guard value.isFinite, var current = fields.first(where: { $0.id == field.id }),
                          let page = session.previewDocument.page(at: current.pageIndex) else { return }
                    current.bounds[keyPath: keyPath] = CGFloat(value)
                    current.bounds = PDFFormPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
                        .clamped(
                            current.bounds,
                            minimumDimension: current.kind.minimumDimension
                        )
                    update(current)
                }), format: .number.precision(.fractionLength(0...2)))
        }
    }

    private func change(_ newFields: [PDFFormDesignField]) {
        guard fields != newFields else { return }
        undoHistory.append(fields)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        fields = newFields
        errorMessage = nil
    }

    private func update(_ field: PDFFormDesignField) {
        guard let previous = fields.first(where: { $0.id == field.id }) else { return }
        var next = fields.map { $0.id == field.id ? field : $0 }
        if field.kind == .radioButton {
            for index in next.indices where next[index].id != field.id && next[index].kind == .radioButton {
                if next[index].name == previous.name { next[index].name = field.name }
                if next[index].name == field.name {
                    if field.isSelected { next[index].isSelected = false }
                    if field.isDefaultSelected { next[index].isDefaultSelected = false }
                }
            }
        }
        change(next)
    }

    private func addField(_ kind: PDFFormDesignKind, at point: CGPoint, geometry: PDFFormPageGeometry) {
        let prefix = kind == .text ? "Text" : kind == .checkBox ? "Checkbox" : "Radio"
        let existing = Set(PDFAcroFormService().snapshots(in: session.sourceDocument).compactMap(\.fieldName))
            .union(fields.map(\.name))
        var number = 1
        while existing.contains("\(prefix)\(number)") { number += 1 }
        let bounds = geometry.clamped(
            CGRect(
                x: point.x, y: point.y - 24,
                width: kind == .text ? 180 : 11,
                height: kind == .text ? 28 : 11
            ),
            minimumDimension: kind.minimumDimension
        )
        let field = PDFFormDesignField(pageIndex: pageIndex, kind: kind, name: "\(prefix)\(number)", bounds: bounds,
                                       exportValue: kind == .radioButton ? "Option1" : "Yes")
        var next = fields + [field]
        if kind == .radioButton {
            var option = field
            option.id = UUID()
            option.exportValue = "Option2"
            option.bounds = geometry.clamped(
                bounds.offsetBy(dx: 40, dy: 0),
                minimumDimension: kind.minimumDimension
            )
            next.append(option)
        }
        change(next)
        selectedID = field.id
        placementKind = nil
    }

    private func addRadioOption(to field: PDFFormDesignField) {
        guard let page = session.previewDocument.page(at: field.pageIndex) else { return }
        var option = field
        option.id = UUID()
        option.isSelected = false
        option.isDefaultSelected = false
        let used = Set(fields.filter { $0.name == field.name }.map(\.exportValue))
        var number = 1
        while used.contains("Option\(number)") { number += 1 }
        option.exportValue = "Option\(number)"
        option.bounds = PDFFormPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            .clamped(
                field.bounds.offsetBy(dx: 40, dy: 0),
                minimumDimension: field.kind.minimumDimension
            )
        change(fields + [option])
        selectedID = option.id
    }

    private func deletesGroup(_ field: PDFFormDesignField) -> Bool {
        field.kind == .radioButton && fields.filter { $0.name == field.name }.count <= 2
    }

    private func deleteTitle(_ field: PDFFormDesignField) -> String {
        deletesGroup(field) ? "Delete Radio Group" : "Delete Field"
    }

    private func delete(_ field: PDFFormDesignField) {
        change(fields.filter { deletesGroup(field) ? $0.name != field.name : $0.id != field.id })
        selectedID = nil
    }

    private func reloadPreview() {
        guard let page = session.previewDocument.page(at: pageIndex) else { preview = nil; return }
        let size = PDFFormPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation).displaySize
        let scale = 1600 / max(size.width, size.height, 1)
        let thumbnail = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
#if os(macOS)
        preview = Image(nsImage: thumbnail)
#else
        preview = Image(uiImage: thumbnail)
#endif
    }
}

private struct PDFFormDesignOverlay: View {
    let field: PDFFormDesignField
    let rect: CGRect
    let scale: CGFloat
    let selected: Bool
    let onSelect: () -> Void
    let onChangeBounds: (CGRect) -> Void
    @GestureState private var move = CGSize.zero
    @GestureState private var resize = CGSize.zero

    var body: some View {
        let handleSize: CGFloat = field.kind == .text ? 12 : 6
        let handlePadding: CGFloat = field.kind == .text ? 5 : 2
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.accentColor.opacity(selected ? 0.22 : 0.10))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    Text(field.kind == .text ? field.name : field.exportValue)
                        .font(.system(size: max(8, min(12, 11 * scale))))
                        .foregroundStyle(.black).lineLimit(1).padding(2).allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .gesture(DragGesture(minimumDistance: 3)
                    .updating($move) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        onSelect()
                        onChangeBounds(rect.offsetBy(dx: value.translation.width / scale,
                                                     dy: value.translation.height / scale))
                    })
            if selected {
                Rectangle().fill(Color.accentColor).frame(width: handleSize, height: handleSize)
                    .padding(handlePadding).contentShape(Rectangle())
                    .offset(x: handlePadding, y: handlePadding)
                    .gesture(DragGesture(minimumDistance: 1)
                        .updating($resize) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            onChangeBounds(CGRect(origin: rect.origin, size: CGSize(
                                width: max(
                                    field.kind.minimumDimension,
                                    rect.width + value.translation.width / scale
                                ),
                                height: max(
                                    field.kind.minimumDimension,
                                    rect.height + value.translation.height / scale
                                ))))
                        })
                    .accessibilityLabel("Resize field")
            }
        }
        .frame(
            width: max(
                field.kind.minimumDimension * scale,
                rect.width * scale + resize.width
            ),
            height: max(
                field.kind.minimumDimension * scale,
                rect.height * scale + resize.height
            )
        )
        .offset(x: rect.minX * scale + move.width, y: rect.minY * scale + move.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(field.kind.title): \(field.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}
