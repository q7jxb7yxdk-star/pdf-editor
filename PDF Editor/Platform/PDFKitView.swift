import PDFKit
import CoreText
import QuartzCore
import SwiftUI

private struct PDFAnnotationActionBar: View {
    let annotation: PDFAnnotationSnapshot
    let onChangeColor: (PDFAnnotationColor) -> Void
    let onChangeFontSize: (CGFloat) -> Void
    let onChangeLineWidth: (CGFloat) -> Void
    let onDelete: () -> Void

    @State private var showsColorPicker = false
    @State private var showsFontSizePicker = false
    @State private var showsLineWidthPicker = false

    private let colorChoices: [(name: String, color: PDFAnnotationColor)] = [
        ("Black", .black),
        ("Yellow", .yellow),
        ("Red", PDFAnnotationColor(red: 0.93, green: 0.18, blue: 0.18, alpha: 1)),
        ("Orange", PDFAnnotationColor(red: 1, green: 0.5, blue: 0.05, alpha: 1)),
        ("Green", PDFAnnotationColor(red: 0.16, green: 0.68, blue: 0.32, alpha: 1)),
        ("Blue", .blue),
        ("Indigo", PDFAnnotationColor(red: 0.29, green: 0.25, blue: 0.78, alpha: 1)),
        ("Purple", PDFAnnotationColor(red: 0.63, green: 0.25, blue: 0.82, alpha: 1)),
    ]
    private let lineWidthChoices: [CGFloat] = [0.5, 1, 2, 4, 8, 12]
    private let fontSizeChoices: [CGFloat] = [8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48]
#if os(macOS)
    private let lineWidthChoiceHitTolerance: CGFloat = 12
#else
    private let lineWidthChoiceHitTolerance: CGFloat = 22
#endif

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showsColorPicker.toggle()
            } label: {
                Circle()
                    .fill(opaqueSwiftUIColor(annotation.color))
                    .frame(width: 18, height: 18)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change color")
            .accessibilityLabel("Change color")
            .accessibilityHint("Choose a new color for this annotation")
            .popover(isPresented: $showsColorPicker, arrowEdge: .bottom) {
                HStack(spacing: 10) {
                    ForEach(availableColorChoices.indices, id: \.self) { index in
                        let choice = availableColorChoices[index]
                        Button {
                            let color = choice.color.withAlpha(
                                annotation.kind == .ink ? 1 : annotation.color.alpha
                            )
                            showsColorPicker = false
                            DispatchQueue.main.async {
                                onChangeColor(color)
                            }
                        } label: {
                            Circle()
                                .fill(opaqueSwiftUIColor(choice.color))
                                .frame(width: 22, height: 22)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(choice.name)
                        .accessibilityLabel("Change color to \(choice.name)")
                    }
                }
                .padding(10)
                .presentationCompactAdaptation(.popover)
            }

            Divider()
                .frame(height: 18)

            if annotation.kind == .freeText {
                Button {
                    showsFontSizePicker.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "textformat.size")
                        Text("\(Int(annotation.fontSize ?? 11))")
                            .monospacedDigit()
                    }
                    .frame(minWidth: 48, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change text size")
                .accessibilityLabel("Change text size")
                .accessibilityValue("\(Int(annotation.fontSize ?? 11)) points")
                .popover(isPresented: $showsFontSizePicker, arrowEdge: .bottom) {
                    VStack(spacing: 2) {
                        ForEach(fontSizeChoices, id: \.self) { fontSize in
                            Button {
                                showsFontSizePicker = false
                                DispatchQueue.main.async {
                                    onChangeFontSize(fontSize)
                                }
                            } label: {
                                HStack {
                                    Text("\(Int(fontSize)) pt")
                                    Spacer()
                                    if abs(fontSize - (annotation.fontSize ?? 11)) < 0.01 {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Int(fontSize)) point text")
                        }
                    }
                    .frame(width: 124)
                    .padding(.vertical, 6)
                    .presentationCompactAdaptation(.popover)
                }

                Divider()
                    .frame(height: 18)
            }

            if annotation.kind == .ink {
                Button {
                    showsLineWidthPicker.toggle()
                } label: {
                    Image(systemName: "lineweight")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Change line thickness")
                .accessibilityLabel("Change line thickness")
                .accessibilityHint("Choose a new thickness for this line")
                .popover(isPresented: $showsLineWidthPicker, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        ForEach(lineWidthChoices, id: \.self) { lineWidth in
                            Button {
                                showsLineWidthPicker = false
                                onChangeLineWidth(lineWidth)
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            abs(lineWidth - annotation.lineWidth) < 0.01
                                                ? Color.accentColor.opacity(0.14)
                                                : Color.clear
                                        )
                                    Capsule()
                                        .fill(.primary)
                                        .frame(width: 30, height: max(1, min(lineWidth, 10)))
                                }
                                .frame(width: 38, height: 32)
                                .contentShape(
                                    Rectangle().inset(by: -lineWidthChoiceHitTolerance)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(lineWidth.formatted()) pt")
                            .accessibilityLabel("\(lineWidth.formatted()) point line")
                        }
                    }
                    .padding(10)
                    .presentationCompactAdaptation(.popover)
                }

                Divider()
                    .frame(height: 18)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .help("Delete")
            .accessibilityLabel("Delete")
            .accessibilityHint("Delete this annotation")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private func opaqueSwiftUIColor(_ color: PDFAnnotationColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue)
        )
    }

    private var availableColorChoices: [(name: String, color: PDFAnnotationColor)] {
        colorChoices.filter { choice in
            (annotation.kind == .ink || annotation.kind == .freeText ||
                choice.name != "Black") &&
                !approximatelySameRGB(annotation.color, choice.color)
        }
    }

    private func approximatelySameRGB(
        _ lhs: PDFAnnotationColor,
        _ rhs: PDFAnnotationColor
    ) -> Bool {
        abs(lhs.red - rhs.red) < 0.01 &&
            abs(lhs.green - rhs.green) < 0.01 &&
            abs(lhs.blue - rhs.blue) < 0.01
    }
}

private struct PDFFormFieldActionBar: View {
    let field: PDFFormDesignField
    let onChangeFontSize: (CGFloat) -> Void
    let onDelete: () -> Void

    @State private var showsFontSizePicker = false
    private let fontSizeChoices: [CGFloat] = [8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48]
    private var fieldTitle: String { field.kind == .text ? "Textbox" : field.kind.title }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showsFontSizePicker.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "textformat.size")
                    Text("\(Int(field.fontSize))")
                        .monospacedDigit()
                }
                .frame(minWidth: 48, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change font size")
            .accessibilityLabel("Change font size")
            .accessibilityValue("\(Int(field.fontSize)) points")
            .popover(isPresented: $showsFontSizePicker, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    ForEach(fontSizeChoices, id: \.self) { fontSize in
                        Button {
                            showsFontSizePicker = false
                            DispatchQueue.main.async { onChangeFontSize(fontSize) }
                        } label: {
                            HStack {
                                Text("\(Int(fontSize)) pt")
                                Spacer()
                                if abs(fontSize - field.fontSize) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minWidth: 110, minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .presentationCompactAdaptation(.popover)
            }

            Divider().frame(height: 18)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete \(fieldTitle)")
            .accessibilityLabel("Delete \(fieldTitle)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#if os(macOS)
import AppKit

private final class PDFAnnotationActionContainerView: NSView {}

private protocol PDFInteractionMouseHandling: AnyObject {
    func shouldCaptureMouse(at point: CGPoint, in pdfView: PDFView) -> Bool
    func usesLightNativeListBoxAppearance(at point: CGPoint, in pdfView: PDFView) -> Bool
    func handleMouseDown(_ event: NSEvent, in pdfView: PDFView) -> Bool
    func handleMouseMoved(_ event: NSEvent, in pdfView: PDFView)
    func handlePointerExited(in pdfView: PDFView)
    func handleAnnotationHoverEnded(in pdfView: PDFView)
    func handleScrollWillBegin(in pdfView: PDFView)
}

private final class PDFInteractionPDFView: PDFView {
    weak var interactionHandler: PDFInteractionMouseHandling?
    private var hoverTrackingArea: NSTrackingArea?
    private var annotationHoverTrackingArea: NSTrackingArea?
    private var listBoxAppearanceGeneration = 0
    private var appearanceBeforeListBoxHit: NSAppearance?
    private var isPreparingListBoxAppearance = false

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let preparesListBoxAppearance = NSApp.currentEvent?.type == .leftMouseDown &&
            interactionHandler?.usesLightNativeListBoxAppearance(
                at: point,
                in: self
            ) == true
        if preparesListBoxAppearance {
            prepareLightNativeListBoxAppearanceBeforeHit()
        }
        let defaultHit = super.hitTest(point)
        if preparesListBoxAppearance {
            applyLightNativeListBoxAppearance()
        }
        if defaultHit is PDFFormPlacementView { return defaultHit }
        if defaultHit?.isInsideAnnotationActionBar == true {
            return defaultHit
        }
        guard NSApp.currentEvent?.type == .leftMouseDown else {
            return defaultHit
        }
        if interactionHandler?.shouldCaptureMouse(at: point, in: self) == true {
            return self
        }
        if interactionHandler?.usesLightNativeListBoxAppearance(
            at: point,
            in: self
        ) == true {
            applyLightNativeListBoxAppearance()
        }
        if let textView = defaultHit as? NSTextView,
           !(textView is PDFPassiveTextView) {
            return textView
        }
        return defaultHit
    }

    private func prepareLightNativeListBoxAppearanceBeforeHit() {
        if containsNativeListBoxTable(in: self) {
            applyLightNativeListBoxAppearance()
            return
        }
        if !isPreparingListBoxAppearance {
            appearanceBeforeListBoxHit = appearance
            isPreparingListBoxAppearance = true
        }
        listBoxAppearanceGeneration &+= 1
        let generation = listBoxAppearanceGeneration
        appearance = NSAppearance(named: .aqua)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  generation == listBoxAppearanceGeneration else { return }
            applyLightNativeListBoxAppearance()
            appearance = appearanceBeforeListBoxHit
            appearanceBeforeListBoxHit = nil
            isPreparingListBoxAppearance = false
        }
    }

    private func containsNativeListBoxTable(in view: NSView) -> Bool {
        view is NSTableView || view.subviews.contains {
            containsNativeListBoxTable(in: $0)
        }
    }

    func applyLightNativeListBoxAppearance() {
        let lightAppearance = NSAppearance(named: .aqua)
        func style(_ view: NSView) {
            if let tableView = view as? NSTableView {
                tableView.appearance = lightAppearance
                tableView.backgroundColor = .white
                tableView.usesAlternatingRowBackgroundColors = false
                if let scrollView = tableView.enclosingScrollView {
                    scrollView.appearance = lightAppearance
                    scrollView.drawsBackground = true
                    scrollView.backgroundColor = .white
                    scrollView.contentView.backgroundColor = .white
                }
                tableView.style = .plain
                tableView.needsLayout = true
                tableView.layoutSubtreeIfNeeded()
                tableView.enclosingScrollView?.layoutSubtreeIfNeeded()
                tableView.needsDisplay = true
            }
            if let textField = view as? NSTextField {
                textField.textColor = .black
                textField.drawsBackground = false
            }
            view.subviews.forEach(style)
        }
        subviews.forEach(style)
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let stylesNativeListBox = interactionHandler?
            .usesLightNativeListBoxAppearance(at: viewPoint, in: self) == true
        if interactionHandler?.handleMouseDown(event, in: self) == true {
            return
        }
        super.mouseDown(with: event)
        if stylesNativeListBox {
            applyLightNativeListBoxAppearance()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if let placement = subviews.compactMap({ $0 as? PDFFormPlacementView }).first {
            placement.updatePointer(with: event)
            return
        }
        interactionHandler?.handleMouseMoved(event, in: self)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverTrackingArea {
            interactionHandler?.handlePointerExited(in: self)
        }
        if event.trackingArea === annotationHoverTrackingArea {
            clearAnnotationHoverTrackingArea()
            interactionHandler?.handleAnnotationHoverEnded(in: self)
        }
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        interactionHandler?.handleScrollWillBegin(in: self)
        super.scrollWheel(with: event)
    }

    fileprivate func removeAnnotationToolTips() {
        removeToolTipsRecursively(from: self)
    }

    fileprivate func trackAnnotationHover(in rect: CGRect) {
        clearAnnotationHoverTrackingArea()
        let trackingArea = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        annotationHoverTrackingArea = trackingArea
    }

    fileprivate func clearAnnotationHoverTrackingArea() {
        if let annotationHoverTrackingArea {
            removeTrackingArea(annotationHoverTrackingArea)
            self.annotationHoverTrackingArea = nil
        }
    }

    private func removeToolTipsRecursively(from view: NSView) {
        view.removeAllToolTips()
        view.subviews.forEach(removeToolTipsRecursively)
    }
}

private extension NSView {
    var isInsideAnnotationActionBar: Bool {
        var candidate: NSView? = self
        while let view = candidate {
            if view is PDFAnnotationActionContainerView { return true }
            candidate = view.superview
        }
        return false
    }
}

private final class PDFPassiveTextView: NSTextView {
    override var shouldDrawInsertionPoint: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PDFPageOverlayContainer: NSView {
    let pageIndex: Int

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        pageIndex = NSNotFound
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === self ? nil : target
    }
}

private final class PDFInlineTextView: NSTextView {
    private let editingUndoManager = UndoManager()

    override var undoManager: UndoManager? { editingUndoManager }

    override var shouldDrawInsertionPoint: Bool {
        isEditable && super.shouldDrawInsertionPoint
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditable ? super.hitTest(point) : nil
    }

    func discardUndoHistory() {
        editingUndoManager.removeAllActions()
    }
}

private final class PDFTextMaskView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum PDFViewerMode: Equatable {
    case singlePage
    case twoPage
    case scrolling
}

final class PDFKitHostView: NSView {
    private(set) var activePDFView: PDFView
    private(set) var pendingPDFView: PDFView?
    var initialPageIndex: Int?
    private var replacementGeneration = 0
    private var initialWindowConfigurationObserver: NSObjectProtocol?

    init(pdfView: PDFView) {
        activePDFView = pdfView
        super.init(frame: .zero)
        addSubview(pdfView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        activePDFView.frame = bounds
        pendingPDFView?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingInitialWindowConfiguration()
        guard initialPageIndex != nil, let window else { return }
        initialWindowConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .pdfEditorWindowDidFinishInitialConfiguration,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.positionInitialPageAtTopIfNeeded()
            }
        }
    }

    private func positionInitialPageAtTopIfNeeded() {
        guard bounds.width > 0, bounds.height > 0,
              let initialPageIndex,
              let document = activePDFView.document,
              let page = document.page(at: initialPageIndex) else { return }
        self.initialPageIndex = nil
        stopObservingInitialWindowConfiguration()
        activePDFView.layoutSubtreeIfNeeded()
        activePDFView.documentView?.layoutSubtreeIfNeeded()
        let pageBounds = page.bounds(for: activePDFView.displayBox)
        activePDFView.go(to: PDFDestination(
            page: page,
            at: CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
        ))
    }

    private func stopObservingInitialWindowConfiguration() {
        guard let initialWindowConfigurationObserver else { return }
        NotificationCenter.default.removeObserver(initialWindowConfigurationObserver)
        self.initialWindowConfigurationObserver = nil
    }

    func stageReplacement(
        _ replacement: PDFView,
        completion: @escaping (_ outgoing: PDFView, _ incoming: PDFView) -> Void
    ) {
        cancelPendingReplacement()
        replacementGeneration &+= 1
        let generation = replacementGeneration
        let outgoing = activePDFView
        pendingPDFView = replacement
        replacement.frame = bounds
        replacement.autoresizingMask = [.width, .height]
        replacement.alphaValue = 1
        addSubview(replacement, positioned: .below, relativeTo: outgoing)

        // Both are live PDFViews in the window. Keep the fully rendered old view
        // visible while PDFKit builds the replacement's page and annotation tiles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self, weak replacement] in
            guard let self, let replacement,
                  generation == self.replacementGeneration,
                  self.pendingPDFView === replacement else { return }
            replacement.layoutSubtreeIfNeeded()
            replacement.documentView?.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                outgoing.animator().alphaValue = 0
            } completionHandler: { [weak self, weak replacement] in
                guard let self, let replacement,
                      generation == self.replacementGeneration,
                      self.pendingPDFView === replacement else { return }
                outgoing.removeFromSuperviewWithoutNeedingDisplay()
                outgoing.alphaValue = 1
                self.activePDFView = replacement
                self.pendingPDFView = nil
                completion(outgoing, replacement)
            }
        }
    }

    func cancelPendingReplacement() {
        replacementGeneration &+= 1
        pendingPDFView?.removeFromSuperviewWithoutNeedingDisplay()
        pendingPDFView = nil
        activePDFView.alphaValue = 1
    }

    deinit {
        if let initialWindowConfigurationObserver {
            NotificationCenter.default.removeObserver(initialWindowConfigurationObserver)
        }
    }
}

struct PDFViewerCommand: Equatable {
    enum Action: Equatable {
        case fitPage
        case fitWidth
        case zoomIn
        case zoomOut
    }

    let id = UUID()
    let action: Action
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var selectedPageIndex: Int?
    @Binding var selection: PDFSelection?
    let objects: [PDFPageObjectSnapshot]
    let stagedTextByObjectID: [String: PDFStagedTextEdit]
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
    @Binding var selectedFormField: PDFFormDesignField?
    let onSetFormFieldBounds: (PDFFormDesignField, CGRect) -> Void
    let onSetFormFieldFontSize: (PDFFormDesignField, CGFloat) -> Void
    let onDeleteFormField: (PDFFormDesignField) -> Void
    let commentPlacementEnabled: Bool
    let onPlaceComment: (Int, CGPoint) -> Void
    let freeTextPlacementEnabled: Bool
    let onPlaceFreeText: (Int, CGRect, String, PDFAnnotationColor, CGFloat) -> Void
    let onCancelFreeTextPlacement: () -> Void
    let signaturePlacementEnabled: Bool
    let signaturePlacementStrokes: [[CGPoint]]?
    let signaturePlacementSize: CGSize
    let signaturePlacementLineWidth: CGFloat
    let onPlaceSignature: (Int, CGPoint) -> Void
    let freehandDrawingEnabled: Bool
    let onAddFreehand: (Int, [CGPoint]) -> Void
    let onReplaceTextObject: (PDFPageObjectSnapshot, String, PDFTextStyle) -> Void
    let onReplaceAnnotationText: (PDFAnnotationSnapshot, String, CGRect) -> Void
    let onUpdateAnnotation: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDeleteAnnotation: (PDFAnnotationSnapshot) -> Void
    let onOpenObject: (PDFPageObjectSnapshot) -> Void
    let onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
    let onAcroFormChange: () -> Void
    let viewerMode: PDFViewerMode
    let viewerCommand: PDFViewerCommand?
    var formPlacement: PDFFormPlacementConfiguration? = nil

    func makeCoordinator() -> Coordinator { makeSharedCoordinator() }

    func makeNSView(context: Context) -> PDFKitHostView {
        let pdfView = makePDFView()
        let hostView = PDFKitHostView(pdfView: pdfView)
        hostView.initialPageIndex = selectedPageIndex
        context.coordinator.observe(pdfView)
        loadDocument(into: pdfView)
        return hostView
    }

    func updateNSView(_ hostView: PDFKitHostView, context: Context) {
        updateCoordinator(context.coordinator)
        update(hostView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ hostView: PDFKitHostView, coordinator: Coordinator) {
        hostView.cancelPendingReplacement()
        coordinator.stopObserving()
    }
}
#elseif os(iOS)
import UIKit

enum PDFViewerMode: Equatable {
    case singlePage
    case twoPage
    case scrolling
}

struct PDFViewerCommand: Equatable {
    enum Action: Equatable {
        case fitPage
        case fitWidth
        case zoomIn
        case zoomOut
    }

    let id = UUID()
    let action: Action
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var selectedPageIndex: Int?
    @Binding var selection: PDFSelection?
    let objects: [PDFPageObjectSnapshot]
    let stagedTextByObjectID: [String: PDFStagedTextEdit]
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
    @Binding var selectedFormField: PDFFormDesignField?
    let onSetFormFieldBounds: (PDFFormDesignField, CGRect) -> Void
    let onSetFormFieldFontSize: (PDFFormDesignField, CGFloat) -> Void
    let onDeleteFormField: (PDFFormDesignField) -> Void
    let commentPlacementEnabled: Bool
    let onPlaceComment: (Int, CGPoint) -> Void
    let freeTextPlacementEnabled: Bool
    let onPlaceFreeText: (Int, CGRect, String, PDFAnnotationColor, CGFloat) -> Void
    let onCancelFreeTextPlacement: () -> Void
    let signaturePlacementEnabled: Bool
    let signaturePlacementStrokes: [[CGPoint]]?
    let signaturePlacementSize: CGSize
    let signaturePlacementLineWidth: CGFloat
    let onPlaceSignature: (Int, CGPoint) -> Void
    let freehandDrawingEnabled: Bool
    let onAddFreehand: (Int, [CGPoint]) -> Void
    let onReplaceTextObject: (PDFPageObjectSnapshot, String, PDFTextStyle) -> Void
    let onReplaceAnnotationText: (PDFAnnotationSnapshot, String, CGRect) -> Void
    let onUpdateAnnotation: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDeleteAnnotation: (PDFAnnotationSnapshot) -> Void
    let onOpenObject: (PDFPageObjectSnapshot) -> Void
    let onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
    let onAcroFormChange: () -> Void
    let viewerMode: PDFViewerMode
    let viewerCommand: PDFViewerCommand?
    var formPlacement: PDFFormPlacementConfiguration? = nil

    func makeCoordinator() -> Coordinator { makeSharedCoordinator() }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = makePDFView()
        context.coordinator.observe(pdfView)
        loadDocument(into: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        updateCoordinator(context.coordinator)
        update(pdfView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }
}
#endif

private extension PDFKitView {
    func makeSharedCoordinator() -> Coordinator {
        Coordinator(
            selectedPageIndex: $selectedPageIndex,
            selection: $selection,
            objects: objects,
            pendingStagedTextByObjectID: stagedTextByObjectID,
            selectedObject: $selectedObject,
            objectEditingEnabled: objectEditingEnabled,
            onTranslateObject: onTranslateObject,
            onSetObjectTransform: onSetObjectTransform,
            annotations: annotations,
            selectedAnnotation: $selectedAnnotation,
            annotationEditingEnabled: annotationEditingEnabled,
            onSetAnnotationBounds: onSetAnnotationBounds,
            selectedFormField: $selectedFormField,
            onSetFormFieldBounds: onSetFormFieldBounds,
            onSetFormFieldFontSize: onSetFormFieldFontSize,
            onDeleteFormField: onDeleteFormField,
            commentPlacementEnabled: commentPlacementEnabled,
            onPlaceComment: onPlaceComment,
            freeTextPlacementEnabled: freeTextPlacementEnabled,
            onPlaceFreeText: onPlaceFreeText,
            onCancelFreeTextPlacement: onCancelFreeTextPlacement,
            signaturePlacementEnabled: signaturePlacementEnabled,
            signaturePlacementStrokes: signaturePlacementStrokes,
            signaturePlacementSize: signaturePlacementSize,
            signaturePlacementLineWidth: signaturePlacementLineWidth,
            onPlaceSignature: onPlaceSignature,
            freehandDrawingEnabled: freehandDrawingEnabled,
            onAddFreehand: onAddFreehand,
            onReplaceTextObject: onReplaceTextObject,
            onReplaceAnnotationText: onReplaceAnnotationText,
            onUpdateAnnotation: onUpdateAnnotation,
            onDeleteAnnotation: onDeleteAnnotation,
            onOpenObject: onOpenObject,
            onOpenAnnotation: onOpenAnnotation,
            onAcroFormChange: onAcroFormChange
        )
    }

    func makePDFView() -> PDFView {
#if os(macOS)
        let pdfView = PDFInteractionPDFView()
#else
        let pdfView = PDFView()
#endif
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        return pdfView
    }

    func loadDocument(into pdfView: PDFView) {
        pdfView.document = document
        applyViewerMode(to: pdfView)
        goToSelectedPage(in: pdfView)
    }

#if os(macOS)
    func update(_ hostView: PDFKitHostView, coordinator: Coordinator) {
        let activePDFView = hostView.activePDFView
        if let pendingPDFView = hostView.pendingPDFView,
           pendingPDFView.document === document {
            applyViewerMode(to: pendingPDFView)
            applyViewerCommand(to: pendingPDFView, coordinator: coordinator)
            PDFFormPlacementView.install(on: pendingPDFView, configuration: formPlacement)
            return
        }

        guard activePDFView.document !== document,
              coordinator.isReplacingDocumentForFormTransition else {
            if activePDFView.document !== document {
                hostView.cancelPendingReplacement()
            }
            update(activePDFView, coordinator: coordinator)
            return
        }

        let destination = activePDFView.currentDestination
        let pageIndex = destination?.page.flatMap { activePDFView.document?.index(for: $0) }
        let scale = activePDFView.scaleFactor
        let autoScales = activePDFView.autoScales
        coordinator.prepareForDocumentReplacement()

        let replacement = makePDFView()
        replacement.frame = hostView.bounds
        replacement.document = document
        applyViewerMode(to: replacement)
        if let destination, let pageIndex, let page = document.page(at: pageIndex) {
            replacement.scaleFactor = scale
            replacement.autoScales = autoScales
            replacement.go(to: PDFDestination(page: page, at: destination.point))
        }
        goToSelectedPage(in: replacement)
        PDFFormPlacementView.install(on: replacement, configuration: formPlacement)
        replacement.layoutSubtreeIfNeeded()
        replacement.documentView?.layoutSubtreeIfNeeded()

        hostView.stageReplacement(replacement) { [weak coordinator] _, incoming in
            guard let coordinator else { return }
            coordinator.stopObserving()
            coordinator.observe(incoming)
            coordinator.completeDocumentReplacement()
        }
    }
#endif

    func update(_ pdfView: PDFView, coordinator: Coordinator) {
        if pdfView.document !== document {
            let wasPlacing = pdfView.subviews.contains { $0 is PDFFormPlacementView }
            let preservesFormTransition = coordinator.isReplacingDocumentForFormTransition
            let destination = wasPlacing || preservesFormTransition
                ? pdfView.currentDestination : nil
            let pageIndex = destination?.page.flatMap { pdfView.document?.index(for: $0) }
            let scale = pdfView.scaleFactor
            let autoScales = pdfView.autoScales
            if preservesFormTransition {
                coordinator.prepareFormDisplayTransitionForDocumentReplacement(document)
            }
            coordinator.prepareForDocumentReplacement()
            pdfView.document = document
            if let destination, let pageIndex, let page = document.page(at: pageIndex) {
                pdfView.scaleFactor = scale
                pdfView.autoScales = autoScales
                pdfView.go(to: PDFDestination(page: page, at: destination.point))
            }
            coordinator.completeDocumentReplacement()
            if preservesFormTransition {
                coordinator.completeFormDisplayTransitionAfterDocumentReplacement()
            }
        }
        goToSelectedPage(in: pdfView, coordinator: coordinator)
        applyViewerMode(to: pdfView)
        applyViewerCommand(to: pdfView, coordinator: coordinator)
        PDFFormPlacementView.install(on: pdfView, configuration: formPlacement)
    }

    func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.formPlacementActive = formPlacement != nil
        coordinator.selectedPageIndex = $selectedPageIndex
        coordinator.selection = $selection
        coordinator.objects = objects
        coordinator.pendingStagedTextByObjectID = stagedTextByObjectID
        coordinator.selectedObject = $selectedObject
        coordinator.objectEditingEnabled = objectEditingEnabled
        coordinator.onTranslateObject = onTranslateObject
        coordinator.onSetObjectTransform = onSetObjectTransform
        coordinator.annotations = annotations
        coordinator.selectedAnnotation = $selectedAnnotation
        coordinator.annotationEditingEnabled = annotationEditingEnabled
        coordinator.onSetAnnotationBounds = onSetAnnotationBounds
        coordinator.selectedFormField = $selectedFormField
        coordinator.onSetFormFieldBounds = onSetFormFieldBounds
        coordinator.onSetFormFieldFontSize = onSetFormFieldFontSize
        coordinator.onDeleteFormField = onDeleteFormField
        coordinator.commentPlacementEnabled = commentPlacementEnabled
        coordinator.onPlaceComment = onPlaceComment
        coordinator.freeTextPlacementEnabled = freeTextPlacementEnabled
        coordinator.onPlaceFreeText = onPlaceFreeText
        coordinator.onCancelFreeTextPlacement = onCancelFreeTextPlacement
        coordinator.signaturePlacementEnabled = signaturePlacementEnabled
        coordinator.signaturePlacementStrokes = signaturePlacementStrokes
        coordinator.signaturePlacementSize = signaturePlacementSize
        coordinator.signaturePlacementLineWidth = signaturePlacementLineWidth
        coordinator.onPlaceSignature = onPlaceSignature
        coordinator.freehandDrawingEnabled = freehandDrawingEnabled
        coordinator.onAddFreehand = onAddFreehand
        coordinator.onReplaceTextObject = onReplaceTextObject
        coordinator.onReplaceAnnotationText = onReplaceAnnotationText
        coordinator.onUpdateAnnotation = onUpdateAnnotation
        coordinator.onDeleteAnnotation = onDeleteAnnotation
        coordinator.onOpenObject = onOpenObject
        coordinator.onOpenAnnotation = onOpenAnnotation
        coordinator.onAcroFormChange = onAcroFormChange
        coordinator.updateGestureAvailability()
    }

    func applyViewerMode(to pdfView: PDFView) {
        let displayMode: PDFDisplayMode
        switch viewerMode {
        case .singlePage: displayMode = .singlePage
        case .twoPage: displayMode = .twoUp
        case .scrolling: displayMode = .singlePageContinuous
        }
        guard pdfView.displayMode != displayMode else { return }
        pdfView.displayMode = displayMode
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
    }

    func applyViewerCommand(to pdfView: PDFView, coordinator: Coordinator) {
        guard let viewerCommand,
              coordinator.lastViewerCommandID != viewerCommand.id else { return }
        coordinator.lastViewerCommandID = viewerCommand.id
        switch viewerCommand.action {
        case .fitPage:
            pdfView.autoScales = true
        case .fitWidth:
            guard let page = pdfView.currentPage else { return }
            pdfView.autoScales = false
            let pageWidth = max(page.bounds(for: pdfView.displayBox).width, 1)
            let availableWidth = max(pdfView.bounds.width - 28, 1)
            let scale = availableWidth / pageWidth
            pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        case .zoomIn:
            pdfView.autoScales = false
            pdfView.zoomIn(nil)
        case .zoomOut:
            pdfView.autoScales = false
            pdfView.zoomOut(nil)
        }
    }

    func goToSelectedPage(
        in pdfView: PDFView,
        coordinator: Coordinator? = nil
    ) {
        guard let selectedPageIndex,
              let page = document.page(at: selectedPageIndex) else { return }
        if pdfView.currentPage === page {
            coordinator?.pendingPageNavigationIndex = nil
            return
        }
        coordinator?.pendingPageNavigationIndex = selectedPageIndex
        pdfView.go(to: page)
    }
}

extension PDFKitView {
    final class Coordinator: NSObject {
        enum DragMode { case move, scale }
        var formPlacementActive = false

        var selectedPageIndex: Binding<Int?>
        var selection: Binding<PDFSelection?>
        var pendingStagedTextByObjectID: [String: PDFStagedTextEdit] {
            didSet {
                guard oldValue != pendingStagedTextByObjectID else { return }
#if os(macOS)
                synchronizeStagedTextEdits()
#endif
            }
        }
        var objects: [PDFPageObjectSnapshot] {
            didSet {
                guard pendingTextActivation != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.resolvePendingTextActivation()
                }
            }
        }
        var selectedObject: Binding<PDFPageObjectSnapshot?>
        var objectEditingEnabled: Bool {
            didSet {
                guard oldValue != objectEditingEnabled else { return }
                updateGestureAvailability()
            }
        }
        var onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
        var onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
        var annotations: [PDFAnnotationSnapshot]
        var selectedAnnotation: Binding<PDFAnnotationSnapshot?>
        var annotationEditingEnabled: Bool {
            didSet {
                guard oldValue != annotationEditingEnabled else { return }
                updateGestureAvailability()
            }
        }
        var onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
        var selectedFormField: Binding<PDFFormDesignField?>
        var onSetFormFieldBounds: (PDFFormDesignField, CGRect) -> Void
        var onSetFormFieldFontSize: (PDFFormDesignField, CGFloat) -> Void
        var onDeleteFormField: (PDFFormDesignField) -> Void
        var commentPlacementEnabled: Bool {
            didSet {
                guard oldValue != commentPlacementEnabled else { return }
                updateGestureAvailability()
            }
        }
        var onPlaceComment: (Int, CGPoint) -> Void
        var freeTextPlacementEnabled: Bool {
            didSet {
                guard oldValue != freeTextPlacementEnabled else { return }
                if !freeTextPlacementEnabled, pendingFreeTextPlacement != nil {
                    finishInlineTextEditing(
                        commit: false,
                        notifiesFreeTextCancellation: false
                    )
                }
                updateGestureAvailability()
            }
        }
        var onPlaceFreeText: (Int, CGRect, String, PDFAnnotationColor, CGFloat) -> Void
        var onCancelFreeTextPlacement: () -> Void
        var signaturePlacementEnabled: Bool {
            didSet {
                guard oldValue != signaturePlacementEnabled else { return }
#if os(macOS)
                if signaturePlacementEnabled {
                    refreshSignaturePreviewAtCurrentMouseLocation()
                } else {
                    hideSignaturePreview()
                }
#endif
                updateGestureAvailability()
            }
        }
        var signaturePlacementStrokes: [[CGPoint]]? {
            didSet {
                guard oldValue != signaturePlacementStrokes else { return }
#if os(macOS)
                refreshSignaturePreviewAtCurrentMouseLocation()
#endif
            }
        }
        var signaturePlacementSize: CGSize {
            didSet {
                guard oldValue != signaturePlacementSize else { return }
#if os(macOS)
                refreshSignaturePreviewAtCurrentMouseLocation()
#endif
            }
        }
        var signaturePlacementLineWidth: CGFloat {
            didSet {
                guard oldValue != signaturePlacementLineWidth else { return }
#if os(macOS)
                refreshSignaturePreviewAtCurrentMouseLocation()
#endif
            }
        }
        var onPlaceSignature: (Int, CGPoint) -> Void
        var freehandDrawingEnabled: Bool {
            didSet {
                guard oldValue != freehandDrawingEnabled else { return }
                if !freehandDrawingEnabled {
                    cancelFreehandDrawing()
#if os(macOS)
                    cancelFreehandStraightLine()
#endif
                }
                updateGestureAvailability()
            }
        }
        var onAddFreehand: (Int, [CGPoint]) -> Void
        var onReplaceTextObject: (PDFPageObjectSnapshot, String, PDFTextStyle) -> Void
        var onReplaceAnnotationText: (PDFAnnotationSnapshot, String, CGRect) -> Void
        var onUpdateAnnotation: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
        var onDeleteAnnotation: (PDFAnnotationSnapshot) -> Void
        var onOpenObject: (PDFPageObjectSnapshot) -> Void
        var onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
        var onAcroFormChange: () -> Void
        var lastViewerCommandID: UUID?
        var pendingPageNavigationIndex: Int?

        private weak var pdfView: PDFView?
        private var observers: [NSObjectProtocol] = []
        private let outlineLayer = CAShapeLayer()
        private let freehandPreviewLayer = CAShapeLayer()
        private var handleLayers: [CAShapeLayer] = []
        private var interactionObject: PDFPageObjectSnapshot?
        private var interactionAnnotation: PDFAnnotationSnapshot?
        private var interactionFormField: PDFFormDesignField?
        private var interactionFormAnchorPoint: CGPoint?
        private var interactionPage: PDFPage?
        private var interactionStartPoint = CGPoint.zero
        private var interactionStartBounds = CGRect.zero
        private var interactionStartTransform = CGAffineTransform.identity
        private var dragMode: DragMode = .move
        private struct PendingTextActivation {
            let pageIndex: Int
            let selection: PDFSelection
            let originalText: String
            var draftText: String?
            var draftStyle: PDFTextStyle?
            var keepsSelectionVisible = true
        }
        private var pendingTextActivation: PendingTextActivation?
        private var hoveredCommentReference: PDFAnnotationReference?
        private weak var freehandGesture: AnyObject?
        private var freehandPage: PDFPage?
        private var freehandPageIndex: Int?
        private var freehandPagePoints: [CGPoint] = []
        private var freehandViewPoints: [CGPoint] = []

#if os(macOS)
        private let signaturePreviewLayer = CAShapeLayer()
        private let freehandStraightLineAnchorLayer = CAShapeLayer()
        private var lastSignaturePreviewViewPoint: CGPoint?
        private weak var freehandStraightLinePage: PDFPage?
        private var freehandStraightLinePageIndex: Int?
        private var freehandStraightLinePagePoint: CGPoint?
        private var freehandStraightLineViewPoint: CGPoint?

        private struct InlineTextStyle {
            let fontDescriptor: NSFontDescriptor
            let pointSize: CGFloat
            let scaleFactor: CGFloat
            let color: NSColor

            init(font: NSFont, scaleFactor: CGFloat, color: NSColor) {
                fontDescriptor = font.fontDescriptor
                pointSize = font.pointSize
                self.scaleFactor = max(scaleFactor, 0.001)
                self.color = color
            }

            func font(at scaleFactor: CGFloat, pdfStyle: PDFTextStyle) -> NSFont {
                let scaledSize = pointSize * max(scaleFactor, 0.001) / self.scaleFactor
                var traits = fontDescriptor.symbolicTraits
                if pdfStyle.contains(.bold) {
                    traits.insert(.bold)
                } else {
                    traits.remove(.bold)
                }
                if pdfStyle.contains(.italic) {
                    traits.insert(.italic)
                } else {
                    traits.remove(.italic)
                }
                let styledDescriptor = fontDescriptor.withSymbolicTraits(traits)
                if let styledFont = NSFont(descriptor: styledDescriptor, size: scaledSize) {
                    return styledFont
                }
                var fallbackFont = pdfStyle.contains(.bold)
                    ? NSFont.boldSystemFont(ofSize: scaledSize)
                    : NSFont.systemFont(ofSize: scaledSize)
                if pdfStyle.contains(.italic) {
                    fallbackFont = NSFontManager.shared.convert(
                        fallbackFont,
                        toHaveTrait: .italicFontMask
                    )
                }
                return fallbackFont
            }
        }

        private struct StagedTextEdit {
            let text: String
            let style: InlineTextStyle
            let pdfStyle: PDFTextStyle
        }

        private var gestures: [NSGestureRecognizer] = []
        private var inlineTextField: PDFInlineTextView?
        private var inlineTextMaskView: PDFTextMaskView?
        private var inlineEditorDidGainFocus = false
        private var pendingInlineCaretLocation: Int?
        private var inlineEditingTextStyle: InlineTextStyle?
        private var inlineEditingPDFStyle: PDFTextStyle = []
        private var inlineStyleBar: NSStackView?
        private var annotationActionContainer: PDFAnnotationActionContainerView?
        private var annotationActionHost: NSHostingView<AnyView>?
        private var formDisplayTransitionSnapshot: NSImageView?
        private var stagedTextByObjectID: [String: StagedTextEdit] = [:]
        private var stagedTextStylesByObjectID: [String: InlineTextStyle] = [:]
        private var stagedTextViews: [String: PDFPassiveTextView] = [:]
        private var stagedTextMaskViews: [String: PDFTextMaskView] = [:]
        private var pageOverlayViews: [Int: PDFPageOverlayContainer] = [:]
        private var scrollWheelEventMonitor: Any?
        private var modifierFlagsEventMonitor: Any?
        private var commentPopover: NSPopover?
        private var commentPopoverReference: PDFAnnotationReference?
        private var commentPopoverOpenedByHover = false
        private var hasEnteredCommentPopover = false
        private var commentPopoverCloseWorkItem: DispatchWorkItem?
        private struct TransientStagedTextFallback {
            let objectID: String
            let pageIndex: Int
            let editor: PDFInlineTextView
            let mask: PDFTextMaskView?
        }
        private var transientStagedTextFallback: TransientStagedTextFallback?
#elseif os(iOS)
        private var gestures: [UIGestureRecognizer] = []
        private var annotationActionContainer: UIView?
        private var annotationActionHostingController: UIHostingController<AnyView>?
        private var formDisplayTransitionSnapshot: UIView?
        private var inlineTextField: UITextView?
        private var inlineEditingBaseFont: UIFont?
        private var inlineEditingPDFStyle: PDFTextStyle = []
        private var inlineBoldButton: UIBarButtonItem?
        private var inlineItalicButton: UIBarButtonItem?
#endif
        private enum ActionBarIdentity: Equatable {
            case annotation(PDFAnnotationSnapshot)
            case formField(PDFFormDesignField)
        }
        private var actionBarIdentity: ActionBarIdentity?
        private var inlineEditingObject: PDFPageObjectSnapshot?
        private var inlineEditingAnnotation: PDFAnnotationSnapshot?
        private struct PendingFreeTextPlacement {
            let pageIndex: Int
            let minimumBounds: CGRect
            var bounds: CGRect
            var color: PDFAnnotationColor
            var fontSize: CGFloat
        }
        private var pendingFreeTextPlacement: PendingFreeTextPlacement?
        private struct HiddenFreeTextAnnotation {
            let annotation: PDFAnnotation
            let shouldDisplay: Bool
        }
        private var hiddenFreeTextAnnotation: HiddenFreeTextAnnotation?
        private var isFinishingInlineTextEditing = false
        private var overlayRefreshScheduled = false
        private var acroFormBaseline: [PDFAcroFormFieldSnapshot]?
        private var acroFormCheckGeneration = 0
        private var activeFormDisplayTransition: PDFFormDisplayTransition?
        private var formDisplayTransitionGeneration = 0
        private var formDisplayTransitionDocumentInstalled = false
        private var formDisplayTransitionSawVisiblePages = false
        private var formDisplayTransitionCompletionScheduled = false
        private weak var formDisplayTransitionTargetDocument: PDFDocument?

        var isReplacingDocumentForFormTransition: Bool {
            activeFormDisplayTransition?.replacesDocument == true
        }

        init(
            selectedPageIndex: Binding<Int?>,
            selection: Binding<PDFSelection?>,
            objects: [PDFPageObjectSnapshot],
            pendingStagedTextByObjectID: [String: PDFStagedTextEdit],
            selectedObject: Binding<PDFPageObjectSnapshot?>,
            objectEditingEnabled: Bool,
            onTranslateObject: @escaping (PDFPageObjectSnapshot, CGSize) -> Void,
            onSetObjectTransform: @escaping (PDFPageObjectSnapshot, CGAffineTransform) -> Void,
            annotations: [PDFAnnotationSnapshot],
            selectedAnnotation: Binding<PDFAnnotationSnapshot?>,
            annotationEditingEnabled: Bool,
            onSetAnnotationBounds: @escaping (PDFAnnotationSnapshot, CGRect) -> Void,
            selectedFormField: Binding<PDFFormDesignField?>,
            onSetFormFieldBounds: @escaping (PDFFormDesignField, CGRect) -> Void,
            onSetFormFieldFontSize: @escaping (PDFFormDesignField, CGFloat) -> Void,
            onDeleteFormField: @escaping (PDFFormDesignField) -> Void,
            commentPlacementEnabled: Bool,
            onPlaceComment: @escaping (Int, CGPoint) -> Void,
            freeTextPlacementEnabled: Bool,
            onPlaceFreeText: @escaping (
                Int,
                CGRect,
                String,
                PDFAnnotationColor,
                CGFloat
            ) -> Void,
            onCancelFreeTextPlacement: @escaping () -> Void,
            signaturePlacementEnabled: Bool,
            signaturePlacementStrokes: [[CGPoint]]?,
            signaturePlacementSize: CGSize,
            signaturePlacementLineWidth: CGFloat,
            onPlaceSignature: @escaping (Int, CGPoint) -> Void,
            freehandDrawingEnabled: Bool,
            onAddFreehand: @escaping (Int, [CGPoint]) -> Void,
            onReplaceTextObject: @escaping (PDFPageObjectSnapshot, String, PDFTextStyle) -> Void,
            onReplaceAnnotationText: @escaping (PDFAnnotationSnapshot, String, CGRect) -> Void,
            onUpdateAnnotation: @escaping (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void,
            onDeleteAnnotation: @escaping (PDFAnnotationSnapshot) -> Void,
            onOpenObject: @escaping (PDFPageObjectSnapshot) -> Void,
            onOpenAnnotation: @escaping (PDFAnnotationSnapshot) -> Void,
            onAcroFormChange: @escaping () -> Void
        ) {
            self.selectedPageIndex = selectedPageIndex
            self.selection = selection
            self.objects = objects
            self.pendingStagedTextByObjectID = pendingStagedTextByObjectID
            self.selectedObject = selectedObject
            self.objectEditingEnabled = objectEditingEnabled
            self.onTranslateObject = onTranslateObject
            self.onSetObjectTransform = onSetObjectTransform
            self.annotations = annotations
            self.selectedAnnotation = selectedAnnotation
            self.annotationEditingEnabled = annotationEditingEnabled
            self.onSetAnnotationBounds = onSetAnnotationBounds
            self.selectedFormField = selectedFormField
            self.onSetFormFieldBounds = onSetFormFieldBounds
            self.onSetFormFieldFontSize = onSetFormFieldFontSize
            self.onDeleteFormField = onDeleteFormField
            self.commentPlacementEnabled = commentPlacementEnabled
            self.onPlaceComment = onPlaceComment
            self.freeTextPlacementEnabled = freeTextPlacementEnabled
            self.onPlaceFreeText = onPlaceFreeText
            self.onCancelFreeTextPlacement = onCancelFreeTextPlacement
            self.signaturePlacementEnabled = signaturePlacementEnabled
            self.signaturePlacementStrokes = signaturePlacementStrokes
            self.signaturePlacementSize = signaturePlacementSize
            self.signaturePlacementLineWidth = signaturePlacementLineWidth
            self.onPlaceSignature = onPlaceSignature
            self.freehandDrawingEnabled = freehandDrawingEnabled
            self.onAddFreehand = onAddFreehand
            self.onReplaceTextObject = onReplaceTextObject
            self.onReplaceAnnotationText = onReplaceAnnotationText
            self.onUpdateAnnotation = onUpdateAnnotation
            self.onDeleteAnnotation = onDeleteAnnotation
            self.onOpenObject = onOpenObject
            self.onOpenAnnotation = onOpenAnnotation
            self.onAcroFormChange = onAcroFormChange
            super.init()
            configureOverlay()
        }

        func observe(_ pdfView: PDFView) {
            self.pdfView = pdfView
#if os(macOS)
            (pdfView as? PDFInteractionPDFView)?.interactionHandler = self
            pdfView.pageOverlayViewProvider = self
            pdfView.wantsLayer = true
            pdfView.layer?.addSublayer(outlineLayer)
            handleLayers.forEach { pdfView.layer?.addSublayer($0) }
            pdfView.layer?.addSublayer(freehandPreviewLayer)
            pdfView.layer?.addSublayer(freehandStraightLineAnchorLayer)
            pdfView.layer?.addSublayer(signaturePreviewLayer)
            synchronizeStagedTextEdits()
#else
            pdfView.layer.addSublayer(outlineLayer)
            handleLayers.forEach { pdfView.layer.addSublayer($0) }
            pdfView.layer.addSublayer(freehandPreviewLayer)
#endif
            installGestures(on: pdfView)

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: .PDFViewPageChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    guard let self, let pdfView,
                          let document = pdfView.document,
                          let page = pdfView.currentPage else { return }
                    let pageIndex = document.index(for: page)
                    if let pendingPageNavigationIndex {
                        guard pageIndex == pendingPageNavigationIndex else { return }
                        self.pendingPageNavigationIndex = nil
                    }
                    if selectedPageIndex.wrappedValue != pageIndex {
                        finishInlineTextEditing(commit: true)
                        selectedPageIndex.wrappedValue = pageIndex
                        selectedObject.wrappedValue = nil
                        selectedAnnotation.wrappedValue = nil
                        if selectedFormField.wrappedValue?.pageIndex != pageIndex {
                            selectedFormField.wrappedValue = nil
                        }
                    }
                    scheduleOverlayRefresh()
                },
                center.addObserver(
                    forName: .PDFViewSelectionChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    self?.selection.wrappedValue = pdfView?.currentSelection
                },
                center.addObserver(
                    forName: .PDFViewScaleChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleOverlayRefresh()
                },
                center.addObserver(
                    forName: .PDFViewVisiblePagesChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.formDisplayTransitionVisiblePagesDidChange()
                    self?.scheduleOverlayRefresh()
                },
                center.addObserver(
                    forName: .PDFViewAnnotationWillHit,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.beginAcroFormInteractionIfNeeded()
                },
                center.addObserver(
                    forName: .PDFViewAnnotationHit,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleAcroFormChangeCheck()
                    self?.scheduleListBoxNativeAppearanceUpdateAfterHit()
                },
            ]
            observers.append(center.addObserver(
                forName: PDFFormDisplayTransitionEvent.willChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.beginFormDisplayTransition(from: notification)
            })
            observers.append(center.addObserver(
                forName: PDFFormDisplayTransitionEvent.didChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.completeFormDisplayTransition(from: notification)
            })
#if os(macOS)
            observers.append(center.addObserver(
                forName: NSControl.textDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedAcroFormChangeCheck()
            })
            observers.append(center.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAcroFormChangeCheck()
            })
#elseif os(iOS)
            observers.append(center.addObserver(
                forName: UITextField.textDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedAcroFormChangeCheck()
            })
            observers.append(center.addObserver(
                forName: UITextView.textDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedAcroFormChangeCheck()
            })
            observers.append(center.addObserver(
                forName: UITextField.textDidEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAcroFormChangeCheck()
            })
            observers.append(center.addObserver(
                forName: UITextView.textDidEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAcroFormChangeCheck()
            })
#endif
#if os(macOS)
            if let scrollWheelEventMonitor {
                NSEvent.removeMonitor(scrollWheelEventMonitor)
            }
            scrollWheelEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self, weak pdfView] event in
                guard let self, let pdfView,
                      event.window === pdfView.window else { return event }
                let point = pdfView.convert(event.locationInWindow, from: nil)
                guard pdfView.bounds.contains(point) else { return event }
                self.handleScrollWillBegin(in: pdfView)
                return event
            }

            if let modifierFlagsEventMonitor {
                NSEvent.removeMonitor(modifierFlagsEventMonitor)
            }
            modifierFlagsEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .flagsChanged
            ) { [weak self, weak pdfView] event in
                guard let self, let pdfView,
                      event.window === pdfView.window else { return event }
                self.handleFreehandModifierFlagsChanged(
                    event.modifierFlags,
                    in: pdfView
                )
                return event
            }

            if let clipView = pdfView.documentView?.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, let pdfView = self.pdfView else { return }
                    self.handleScrollWillBegin(in: pdfView)
                })
            }
#endif
            updateGestureAvailability()
            scheduleOverlayRefresh()
        }

        func stopObserving() {
            finishInlineTextEditing(commit: false)
            restoreHiddenFreeTextAnnotation()
            pendingTextActivation = nil
            hoveredCommentReference = nil
            acroFormBaseline = nil
            acroFormCheckGeneration &+= 1
            cancelFormDisplayTransition()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
#if os(macOS)
            if let scrollWheelEventMonitor {
                NSEvent.removeMonitor(scrollWheelEventMonitor)
                self.scrollWheelEventMonitor = nil
            }
            if let modifierFlagsEventMonitor {
                NSEvent.removeMonitor(modifierFlagsEventMonitor)
                self.modifierFlagsEventMonitor = nil
            }
#endif
            outlineLayer.removeFromSuperlayer()
            handleLayers.forEach { $0.removeFromSuperlayer() }
            freehandPreviewLayer.removeFromSuperlayer()
#if os(macOS)
            freehandStraightLineAnchorLayer.removeFromSuperlayer()
            signaturePreviewLayer.removeFromSuperlayer()
            lastSignaturePreviewViewPoint = nil
            cancelFreehandStraightLine()
#endif
            removeAnnotationActionBar()
            if let pdfView {
#if os(macOS)
                closeCommentPopover()
                (pdfView as? PDFInteractionPDFView)?.clearAnnotationHoverTrackingArea()
                (pdfView as? PDFInteractionPDFView)?.interactionHandler = nil
                pdfView.pageOverlayViewProvider = nil
                removeTransientStagedTextFallback()
                stagedTextViews.values.forEach { $0.removeFromSuperview() }
                stagedTextViews.removeAll()
                stagedTextMaskViews.values.forEach { $0.removeFromSuperview() }
                stagedTextMaskViews.removeAll()
                pageOverlayViews.removeAll()
#endif
                gestures.forEach(pdfView.removeGestureRecognizer)
            }
            gestures.removeAll()
            overlayRefreshScheduled = false
            self.pdfView = nil
        }

        func prepareForDocumentReplacement() {
            finishInlineTextEditing(commit: false)
            restoreHiddenFreeTextAnnotation()
            pendingTextActivation = nil
            acroFormBaseline = nil
            acroFormCheckGeneration &+= 1
#if os(macOS)
            hideSignaturePreview()
            cancelFreehandStraightLine()
            removeTransientStagedTextFallback()
            stagedTextByObjectID.removeAll()
            stagedTextStylesByObjectID.removeAll()
            stagedTextViews.values.forEach { $0.removeFromSuperview() }
            stagedTextViews.removeAll()
            stagedTextMaskViews.values.forEach { $0.removeFromSuperview() }
            stagedTextMaskViews.removeAll()
            pageOverlayViews.removeAll()
#endif
            clearInteraction()
            setOverlayHidden(true)
        }

        func completeDocumentReplacement() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                selection.wrappedValue = nil
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = nil
                selectedFormField.wrappedValue = nil
                pdfView?.clearSelection()
                refreshOverlay()
            }
        }

        /// Resolve only Widgets created by this app. Foreign form controls
        /// continue to use PDFKit without exposing authoring handles.
        func authoredFormField(at point: CGPoint, in pdfView: PDFView) -> PDFFormDesignField? {
            guard !formPlacementActive, !commentPlacementEnabled, !freeTextPlacementEnabled,
                  !signaturePlacementEnabled, !freehandDrawingEnabled, inlineTextField == nil,
                  let document = pdfView.document,
                  let page = pdfView.page(for: point, nearest: false) else { return nil }
            let pageIndex = document.index(for: page)
            let location = pdfView.convert(point, to: page)
            let identifierKey = PDFAnnotationKey(rawValue: "/PDFEditorFormID")
            guard let id = page.annotations
                .filter({ $0.type == "Widget" && $0.bounds.contains(location) })
                .compactMap({ ($0.value(forAnnotationKey: identifierKey) as? String).flatMap(UUID.init(uuidString:)) })
                .first else { return nil }
            return PDFFormDesignService().fields(in: document).first {
                $0.id == id && $0.pageIndex == pageIndex
            }
        }

        func authoredWidgetOwnsInput(at point: CGPoint, in pdfView: PDFView) -> Bool {
            authoredFormField(at: point, in: pdfView) != nil
        }

        private func formResizeHandleContains(_ point: CGPoint, in pdfView: PDFView) -> Bool {
            guard let field = selectedFormField.wrappedValue,
                  let page = pdfView.document?.page(at: field.pageIndex) else { return false }
            let rect = pdfView.convert(field.bounds, from: page).standardized
            let hitRadius = formResizeHandleHitRadius(for: rect)
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                .contains { hypot($0.x - point.x, $0.y - point.y) <= hitRadius }
        }

        private func formResizeHandleHitRadius(for rect: CGRect) -> CGFloat {
            min(10, max(3.5, min(rect.width, rect.height) * 0.22))
        }

        private func selectedFormFieldContains(_ point: CGPoint, in pdfView: PDFView) -> Bool {
            guard let field = selectedFormField.wrappedValue,
                  let page = pdfView.document?.page(at: field.pageIndex) else { return false }
            return pdfView.convert(field.bounds, from: page).standardized.contains(point)
        }

        private func formFieldInteractionContains(_ point: CGPoint, in pdfView: PDFView) -> Bool {
            selectedFormFieldContains(point, in: pdfView) ||
                formResizeHandleContains(point, in: pdfView)
        }

        @discardableResult
        private func selectAuthoredFormField(at point: CGPoint, in pdfView: PDFView) -> Bool {
            guard let field = authoredFormField(at: point, in: pdfView) else { return false }
            selectAuthoredFormField(field, in: pdfView)
            return true
        }

        private func selectAuthoredFormField(
            _ field: PDFFormDesignField,
            in pdfView: PDFView
        ) {
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            selectedFormField.wrappedValue = field
            selectedPageIndex.wrappedValue = field.pageIndex
            pdfView.clearSelection()
            selection.wrappedValue = nil
            updateGestureAvailability()
            refreshOverlay()
        }

        private func prepareFormFieldPan(at point: CGPoint, in pdfView: PDFView) -> Bool {
            if let field = authoredFormField(at: point, in: pdfView),
               selectedFormField.wrappedValue?.id != field.id {
                selectAuthoredFormField(field, in: pdfView)
            }
            return formFieldInteractionContains(point, in: pdfView)
        }

        private func beginAcroFormInteractionIfNeeded() {
            guard acroFormBaseline == nil,
                  let document = pdfView?.document else { return }
            let service = PDFAcroFormService()
            guard service.hasAcroFormFields(in: document) else { return }
            acroFormBaseline = service.snapshots(in: document)
        }

        private func scheduleAcroFormChangeCheck() {
            guard let document = pdfView?.document,
                  PDFAcroFormService().hasAcroFormFields(in: document) else { return }
            acroFormCheckGeneration &+= 1
            let generation = acroFormCheckGeneration
            DispatchQueue.main.async { [weak self] in
                self?.commitAcroFormChangeIfNeeded(generation: generation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.commitAcroFormChangeIfNeeded(generation: generation)
            }
        }

        private func scheduleDebouncedAcroFormChangeCheck() {
            guard let document = pdfView?.document,
                  PDFAcroFormService().hasAcroFormFields(in: document) else { return }
            acroFormCheckGeneration &+= 1
            let generation = acroFormCheckGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.commitAcroFormChangeIfNeeded(generation: generation)
            }
        }

        private func scheduleListBoxNativeAppearanceUpdateAfterHit() {
#if os(macOS)
            // PDFKit creates an AppKit table for an active List Box. Style it
            // after the native hit as well as during hit testing so controls
            // created late in the event cycle retain the PDF's white surface.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      let field = selectedFormField.wrappedValue,
                      field.kind == .listBox else { return }
                (pdfView as? PDFInteractionPDFView)?
                    .applyLightNativeListBoxAppearance()
            }
#endif
        }

        private func commitAcroFormChangeIfNeeded(generation: Int) {
            guard generation == acroFormCheckGeneration,
                  let document = pdfView?.document else { return }
            let service = PDFAcroFormService()
            let current = service.snapshots(in: document)
            if let baseline = acroFormBaseline,
               !service.hasValueChanges(from: baseline, to: current) { return }
            acroFormBaseline = nil
            onAcroFormChange()
        }

        func refreshOverlay(previewBounds: CGRect? = nil) {
            guard let pdfView else {
                setOverlayHidden(true)
                return
            }
#if os(macOS)
            updateStagedTextOverlays()
#endif
            updateInlineTextEditorFrame()
            if pendingFreeTextPlacement != nil,
               let inlineTextField {
                outlineLayer.isHidden = true
                handleLayers.forEach { $0.isHidden = true }
                updatePendingFreeTextActionBar(
                    above: inlineTextField.frame,
                    in: pdfView
                )
                return
            }
            let pageIndex: Int
            let pageBounds: CGRect
            if let field = selectedFormField.wrappedValue {
                pageIndex = field.pageIndex
                pageBounds = previewBounds ?? field.bounds
            } else if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
                pageIndex = annotation.reference.pageIndex
                pageBounds = previewBounds ?? annotation.bounds
            } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
                pageIndex = object.pageIndex
                pageBounds = previewBounds ?? object.bounds
            } else if objectEditingEnabled,
                      let pendingTextActivation,
                      pendingTextActivation.keepsSelectionVisible,
                      inlineTextField != nil,
                      let page = pdfView.document?.page(
                          at: pendingTextActivation.pageIndex
                      ) {
                pageIndex = pendingTextActivation.pageIndex
                pageBounds = pendingTextActivation.selection.bounds(for: page)
            } else {
                setOverlayHidden(true)
                return
            }
            guard let page = pdfView.document?.page(at: pageIndex) else {
                setOverlayHidden(true)
                return
            }
            let viewBounds = pdfView.convert(pageBounds, from: page).standardized
            guard viewBounds.width.isFinite, viewBounds.height.isFinite else {
                setOverlayHidden(true)
                return
            }
            let displayBounds: CGRect
            if objectEditingEnabled, selectedObject.wrappedValue?.kind == .text {
                displayBounds = minimumVisibleSelectionRect(viewBounds)
            } else {
                displayBounds = viewBounds
            }
            setOverlayHidden(false)
            let usesFreeTextEditorFrame = selectedAnnotation.wrappedValue?.kind == .freeText
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outlineLayer.frame = pdfView.bounds
            outlineLayer.lineWidth = usesFreeTextEditorFrame ? 1 : 2
            outlineLayer.lineDashPattern = usesFreeTextEditorFrame ? nil : [6, 4]
            outlineLayer.opacity = usesFreeTextEditorFrame ? 0.75 : 1
            outlineLayer.path = usesFreeTextEditorFrame
                ? CGPath(
                    roundedRect: displayBounds,
                    cornerWidth: 3,
                    cornerHeight: 3,
                    transform: nil
                )
                : CGPath(rect: displayBounds, transform: nil)
            let points = [
                CGPoint(x: displayBounds.minX, y: displayBounds.minY),
                CGPoint(x: displayBounds.maxX, y: displayBounds.minY),
                CGPoint(x: displayBounds.maxX, y: displayBounds.maxY),
                CGPoint(x: displayBounds.minX, y: displayBounds.maxY),
            ]
            let handleDiameter: CGFloat = selectedFormField.wrappedValue?.kind.isButton == true
                ? 6 : 10
            for (layer, point) in zip(handleLayers, points) {
                layer.isHidden = usesFreeTextEditorFrame
                layer.frame = CGRect(
                    x: point.x - handleDiameter / 2,
                    y: point.y - handleDiameter / 2,
                    width: handleDiameter,
                    height: handleDiameter
                )
                layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            }
            if usesFreeTextEditorFrame, inlineEditingAnnotation != nil {
                outlineLayer.isHidden = true
            }
            CATransaction.commit()
            if let field = selectedFormField.wrappedValue {
                updateFormFieldActionBar(
                    for: field, above: displayBounds, in: pdfView
                )
            } else {
                updateAnnotationActionBar(
                    for: selectedAnnotation.wrappedValue,
                    above: displayBounds,
                    in: pdfView
                )
            }
        }

        private func minimumVisibleSelectionRect(_ rect: CGRect) -> CGRect {
            let width = max(rect.width, 28)
            let height = max(rect.height, 20)
            return CGRect(
                x: rect.midX - width / 2,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
        }

        private func scheduleOverlayRefresh() {
            guard !overlayRefreshScheduled else { return }
            overlayRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                overlayRefreshScheduled = false
                refreshOverlay()
#if os(macOS)
                if let viewPoint = lastSignaturePreviewViewPoint,
                   signaturePlacementEnabled {
                    updateSignaturePreview(at: viewPoint)
                }
#endif
            }
        }

        private func configureOverlay() {
#if os(macOS)
            let accent = NSColor.controlAccentColor.cgColor
            freehandStraightLineAnchorLayer.strokeColor = nil
            freehandStraightLineAnchorLayer.zPosition = 10_003
            freehandStraightLineAnchorLayer.isHidden = true
            signaturePreviewLayer.strokeColor = NSColor.labelColor
                .withAlphaComponent(0.68)
                .cgColor
            signaturePreviewLayer.fillColor = nil
            signaturePreviewLayer.lineWidth = 2
            signaturePreviewLayer.lineCap = .round
            signaturePreviewLayer.lineJoin = .round
            signaturePreviewLayer.zPosition = 10_003
            signaturePreviewLayer.isHidden = true
#else
            let accent = UIColor.systemBlue.cgColor
#endif
            outlineLayer.strokeColor = accent
            outlineLayer.fillColor = nil
            outlineLayer.lineWidth = 2
            outlineLayer.lineDashPattern = [6, 4]
            outlineLayer.zPosition = 10_000
            freehandPreviewLayer.strokeColor = CGColor(
                red: 0.9,
                green: 0.15,
                blue: 0.15,
                alpha: 1
            )
#if os(macOS)
            freehandStraightLineAnchorLayer.fillColor = freehandPreviewLayer.strokeColor
#endif
            freehandPreviewLayer.fillColor = nil
            freehandPreviewLayer.lineWidth = 2
            freehandPreviewLayer.lineCap = .round
            freehandPreviewLayer.lineJoin = .round
            freehandPreviewLayer.zPosition = 10_002
            freehandPreviewLayer.isHidden = true
            handleLayers = (0..<4).map { _ in
                let layer = CAShapeLayer()
                layer.fillColor = accent
                layer.strokeColor = CGColor(gray: 1, alpha: 1)
                layer.lineWidth = 1
                layer.zPosition = 10_001
                return layer
            }
            setOverlayHidden(true)
        }

        private func setOverlayHidden(_ hidden: Bool) {
            outlineLayer.isHidden = hidden
            handleLayers.forEach { $0.isHidden = hidden }
            if hidden { removeAnnotationActionBar() }
        }

        private func updateAnnotationActionBar(
            for annotation: PDFAnnotationSnapshot?,
            above annotationBounds: CGRect,
            in pdfView: PDFView,
            onChangeColor customColorChange: ((PDFAnnotationColor) -> Void)? = nil,
            onChangeFontSize customFontSizeChange: ((CGFloat) -> Void)? = nil,
            onDelete customDelete: (() -> Void)? = nil
        ) {
            guard let annotation,
                  annotation.kind == .highlight || annotation.kind == .ink ||
                  annotation.kind == .freeText else {
                removeAnnotationActionBar()
                return
            }

            let actionBar = PDFAnnotationActionBar(
                annotation: annotation,
                onChangeColor: { [weak self] color in
                    if let customColorChange {
                        customColorChange(color)
                        return
                    }
                    guard let self else { return }
                    self.onUpdateAnnotation(
                        annotation,
                        annotation.kind == .freeText
                            ? PDFAnnotationUpdate(fontColor: color)
                            : PDFAnnotationUpdate(color: color)
                    )
                    self.refreshPDFViewDisplay()
                    self.scheduleOverlayRefresh()
                },
                onChangeFontSize: { [weak self] fontSize in
                    if let customFontSizeChange {
                        customFontSizeChange(fontSize)
                        return
                    }
                    guard let self else { return }
                    self.onUpdateAnnotation(
                        annotation,
                        PDFAnnotationUpdate(fontSize: fontSize)
                    )
                    self.refreshPDFViewDisplay()
                    self.scheduleOverlayRefresh()
                },
                onChangeLineWidth: { [weak self] lineWidth in
                    self?.onUpdateAnnotation(
                        annotation,
                        PDFAnnotationUpdate(lineWidth: lineWidth)
                    )
                },
                onDelete: { [weak self] in
                    if let customDelete {
                        customDelete()
                    } else {
                        self?.onDeleteAnnotation(annotation)
                    }
                }
            )

            presentActionBar(
                AnyView(actionBar), identity: .annotation(annotation),
                above: annotationBounds, in: pdfView
            )
        }

        private func updateFormFieldActionBar(
            for field: PDFFormDesignField,
            above fieldBounds: CGRect,
            in pdfView: PDFView
        ) {
            guard field.kind == .text || field.kind.isChoice else {
                removeAnnotationActionBar()
                return
            }
            let actionBar = PDFFormFieldActionBar(
                field: field,
                onChangeFontSize: { [weak self] fontSize in
                    guard let self else { return }
                    self.onSetFormFieldFontSize(field, fontSize)
                    self.scheduleOverlayRefresh()
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    self.finishNativeFormEditingBeforeDeletion(in: pdfView)
                    self.hideFormSelectionForMutation()
                    self.onDeleteFormField(field)
                    guard self.selectedFormField.wrappedValue?.id != field.id else {
                        self.annotationActionContainer?.isHidden = false
                        self.scheduleOverlayRefresh()
                        return
                    }
                    self.setOverlayHidden(true)
                    self.clearInteraction()
                    self.updateGestureAvailability()
                }
            )
            presentActionBar(
                AnyView(actionBar), identity: .formField(field),
                above: fieldBounds, in: pdfView
            )
        }

        private func finishNativeFormEditingBeforeDeletion(in pdfView: PDFView) {
#if os(macOS)
            _ = pdfView.window?.makeFirstResponder(pdfView)
#else
            pdfView.endEditing(true)
#endif
        }

        private func hideFormSelectionForMutation() {
            outlineLayer.isHidden = true
            handleLayers.forEach { $0.isHidden = true }
            annotationActionContainer?.isHidden = true
        }

        private func beginFormDisplayTransition(from notification: Notification) {
            guard let pdfView,
                  let document = notification.object as? PDFDocument,
                  document === pdfView.document,
                  let transition = notification.userInfo?[
                    PDFFormDisplayTransitionEvent.transitionUserInfoKey
                  ] as? PDFFormDisplayTransition else { return }
            cancelFormDisplayTransition()
            activeFormDisplayTransition = transition
#if os(iOS)
            guard let snapshot = pdfView.snapshotView(afterScreenUpdates: false) else {
                return
            }
            snapshot.autoresizingMask = []
            snapshot.isUserInteractionEnabled = false
            if let host = pdfView.superview {
                snapshot.frame = host.convert(pdfView.bounds, from: pdfView)
                host.addSubview(snapshot)
                host.bringSubviewToFront(snapshot)
            } else {
                snapshot.frame = pdfView.bounds
                pdfView.addSubview(snapshot)
                pdfView.bringSubviewToFront(snapshot)
            }
            formDisplayTransitionSnapshot = snapshot
#endif
        }

        private func completeFormDisplayTransition(from notification: Notification) {
            guard let pdfView,
                  let document = notification.object as? PDFDocument,
                  document === pdfView.document,
                  let transition = notification.userInfo?[
                    PDFFormDisplayTransitionEvent.transitionUserInfoKey
                  ] as? PDFFormDisplayTransition,
                  transition == activeFormDisplayTransition else { return }
#if os(macOS)
            if transition.replacesDocument { return }
#endif
            completeFormDisplayTransition(transition, in: pdfView)
        }

        func prepareFormDisplayTransitionForDocumentReplacement(_ document: PDFDocument) {
            guard let pdfView, isReplacingDocumentForFormTransition else { return }
            formDisplayTransitionTargetDocument = document
            formDisplayTransitionDocumentInstalled = false
            formDisplayTransitionSawVisiblePages = false
            formDisplayTransitionCompletionScheduled = false
            keepFormDisplayTransitionSnapshotOnTop(in: pdfView)
        }

        func completeFormDisplayTransitionAfterDocumentReplacement() {
            guard let pdfView,
                  let transition = activeFormDisplayTransition,
                  transition.replacesDocument,
                  pdfView.document === formDisplayTransitionTargetDocument else { return }
            formDisplayTransitionDocumentInstalled = true
            layoutFormDisplayTransition(in: pdfView)
            redrawFormDisplayTransition(transition, in: pdfView)
            keepFormDisplayTransitionSnapshotOnTop(in: pdfView)
            if formDisplayTransitionSawVisiblePages {
                scheduleFormDisplayTransitionCompletion(transition, in: pdfView)
            }
            // Visible-pages notifications describe layout, not tile-render completion.
            // Bound the shield lifetime when PDFKit does not send a notification.
            let generation = formDisplayTransitionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      generation == self.formDisplayTransitionGeneration,
                      self.activeFormDisplayTransition == transition else { return }
                self.scheduleFormDisplayTransitionCompletion(transition, in: pdfView)
            }
        }

        private func formDisplayTransitionVisiblePagesDidChange() {
            guard let pdfView,
                  let transition = activeFormDisplayTransition,
                  transition.replacesDocument,
                  formDisplayTransitionTargetDocument != nil,
                  pdfView.document === formDisplayTransitionTargetDocument else { return }
            // The document setter can deliver this synchronously, before the
            // caller has restored the destination and scale.
            formDisplayTransitionSawVisiblePages = true
            guard formDisplayTransitionDocumentInstalled else { return }
            scheduleFormDisplayTransitionCompletion(transition, in: pdfView)
        }

        private func completeFormDisplayTransition(
            _ transition: PDFFormDisplayTransition,
            in pdfView: PDFView
        ) {
            layoutFormDisplayTransition(in: pdfView)
            redrawFormDisplayTransition(transition, in: pdfView)
            keepFormDisplayTransitionSnapshotOnTop(in: pdfView)
            scheduleFormDisplayTransitionCompletion(transition, in: pdfView)
        }

        private func scheduleFormDisplayTransitionCompletion(
            _ transition: PDFFormDisplayTransition,
            in pdfView: PDFView
        ) {
            guard !formDisplayTransitionCompletionScheduled else { return }
            formDisplayTransitionCompletionScheduled = true
            let generation = formDisplayTransitionGeneration
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      generation == self.formDisplayTransitionGeneration else { return }
                self.layoutFormDisplayTransition(in: pdfView)
                self.redrawFormDisplayTransition(transition, in: pdfView)
                self.keepFormDisplayTransitionSnapshotOnTop(in: pdfView)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak pdfView] in
                    guard let self, let pdfView,
                          generation == self.formDisplayTransitionGeneration else { return }
                    self.layoutFormDisplayTransition(in: pdfView)
                    // The replacement was redrawn while the shield was still up.
                    // Do not invalidate the whole page again as we uncover it.
                    if !transition.replacesDocument {
                        self.redrawFormDisplayTransition(transition, in: pdfView)
                    }
                    self.cancelFormDisplayTransition()
                }
            }
        }

        private func redrawFormDisplayTransition(
            _ transition: PDFFormDisplayTransition,
            in pdfView: PDFView
        ) {
            guard let page = pdfView.document?.page(at: transition.pageIndex),
                  let documentView = pdfView.documentView else { return }
            let pageBounds = transition.replacesDocument
                ? page.bounds(for: .cropBox)
                : [transition.beforeBounds, transition.afterBounds]
                    .compactMap { $0 }
                    .reduce(CGRect.null) { $0.union($1) }
            guard !pageBounds.isNull else { return }
            let viewBounds = pdfView.convert(pageBounds, from: page)
                .standardized.insetBy(dx: -4, dy: -4)
            let documentBounds = documentView.convert(viewBounds, from: pdfView)
#if os(macOS)
            documentView.setNeedsDisplay(documentBounds)
            documentView.displayIfNeeded()
#else
            documentView.setNeedsDisplay(documentBounds)
            documentView.layoutIfNeeded()
#endif
        }

        private func layoutFormDisplayTransition(in pdfView: PDFView) {
#if os(macOS)
            pdfView.layoutSubtreeIfNeeded()
            pdfView.documentView?.layoutSubtreeIfNeeded()
#else
            pdfView.layoutIfNeeded()
            pdfView.documentView?.layoutIfNeeded()
#endif
        }

        private func keepFormDisplayTransitionSnapshotOnTop(in pdfView: PDFView) {
            guard let snapshot = formDisplayTransitionSnapshot else { return }
            // Stay outside PDFKit's internal view hierarchy throughout its rebuild.
            let host = pdfView.superview ?? pdfView
            snapshot.frame = host.convert(pdfView.bounds, from: pdfView)
#if os(macOS)
            host.addSubview(snapshot, positioned: .above, relativeTo: nil)
#else
            if snapshot.superview !== host {
                snapshot.removeFromSuperview()
                host.addSubview(snapshot)
            }
            host.bringSubviewToFront(snapshot)
#endif
        }

        private func cancelFormDisplayTransition() {
            formDisplayTransitionGeneration &+= 1
            activeFormDisplayTransition = nil
            formDisplayTransitionDocumentInstalled = false
            formDisplayTransitionSawVisiblePages = false
            formDisplayTransitionCompletionScheduled = false
            formDisplayTransitionTargetDocument = nil
#if os(macOS)
            formDisplayTransitionSnapshot?.removeFromSuperviewWithoutNeedingDisplay()
#else
            formDisplayTransitionSnapshot?.removeFromSuperview()
#endif
            formDisplayTransitionSnapshot = nil
        }

        private func presentActionBar(
            _ actionBar: AnyView,
            identity: ActionBarIdentity,
            above annotationBounds: CGRect,
            in pdfView: PDFView
        ) {

#if os(macOS)
            let container: PDFAnnotationActionContainerView
            let host: NSHostingView<AnyView>
            if let existingContainer = annotationActionContainer,
               let existingHost = annotationActionHost {
                container = existingContainer
                host = existingHost
                if actionBarIdentity != identity {
                    host.rootView = actionBar
                    actionBarIdentity = identity
                }
            } else {
                container = PDFAnnotationActionContainerView(frame: .zero)
                host = NSHostingView(rootView: actionBar)
                container.addSubview(host)
                pdfView.addSubview(container)
                annotationActionContainer = container
                annotationActionHost = host
                actionBarIdentity = identity
            }
            let fittingSize = host.fittingSize
            let size = CGSize(width: max(fittingSize.width, 150), height: max(fittingSize.height, 32))
            host.frame = CGRect(origin: .zero, size: size)
#else
            let container: UIView
            let hostingController: UIHostingController<AnyView>
            if let existingContainer = annotationActionContainer,
               let existingController = annotationActionHostingController {
                container = existingContainer
                hostingController = existingController
                if actionBarIdentity != identity {
                    hostingController.rootView = actionBar
                    actionBarIdentity = identity
                }
            } else {
                container = UIView(frame: .zero)
                container.backgroundColor = .clear
                hostingController = UIHostingController(rootView: actionBar)
                hostingController.view.backgroundColor = .clear
                container.addSubview(hostingController.view)
                pdfView.addSubview(container)
                annotationActionContainer = container
                annotationActionHostingController = hostingController
                actionBarIdentity = identity
            }
            let fittingSize = hostingController.sizeThatFits(
                in: CGSize(width: 320, height: 80)
            )
            let size = CGSize(width: max(fittingSize.width, 150), height: max(fittingSize.height, 32))
            hostingController.view.frame = CGRect(origin: .zero, size: size)
#endif

            let horizontalInset: CGFloat = 8
            let spacing: CGFloat = 8
            let availableBounds = pdfView.bounds.insetBy(dx: horizontalInset, dy: horizontalInset)
            let originX = min(
                max(annotationBounds.midX - size.width / 2, availableBounds.minX),
                max(availableBounds.minX, availableBounds.maxX - size.width)
            )
#if os(macOS)
            let preferredY: CGFloat
            if pdfView.isFlipped {
                let aboveY = annotationBounds.minY - size.height - spacing
                preferredY = aboveY >= availableBounds.minY
                    ? aboveY
                    : annotationBounds.maxY + spacing
            } else {
                let aboveY = annotationBounds.maxY + spacing
                preferredY = aboveY + size.height <= availableBounds.maxY
                    ? aboveY
                    : annotationBounds.minY - size.height - spacing
            }
            let originY = min(
                max(preferredY, availableBounds.minY),
                max(availableBounds.minY, availableBounds.maxY - size.height)
            )
#else
            let aboveY = annotationBounds.minY - size.height - spacing
            let preferredY = aboveY >= availableBounds.minY
                ? aboveY
                : annotationBounds.maxY + spacing
            let originY = min(
                max(preferredY, availableBounds.minY),
                max(availableBounds.minY, availableBounds.maxY - size.height)
            )
#endif
            container.frame = CGRect(
                origin: CGPoint(x: originX, y: originY),
                size: size
            )
#if os(macOS)
            container.wantsLayer = true
#endif
        }

        private func updatePendingFreeTextActionBar(
            above editorBounds: CGRect,
            in pdfView: PDFView
        ) {
            guard let pendingFreeTextPlacement else {
                removeAnnotationActionBar()
                return
            }
#if os(macOS)
            let text = inlineTextField?.string ?? ""
#else
            let text = inlineTextField?.text ?? ""
#endif
            let snapshot = PDFAnnotationSnapshot(
                reference: PDFAnnotationReference(
                    pageIndex: pendingFreeTextPlacement.pageIndex,
                    annotationIndex: -1
                ),
                kind: .freeText,
                bounds: pendingFreeTextPlacement.bounds,
                contents: text,
                color: pendingFreeTextPlacement.color,
                fontColor: pendingFreeTextPlacement.color,
                fontSize: pendingFreeTextPlacement.fontSize,
                lineWidth: 0,
                geometryPointCount: 0,
                hasAppearanceStream: false
            )
            updateAnnotationActionBar(
                for: snapshot,
                above: editorBounds,
                in: pdfView,
                onChangeColor: { [weak self] color in
                    self?.updatePendingFreeTextColor(color)
                },
                onChangeFontSize: { [weak self] fontSize in
                    self?.updatePendingFreeTextFontSize(fontSize)
                },
                onDelete: { [weak self] in
                    self?.finishInlineTextEditing(commit: false)
                }
            )
        }

        private func removeAnnotationActionBar() {
            actionBarIdentity = nil
#if os(macOS)
            annotationActionContainer?.removeFromSuperview()
            annotationActionContainer = nil
            annotationActionHost = nil
#else
            annotationActionHostingController?.view.removeFromSuperview()
            annotationActionHostingController = nil
            annotationActionContainer?.removeFromSuperview()
            annotationActionContainer = nil
#endif
        }

        func updateGestureAvailability() {
#if os(macOS)
            let hasSelectedObject = objectEditingEnabled &&
                selectedObject.wrappedValue != nil
            let hasSelectedAnnotation = annotationEditingEnabled &&
                selectedAnnotation.wrappedValue != nil
            let hasSelectedFormField = selectedFormField.wrappedValue != nil
            for gesture in gestures {
                if gesture === freehandGesture {
                    gesture.isEnabled = freehandDrawingEnabled
                } else if freehandDrawingEnabled {
                    gesture.isEnabled = false
                } else if gesture is NSRotationGestureRecognizer {
                    gesture.isEnabled = hasSelectedObject && !hasSelectedAnnotation
                } else if gesture is NSMagnificationGestureRecognizer {
                    gesture.isEnabled = hasSelectedObject || hasSelectedAnnotation
                } else {
                    gesture.isEnabled = hasSelectedObject || hasSelectedAnnotation || hasSelectedFormField
                }
            }
#else
            for gesture in gestures {
                if gesture === freehandGesture {
                    gesture.isEnabled = freehandDrawingEnabled
                } else if freehandDrawingEnabled {
                    gesture.isEnabled = false
                } else if gesture is UITapGestureRecognizer {
                    gesture.isEnabled = commentPlacementEnabled ||
                        freeTextPlacementEnabled ||
                        signaturePlacementEnabled ||
                        objectEditingEnabled || annotationEditingEnabled
                } else {
                    gesture.isEnabled = objectEditingEnabled || annotationEditingEnabled ||
                        selectedFormField.wrappedValue != nil
                }
            }
#endif
            scheduleOverlayRefresh()
        }

        private func beginFreehandDrawing(at viewPoint: CGPoint) {
            guard freehandDrawingEnabled,
                  let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.page(for: viewPoint, nearest: false) else {
                cancelFreehandDrawing()
                return
            }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else {
                cancelFreehandDrawing()
                return
            }

            finishInlineTextEditing(commit: true)
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            pdfView.clearSelection()
            selection.wrappedValue = nil
            setOverlayHidden(true)

            freehandPage = page
            freehandPageIndex = pageIndex
            freehandPagePoints = [pdfView.convert(viewPoint, to: page)]
            freehandViewPoints = [viewPoint]
            updateFreehandPreview()
        }

        private func appendFreehandPoint(_ viewPoint: CGPoint) {
            guard let pdfView, let page = freehandPage,
                  pdfView.page(for: viewPoint, nearest: false) === page else { return }
            if let previous = freehandViewPoints.last,
               hypot(viewPoint.x - previous.x, viewPoint.y - previous.y) < 0.5 {
                return
            }
            freehandViewPoints.append(viewPoint)
            freehandPagePoints.append(pdfView.convert(viewPoint, to: page))
            updateFreehandPreview()
        }

        private func finishFreehandDrawing(at viewPoint: CGPoint) {
            appendFreehandPoint(viewPoint)
            let pageIndex = freehandPageIndex
            let points = freehandPagePoints
            cancelFreehandDrawing()
            guard let pageIndex, points.count > 1 else { return }
            onAddFreehand(pageIndex, points)
        }

        private func cancelFreehandDrawing() {
            freehandPage = nil
            freehandPageIndex = nil
            freehandPagePoints.removeAll()
            freehandViewPoints.removeAll()
            freehandPreviewLayer.path = nil
            freehandPreviewLayer.isHidden = true
        }

        private func updateFreehandPreview() {
            guard let first = freehandViewPoints.first else {
                freehandPreviewLayer.path = nil
                freehandPreviewLayer.isHidden = true
                return
            }
            let path = CGMutablePath()
            path.move(to: first)
            for point in freehandViewPoints.dropFirst() {
                path.addLine(to: point)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            freehandPreviewLayer.frame = pdfView?.bounds ?? .zero
            freehandPreviewLayer.path = path
            freehandPreviewLayer.isHidden = false
            CATransaction.commit()
        }

#if os(macOS)
        private func beginFreehandStraightLine(at viewPoint: CGPoint) {
            guard freehandDrawingEnabled,
                  freehandPage == nil,
                  freehandStraightLinePage == nil,
                  let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.page(for: viewPoint, nearest: false) else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }

            finishInlineTextEditing(commit: true)
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            pdfView.clearSelection()
            selection.wrappedValue = nil
            setOverlayHidden(true)

            freehandStraightLinePage = page
            freehandStraightLinePageIndex = pageIndex
            freehandStraightLinePagePoint = pdfView.convert(viewPoint, to: page)
            freehandStraightLineViewPoint = viewPoint
            updateFreehandStraightLinePreview(at: viewPoint)
        }

        private func updateFreehandStraightLinePreview(at viewPoint: CGPoint) {
            guard let pdfView,
                  let page = freehandStraightLinePage,
                  let anchor = freehandStraightLineViewPoint else { return }

            let path = CGMutablePath()
            path.move(to: anchor)
            if pdfView.page(for: viewPoint, nearest: false) === page {
                path.addLine(to: viewPoint)
            }

            let dotRadius = max(3, freehandPreviewLayer.lineWidth * 1.5)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            freehandPreviewLayer.frame = pdfView.bounds
            freehandPreviewLayer.path = path
            freehandPreviewLayer.isHidden = false
            freehandStraightLineAnchorLayer.frame = pdfView.bounds
            freehandStraightLineAnchorLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: anchor.x - dotRadius,
                    y: anchor.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ),
                transform: nil
            )
            freehandStraightLineAnchorLayer.isHidden = false
            CATransaction.commit()
        }

        @discardableResult
        private func finishFreehandStraightLine(at viewPoint: CGPoint) -> Bool {
            guard let pdfView,
                  let page = freehandStraightLinePage,
                  pdfView.page(for: viewPoint, nearest: false) === page,
                  let pageIndex = freehandStraightLinePageIndex,
                  let startPoint = freehandStraightLinePagePoint else { return false }
            let endPoint = pdfView.convert(viewPoint, to: page)
            cancelFreehandStraightLine()
            guard hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) >= 0.5 else {
                return true
            }
            onAddFreehand(pageIndex, [startPoint, endPoint])
            return true
        }

        private func cancelFreehandStraightLine() {
            let hadStraightLine = freehandStraightLinePage != nil
            freehandStraightLinePage = nil
            freehandStraightLinePageIndex = nil
            freehandStraightLinePagePoint = nil
            freehandStraightLineViewPoint = nil
            if hadStraightLine {
                freehandPreviewLayer.path = nil
                freehandPreviewLayer.isHidden = true
            }
            freehandStraightLineAnchorLayer.path = nil
            freehandStraightLineAnchorLayer.isHidden = true
        }

        private func handleFreehandModifierFlagsChanged(
            _ modifierFlags: NSEvent.ModifierFlags,
            in pdfView: PDFView
        ) {
            guard freehandDrawingEnabled, modifierFlags.contains(.shift) else {
                cancelFreehandStraightLine()
                return
            }
            guard freehandPage == nil,
                  freehandStraightLinePage == nil,
                  let viewPoint = currentMouseViewPoint(in: pdfView) else { return }
            beginFreehandStraightLine(at: viewPoint)
        }

        private func currentMouseViewPoint(in pdfView: PDFView) -> CGPoint? {
            guard let window = pdfView.window else { return nil }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let viewPoint = pdfView.convert(windowPoint, from: nil)
            guard pdfView.bounds.contains(viewPoint),
                  pdfView.page(for: viewPoint, nearest: false) != nil else { return nil }
            return viewPoint
        }
#endif

        private func selectTarget(at viewPoint: CGPoint) {
            guard prepareForCanvasInteraction(at: viewPoint),
                  let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false),
                  let document = pdfView.document else { return }
            pendingTextActivation = nil
            let pageIndex = document.index(for: page)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            if selectAuthoredFormField(at: viewPoint, in: pdfView) { return }
            selectedFormField.wrappedValue = nil
            if freeTextPlacementEnabled {
                beginFreeTextPlacement(
                    pageIndex: pageIndex,
                    pagePoint: pagePoint,
                    on: page
                )
                return
            }
            if commentPlacementEnabled {
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = nil
                selectedPageIndex.wrappedValue = pageIndex
                onPlaceComment(pageIndex, pagePoint)
                updateGestureAvailability()
                return
            }
            if signaturePlacementEnabled {
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = nil
                selectedPageIndex.wrappedValue = pageIndex
#if os(macOS)
                hideSignaturePreview()
#endif
                onPlaceSignature(pageIndex, pagePoint)
                updateGestureAvailability()
                return
            }
            if annotationEditingEnabled,
               let annotation = annotation(at: pagePoint, pageIndex: pageIndex) {
                pdfView.clearSelection()
                selection.wrappedValue = nil
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = annotation
                selectedPageIndex.wrappedValue = pageIndex
#if os(macOS)
                if annotation.kind == .note {
                    presentCommentPopover(
                        for: annotation,
                        on: page,
                        in: pdfView,
                        openedByHover: false
                    )
                } else {
                    onOpenAnnotation(annotation)
                }
#else
                onOpenAnnotation(annotation)
#endif
                updateGestureAvailability()
                return
            }
            guard objectEditingEnabled else { return }
            selectedAnnotation.wrappedValue = nil
#if os(macOS)
            if selectStagedText(at: viewPoint, pageIndex: pageIndex) {
                return
            }
#endif
            let touchedObject = editableObject(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            )
            if touchedObject?.kind == .text {
                _ = selectCopyableText(at: pagePoint, on: page, pageIndex: pageIndex)
                return
            }
            if selectCopyableText(at: pagePoint, on: page, pageIndex: pageIndex) {
                return
            }
            pdfView.clearSelection()
            selection.wrappedValue = nil
            selectedObject.wrappedValue = touchedObject
            if let touchedObject {
                selectedPageIndex.wrappedValue = touchedObject.pageIndex
            }
            updateGestureAvailability()
            refreshOverlay()
        }

        private func activateTarget(at viewPoint: CGPoint) {
            guard prepareForCanvasInteraction(at: viewPoint),
                  !commentPlacementEnabled,
                  !freeTextPlacementEnabled,
                  !signaturePlacementEnabled,
                  let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false),
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
#if os(macOS)
            pendingInlineCaretLocation = nil
#endif
            if annotationEditingEnabled,
               let annotation = annotation(
                   at: pdfView.convert(viewPoint, to: page),
                   pageIndex: pageIndex
               ) {
                pdfView.clearSelection()
                selection.wrappedValue = nil
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = annotation
                selectedPageIndex.wrappedValue = pageIndex
                updateGestureAvailability()
                refreshOverlay()
                if annotation.kind == .freeText {
                    DispatchQueue.main.async { [weak self] in
                        self?.beginInlineTextEditing(annotation)
                    }
                } else {
#if os(macOS)
                    if annotation.kind == .note {
                        presentCommentPopover(
                            for: annotation,
                            on: page,
                            in: pdfView,
                            openedByHover: false
                        )
                    } else {
                        onOpenAnnotation(annotation)
                    }
#else
                    onOpenAnnotation(annotation)
#endif
                }
                return
            }
            guard objectEditingEnabled else { return }
#if os(macOS)
            pendingInlineCaretLocation = stagedTextHit(
                at: viewPoint,
                pageIndex: pageIndex
            )?.selectedRange.location
#endif
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let wordSelection = copyableWordSelection(at: pagePoint, on: page)
            guard let object = editableObject(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            ) else {
                guard let wordSelection,
                      let text = wordSelection.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                beginPendingTextActivation(
                    selection: wordSelection,
                    text: text,
                    pageIndex: pageIndex,
                    page: page
                )
                return
            }
            activateTextOrImageObject(
                object,
                pageIndex: pageIndex,
                in: pdfView,
                textSelection: wordSelection
            )
        }

        private func beginPendingTextActivation(
            selection wordSelection: PDFSelection,
            text: String,
            pageIndex: Int,
            page: PDFPage
        ) {
            let selectionBounds = wordSelection.bounds(for: page)
            guard let pdfView,
                  let frame = inlineTextEditorFrame(
                      pageIndex: pageIndex,
                      bounds: selectionBounds
                  ) else { return }
            finishInlineTextEditing(commit: false)
            pendingTextActivation = PendingTextActivation(
                pageIndex: pageIndex,
                selection: wordSelection,
                originalText: text,
                draftText: nil,
                draftStyle: nil
            )
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            selectedPageIndex.wrappedValue = pageIndex
            pdfView.clearSelection()
            self.selection.wrappedValue = nil
            beginInlineTextEditing(
                text: text,
                color: PDFObjectColor(red: 0, green: 0, blue: 0, alpha: 255),
                fontName: fontName(from: wordSelection),
                displayFontSize: displayFontSize(from: wordSelection) ??
                    max(frame.height * 0.82, 6),
                fontData: nil,
                frame: frame,
                maskFrame: textMaskFrame(pageIndex: pageIndex, bounds: selectionBounds),
                initialStyle: PDFTextStyle.inferred(
                    fromFontName: fontName(from: wordSelection)
                ),
                object: nil,
                annotation: nil
            )
        }

        private func activateTextOrImageObject(
            _ object: PDFPageObjectSnapshot,
            pageIndex: Int,
            in pdfView: PDFView,
            textSelection: PDFSelection? = nil
        ) {
            pendingTextActivation = nil
            let resolvedObject = object.kind == .text
                ? hydratedTextObject(object, on: pdfView.document?.page(at: pageIndex),
                                     selection: textSelection)
                : object
            pdfView.clearSelection()
            selection.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            selectedObject.wrappedValue = resolvedObject
            selectedPageIndex.wrappedValue = pageIndex
            updateGestureAvailability()
            refreshOverlay()
            if resolvedObject.kind == .text {
                DispatchQueue.main.async { [weak self] in
                    self?.beginInlineTextEditing(resolvedObject)
                }
            } else {
                onOpenObject(resolvedObject)
            }
        }

        private func beginFreeTextPlacement(
            pageIndex: Int,
            pagePoint: CGPoint,
            on page: PDFPage
        ) {
            guard freeTextPlacementEnabled else { return }
            finishInlineTextEditing(commit: true)
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            pdfView?.clearSelection()
            selection.wrappedValue = nil
            selectedPageIndex.wrappedValue = pageIndex

            let pageBounds = page.bounds(for: .cropBox).standardized
            let size = CGSize(
                width: min(72, pageBounds.width),
                height: min(28, pageBounds.height)
            )
            let maximumX = max(pageBounds.minX, pageBounds.maxX - size.width)
            let maximumY = max(pageBounds.minY, pageBounds.maxY - size.height)
            let bounds = CGRect(
                x: min(max(pagePoint.x, pageBounds.minX), maximumX),
                y: min(max(pagePoint.y - size.height, pageBounds.minY), maximumY),
                width: size.width,
                height: size.height
            )
            guard let frame = inlineTextEditorFrame(
                pageIndex: pageIndex,
                bounds: bounds
            ) else { return }

            pendingFreeTextPlacement = PendingFreeTextPlacement(
                pageIndex: pageIndex,
                minimumBounds: bounds,
                bounds: bounds,
                color: .black,
                fontSize: 11
            )
            beginInlineTextEditing(
                text: "",
                color: PDFObjectColor(red: 0, green: 0, blue: 0, alpha: 255),
                fontName: nil,
                displayFontSize: 11 * (pdfView?.scaleFactor ?? 1),
                fontData: nil,
                frame: frame,
                maskFrame: nil,
                initialStyle: [],
                object: nil,
                annotation: nil
            )
        }

        private func resolvePendingTextActivation() {
            guard let pendingTextActivation,
                  let pdfView,
                  let page = pdfView.document?.page(at: pendingTextActivation.pageIndex) else {
                return
            }
            guard objects.contains(where: {
                $0.pageIndex == pendingTextActivation.pageIndex
            }) else { return }
            guard let object = textObject(
                matching: pendingTextActivation.selection,
                on: page,
                pageIndex: pendingTextActivation.pageIndex
            ) else {
                return
            }
            let resolvedObject = hydratedTextObject(
                object,
                on: page,
                selection: pendingTextActivation.selection
            )
            let draft = pendingTextActivation.draftText
            let draftStyle = pendingTextActivation.draftStyle
            let keepsSelectionVisible = pendingTextActivation.keepsSelectionVisible
            self.pendingTextActivation = nil
            selectedObject.wrappedValue = keepsSelectionVisible ? resolvedObject : nil
            selectedPageIndex.wrappedValue = resolvedObject.pageIndex
            if let field = inlineTextField {
                inlineEditingObject = resolvedObject
#if os(macOS)
                if field.string == pendingTextActivation.originalText,
                   let resolvedText = resolvedObject.text {
                    field.string = resolvedText
                }
#elseif os(iOS)
                if field.text == pendingTextActivation.originalText,
                   let resolvedText = resolvedObject.text {
                    field.text = resolvedText
                }
#endif
                applyResolvedTextStyle(
                    resolvedObject,
                    to: field,
                    preservingCurrentPDFStyle: true
                )
            } else if let draft {
                let resolvedStyle = draftStyle ??
                    PDFTextStyle.inferred(fromFontName: resolvedObject.fontName)
                let originalStyle = PDFTextStyle.inferred(
                    fromFontName: resolvedObject.fontName
                )
                guard draft != pendingTextActivation.originalText ||
                        resolvedStyle != originalStyle else {
                    updateGestureAvailability()
                    refreshOverlay()
                    return
                }
                onReplaceTextObject(
                    resolvedObject,
                    draft,
                    resolvedStyle
                )
            }
            updateGestureAvailability()
            refreshOverlay()
        }

        private func hydratedTextObject(
            _ object: PDFPageObjectSnapshot,
            on page: PDFPage?,
            selection: PDFSelection?
        ) -> PDFPageObjectSnapshot {
            guard object.kind == .text else { return object }
            let objectSelection = page?.selection(for: object.bounds)
            let text = objectSelection?.string ?? selection?.string ?? object.text
            let resolvedFontName = fontName(from: objectSelection ?? selection)
            return PDFPageObjectSnapshot(
                pageIndex: object.pageIndex,
                path: object.path,
                kind: object.kind,
                bounds: object.bounds,
                transform: object.transform,
                fillColor: object.fillColor,
                text: text,
                fontName: resolvedFontName ?? object.fontName,
                fontSize: object.fontSize,
                fontData: object.fontData,
                imagePixelSize: object.imagePixelSize
            )
        }

        private func selectCopyableText(
            at pagePoint: CGPoint,
            on page: PDFPage,
            pageIndex: Int
        ) -> Bool {
#if os(macOS)
            clearStagedTextSelection()
#endif
            guard let pdfView,
                  let wordSelection = copyableWordSelection(at: pagePoint, on: page),
                  let text = wordSelection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pdfView?.clearSelection()
                selection.wrappedValue = nil
                selectedObject.wrappedValue = nil
                refreshOverlay()
                return false
            }
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            selectedPageIndex.wrappedValue = pageIndex
#if os(macOS)
            pdfView.window?.makeFirstResponder(pdfView)
#endif
            pdfView.setCurrentSelection(wordSelection, animate: false)
            selection.wrappedValue = wordSelection
            updateGestureAvailability()
            refreshOverlay()
            return true
        }

        private func copyableWordSelection(
            at pagePoint: CGPoint,
            on page: PDFPage
        ) -> PDFSelection? {
            let offsets: [CGFloat] = [0, -1.5, 1.5, -3, 3]
            for yOffset in offsets {
                for xOffset in offsets {
                    let point = CGPoint(
                        x: pagePoint.x + xOffset,
                        y: pagePoint.y + yOffset
                    )
                    if let selection = page.selectionForWord(at: point),
                       let text = selection.string,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return expandedContiguousWord(from: selection)
                    }
                }
            }
            let fallbackRect = CGRect(
                x: pagePoint.x - 4,
                y: pagePoint.y - 4,
                width: 8,
                height: 8
            )
            guard let selection = page.selection(for: fallbackRect),
                  let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return expandedContiguousWord(from: selection)
        }

        private func expandedContiguousWord(from selection: PDFSelection) -> PDFSelection {
            guard var expanded = selection.copy() as? PDFSelection else { return selection }
            for _ in 0..<32 {
                guard let currentText = expanded.string else { break }
                let candidates: [PDFSelection] = [true, false].compactMap { extendsStart in
                    guard let candidate = expanded.copy() as? PDFSelection else { return nil }
                    if extendsStart {
                        candidate.extend(atStart: 1)
                    } else {
                        candidate.extend(atEnd: 1)
                    }
                    return candidate
                }
                guard let candidate = candidates.first(where: { candidate in
                    guard let candidateText = candidate.string,
                          candidateText != currentText else { return false }
                    let addedText: Substring
                    if candidateText.hasPrefix(currentText) {
                        addedText = candidateText.dropFirst(currentText.count)
                    } else if candidateText.hasSuffix(currentText) {
                        addedText = candidateText.dropLast(currentText.count)
                    } else {
                        return false
                    }
                    return !addedText.isEmpty && addedText.allSatisfy(isWordCharacter)
                }) else { break }
                expanded = candidate
            }
            return expanded
        }

        private func isWordCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0.value == 95
            }
        }

        private func object(
            at pagePoint: CGPoint,
            pageIndex: Int
        ) -> PDFPageObjectSnapshot? {
            objects
                .filter {
                    $0.pageIndex == pageIndex &&
                    $0.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
                }
                .min { lhs, rhs in
                    let leftPriority = objectPriority(lhs)
                    let rightPriority = objectPriority(rhs)
                    if leftPriority != rightPriority { return leftPriority < rightPriority }
                    return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
                }
        }

        private func object(
            at viewPoint: CGPoint,
            on page: PDFPage,
            pageIndex: Int
        ) -> PDFPageObjectSnapshot? {
            guard let pdfView else { return nil }
            let hitTolerance: CGFloat = 6
            return objects
                .filter { object in
                    guard object.pageIndex == pageIndex else { return false }
                    return pdfView.convert(object.bounds, from: page)
                        .standardized
                        .insetBy(dx: -hitTolerance, dy: -hitTolerance)
                        .contains(viewPoint)
                }
                .min { lhs, rhs in
                    let leftPriority = objectPriority(lhs)
                    let rightPriority = objectPriority(rhs)
                    if leftPriority != rightPriority { return leftPriority < rightPriority }
                    let leftBounds = pdfView.convert(lhs.bounds, from: page).standardized
                    let rightBounds = pdfView.convert(rhs.bounds, from: page).standardized
                    return leftBounds.width * leftBounds.height <
                        rightBounds.width * rightBounds.height
                }
        }

        private func editableObject(
            at viewPoint: CGPoint,
            on page: PDFPage,
            pageIndex: Int
        ) -> PDFPageObjectSnapshot? {
#if os(macOS)
            if let stagedObject = stagedTextTarget(
                at: viewPoint,
                pageIndex: pageIndex
            )?.object {
                return stagedObject
            }
#endif
            let exactObject = object(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            )
            if exactObject?.kind == .text { return exactObject }
            guard let pdfView,
                  let selection = copyableWordSelection(
                      at: pdfView.convert(viewPoint, to: page),
                      on: page
                  ) else { return exactObject }
            return textObject(matching: selection, on: page, pageIndex: pageIndex) ?? exactObject
        }

        private func textObject(
            matching selection: PDFSelection,
            on page: PDFPage,
            pageIndex: Int
        ) -> PDFPageObjectSnapshot? {
            let selectionBounds = selection.bounds(for: page)
                .standardized
                .insetBy(dx: -3, dy: -3)
            let matchingTextObject = objects
                .filter {
                    $0.pageIndex == pageIndex &&
                    $0.kind == .text &&
                    $0.bounds.standardized.intersects(selectionBounds)
                }
                .min { lhs, rhs in
                    let left = lhs.bounds.standardized
                    let right = rhs.bounds.standardized
                    let leftDistance = hypot(
                        left.midX - selectionBounds.midX,
                        left.midY - selectionBounds.midY
                    )
                    let rightDistance = hypot(
                        right.midX - selectionBounds.midX,
                        right.midY - selectionBounds.midY
                    )
                    return leftDistance < rightDistance
                }
            return matchingTextObject
        }

        private func prepareForCanvasInteraction(at viewPoint: CGPoint) -> Bool {
            guard inlineTextField != nil else { return true }
            if inlineEditorContains(viewPoint) { return false }
            if pendingFreeTextPlacement != nil {
                finishInlineTextEditing(commit: true)
                return false
            }
            finishInlineTextEditing(commit: true)
            return true
        }

        private func inlineEditorContains(_ viewPoint: CGPoint) -> Bool {
            guard let pdfView, let inlineTextField else { return false }
            if let superview = inlineTextField.superview,
               pdfView.convert(inlineTextField.frame, from: superview).contains(viewPoint) {
                return true
            }
#if os(macOS)
            if let inlineStyleBar, let superview = inlineStyleBar.superview,
               pdfView.convert(inlineStyleBar.frame, from: superview).contains(viewPoint) {
                return true
            }
#endif
            return false
        }

        private func beginInlineTextEditing(_ object: PDFPageObjectSnapshot) {
            guard object.kind == .text,
                  let frame = inlineTextEditorFrame(for: object) else { return }
#if os(macOS)
            let editableText = stagedTextByObjectID[object.id]?.text ?? object.text ?? ""
            let initialStyle = stagedTextByObjectID[object.id]?.pdfStyle ??
                PDFTextStyle.inferred(fromFontName: object.fontName)
#else
            let editableText = object.text ?? ""
            let initialStyle = PDFTextStyle.inferred(fromFontName: object.fontName)
#endif
            beginInlineTextEditing(
                text: editableText,
                color: object.fillColor,
                fontName: object.fontName,
                displayFontSize: displayFontSize(for: object),
                fontData: object.fontData,
                frame: frame,
                maskFrame: textMaskFrame(for: object),
                initialStyle: initialStyle,
                object: object,
                annotation: nil
            )
        }

        private func beginInlineTextEditing(_ annotation: PDFAnnotationSnapshot) {
            guard annotation.kind == .freeText,
                  let frame = inlineTextEditorFrame(
                      pageIndex: annotation.reference.pageIndex,
                      bounds: annotation.bounds
                  ) else { return }
            let fontColor = annotation.fontColor ?? annotation.color
            beginInlineTextEditing(
                text: annotation.contents,
                color: PDFObjectColor(
                    red: UInt32((fontColor.red * 255).rounded()),
                    green: UInt32((fontColor.green * 255).rounded()),
                    blue: UInt32((fontColor.blue * 255).rounded()),
                    alpha: UInt32((fontColor.alpha * 255).rounded())
                ),
                fontName: nil,
                displayFontSize: annotation.fontSize.map {
                    $0 * (pdfView?.scaleFactor ?? 1)
                },
                fontData: nil,
                frame: frame,
                maskFrame: nil,
                initialStyle: [],
                object: nil,
                annotation: annotation
            )
        }

        private func beginInlineTextEditing(
            text: String,
            color: PDFObjectColor,
            fontName: String?,
            displayFontSize: CGFloat?,
            fontData: Data?,
            frame: CGRect,
            maskFrame: CGRect?,
            initialStyle: PDFTextStyle,
            object: PDFPageObjectSnapshot?,
            annotation: PDFAnnotationSnapshot?
        ) {
            guard let pdfView else { return }
#if os(macOS)
            removeTransientStagedTextFallback()
#endif
            finishInlineTextEditing(commit: false)
            inlineEditingObject = object
            inlineEditingAnnotation = annotation
            inlineEditingPDFStyle = initialStyle
            let isFreeTextEditor = annotation != nil || pendingFreeTextPlacement != nil
            if let annotation {
                hideFreeTextAnnotationForEditing(annotation)
            }

#if os(macOS)
            stagedTextViews[object?.id ?? ""]?.isHidden = true
            if let maskFrame {
                let maskView = PDFTextMaskView(frame: maskFrame)
                inlineTextMaskView = maskView
                pdfView.addSubview(maskView, positioned: .above, relativeTo: nil)
            }
            let field = PDFInlineTextView(frame: frame)
            field.allowsUndo = false
            field.string = text
            field.drawsBackground = maskFrame == nil && !isFreeTextEditor
            field.backgroundColor = maskFrame == nil && !isFreeTextEditor
                ? NSColor.white.withAlphaComponent(0.98)
                : .clear
            if isFreeTextEditor {
                field.wantsLayer = true
                field.layer?.borderWidth = 1
                field.layer?.borderColor = NSColor.controlAccentColor
                    .withAlphaComponent(0.75).cgColor
                field.layer?.cornerRadius = 3
            }
            let resolvedColor = objectTextColor(color)
            let resolvedStyle: InlineTextStyle
            if let object, let stagedEdit = stagedTextByObjectID[object.id] {
                resolvedStyle = stagedEdit.style
            } else {
                let font = objectFont(
                    named: fontName,
                    displayPointSize: displayFontSize,
                    fontData: fontData,
                    viewHeight: frame.height
                )
                resolvedStyle = InlineTextStyle(
                    font: font,
                    scaleFactor: pdfView.scaleFactor,
                    color: resolvedColor
                )
            }
            inlineEditingTextStyle = resolvedStyle
            field.textColor = resolvedStyle.color
            field.font = resolvedStyle.font(
                at: pdfView.scaleFactor,
                pdfStyle: inlineEditingPDFStyle
            )
            field.isEditable = true
            field.isSelectable = true
            field.isRichText = false
            field.importsGraphics = false
            field.allowsUndo = true
            field.textContainerInset = NSSize(width: 6, height: 4)
            field.textContainer?.lineFragmentPadding = 0
            field.isHorizontallyResizable = true
            field.isVerticallyResizable = true
            field.textContainer?.widthTracksTextView = false
            field.textContainer?.heightTracksTextView = false
            field.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            field.delegate = self
            inlineEditorDidGainFocus = false
            inlineTextField = field
            pdfView.addSubview(field, positioned: .above, relativeTo: inlineTextMaskView)
            if object != nil || pendingTextActivation != nil {
                installInlineStyleBar(above: field.frame, in: pdfView)
            }
            adjustInlineEditorWidth(field)
            adjustInlineEditorHeight(field)
            alignInlineTextBaseline(field, object: object, annotation: annotation)
            resizeFreeTextEditorToFit()
            focusInlineTextField(field, in: pdfView, attempt: 0)
#elseif os(iOS)
            let field = UITextView(frame: frame)
            field.text = text
            field.backgroundColor = isFreeTextEditor
                ? .clear
                : UIColor.systemBackground.withAlphaComponent(0.96)
            if isFreeTextEditor {
                field.layer.borderWidth = 1
                field.layer.borderColor = UIColor.systemBlue
                    .withAlphaComponent(0.75).cgColor
                field.layer.cornerRadius = 3
            }
            field.textColor = objectTextColor(color)
            field.textContainerInset = UIEdgeInsets(
                top: 4,
                left: 6,
                bottom: 4,
                right: 6
            )
            field.textContainer.lineFragmentPadding = 0
            let baseFont = objectFont(
                named: fontName,
                displayPointSize: displayFontSize,
                fontData: fontData,
                viewHeight: frame.height
            )
            inlineEditingBaseFont = baseFont
            field.font = styledFont(baseFont, style: inlineEditingPDFStyle)
            field.delegate = self
            field.inputAccessoryView = makeInlineStyleToolbar(
                showsStyleControls: object != nil || pendingTextActivation != nil
            )
            inlineTextField = field
            pdfView.addSubview(field)
            resizeFreeTextEditorToFit()
            field.becomeFirstResponder()
            if let range = field.textRange(
                from: field.beginningOfDocument,
                to: field.endOfDocument
            ) {
                field.selectedTextRange = range
            }
#endif
            refreshOverlay()
        }

        private func finishInlineTextEditing(
            commit: Bool,
            notifiesFreeTextCancellation: Bool = true
        ) {
            guard !isFinishingInlineTextEditing,
                  let field = inlineTextField else { return }
            let object = inlineEditingObject
            let annotation = inlineEditingAnnotation
            let freeTextPlacement = pendingFreeTextPlacement
            guard object != nil || annotation != nil || pendingTextActivation != nil ||
                    freeTextPlacement != nil else { return }
            let editedAnnotationBounds: CGRect?
            if let annotation,
               let pdfView,
               let page = pdfView.document?.page(
                   at: annotation.reference.pageIndex
               ) {
                editedAnnotationBounds = pdfView.convert(
                    field.frame,
                    to: page
                ).standardized
            } else {
                editedAnnotationBounds = nil
            }
            restoreHiddenFreeTextAnnotation()
            isFinishingInlineTextEditing = true
#if os(macOS)
            let text = field.string
            let textStyle = inlineEditingTextStyle
            let pdfStyle = inlineEditingPDFStyle
            field.delegate = nil
            field.discardUndoHistory()
            pdfView?.window?.makeFirstResponder(pdfView)
            let mask = inlineTextMaskView
            inlineTextMaskView = nil
            inlineStyleBar?.removeFromSuperview()
            inlineStyleBar = nil
            inlineEditorDidGainFocus = false
            inlineEditingTextStyle = nil
            pdfView?.needsDisplay = true
#elseif os(iOS)
            let text = field.text ?? ""
            let pdfStyle = inlineEditingPDFStyle
            field.delegate = nil
            field.resignFirstResponder()
            field.removeFromSuperview()
            inlineEditingBaseFont = nil
            inlineBoldButton = nil
            inlineItalicButton = nil
#endif
            inlineTextField = nil
            inlineEditingObject = nil
            inlineEditingAnnotation = nil
            pendingFreeTextPlacement = nil
            inlineEditingPDFStyle = []
            isFinishingInlineTextEditing = false
            if let freeTextPlacement {
#if os(macOS)
                removeInlineTextEditingViews(field, mask: mask)
#endif
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if commit, !trimmedText.isEmpty {
                    onPlaceFreeText(
                        freeTextPlacement.pageIndex,
                        freeTextPlacement.bounds,
                        text,
                        freeTextPlacement.color,
                        freeTextPlacement.fontSize
                    )
                } else if notifiesFreeTextCancellation {
                    onCancelFreeTextPlacement()
                }
                refreshOverlay()
                return
            }
            if object == nil, annotation == nil {
#if os(macOS)
                removeInlineTextEditingViews(field, mask: mask)
#endif
                if commit {
                    pendingTextActivation?.draftText = text
                    pendingTextActivation?.draftStyle = pdfStyle
                    pendingTextActivation?.keepsSelectionVisible = false
                } else {
                    pendingTextActivation = nil
                }
                refreshOverlay()
                return
            }
#if os(macOS)
            if let object {
                let originalStyle = PDFTextStyle.inferred(fromFontName: object.fontName)
                if commit, (text != object.text || pdfStyle != originalStyle), let textStyle {
                    stagedTextStylesByObjectID[object.id] = textStyle
                    stagedTextByObjectID[object.id] = StagedTextEdit(
                        text: text,
                        style: textStyle,
                        pdfStyle: pdfStyle
                    )
                } else if commit {
                    stagedTextByObjectID.removeValue(forKey: object.id)
                }
                if commit,
                   stagedTextByObjectID[object.id] != nil,
                   !hasMountedPageOverlay(for: object.pageIndex) {
                    freezeInlineTextEditor(
                        field,
                        mask: mask,
                        for: object
                    )
                } else {
                    removeInlineTextEditingViews(field, mask: mask)
                }
                updateStagedTextOverlays()
            } else {
                removeInlineTextEditingViews(field, mask: mask)
            }
#endif
            refreshOverlay()
            if commit, let object {
#if os(macOS)
                DispatchQueue.main.async { [weak self] in
                    self?.onReplaceTextObject(object, text, pdfStyle)
                }
#else
                onReplaceTextObject(object, text, pdfStyle)
#endif
            }
            if commit, let annotation, text != annotation.contents {
                onReplaceAnnotationText(
                    annotation,
                    text,
                    editedAnnotationBounds ?? annotation.bounds
                )
            }
        }

        private func updateInlineTextEditorFrame() {
            let frame: CGRect?
            if let object = inlineEditingObject {
                frame = inlineTextEditorFrame(for: object)
            } else if let annotation = inlineEditingAnnotation {
                frame = inlineTextEditorFrame(
                    pageIndex: annotation.reference.pageIndex,
                    bounds: annotation.bounds
                )
            } else if let pendingFreeTextPlacement {
                frame = inlineTextEditorFrame(
                    pageIndex: pendingFreeTextPlacement.pageIndex,
                    bounds: pendingFreeTextPlacement.bounds
                )
            } else if let pendingTextActivation,
                      let page = pdfView?.document?.page(
                          at: pendingTextActivation.pageIndex
                      ) {
                frame = inlineTextEditorFrame(
                    pageIndex: pendingTextActivation.pageIndex,
                    bounds: pendingTextActivation.selection.bounds(for: page)
                )
            } else {
                frame = nil
            }
            guard let frame, let inlineTextField else { return }
#if os(macOS)
            if let pdfView, let superview = inlineTextField.superview {
                let localFrame = superview.convert(frame, from: pdfView)
                if let object = inlineEditingObject {
                    inlineTextMaskView?.frame = textMaskFrame(for: object).map {
                        superview.convert($0, from: pdfView)
                    } ?? .zero
                }
                inlineTextField.frame = localFrame
                adjustInlineEditorWidth(inlineTextField)
                adjustInlineEditorHeight(inlineTextField)
                alignInlineTextBaseline(
                    inlineTextField,
                    object: inlineEditingObject,
                    annotation: inlineEditingAnnotation
                )
                positionInlineStyleBar(above: inlineTextField.frame)
                resizeFreeTextEditorToFit()
                return
            }
#endif
            let current = inlineTextField.frame
            guard abs(current.minX - frame.minX) > 0.5 ||
                    abs(current.minY - frame.minY) > 0.5 ||
                    abs(current.width - frame.width) > 0.5 ||
                    abs(current.height - frame.height) > 0.5 else { return }
            inlineTextField.frame = frame
            resizeFreeTextEditorToFit()
        }

        private func resizeFreeTextEditorToFit() {
            guard inlineEditingObject == nil,
                  pendingTextActivation == nil,
                  let pdfView,
                  let field = inlineTextField else { return }

            let pageIndex: Int
            let minimumBounds: CGRect
            if let pendingFreeTextPlacement {
                pageIndex = pendingFreeTextPlacement.pageIndex
                minimumBounds = pendingFreeTextPlacement.minimumBounds
            } else if let annotation = inlineEditingAnnotation {
                pageIndex = annotation.reference.pageIndex
                minimumBounds = annotation.bounds
            } else {
                return
            }
            guard let page = pdfView.document?.page(at: pageIndex) else { return }

#if os(macOS)
            let text = field.string
            guard let font = field.font else { return }
            let lineHeight = ceil(
                field.layoutManager?.defaultLineHeight(for: font) ??
                    font.ascender - font.descender + font.leading
            )
#else
            let text = field.text ?? ""
            guard let font = field.font else { return }
            let lineHeight = ceil(font.lineHeight)
#endif
            let lines = text.components(separatedBy: "\n")
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let widestLine = lines.reduce(CGFloat.zero) { width, line in
                max(width, (line as NSString).size(withAttributes: attributes).width)
            }

            let minimumFrame = pdfView.convert(minimumBounds, from: page).standardized
            let pageFrame = pdfView.convert(
                page.bounds(for: .cropBox),
                from: page
            ).standardized
            let minimumWidth = text.isEmpty
                ? min(minimumFrame.width, pageFrame.width)
                : min(24, pageFrame.width)
            let width = min(
                max(minimumWidth, ceil(widestLine) + 12),
                pageFrame.width
            )
            let renderedHeight = (text as NSString).boundingRect(
                with: CGSize(
                    width: max(width - 12, 1),
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).height
            let contentHeight = max(
                lineHeight * CGFloat(max(lines.count, 1)),
                ceil(renderedHeight)
            )
            let measuredHeight = contentHeight + 8
            let minimumHeight = text.isEmpty
                ? min(minimumFrame.height, pageFrame.height)
                : CGFloat.zero
            let height = min(
                max(minimumHeight, measuredHeight),
                pageFrame.height
            )
            let origin = CGPoint(
                x: min(
                    max(minimumFrame.minX, pageFrame.minX),
                    max(pageFrame.minX, pageFrame.maxX - width)
                ),
                y: min(
                    max(minimumFrame.minY, pageFrame.minY),
                    max(pageFrame.minY, pageFrame.maxY - height)
                )
            )
            let fittedFrame = CGRect(
                origin: origin,
                size: CGSize(width: width, height: height)
            )
            field.frame = fittedFrame
            let verticalInset = max(0, (height - contentHeight) / 2)
#if os(macOS)
            field.textContainerInset = NSSize(width: 6, height: verticalInset)
#else
            field.textContainerInset = UIEdgeInsets(
                top: verticalInset,
                left: 6,
                bottom: verticalInset,
                right: 6
            )
#endif

            if var pendingFreeTextPlacement {
                pendingFreeTextPlacement.bounds = pdfView.convert(
                    fittedFrame,
                    to: page
                ).standardized
                self.pendingFreeTextPlacement = pendingFreeTextPlacement
                updatePendingFreeTextActionBar(
                    above: fittedFrame,
                    in: pdfView
                )
            }
        }

        private func updatePendingFreeTextColor(_ color: PDFAnnotationColor) {
            guard var pendingFreeTextPlacement,
                  let field = inlineTextField else { return }
            pendingFreeTextPlacement.color = color
            self.pendingFreeTextPlacement = pendingFreeTextPlacement
#if os(macOS)
            field.textColor = NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
            if let pdfView {
                focusInlineTextField(field, in: pdfView, attempt: 0)
            }
#else
            field.textColor = UIColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
            field.becomeFirstResponder()
#endif
            refreshOverlay()
        }

        private func updatePendingFreeTextFontSize(_ fontSize: CGFloat) {
            guard var pendingFreeTextPlacement,
                  let pdfView,
                  let field = inlineTextField else { return }
            pendingFreeTextPlacement.fontSize = fontSize
            self.pendingFreeTextPlacement = pendingFreeTextPlacement
            let displayFontSize = fontSize * max(pdfView.scaleFactor, 0.001)
#if os(macOS)
            field.font = NSFont.systemFont(ofSize: displayFontSize)
#else
            let font = UIFont.systemFont(ofSize: displayFontSize)
            inlineEditingBaseFont = font
            field.font = font
#endif
            resizeFreeTextEditorToFit()
#if os(macOS)
            focusInlineTextField(field, in: pdfView, attempt: 0)
#else
            field.becomeFirstResponder()
#endif
            refreshOverlay()
        }

        private func hideFreeTextAnnotationForEditing(
            _ snapshot: PDFAnnotationSnapshot
        ) {
            restoreHiddenFreeTextAnnotation()
            guard let pdfView,
                  let page = pdfView.document?.page(at: snapshot.reference.pageIndex),
                  page.annotations.indices.contains(snapshot.reference.annotationIndex) else {
                return
            }
            let annotation = page.annotations[snapshot.reference.annotationIndex]
            guard annotation.type == "FreeText" else { return }
            hiddenFreeTextAnnotation = HiddenFreeTextAnnotation(
                annotation: annotation,
                shouldDisplay: annotation.shouldDisplay
            )
            annotation.shouldDisplay = false
            refreshPDFViewDisplay()
        }

        private func restoreHiddenFreeTextAnnotation() {
            guard let hiddenFreeTextAnnotation else { return }
            self.hiddenFreeTextAnnotation = nil
            hiddenFreeTextAnnotation.annotation.shouldDisplay =
                hiddenFreeTextAnnotation.shouldDisplay
            refreshPDFViewDisplay()
        }

        private func refreshPDFViewDisplay() {
#if os(macOS)
            pdfView?.needsDisplay = true
#else
            pdfView?.setNeedsDisplay()
#endif
        }

        private func inlineTextEditorFrame(
            for object: PDFPageObjectSnapshot
        ) -> CGRect? {
            inlineTextEditorFrame(pageIndex: object.pageIndex, bounds: object.bounds)
        }

        private func textMaskFrame(
            for object: PDFPageObjectSnapshot
        ) -> CGRect? {
            textMaskFrame(pageIndex: object.pageIndex, bounds: object.bounds)
        }

        private func textMaskFrame(
            pageIndex: Int,
            bounds: CGRect
        ) -> CGRect? {
            guard let pdfView,
                  let page = pdfView.document?.page(at: pageIndex) else { return nil }
            let converted = pdfView.convert(bounds, from: page).standardized
            guard converted.width.isFinite,
                  converted.height.isFinite,
                  converted.width > 0,
                  converted.height > 0 else { return nil }
#if os(macOS)
            return backingAlignedMaskFrame(converted, in: pdfView)
#else
            return converted
#endif
        }

#if os(macOS)
        private func backingAlignedMaskFrame(
            _ frame: CGRect,
            in pdfView: PDFView
        ) -> CGRect {
            let backingFrame = pdfView.convertToBacking(frame)
            let minX = floor(backingFrame.minX)
            let minY = floor(backingFrame.minY)
            let maxX = ceil(backingFrame.maxX)
            let maxY = ceil(backingFrame.maxY)
            guard maxX > minX, maxY > minY else { return frame }
            return pdfView.convertFromBacking(CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )).standardized
        }

        private func hasMountedPageOverlay(for pageIndex: Int) -> Bool {
            guard let pageOverlay = pageOverlayViews[pageIndex] else { return false }
            return pageOverlay.superview != nil && pageOverlay.window != nil
        }

        private func freezeInlineTextEditor(
            _ editor: PDFInlineTextView,
            mask: PDFTextMaskView?,
            for object: PDFPageObjectSnapshot
        ) {
            removeTransientStagedTextFallback()
            editor.isEditable = false
            editor.isSelectable = false
            editor.selectedRange = NSRange(location: 0, length: 0)
            editor.insertionPointColor = .clear
            transientStagedTextFallback = TransientStagedTextFallback(
                objectID: object.id,
                pageIndex: object.pageIndex,
                editor: editor,
                mask: mask
            )
        }

        private func removeInlineTextEditingViews(
            _ editor: PDFInlineTextView,
            mask: PDFTextMaskView?
        ) {
            editor.removeFromSuperview()
            mask?.removeFromSuperview()
        }

        private func removeTransientStagedTextFallback() {
            transientStagedTextFallback?.editor.removeFromSuperview()
            transientStagedTextFallback?.mask?.removeFromSuperview()
            transientStagedTextFallback = nil
        }

        private func removeTransientStagedTextFallback(for objectID: String) {
            guard transientStagedTextFallback?.objectID == objectID else { return }
            removeTransientStagedTextFallback()
        }
#endif

        private func inlineTextEditorFrame(
            pageIndex: Int,
            bounds: CGRect
        ) -> CGRect? {
            guard let pdfView,
                  let page = pdfView.document?.page(at: pageIndex) else { return nil }
            let converted = pdfView.convert(bounds, from: page).standardized
            guard converted.width.isFinite, converted.height.isFinite else { return nil }
            let width = max(converted.width, 24)
            let height = max(converted.height, 14)
            return CGRect(
                x: converted.minX,
                y: converted.minY,
                width: width,
                height: height
            )
        }

        private func displayFontSize(for object: PDFPageObjectSnapshot) -> CGFloat? {
            guard let pdfView,
                  let page = pdfView.document?.page(at: object.pageIndex),
                  let fontSize = object.fontSize else { return nil }
            let verticalScale = hypot(object.transform.c, object.transform.d)
            let effectiveHeight = fontSize * max(verticalScale, 0.001)
            let origin = pdfView.convert(CGPoint.zero, from: page)
            let verticalPoint = pdfView.convert(
                CGPoint(x: 0, y: effectiveHeight),
                from: page
            )
            let displaySize = hypot(
                verticalPoint.x - origin.x,
                verticalPoint.y - origin.y
            )
            guard displaySize.isFinite, displaySize > 0 else { return nil }
            return displaySize
        }

#if os(macOS)
        private func installInlineStyleBar(above frame: CGRect, in container: NSView) {
            let boldButton = NSButton(
                title: "B",
                target: self,
                action: #selector(toggleInlineBold(_:))
            )
            boldButton.tag = 1
            boldButton.toolTip = "Bold"
            boldButton.setAccessibilityLabel("Bold")
            boldButton.setButtonType(.toggle)
            boldButton.refusesFirstResponder = true
            boldButton.bezelStyle = .texturedRounded
            boldButton.font = .boldSystemFont(ofSize: 13)

            let italicButton = NSButton(
                title: "I",
                target: self,
                action: #selector(toggleInlineItalic(_:))
            )
            italicButton.tag = 2
            italicButton.toolTip = "Italic"
            italicButton.setAccessibilityLabel("Italic")
            italicButton.setButtonType(.toggle)
            italicButton.refusesFirstResponder = true
            italicButton.bezelStyle = .texturedRounded
            italicButton.font = NSFontManager.shared.convert(
                .systemFont(ofSize: 13),
                toHaveTrait: .italicFontMask
            )

            let stack = NSStackView(views: [boldButton, italicButton])
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.96).cgColor
            stack.layer?.cornerRadius = 6
            stack.frame.size = stack.fittingSize
            inlineStyleBar = stack
            container.addSubview(stack, positioned: .above, relativeTo: inlineTextField)
            positionInlineStyleBar(above: frame)
            updateInlineStyleButtonStates()
        }

        private func positionInlineStyleBar(above frame: CGRect) {
            guard let inlineStyleBar, let container = inlineStyleBar.superview else { return }
            let size = inlineStyleBar.fittingSize
            let y: CGFloat
            if container.isFlipped {
                y = max(frame.minY - size.height - 4, 4)
            } else {
                y = min(
                    frame.maxY + 4,
                    max(container.bounds.maxY - size.height - 4, 4)
                )
            }
            inlineStyleBar.frame = CGRect(
                x: min(max(frame.minX, 4), max(container.bounds.maxX - size.width - 4, 4)),
                y: y,
                width: size.width,
                height: size.height
            )
        }

        @objc private func toggleInlineBold(_ sender: NSButton) {
            inlineEditingPDFStyle.formSymmetricDifference(.bold)
            updateInlineTextStylePreview()
        }

        @objc private func toggleInlineItalic(_ sender: NSButton) {
            inlineEditingPDFStyle.formSymmetricDifference(.italic)
            updateInlineTextStylePreview()
        }

        private func updateInlineStyleButtonStates() {
            guard let buttons = inlineStyleBar?.views as? [NSButton] else { return }
            for button in buttons {
                if button.tag == 1 {
                    button.state = inlineEditingPDFStyle.contains(.bold) ? .on : .off
                } else if button.tag == 2 {
                    button.state = inlineEditingPDFStyle.contains(.italic) ? .on : .off
                }
            }
        }

        private func updateInlineTextStylePreview() {
            guard let pdfView,
                  let field = inlineTextField,
                  let style = inlineEditingTextStyle else { return }
            field.font = style.font(
                at: field.superview is PDFPageOverlayContainer ? 1 : pdfView.scaleFactor,
                pdfStyle: inlineEditingPDFStyle
            )
            updateInlineStyleButtonStates()
            adjustInlineEditorWidth(field)
            adjustInlineEditorHeight(field)
            alignInlineTextBaseline(
                field,
                object: inlineEditingObject,
                annotation: inlineEditingAnnotation
            )
            positionInlineStyleBar(above: field.frame)
        }

        private func focusInlineTextField(
            _ field: NSTextView,
            in pdfView: PDFView,
            attempt: Int
        ) {
            let delay = attempt == 0 ? 0 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak pdfView, weak field] in
                guard let self, let pdfView, let field,
                      inlineTextField === field else { return }
                let accepted = pdfView.window?.makeFirstResponder(field) == true
                if accepted {
                    inlineEditorDidGainFocus = true
                    if let pendingInlineCaretLocation {
                        let location = min(
                            max(pendingInlineCaretLocation, 0),
                            field.string.utf16.count
                        )
                        field.selectedRange = NSRange(location: location, length: 0)
                        self.pendingInlineCaretLocation = nil
                    } else {
                        field.selectedRange = NSRange(
                            location: 0,
                            length: field.string.utf16.count
                        )
                    }
                } else if attempt < 3 {
                    focusInlineTextField(field, in: pdfView, attempt: attempt + 1)
                } else {
                    pendingInlineCaretLocation = nil
                }
            }
        }

        private func objectTextColor(_ color: PDFObjectColor) -> NSColor {
            NSColor(
                calibratedRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: max(CGFloat(color.alpha) / 255, 0.15)
            )
        }

        private func fontName(from selection: PDFSelection?) -> String? {
            guard let attributedString = selection?.attributedString,
                  attributedString.length > 0 else { return nil }
            return (attributedString.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont)?.fontName
        }

        private func displayFontSize(from selection: PDFSelection?) -> CGFloat? {
            guard let pdfView,
                  let attributedString = selection?.attributedString,
                  attributedString.length > 0,
                  let font = attributedString.attribute(
                      .font,
                      at: 0,
                      effectiveRange: nil
                  ) as? NSFont else { return nil }
            let displaySize = font.pointSize * max(pdfView.scaleFactor, 0.001)
            return displaySize.isFinite && displaySize > 0 ? displaySize : nil
        }

        private func applyResolvedTextStyle(
            _ object: PDFPageObjectSnapshot,
            to field: NSTextView,
            preservingCurrentPDFStyle: Bool
        ) {
            guard let pdfView else { return }
            let color = objectTextColor(object.fillColor)
            let font = objectFont(
                named: object.fontName,
                displayPointSize: displayFontSize(for: object),
                fontData: object.fontData,
                viewHeight: field.frame.height
            )
            let style = InlineTextStyle(
                font: font,
                scaleFactor: pdfView.scaleFactor,
                color: color
            )
            if !preservingCurrentPDFStyle {
                inlineEditingPDFStyle = stagedTextByObjectID[object.id]?.pdfStyle ??
                    PDFTextStyle.inferred(fromFontName: object.fontName)
            }
            inlineEditingTextStyle = style
            field.textColor = color
            field.font = style.font(
                at: field.superview is PDFPageOverlayContainer ? 1 : pdfView.scaleFactor,
                pdfStyle: inlineEditingPDFStyle
            )
            if inlineStyleBar == nil {
                guard let container = field.superview else { return }
                installInlineStyleBar(above: field.frame, in: container)
            } else {
                updateInlineStyleButtonStates()
            }
            if let frame = inlineTextEditorFrame(for: object) {
                field.frame = field.superview?.convert(frame, from: pdfView) ?? frame
            }
            inlineTextMaskView?.frame = textMaskFrame(for: object).map {
                field.superview?.convert($0, from: pdfView) ?? $0
            } ?? .zero
            adjustInlineEditorWidth(field)
            adjustInlineEditorHeight(field)
            alignInlineTextBaseline(field, object: object, annotation: nil)
        }

        private func objectFont(
            named fontName: String?,
            displayPointSize: CGFloat?,
            fontData: Data?,
            viewHeight: CGFloat
        ) -> NSFont {
            let size = max(min(displayPointSize ?? viewHeight * 0.82, 192), 6)
            let font: NSFont
            if let fontData,
               let provider = CGDataProvider(data: fontData as CFData),
               let graphicsFont = CGFont(provider) {
                font = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as NSFont
            } else {
                let name = fontName?.split(separator: "+").last.map(String.init)
                font = name.flatMap { NSFont(name: $0, size: size) } ??
                    NSFont.systemFont(ofSize: size)
            }
            return font
        }

        private func adjustInlineEditorWidth(_ textView: NSTextView) {
            guard let pdfView,
                  let superview = textView.superview,
                  let object = inlineEditingObject,
                  let baseFrame = inlineTextEditorFrame(for: object),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let localBaseFrame = superview.convert(baseFrame, from: pdfView)
            layoutManager.ensureLayout(for: textContainer)
            let measuredWidth = layoutManager.usedRect(for: textContainer).width + 4
            let availableWidth = max(
                superview.bounds.maxX - localBaseFrame.minX - 8,
                localBaseFrame.width
            )
            textView.frame.size.width = min(
                max(localBaseFrame.width, measuredWidth),
                availableWidth
            )
        }

        private func adjustInlineEditorHeight(_ textView: NSTextView) {
            guard let pdfView,
                  let superview = textView.superview,
                  let object = inlineEditingObject,
                  let baseFrame = inlineTextEditorFrame(for: object),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let localBaseFrame = superview.convert(baseFrame, from: pdfView)
            layoutManager.ensureLayout(for: textContainer)
            let measuredHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            guard measuredHeight.isFinite else { return }
            textView.frame.size.height = max(localBaseFrame.height, measuredHeight)
        }

        private func alignInlineTextBaseline(
            _ textView: NSTextView,
            object: PDFPageObjectSnapshot?,
            annotation: PDFAnnotationSnapshot?
        ) {
            guard annotation == nil else { return }
            guard let pdfView, let superview = textView.superview else { return }
            let baselineY: CGFloat
            if let object,
               let objectBaselineY = inlineTextBaselineY(for: object),
               let objectFrame = inlineTextEditorFrame(for: object) {
                baselineY = superview.convert(
                    CGPoint(x: objectFrame.minX, y: objectBaselineY),
                    from: pdfView
                ).y
            } else {
                guard let font = textView.font else { return }
                baselineY = superview.isFlipped
                    ? textView.frame.maxY + font.descender
                    : textView.frame.minY - font.descender
            }
            textView.frame = baselineAlignedFrame(
                for: textView,
                baseFrame: textView.frame,
                baselineY: baselineY,
                usesFlippedCoordinates: superview.isFlipped
            )
        }

        private func inlineTextBaselineY(
            for object: PDFPageObjectSnapshot
        ) -> CGFloat? {
            guard let pdfView,
                  let page = pdfView.document?.page(at: object.pageIndex) else { return nil }
            let baseline = pdfView.convert(
                CGPoint(x: object.transform.tx, y: object.transform.ty),
                from: page
            ).y
            return baseline.isFinite ? baseline : nil
        }

        private func baselineAlignedFrame(
            for textView: NSTextView,
            baseFrame: CGRect,
            baselineY: CGFloat,
            usesFlippedCoordinates: Bool? = nil
        ) -> CGRect {
            guard let pdfView,
                  !textView.string.isEmpty,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return baseFrame }
            layoutManager.ensureLayout(for: textContainer)
            guard layoutManager.numberOfGlyphs > 0 else { return baseFrame }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
            let baselineOffsetFromTop = textView.textContainerOrigin.y +
                lineRect.minY + glyphLocation.y
            guard baselineOffsetFromTop.isFinite else { return baseFrame }
            var alignedFrame = baseFrame
            alignedFrame.origin.y = (usesFlippedCoordinates ?? pdfView.isFlipped)
                ? baselineY - baselineOffsetFromTop
                : baselineY + baselineOffsetFromTop - baseFrame.height
            return alignedFrame
        }

        private func updateStagedTextOverlays() {
            guard let pdfView, let document = pdfView.document else { return }
            let liveObjects = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
            if let fallback = transientStagedTextFallback,
               stagedTextByObjectID[fallback.objectID] == nil ||
               liveObjects[fallback.objectID] == nil {
                removeTransientStagedTextFallback()
            }
            let renderedIDs = Set(stagedTextViews.keys).union(stagedTextMaskViews.keys)
            let obsoleteIDs = renderedIDs.filter {
                stagedTextByObjectID[$0] == nil || liveObjects[$0] == nil
            }
            for objectID in obsoleteIDs {
                stagedTextViews.removeValue(forKey: objectID)?.removeFromSuperview()
                stagedTextMaskViews.removeValue(forKey: objectID)?.removeFromSuperview()
            }

            for (objectID, edit) in stagedTextByObjectID {
                guard let object = liveObjects[objectID],
                      let page = document.page(at: object.pageIndex),
                      hasMountedPageOverlay(for: object.pageIndex),
                      let pageOverlay = pageOverlayViews[object.pageIndex],
                      let frame = inlineTextEditorFrame(for: object),
                      let maskFrame = textMaskFrame(for: object) else { continue }
                let pageFrame = pageOverlay.convert(frame, from: pdfView)
                let maskView = stagedTextMaskViews[objectID] ?? PDFTextMaskView(frame: maskFrame)
                if stagedTextMaskViews[objectID] == nil {
                    stagedTextMaskViews[objectID] = maskView
                }
                if maskView.superview !== pageOverlay {
                    maskView.removeFromSuperview()
                    pageOverlay.addSubview(maskView, positioned: .above, relativeTo: nil)
                }
                maskView.frame = pageOverlay.convert(maskFrame, from: pdfView)
                let view = stagedTextViews[objectID] ?? PDFPassiveTextView(frame: frame)
                if stagedTextViews[objectID] == nil {
                    view.isEditable = false
                    view.isSelectable = true
                    view.isRichText = false
                    view.drawsBackground = false
                    view.backgroundColor = .clear
                    view.isVerticallyResizable = true
                    view.maxSize = NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                    view.textContainerInset = .zero
                    view.textContainer?.lineFragmentPadding = 0
                    view.textContainer?.widthTracksTextView = true
                    view.textContainer?.heightTracksTextView = false
                    stagedTextViews[objectID] = view
                }
                if view.superview !== pageOverlay {
                    view.removeFromSuperview()
                    pageOverlay.addSubview(view, positioned: .above, relativeTo: maskView)
                }
                if view.string != edit.text {
                    view.string = edit.text
                }
                view.textColor = edit.style.color
                view.font = edit.style.font(
                    at: 1,
                    pdfStyle: edit.pdfStyle
                )
                var stagedFrame = pageFrame
                if let font = view.font {
                    let measuredWidth = (edit.text as NSString).size(
                        withAttributes: [.font: font]
                    ).width + 4
                    let pageBounds = pageOverlay.convert(
                        pdfView.convert(page.bounds(for: pdfView.displayBox), from: page),
                        from: pdfView
                    ).standardized
                    let availableWidth = max(
                        pageBounds.maxX - pageFrame.minX - 8,
                        pageFrame.width
                    )
                    stagedFrame.size.width = min(
                        max(pageFrame.width, measuredWidth),
                        availableWidth
                    )
                }
                if let layoutManager = view.layoutManager,
                   let textContainer = view.textContainer {
                    textContainer.containerSize = NSSize(
                        width: stagedFrame.width,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                    layoutManager.ensureLayout(for: textContainer)
                    let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
                    if contentHeight.isFinite {
                        stagedFrame.size.height = max(pageFrame.height, contentHeight)
                    }
                }
                if let baselineY = inlineTextBaselineY(for: object) {
                    let pageBaselineY = pageOverlay.convert(
                        CGPoint(x: frame.minX, y: baselineY),
                        from: pdfView
                    ).y
                    stagedFrame = baselineAlignedFrame(
                        for: view,
                        baseFrame: stagedFrame,
                        baselineY: pageBaselineY,
                        usesFlippedCoordinates: pageOverlay.isFlipped
                    )
                }
                view.frame = stagedFrame
                view.isHidden = inlineEditingObject?.id == objectID
                maskView.needsDisplay = true
                view.needsDisplay = true
                pageOverlay.needsDisplay = true
                removeTransientStagedTextFallback(for: objectID)
            }
        }

        private func stagedTextTarget(
            at viewPoint: CGPoint,
            pageIndex: Int
        ) -> (object: PDFPageObjectSnapshot, view: PDFPassiveTextView)? {
            guard let pdfView,
                  let objectID = stagedTextViews.first(where: { objectID, view in
                guard let superview = view.superview else { return false }
                let frameInPDFView = pdfView.convert(view.frame, from: superview)
                return stagedTextByObjectID[objectID] != nil &&
                    !view.isHidden &&
                    frameInPDFView.contains(viewPoint)
            })?.key,
                  let view = stagedTextViews[objectID],
                  let object = objects.first(where: {
                      $0.id == objectID && $0.pageIndex == pageIndex
                  }) else { return nil }
            return (object, view)
        }

        private func selectStagedText(
            at viewPoint: CGPoint,
            pageIndex: Int
        ) -> Bool {
            guard let pdfView,
                  let hit = stagedTextHit(at: viewPoint, pageIndex: pageIndex) else {
                return false
            }
            pdfView.clearSelection()
            selection.wrappedValue = nil
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            selectedPageIndex.wrappedValue = pageIndex
            hit.target.view.window?.makeFirstResponder(hit.target.view)
            hit.target.view.selectedRange = hit.selectedRange
            updateGestureAvailability()
            return true
        }

        private func stagedTextHit(
            at viewPoint: CGPoint,
            pageIndex: Int
        ) -> (
            target: (object: PDFPageObjectSnapshot, view: PDFPassiveTextView),
            selectedRange: NSRange
        )? {
            guard let pdfView,
                  let target = stagedTextTarget(at: viewPoint, pageIndex: pageIndex),
                  let layoutManager = target.view.layoutManager,
                  let textContainer = target.view.textContainer else { return nil }
            let localPoint = target.view.convert(viewPoint, from: pdfView)
            let containerPoint = CGPoint(
                x: localPoint.x - target.view.textContainerOrigin.x,
                y: localPoint.y - target.view.textContainerOrigin.y
            )
            layoutManager.ensureLayout(for: textContainer)
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceThroughGlyph: &fraction
            )
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else {
                return nil
            }
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let selectedRange = stagedWordRange(
                at: characterIndex,
                in: target.view.string as NSString
            )
            guard selectedRange.length > 0 else { return nil }
            return (target, selectedRange)
        }

        private func stagedWordRange(
            at characterIndex: Int,
            in text: NSString
        ) -> NSRange {
            guard characterIndex >= 0, characterIndex < text.length else {
                return NSRange(location: NSNotFound, length: 0)
            }
            func isWordUnit(at index: Int) -> Bool {
                guard index >= 0,
                      index < text.length,
                      let scalar = UnicodeScalar(text.character(at: index)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95
            }
            guard isWordUnit(at: characterIndex) else {
                return NSRange(location: characterIndex, length: 1)
            }
            var lowerBound = characterIndex
            var upperBound = characterIndex + 1
            while lowerBound > 0, isWordUnit(at: lowerBound - 1) {
                lowerBound -= 1
            }
            while upperBound < text.length, isWordUnit(at: upperBound) {
                upperBound += 1
            }
            return NSRange(location: lowerBound, length: upperBound - lowerBound)
        }

        private func clearStagedTextSelection() {
            for view in stagedTextViews.values where view.selectedRange.length > 0 {
                view.selectedRange = NSRange(location: 0, length: 0)
            }
        }

        private func synchronizeStagedTextEdits() {
            let pendingIDs = Set(pendingStagedTextByObjectID.keys)
            for objectID in Array(stagedTextByObjectID.keys)
            where !pendingIDs.contains(objectID) {
                stagedTextByObjectID.removeValue(forKey: objectID)
            }
            for (objectID, pendingEdit) in pendingStagedTextByObjectID {
                let style = stagedTextStylesByObjectID[objectID] ??
                    stagedTextByObjectID[objectID]?.style ??
                    objects.first(where: { $0.id == objectID }).flatMap(makeInlineTextStyle)
                guard let style else { continue }
                stagedTextStylesByObjectID[objectID] = style
                stagedTextByObjectID[objectID] = StagedTextEdit(
                    text: pendingEdit.text,
                    style: style,
                    pdfStyle: pendingEdit.style
                )
            }
            if let fallback = transientStagedTextFallback,
               stagedTextByObjectID[fallback.objectID] == nil {
                removeTransientStagedTextFallback()
            }
            scheduleOverlayRefresh()
        }

        private func makeInlineTextStyle(
            for object: PDFPageObjectSnapshot
        ) -> InlineTextStyle? {
            guard let pdfView,
                  let frame = inlineTextEditorFrame(for: object) else { return nil }
            let font = objectFont(
                named: object.fontName,
                displayPointSize: displayFontSize(for: object),
                fontData: object.fontData,
                viewHeight: frame.height
            )
            return InlineTextStyle(
                font: font,
                scaleFactor: pdfView.scaleFactor,
                color: objectTextColor(object.fillColor)
            )
        }
#elseif os(iOS)
        private func makeInlineStyleToolbar(showsStyleControls: Bool) -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            let boldButton = UIBarButtonItem(
                title: "Bold",
                style: .plain,
                target: self,
                action: #selector(toggleInlineBold)
            )
            let italicButton = UIBarButtonItem(
                title: "Italic",
                style: .plain,
                target: self,
                action: #selector(toggleInlineItalic)
            )
            inlineBoldButton = boldButton
            inlineItalicButton = italicButton
            var items: [UIBarButtonItem] = []
            if showsStyleControls {
                items.append(contentsOf: [boldButton, italicButton])
            }
            items.append(contentsOf: [
                UIBarButtonItem(
                    barButtonSystemItem: .flexibleSpace,
                    target: nil,
                    action: nil
                ),
                UIBarButtonItem(
                    title: "Done",
                    style: .done,
                    target: self,
                    action: #selector(finishInlineEditingFromToolbar)
                ),
            ])
            toolbar.items = items
            updateInlineStyleButtonStates()
            return toolbar
        }

        @objc private func toggleInlineBold() {
            inlineEditingPDFStyle.formSymmetricDifference(.bold)
            updateInlineTextStylePreview()
        }

        @objc private func toggleInlineItalic() {
            inlineEditingPDFStyle.formSymmetricDifference(.italic)
            updateInlineTextStylePreview()
        }

        @objc private func finishInlineEditingFromToolbar() {
            finishInlineTextEditing(commit: true)
        }

        private func styledFont(_ baseFont: UIFont, style: PDFTextStyle) -> UIFont {
            var traits = baseFont.fontDescriptor.symbolicTraits
            if style.contains(.bold) {
                traits.insert(.traitBold)
            } else {
                traits.remove(.traitBold)
            }
            if style.contains(.italic) {
                traits.insert(.traitItalic)
            } else {
                traits.remove(.traitItalic)
            }
            guard let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) else {
                var fallbackTraits: UIFontDescriptor.SymbolicTraits = []
                if style.contains(.bold) { fallbackTraits.insert(.traitBold) }
                if style.contains(.italic) { fallbackTraits.insert(.traitItalic) }
                let systemFont = UIFont.systemFont(
                    ofSize: baseFont.pointSize,
                    weight: style.contains(.bold) ? .bold : .regular
                )
                guard let fallbackDescriptor = systemFont.fontDescriptor
                    .withSymbolicTraits(fallbackTraits) else { return systemFont }
                return UIFont(descriptor: fallbackDescriptor, size: baseFont.pointSize)
            }
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        private func updateInlineStyleButtonStates() {
            inlineBoldButton?.style = inlineEditingPDFStyle.contains(.bold) ? .done : .plain
            inlineItalicButton?.style = inlineEditingPDFStyle.contains(.italic) ? .done : .plain
        }

        private func updateInlineTextStylePreview() {
            guard let field = inlineTextField, let baseFont = inlineEditingBaseFont else { return }
            field.font = styledFont(baseFont, style: inlineEditingPDFStyle)
            updateInlineStyleButtonStates()
        }

        private func objectTextColor(_ color: PDFObjectColor) -> UIColor {
            UIColor(
                red: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: max(CGFloat(color.alpha) / 255, 0.15)
            )
        }

        private func fontName(from selection: PDFSelection?) -> String? {
            guard let attributedString = selection?.attributedString,
                  attributedString.length > 0 else { return nil }
            return (attributedString.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont)?.fontName
        }

        private func displayFontSize(from selection: PDFSelection?) -> CGFloat? {
            guard let pdfView,
                  let attributedString = selection?.attributedString,
                  attributedString.length > 0,
                  let font = attributedString.attribute(
                      .font,
                      at: 0,
                      effectiveRange: nil
                  ) as? UIFont else { return nil }
            let displaySize = font.pointSize * max(pdfView.scaleFactor, 0.001)
            return displaySize.isFinite && displaySize > 0 ? displaySize : nil
        }

        private func applyResolvedTextStyle(
            _ object: PDFPageObjectSnapshot,
            to field: UITextView,
            preservingCurrentPDFStyle: Bool
        ) {
            field.textColor = objectTextColor(object.fillColor)
            let baseFont = objectFont(
                named: object.fontName,
                displayPointSize: displayFontSize(for: object),
                fontData: object.fontData,
                viewHeight: field.frame.height
            )
            if !preservingCurrentPDFStyle {
                inlineEditingPDFStyle = PDFTextStyle.inferred(fromFontName: object.fontName)
            }
            inlineEditingBaseFont = baseFont
            field.font = styledFont(baseFont, style: inlineEditingPDFStyle)
            if field.inputAccessoryView == nil {
                field.inputAccessoryView = makeInlineStyleToolbar(
                    showsStyleControls: true
                )
                field.reloadInputViews()
            }
        }

        private func objectFont(
            named fontName: String?,
            displayPointSize: CGFloat?,
            fontData: Data?,
            viewHeight: CGFloat
        ) -> UIFont {
            let size = max(min(displayPointSize ?? viewHeight * 0.82, 192), 6)
            let font: UIFont
            if let fontData,
               let provider = CGDataProvider(data: fontData as CFData),
               let graphicsFont = CGFont(provider) {
                font = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont
            } else {
                let name = fontName?.split(separator: "+").last.map(String.init)
                font = name.flatMap { UIFont(name: $0, size: size) } ??
                    UIFont.systemFont(ofSize: size)
            }
            return font
        }
#endif

        private func annotation(
            at pagePoint: CGPoint,
            pageIndex: Int
        ) -> PDFAnnotationSnapshot? {
            let scaleFactor = max(pdfView?.scaleFactor ?? 1, 0.01)
#if os(macOS)
            let minimumInkHitPaddingInViewPoints: CGFloat = 12
#else
            let minimumInkHitPaddingInViewPoints: CGFloat = 22
#endif
            return annotations
                .filter {
                    guard $0.reference.pageIndex == pageIndex else { return false }
                    let padding = $0.kind == .ink
                        ? max(8, minimumInkHitPaddingInViewPoints / scaleFactor)
                        : 8
                    return $0.bounds.insetBy(dx: -padding, dy: -padding).contains(pagePoint)
                }
                .min { lhs, rhs in
                    lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
                }
        }

        private func objectPriority(_ object: PDFPageObjectSnapshot) -> Int {
            switch object.kind {
            case .text, .image: 0
            case .path: 1
            case .form: 2
            case .shading, .unknown: 3
            }
        }

        private func beginPan(at viewPoint: CGPoint) {
            guard inlineTextField == nil,
                  let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false),
                  let document = pdfView.document else { return }
            let touchedPageIndex = document.index(for: page)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let pageIndex: Int
            let bounds: CGRect
            if let field = selectedFormField.wrappedValue {
                guard field.pageIndex == touchedPageIndex else { return }
                let selectionRect = pdfView.convert(field.bounds, from: page).standardized
                let corners = [
                    CGPoint(x: selectionRect.minX, y: selectionRect.minY),
                    CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
                    CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
                    CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
                ]
                let cornerIndex = corners.indices.min(by: {
                    hypot(corners[$0].x - viewPoint.x, corners[$0].y - viewPoint.y) <
                        hypot(corners[$1].x - viewPoint.x, corners[$1].y - viewPoint.y)
                })
                let hitRadius = formResizeHandleHitRadius(for: selectionRect)
                let touchesCorner = cornerIndex.map {
                    hypot(corners[$0].x - viewPoint.x, corners[$0].y - viewPoint.y) <= hitRadius
                } ?? false
                guard touchesCorner || selectionRect.contains(viewPoint),
                      let cornerIndex else { return }
                interactionFormField = field
                if touchesCorner {
                    interactionFormAnchorPoint = pdfView.convert(
                        corners[(cornerIndex + 2) % 4], to: page
                    )
                    dragMode = .scale
                } else {
                    interactionFormAnchorPoint = nil
                    dragMode = .move
                }
                pageIndex = field.pageIndex
                bounds = field.bounds
            } else if annotationEditingEnabled,
               let annotation = annotation(at: pagePoint, pageIndex: touchedPageIndex) {
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = annotation
                interactionAnnotation = annotation
                pageIndex = annotation.reference.pageIndex
                bounds = annotation.bounds
            } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
                interactionObject = object
                pageIndex = object.pageIndex
                bounds = object.bounds
                interactionStartTransform = object.transform
            } else { return }
            guard pageIndex == touchedPageIndex else { return }
            let convertedSelectionRect = pdfView.convert(bounds, from: page).standardized
            let selectionRect = interactionObject?.kind == .text
                ? minimumVisibleSelectionRect(convertedSelectionRect)
                : convertedSelectionRect
            guard selectionRect.insetBy(dx: -18, dy: -18).contains(viewPoint) else { return }
            interactionPage = page
            interactionStartPoint = pdfView.convert(viewPoint, to: page)
            interactionStartBounds = bounds
            let corners = [
                CGPoint(x: selectionRect.minX, y: selectionRect.minY),
                CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
                CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
                CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            ]
            if interactionFormField != nil {
                // The field branch selected move or scale from its body/handle hit.
            } else if interactionAnnotation?.kind == .note {
                dragMode = .move
            } else {
                dragMode = corners.contains {
                    hypot($0.x - viewPoint.x, $0.y - viewPoint.y) <= 20
                } ? .scale : .move
            }
        }

        private func updatePan(at viewPoint: CGPoint, finished: Bool) {
            guard let pdfView, let page = interactionPage else { return }
            let current = pdfView.convert(viewPoint, to: page)
            switch dragMode {
            case .move:
                let offset = CGSize(
                    width: current.x - interactionStartPoint.x,
                    height: current.y - interactionStartPoint.y
                )
                let translatedBounds = interactionStartBounds.offsetBy(
                    dx: offset.width, dy: offset.height
                )
                if let field = interactionFormField {
                    let bounds = PDFFormPageGeometry(
                        cropBox: page.bounds(for: .cropBox), rotation: page.rotation
                    ).clamped(
                        translatedBounds,
                        minimumDimension: field.kind.minimumDimension
                    )
                    refreshOverlay(previewBounds: bounds)
                    let changed = abs(bounds.minX - interactionStartBounds.minX) +
                        abs(bounds.minY - interactionStartBounds.minY) > 0.01
                    if finished, changed { onSetFormFieldBounds(field, bounds) }
                } else {
                    refreshOverlay(previewBounds: translatedBounds)
                    if finished, abs(offset.width) + abs(offset.height) > 0.01,
                       let annotation = interactionAnnotation {
                        onSetAnnotationBounds(
                            annotation, translatedBounds
                        )
                    } else if finished, abs(offset.width) + abs(offset.height) > 0.01,
                              let object = interactionObject {
                        onTranslateObject(object, offset)
                    }
                }
            case .scale:
                let center = CGPoint(x: interactionStartBounds.midX, y: interactionStartBounds.midY)
                let initialDistance = max(hypot(
                    interactionStartPoint.x - center.x,
                    interactionStartPoint.y - center.y
                ), 0.01)
                let factor = min(max(
                    hypot(current.x - center.x, current.y - center.y) / initialDistance,
                    0.05
                ), 20)
                let operation = scaleTransform(factor: factor, center: center)
                if let field = interactionFormField, let anchor = interactionFormAnchorPoint {
                    let minimum = field.kind.minimumDimension
                    let width = max(abs(current.x - anchor.x), minimum)
                    let height = max(abs(current.y - anchor.y), minimum)
                    let rawBounds = CGRect(
                        x: current.x < anchor.x ? anchor.x - width : anchor.x,
                        y: current.y < anchor.y ? anchor.y - height : anchor.y,
                        width: width, height: height
                    )
                    let bounds = PDFFormPageGeometry(
                        cropBox: page.bounds(for: .cropBox), rotation: page.rotation
                    ).clamped(rawBounds, minimumDimension: minimum)
                    refreshOverlay(previewBounds: bounds)
                    if finished { onSetFormFieldBounds(field, bounds) }
                } else if let annotation = interactionAnnotation {
                    applyAnnotationTransform(annotation, operation: operation, finished: finished)
                } else if let object = interactionObject {
                    applyPageTransform(object: object, pageOperation: operation, finished: finished)
                }
            }
            if finished { clearInteraction() }
        }

        private func beginTransformGesture() {
            guard inlineTextField == nil, let pdfView else { return }
            let pageIndex: Int
            if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
                interactionAnnotation = annotation
                pageIndex = annotation.reference.pageIndex
                interactionStartBounds = annotation.bounds
            } else if let object = selectedObject.wrappedValue {
                interactionObject = object
                pageIndex = object.pageIndex
                interactionStartBounds = object.bounds
                interactionStartTransform = object.transform
            } else { return }
            guard let page = pdfView.document?.page(at: pageIndex) else { return }
            interactionPage = page
        }

        private func updateScaleGesture(factor: CGFloat, finished: Bool) {
            let center = CGPoint(x: interactionStartBounds.midX, y: interactionStartBounds.midY)
            let operation = scaleTransform(
                factor: min(max(factor, 0.05), 20),
                center: center
            )
            if let annotation = interactionAnnotation {
                applyAnnotationTransform(annotation, operation: operation, finished: finished)
            } else if let object = interactionObject {
                applyPageTransform(object: object, pageOperation: operation, finished: finished)
            }
            if finished { clearInteraction() }
        }

        private func updateRotationGesture(radians: CGFloat, finished: Bool) {
            guard interactionAnnotation == nil else {
                if finished { clearInteraction() }
                return
            }
            guard let object = interactionObject else { return }
            let center = CGPoint(x: interactionStartBounds.midX, y: interactionStartBounds.midY)
            let operation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            applyPageTransform(object: object, pageOperation: operation, finished: finished)
            if finished { clearInteraction() }
        }

        private func scaleTransform(factor: CGFloat, center: CGPoint) -> CGAffineTransform {
            CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: factor, y: factor)
                .translatedBy(x: -center.x, y: -center.y)
        }

        private func applyPageTransform(
            object: PDFPageObjectSnapshot,
            pageOperation: CGAffineTransform,
            finished: Bool
        ) {
            refreshOverlay(previewBounds: interactionStartBounds.applying(pageOperation))
            if finished {
                onSetObjectTransform(
                    object,
                    interactionStartTransform.concatenating(pageOperation)
                )
            }
        }

        private func applyAnnotationTransform(
            _ annotation: PDFAnnotationSnapshot,
            operation: CGAffineTransform,
            finished: Bool
        ) {
            let bounds = interactionStartBounds.applying(operation).standardized
            refreshOverlay(previewBounds: bounds)
            if finished { onSetAnnotationBounds(annotation, bounds) }
        }

        private func clearInteraction() {
            interactionObject = nil
            interactionAnnotation = nil
            interactionFormField = nil
            interactionFormAnchorPoint = nil
            interactionPage = nil
        }

#if os(macOS)
        private func refreshSignaturePreviewAtCurrentMouseLocation() {
            guard signaturePlacementEnabled,
                  signaturePlacementStrokes?.isEmpty == false,
                  let pdfView,
                  let window = pdfView.window else {
                hideSignaturePreview()
                return
            }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            updateSignaturePreview(at: pdfView.convert(windowPoint, from: nil))
        }

        private func updateSignaturePreview(at viewPoint: CGPoint) {
            guard signaturePlacementEnabled,
                  let strokes = signaturePlacementStrokes,
                  !strokes.isEmpty,
                  let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false) else {
                hideSignaturePreview()
                return
            }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let bounds = SignaturePlacementGeometry.bounds(
                centeredAt: pagePoint,
                pageBounds: page.bounds(for: .cropBox),
                preferredSize: signaturePlacementSize
            )
            guard bounds.width > 0, bounds.height > 0 else {
                hideSignaturePreview()
                return
            }

            let path = CGMutablePath()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                let firstPagePoint = CGPoint(
                    x: bounds.minX + first.x * bounds.width,
                    y: bounds.minY + (1 - first.y) * bounds.height
                )
                path.move(to: pdfView.convert(firstPagePoint, from: page))
                for point in stroke.dropFirst() {
                    let pageStrokePoint = CGPoint(
                        x: bounds.minX + point.x * bounds.width,
                        y: bounds.minY + (1 - point.y) * bounds.height
                    )
                    path.addLine(to: pdfView.convert(pageStrokePoint, from: page))
                }
            }

            lastSignaturePreviewViewPoint = viewPoint
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            signaturePreviewLayer.frame = pdfView.bounds
            signaturePreviewLayer.path = path
            signaturePreviewLayer.lineWidth = max(
                1,
                signaturePlacementLineWidth * pdfView.scaleFactor
            )
            signaturePreviewLayer.isHidden = path.isEmpty
            CATransaction.commit()
        }

        private func hideSignaturePreview() {
            lastSignaturePreviewViewPoint = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            signaturePreviewLayer.path = nil
            signaturePreviewLayer.isHidden = true
            CATransaction.commit()
        }

        private func installGestures(on pdfView: PDFView) {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let freehandPan = NSPanGestureRecognizer(
                target: self,
                action: #selector(handleFreehandPan(_:))
            )
            let magnify = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleMagnification(_:))
            )
            let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            freehandGesture = freehandPan
            gestures = [pan, magnify, rotate, freehandPan]
            gestures.forEach { $0.delegate = self }
            gestures.forEach(pdfView.addGestureRecognizer)
        }

        @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: pdfView)
                beginPan(at: CGPoint(
                    x: point.x - translation.x,
                    y: point.y - translation.y
                ))
            case .changed: updatePan(at: point, finished: false)
            case .ended: updatePan(at: point, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }

        @objc private func handleFreehandPan(_ recognizer: NSPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: pdfView)
                beginFreehandDrawing(at: CGPoint(
                    x: point.x - translation.x,
                    y: point.y - translation.y
                ))
                appendFreehandPoint(point)
            case .changed:
                appendFreehandPoint(point)
            case .ended:
                finishFreehandDrawing(at: point)
            case .cancelled, .failed:
                cancelFreehandDrawing()
            default:
                break
            }
        }

        @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            switch recognizer.state {
            case .began: beginTransformGesture()
            case .changed: updateScaleGesture(factor: 1 + recognizer.magnification, finished: false)
            case .ended: updateScaleGesture(factor: 1 + recognizer.magnification, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }

        @objc private func handleRotation(_ recognizer: NSRotationGestureRecognizer) {
            switch recognizer.state {
            case .began: beginTransformGesture()
            case .changed: updateRotationGesture(radians: recognizer.rotation, finished: false)
            case .ended: updateRotationGesture(radians: recognizer.rotation, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }
#elseif os(iOS)
        private func installGestures(on pdfView: PDFView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            let doubleTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleDoubleTap(_:))
            )
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let freehandPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleFreehandPan(_:))
            )
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            freehandGesture = freehandPan
            gestures = [tap, doubleTap, pan, pinch, rotate, freehandPan]
            gestures.forEach {
                $0.delegate = self
                pdfView.addGestureRecognizer($0)
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView else { return }
            selectTarget(at: recognizer.location(in: pdfView))
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView else { return }
            activateTarget(at: recognizer.location(in: pdfView))
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: pdfView)
                beginPan(at: CGPoint(
                    x: point.x - translation.x,
                    y: point.y - translation.y
                ))
            case .changed: updatePan(at: point, finished: false)
            case .ended: updatePan(at: point, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }

        @objc private func handleFreehandPan(_ recognizer: UIPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: pdfView)
                beginFreehandDrawing(at: CGPoint(
                    x: point.x - translation.x,
                    y: point.y - translation.y
                ))
                appendFreehandPoint(point)
            case .changed:
                appendFreehandPoint(point)
            case .ended:
                finishFreehandDrawing(at: point)
            case .cancelled, .failed:
                cancelFreehandDrawing()
            default:
                break
            }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began: beginTransformGesture()
            case .changed: updateScaleGesture(factor: recognizer.scale, finished: false)
            case .ended: updateScaleGesture(factor: recognizer.scale, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }

        @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began: beginTransformGesture()
            case .changed: updateRotationGesture(radians: recognizer.rotation, finished: false)
            case .ended: updateRotationGesture(radians: recognizer.rotation, finished: true)
            case .cancelled: clearInteraction(); refreshOverlay()
            default: break
            }
        }
#endif

        deinit { stopObserving() }
    }
}

#if os(macOS)
extension PDFKitView.Coordinator: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document = view.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let overlay = PDFPageOverlayContainer(pageIndex: pageIndex)
        pageOverlayViews[pageIndex] = overlay
        return overlay
    }

    func pdfView(
        _ pdfView: PDFView,
        willDisplayOverlayView overlayView: NSView,
        for page: PDFPage
    ) {
        guard let overlay = overlayView as? PDFPageOverlayContainer else { return }
        pageOverlayViews[overlay.pageIndex] = overlay
        scheduleOverlayRefresh()
    }

    func pdfView(
        _ pdfView: PDFView,
        willEndDisplayingOverlayView overlayView: NSView,
        for page: PDFPage
    ) {
        guard let overlay = overlayView as? PDFPageOverlayContainer,
              pageOverlayViews[overlay.pageIndex] === overlay else { return }
        if inlineTextField?.superview === overlayView {
            finishInlineTextEditing(commit: true)
        }
        stagedTextViews.values
            .filter { $0.superview === overlayView }
            .forEach { $0.removeFromSuperview() }
        stagedTextMaskViews.values
            .filter { $0.superview === overlayView }
            .forEach { $0.removeFromSuperview() }
        pageOverlayViews.removeValue(forKey: overlay.pageIndex)
    }
}

extension PDFKitView.Coordinator: PDFInteractionMouseHandling {
    func handleMouseMoved(_ event: NSEvent, in pdfView: PDFView) {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        if freehandDrawingEnabled {
            endAnnotationHover(in: pdfView)
            if event.modifierFlags.contains(.shift) {
                if freehandStraightLinePage == nil {
                    beginFreehandStraightLine(at: viewPoint)
                } else {
                    updateFreehandStraightLinePreview(at: viewPoint)
                }
            } else {
                cancelFreehandStraightLine()
            }
            return
        }
        if signaturePlacementEnabled {
            endAnnotationHover(in: pdfView)
            updateSignaturePreview(at: viewPoint)
            return
        }
        guard let page = pdfView.page(for: viewPoint, nearest: false),
              let document = pdfView.document else {
            endAnnotationHover(in: pdfView)
            return
        }
        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(viewPoint, to: page)
        guard let annotation = annotation(at: pagePoint, pageIndex: pageIndex),
              annotation.kind == .note else {
            endAnnotationHover(in: pdfView)
            return
        }
        guard hoveredCommentReference != annotation.reference else { return }
        if hoveredCommentReference != nil { scheduleCommentPopoverClose() }
        hoveredCommentReference = annotation.reference
        if let interactionView = pdfView as? PDFInteractionPDFView {
            interactionView.removeAnnotationToolTips()
            interactionView.trackAnnotationHover(
                in: pdfView.convert(annotation.bounds, from: page)
            )
        }
        selectedFormField.wrappedValue = nil
        selectedAnnotation.wrappedValue = annotation
        selectedPageIndex.wrappedValue = pageIndex
        onOpenAnnotation(annotation)
        presentCommentPopover(
            for: annotation,
            on: page,
            in: pdfView,
            openedByHover: true
        )
    }

    func handleAnnotationHoverEnded(in pdfView: PDFView) {
        endAnnotationHover(in: pdfView)
    }

    func handlePointerExited(in pdfView: PDFView) {
        hideSignaturePreview()
        cancelFreehandStraightLine()
        endAnnotationHover(in: pdfView)
    }

    private func endAnnotationHover(in pdfView: PDFView) {
        guard hoveredCommentReference != nil else { return }
        hoveredCommentReference = nil
        (pdfView as? PDFInteractionPDFView)?.clearAnnotationHoverTrackingArea()
        scheduleCommentPopoverClose()
    }

    private func presentCommentPopover(
        for annotation: PDFAnnotationSnapshot,
        on page: PDFPage,
        in pdfView: PDFView,
        openedByHover: Bool
    ) {
        if commentPopoverReference == annotation.reference,
           commentPopover?.isShown == true {
            if !openedByHover {
                commentPopoverOpenedByHover = false
                cancelCommentPopoverClose()
            }
            return
        }

        closeCommentPopover()
        commentPopoverReference = annotation.reference
        commentPopoverOpenedByHover = openedByHover
        hasEnteredCommentPopover = false

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let rootView = PDFCommentEditor(
            annotation: annotation,
            onApply: { [weak self] update in
                self?.onUpdateAnnotation(annotation, update)
            },
            onDelete: { [weak self] in
                self?.onDeleteAnnotation(annotation)
            },
            onDismiss: { [weak self] in
                self?.closeCommentPopover()
            },
            onHoverChanged: { [weak self] isHovering in
                self?.handleCommentPopoverHover(isHovering)
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 360, height: 320)
        commentPopover = popover

        let anchorRect = pdfView.convert(annotation.bounds, from: page).standardized
        popover.show(relativeTo: anchorRect, of: pdfView, preferredEdge: .maxX)
    }

    private func handleCommentPopoverHover(_ isHovering: Bool) {
        guard commentPopoverOpenedByHover else { return }
        cancelCommentPopoverClose()
        if isHovering {
            hasEnteredCommentPopover = true
        } else if hasEnteredCommentPopover {
            closeCommentPopover()
        }
    }

    private func scheduleCommentPopoverClose() {
        guard commentPopoverOpenedByHover,
              !hasEnteredCommentPopover else { return }
        cancelCommentPopoverClose()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.commentPopoverOpenedByHover,
                  !self.hasEnteredCommentPopover else { return }
            self.closeCommentPopover()
        }
        commentPopoverCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func cancelCommentPopoverClose() {
        commentPopoverCloseWorkItem?.cancel()
        commentPopoverCloseWorkItem = nil
    }

    private func closeCommentPopover() {
        cancelCommentPopoverClose()
        commentPopover?.performClose(nil)
        commentPopover = nil
        commentPopoverReference = nil
        commentPopoverOpenedByHover = false
        hasEnteredCommentPopover = false
    }

    func handleScrollWillBegin(in pdfView: PDFView) {
        closeCommentPopover()
        hideSignaturePreview()
        cancelFreehandStraightLine()
        if inlineTextField != nil {
            finishInlineTextEditing(commit: true)
            clearStagedTextSelection()
            selectedObject.wrappedValue = nil
            selectedAnnotation.wrappedValue = nil
            pdfView.clearSelection()
            selection.wrappedValue = nil
            setOverlayHidden(true)
            updateGestureAvailability()
        } else {
            // A PDFView-level fallback must never follow scrolling content.
            removeTransientStagedTextFallback()
        }
    }

    func shouldCaptureMouse(at viewPoint: CGPoint, in pdfView: PDFView) -> Bool {
        if formResizeHandleContains(viewPoint, in: pdfView) { return true }
        if let field = authoredFormField(at: viewPoint, in: pdfView) {
            // PDFKit renders a List Box with an internal native selection view.
            // Let hit testing reach it; the parent pan recognizer still handles
            // authored-field movement and corner resizing.
            return field.kind != .listBox
        }
        if freehandDrawingEnabled {
            return pdfView.page(for: viewPoint, nearest: false) != nil
        }
        if inlineTextField != nil {
            return !inlineEditorContains(viewPoint)
        }
        if pdfView.currentSelection != nil ||
            selection.wrappedValue != nil ||
            selectedObject.wrappedValue != nil ||
            selectedAnnotation.wrappedValue != nil {
            return true
        }
        guard let page = pdfView.page(for: viewPoint, nearest: false),
              let document = pdfView.document else { return false }
        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(viewPoint, to: page)

        if freehandDrawingEnabled {
            return true
        }
        if commentPlacementEnabled {
            return true
        }
        if freeTextPlacementEnabled {
            return true
        }
        if signaturePlacementEnabled {
            return true
        }
        if annotationEditingEnabled,
           annotation(at: pagePoint, pageIndex: pageIndex) != nil {
            return true
        }
        if objectEditingEnabled {
            if stagedTextTarget(at: viewPoint, pageIndex: pageIndex) != nil {
                return true
            }
            let editableObject = editableObject(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            )
            let touchesCopyableText = editableObject?.kind == .text ||
                copyableWordSelection(at: pagePoint, on: page) != nil
            if (NSApp.currentEvent?.clickCount ?? 0) >= 2, touchesCopyableText {
                return true
            }
            if let editableObject, editableObject.kind != .text {
                return true
            }
        }
        return false
    }

    func usesLightNativeListBoxAppearance(
        at viewPoint: CGPoint,
        in pdfView: PDFView
    ) -> Bool {
        authoredFormField(at: viewPoint, in: pdfView)?.kind == .listBox
    }

    func handleMouseDown(_ event: NSEvent, in pdfView: PDFView) -> Bool {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        if selectAuthoredFormField(at: viewPoint, in: pdfView) {
            // PDFView still receives the event, preserving native text/button use.
            return false
        }
        if formResizeHandleContains(viewPoint, in: pdfView) { return false }
        selectedFormField.wrappedValue = nil
        if inlineEditorContains(viewPoint) {
            return false
        }

        if freehandDrawingEnabled, freehandStraightLinePage != nil {
            guard event.modifierFlags.contains(.shift) else {
                cancelFreehandStraightLine()
                return false
            }
            return finishFreehandStraightLine(at: viewPoint)
        }

        guard let page = pdfView.page(for: viewPoint, nearest: false),
              let document = pdfView.document else {
            finishInlineTextEditing(commit: true)
            return false
        }
        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(viewPoint, to: page)

        if event.clickCount >= 2,
           !commentPlacementEnabled,
           !freeTextPlacementEnabled,
           !signaturePlacementEnabled {
            let hasEditableAnnotation = annotationEditingEnabled &&
                annotation(at: pagePoint, pageIndex: pageIndex) != nil
            let hasEditableContent = objectEditingEnabled && (
                editableObject(at: viewPoint, on: page, pageIndex: pageIndex) != nil ||
                copyableWordSelection(at: pagePoint, on: page) != nil
            )
            if hasEditableAnnotation || hasEditableContent {
                activateTarget(at: viewPoint)
                return true
            }
        }

        if commentPlacementEnabled || freeTextPlacementEnabled ||
            signaturePlacementEnabled {
            selectTarget(at: viewPoint)
            return true
        }
        if annotationEditingEnabled,
           annotation(at: pagePoint, pageIndex: pageIndex) != nil {
            selectTarget(at: viewPoint)
            return true
        }
        if objectEditingEnabled {
            if stagedTextTarget(at: viewPoint, pageIndex: pageIndex) != nil {
                selectTarget(at: viewPoint)
                return true
            }
            let touchedObject = editableObject(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            )
            let touchesText = touchedObject?.kind == .text ||
                copyableWordSelection(at: pagePoint, on: page) != nil
            if touchesText {
                finishInlineTextEditing(commit: true)
                clearStagedTextSelection()
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = nil
                updateGestureAvailability()
                refreshOverlay()
                return false
            }
            if touchedObject != nil {
                selectTarget(at: viewPoint)
                return true
            }
        }

        finishInlineTextEditing(commit: true)
        clearStagedTextSelection()
        selectedObject.wrappedValue = nil
        selectedAnnotation.wrappedValue = nil
        pdfView.clearSelection()
        selection.wrappedValue = nil
        updateGestureAvailability()
        refreshOverlay()
        return false
    }
}

extension PDFKitView.Coordinator: NSGestureRecognizerDelegate, NSTextViewDelegate {

    private func interactionStartPoint(
        for gestureRecognizer: NSGestureRecognizer,
        in pdfView: PDFView
    ) -> CGPoint {
        let point = gestureRecognizer.location(in: pdfView)
        guard let pan = gestureRecognizer as? NSPanGestureRecognizer else { return point }
        let translation = pan.translation(in: pdfView)
        return CGPoint(x: point.x - translation.x, y: point.y - translation.y)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard !formPlacementActive else { return false }
        guard inlineTextField == nil, let pdfView else { return false }
        let point = interactionStartPoint(for: gestureRecognizer, in: pdfView)
        if authoredWidgetOwnsInput(at: point, in: pdfView) {
            guard gestureRecognizer is NSPanGestureRecognizer else { return false }
            guard prepareFormFieldPan(at: point, in: pdfView) else { return false }
        }
        return shouldBeginInteractionGesture(
            gestureRecognizer,
            at: point,
            in: pdfView
        )
    }

    private func shouldBeginInteractionGesture(
        _ gestureRecognizer: NSGestureRecognizer,
        at viewPoint: CGPoint,
        in pdfView: PDFView
    ) -> Bool {
        if gestureRecognizer === freehandGesture {
            return freehandDrawingEnabled &&
                freehandStraightLinePage == nil &&
                pdfView.page(for: viewPoint, nearest: false) != nil
        }
        if freehandDrawingEnabled { return false }
        if gestureRecognizer is NSRotationGestureRecognizer {
            return objectEditingEnabled &&
                selectedObject.wrappedValue != nil &&
                selectedAnnotation.wrappedValue == nil
        }
        if gestureRecognizer is NSMagnificationGestureRecognizer {
            return (objectEditingEnabled && selectedObject.wrappedValue != nil) ||
                (annotationEditingEnabled && selectedAnnotation.wrappedValue != nil)
        }
        guard gestureRecognizer is NSPanGestureRecognizer else { return false }

        guard let page = pdfView.page(for: viewPoint, nearest: false),
              let document = pdfView.document else { return false }
        let touchedPageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(viewPoint, to: page)
        let pageIndex: Int
        let bounds: CGRect
        let isTextObject: Bool
        if let field = selectedFormField.wrappedValue,
           formFieldInteractionContains(viewPoint, in: pdfView) {
            pageIndex = field.pageIndex
            bounds = field.bounds
            isTextObject = false
        } else if annotationEditingEnabled,
           let annotation = annotation(at: pagePoint, pageIndex: touchedPageIndex) {
            pageIndex = annotation.reference.pageIndex
            bounds = annotation.bounds
            isTextObject = false
        } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
            pageIndex = object.pageIndex
            bounds = object.bounds
            isTextObject = object.kind == .text
        } else {
            return false
        }
        guard pageIndex == touchedPageIndex else { return false }
        let convertedBounds = pdfView.convert(bounds, from: page).standardized
        let interactionBounds = isTextObject
            ? minimumVisibleSelectionRect(convertedBounds)
            : convertedBounds
        return interactionBounds.insetBy(dx: -18, dy: -18).contains(viewPoint)
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard let pdfView else { return false }
        let eventPoint = pdfView.convert(event.locationInWindow, from: nil)
        if inlineEditorContains(eventPoint) {
            return false
        }
        if gestureRecognizer is NSPanGestureRecognizer,
           authoredWidgetOwnsInput(at: eventPoint, in: pdfView),
           !prepareFormFieldPan(at: eventPoint, in: pdfView) {
            return false
        }
        return shouldBeginInteractionGesture(
            gestureRecognizer,
            at: eventPoint,
            in: pdfView
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        false
    }

    func textDidBeginEditing(_ notification: Notification) {
        inlineEditorDidGainFocus = true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              inlineTextField === textView else { return }
        adjustInlineEditorWidth(textView)
        adjustInlineEditorHeight(textView)
        alignInlineTextBaseline(
            textView,
            object: inlineEditingObject,
            annotation: inlineEditingAnnotation
        )
        resizeFreeTextEditorToFit()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard inlineEditorDidGainFocus else { return }
        if pendingFreeTextPlacement != nil { return }
        finishInlineTextEditing(commit: true)
    }

    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineTextEditing(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            finishInlineTextEditing(commit: true)
            return true
        }
        return false
    }
}
#endif

#if os(iOS)
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate, UITextViewDelegate {
    private func interactionStartPoint(
        for gestureRecognizer: UIGestureRecognizer,
        in pdfView: PDFView
    ) -> CGPoint {
        let point = gestureRecognizer.location(in: pdfView)
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return point }
        let translation = pan.translation(in: pdfView)
        return CGPoint(x: point.x - translation.x, y: point.y - translation.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard !formPlacementActive else { return false }
        if let pdfView, authoredWidgetOwnsInput(at: touch.location(in: pdfView), in: pdfView) {
            return gestureRecognizer is UITapGestureRecognizer ||
                gestureRecognizer is UIPanGestureRecognizer
        }
        guard let touchedView = touch.view else { return true }
        if let annotationActionContainer,
           touchedView === annotationActionContainer ||
            touchedView.isDescendant(of: annotationActionContainer) {
            return false
        }
        guard let inlineTextField else { return true }
        return touchedView !== inlineTextField && !touchedView.isDescendant(of: inlineTextField)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !formPlacementActive else { return false }
        if let pdfView {
            let point = interactionStartPoint(for: gestureRecognizer, in: pdfView)
            if authoredWidgetOwnsInput(at: point, in: pdfView) {
                if gestureRecognizer is UITapGestureRecognizer { return true }
                if gestureRecognizer is UIPanGestureRecognizer {
                    return prepareFormFieldPan(at: point, in: pdfView)
                }
                return false
            }
        }
        if gestureRecognizer === freehandGesture {
            guard freehandDrawingEnabled, let pdfView else { return false }
            return pdfView.page(
                for: gestureRecognizer.location(in: pdfView),
                nearest: false
            ) != nil
        }
        if freehandDrawingEnabled { return false }
        if gestureRecognizer is UITapGestureRecognizer {
            return commentPlacementEnabled || freeTextPlacementEnabled ||
                signaturePlacementEnabled ||
                objectEditingEnabled || annotationEditingEnabled
        }
        if gestureRecognizer is UIRotationGestureRecognizer,
           selectedAnnotation.wrappedValue != nil {
            return false
        }
        guard let pdfView else { return false }
        let pageIndex: Int
        let bounds: CGRect
        var interactionPoint = gestureRecognizer.location(in: pdfView)
        if let field = selectedFormField.wrappedValue,
           gestureRecognizer is UIPanGestureRecognizer,
           formFieldInteractionContains(
               interactionStartPoint(for: gestureRecognizer, in: pdfView), in: pdfView
           ) {
            pageIndex = field.pageIndex
            bounds = field.bounds
            interactionPoint = interactionStartPoint(for: gestureRecognizer, in: pdfView)
        } else if annotationEditingEnabled,
           gestureRecognizer is UIPanGestureRecognizer,
           let page = pdfView.page(
               for: gestureRecognizer.location(in: pdfView),
               nearest: false
           ),
           let document = pdfView.document,
           let annotation = annotation(
               at: pdfView.convert(gestureRecognizer.location(in: pdfView), to: page),
               pageIndex: document.index(for: page)
           ) {
            pageIndex = annotation.reference.pageIndex
            bounds = annotation.bounds
        } else if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
            pageIndex = annotation.reference.pageIndex
            bounds = annotation.bounds
        } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
            pageIndex = object.pageIndex
            bounds = object.bounds
        } else { return false }
        guard let page = pdfView.document?.page(at: pageIndex) else { return false }
        if gestureRecognizer is UIPanGestureRecognizer {
            let rect = pdfView.convert(bounds, from: page).standardized
            return rect.insetBy(dx: -18, dy: -18).contains(interactionPoint)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UITapGestureRecognizer ||
            otherGestureRecognizer is UITapGestureRecognizer
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if pendingFreeTextPlacement != nil { return }
        finishInlineTextEditing(commit: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard inlineTextField === textView else { return }
        resizeFreeTextEditorToFit()
    }
}
#endif
