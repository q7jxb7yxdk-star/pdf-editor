import PDFKit
import CoreText
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit

private protocol PDFInteractionMouseHandling: AnyObject {
    func shouldCaptureMouse(at point: CGPoint, in pdfView: PDFView) -> Bool
    func handleMouseDown(_ event: NSEvent, in pdfView: PDFView) -> Bool
}

private final class PDFInteractionPDFView: PDFView {
    weak var interactionHandler: PDFInteractionMouseHandling?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let defaultHit = super.hitTest(point)
        guard NSApp.currentEvent?.type == .leftMouseDown else {
            return defaultHit
        }
        if interactionHandler?.shouldCaptureMouse(at: point, in: self) == true {
            return self
        }
        if let textView = defaultHit as? NSTextView,
           !(textView is PDFPassiveTextView) {
            return textView
        }
        return defaultHit
    }

    override func mouseDown(with event: NSEvent) {
        if interactionHandler?.handleMouseDown(event, in: self) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

private final class PDFPassiveTextView: NSTextView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PDFInlineTextView: NSTextView {
    private let editingUndoManager = UndoManager()

    override var undoManager: UndoManager? { editingUndoManager }

    func discardUndoHistory() {
        editingUndoManager.removeAllActions()
    }
}

private final class PDFTextMaskView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor
            .withAlphaComponent(0.98)
            .cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor
            .withAlphaComponent(0.98)
            .cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var selectedPageIndex: Int?
    @Binding var selection: PDFSelection?
    let objects: [PDFPageObjectSnapshot]
    let stagedTextByObjectID: [String: String]
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
    let commentPlacementEnabled: Bool
    let onPlaceComment: (Int, CGPoint) -> Void
    let onReplaceTextObject: (PDFPageObjectSnapshot, String) -> Void
    let onReplaceAnnotationText: (PDFAnnotationSnapshot, String) -> Void
    let onOpenObject: (PDFPageObjectSnapshot) -> Void
    let onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
    let viewerMode: PDFViewerMode
    let viewerCommand: PDFViewerCommand?

    func makeCoordinator() -> Coordinator { makeSharedCoordinator() }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = makePDFView()
        context.coordinator.observe(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        updateCoordinator(context.coordinator)
        update(pdfView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
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
    let stagedTextByObjectID: [String: String]
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
    let commentPlacementEnabled: Bool
    let onPlaceComment: (Int, CGPoint) -> Void
    let onReplaceTextObject: (PDFPageObjectSnapshot, String) -> Void
    let onReplaceAnnotationText: (PDFAnnotationSnapshot, String) -> Void
    let onOpenObject: (PDFPageObjectSnapshot) -> Void
    let onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
    let viewerMode: PDFViewerMode
    let viewerCommand: PDFViewerCommand?

    func makeCoordinator() -> Coordinator { makeSharedCoordinator() }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = makePDFView()
        context.coordinator.observe(pdfView)
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
            commentPlacementEnabled: commentPlacementEnabled,
            onPlaceComment: onPlaceComment,
            onReplaceTextObject: onReplaceTextObject,
            onReplaceAnnotationText: onReplaceAnnotationText,
            onOpenObject: onOpenObject,
            onOpenAnnotation: onOpenAnnotation
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
        pdfView.document = document
        applyViewerMode(to: pdfView)
        goToSelectedPage(in: pdfView)
        return pdfView
    }

    func update(_ pdfView: PDFView, coordinator: Coordinator) {
        if pdfView.document !== document {
            coordinator.prepareForDocumentReplacement()
            pdfView.document = document
            coordinator.completeDocumentReplacement()
        }
        goToSelectedPage(in: pdfView, coordinator: coordinator)
        applyViewerMode(to: pdfView)
        applyViewerCommand(to: pdfView, coordinator: coordinator)
    }

    func updateCoordinator(_ coordinator: Coordinator) {
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
        coordinator.commentPlacementEnabled = commentPlacementEnabled
        coordinator.onPlaceComment = onPlaceComment
        coordinator.onReplaceTextObject = onReplaceTextObject
        coordinator.onReplaceAnnotationText = onReplaceAnnotationText
        coordinator.onOpenObject = onOpenObject
        coordinator.onOpenAnnotation = onOpenAnnotation
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

        var selectedPageIndex: Binding<Int?>
        var selection: Binding<PDFSelection?>
        var pendingStagedTextByObjectID: [String: String] {
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
        var commentPlacementEnabled: Bool {
            didSet {
                guard oldValue != commentPlacementEnabled else { return }
                updateGestureAvailability()
            }
        }
        var onPlaceComment: (Int, CGPoint) -> Void
        var onReplaceTextObject: (PDFPageObjectSnapshot, String) -> Void
        var onReplaceAnnotationText: (PDFAnnotationSnapshot, String) -> Void
        var onOpenObject: (PDFPageObjectSnapshot) -> Void
        var onOpenAnnotation: (PDFAnnotationSnapshot) -> Void
        var lastViewerCommandID: UUID?
        var pendingPageNavigationIndex: Int?

        private weak var pdfView: PDFView?
        private var observers: [NSObjectProtocol] = []
        private let outlineLayer = CAShapeLayer()
        private var handleLayers: [CAShapeLayer] = []
        private var interactionObject: PDFPageObjectSnapshot?
        private var interactionAnnotation: PDFAnnotationSnapshot?
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
        }
        private var pendingTextActivation: PendingTextActivation?

#if os(macOS)
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

            func font(at scaleFactor: CGFloat) -> NSFont {
                let scaledSize = pointSize * max(scaleFactor, 0.001) / self.scaleFactor
                return NSFont(descriptor: fontDescriptor, size: scaledSize) ??
                    NSFont.systemFont(ofSize: scaledSize)
            }
        }

        private struct StagedTextEdit {
            let text: String
            let style: InlineTextStyle
        }

        private var gestures: [NSGestureRecognizer] = []
        private var inlineTextField: PDFInlineTextView?
        private var inlineTextMaskView: PDFTextMaskView?
        private var inlineEditorDidGainFocus = false
        private var pendingInlineCaretLocation: Int?
        private var inlineEditingTextStyle: InlineTextStyle?
        private var stagedTextByObjectID: [String: StagedTextEdit] = [:]
        private var stagedTextStylesByObjectID: [String: InlineTextStyle] = [:]
        private var stagedTextViews: [String: PDFPassiveTextView] = [:]
        private var stagedTextMaskViews: [String: PDFTextMaskView] = [:]
#elseif os(iOS)
        private var gestures: [UIGestureRecognizer] = []
        private var inlineTextField: UITextField?
#endif
        private var inlineEditingObject: PDFPageObjectSnapshot?
        private var inlineEditingAnnotation: PDFAnnotationSnapshot?
        private var isFinishingInlineTextEditing = false
        private var overlayRefreshScheduled = false

        init(
            selectedPageIndex: Binding<Int?>,
            selection: Binding<PDFSelection?>,
            objects: [PDFPageObjectSnapshot],
            pendingStagedTextByObjectID: [String: String],
            selectedObject: Binding<PDFPageObjectSnapshot?>,
            objectEditingEnabled: Bool,
            onTranslateObject: @escaping (PDFPageObjectSnapshot, CGSize) -> Void,
            onSetObjectTransform: @escaping (PDFPageObjectSnapshot, CGAffineTransform) -> Void,
            annotations: [PDFAnnotationSnapshot],
            selectedAnnotation: Binding<PDFAnnotationSnapshot?>,
            annotationEditingEnabled: Bool,
            onSetAnnotationBounds: @escaping (PDFAnnotationSnapshot, CGRect) -> Void,
            commentPlacementEnabled: Bool,
            onPlaceComment: @escaping (Int, CGPoint) -> Void,
            onReplaceTextObject: @escaping (PDFPageObjectSnapshot, String) -> Void,
            onReplaceAnnotationText: @escaping (PDFAnnotationSnapshot, String) -> Void,
            onOpenObject: @escaping (PDFPageObjectSnapshot) -> Void,
            onOpenAnnotation: @escaping (PDFAnnotationSnapshot) -> Void
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
            self.commentPlacementEnabled = commentPlacementEnabled
            self.onPlaceComment = onPlaceComment
            self.onReplaceTextObject = onReplaceTextObject
            self.onReplaceAnnotationText = onReplaceAnnotationText
            self.onOpenObject = onOpenObject
            self.onOpenAnnotation = onOpenAnnotation
            super.init()
            configureOverlay()
        }

        func observe(_ pdfView: PDFView) {
            self.pdfView = pdfView
#if os(macOS)
            (pdfView as? PDFInteractionPDFView)?.interactionHandler = self
            pdfView.wantsLayer = true
            pdfView.layer?.addSublayer(outlineLayer)
            handleLayers.forEach { pdfView.layer?.addSublayer($0) }
            synchronizeStagedTextEdits()
#else
            pdfView.layer.addSublayer(outlineLayer)
            handleLayers.forEach { pdfView.layer.addSublayer($0) }
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
                ) { [weak self] _ in self?.scheduleOverlayRefresh() },
                center.addObserver(
                    forName: .PDFViewVisiblePagesChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in self?.scheduleOverlayRefresh() },
            ]
            updateGestureAvailability()
            scheduleOverlayRefresh()
        }

        func stopObserving() {
            finishInlineTextEditing(commit: false)
            pendingTextActivation = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            outlineLayer.removeFromSuperlayer()
            handleLayers.forEach { $0.removeFromSuperlayer() }
            if let pdfView {
#if os(macOS)
                (pdfView as? PDFInteractionPDFView)?.interactionHandler = nil
                stagedTextViews.values.forEach { $0.removeFromSuperview() }
                stagedTextViews.removeAll()
                stagedTextMaskViews.values.forEach { $0.removeFromSuperview() }
                stagedTextMaskViews.removeAll()
#endif
                gestures.forEach(pdfView.removeGestureRecognizer)
            }
            gestures.removeAll()
            overlayRefreshScheduled = false
            self.pdfView = nil
        }

        func prepareForDocumentReplacement() {
            finishInlineTextEditing(commit: false)
            pendingTextActivation = nil
#if os(macOS)
            stagedTextByObjectID.removeAll()
            stagedTextStylesByObjectID.removeAll()
            stagedTextViews.values.forEach { $0.removeFromSuperview() }
            stagedTextViews.removeAll()
            stagedTextMaskViews.values.forEach { $0.removeFromSuperview() }
            stagedTextMaskViews.removeAll()
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
                pdfView?.clearSelection()
                refreshOverlay()
            }
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
            let pageIndex: Int
            let pageBounds: CGRect
            if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
                pageIndex = annotation.reference.pageIndex
                pageBounds = previewBounds ?? annotation.bounds
            } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
                pageIndex = object.pageIndex
                pageBounds = previewBounds ?? object.bounds
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outlineLayer.frame = pdfView.bounds
            outlineLayer.path = CGPath(rect: displayBounds, transform: nil)
            let points = [
                CGPoint(x: displayBounds.minX, y: displayBounds.minY),
                CGPoint(x: displayBounds.maxX, y: displayBounds.minY),
                CGPoint(x: displayBounds.maxX, y: displayBounds.maxY),
                CGPoint(x: displayBounds.minX, y: displayBounds.maxY),
            ]
            for (layer, point) in zip(handleLayers, points) {
                layer.frame = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            }
            CATransaction.commit()
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
            }
        }

        private func configureOverlay() {
#if os(macOS)
            let accent = NSColor.controlAccentColor.cgColor
#else
            let accent = UIColor.systemBlue.cgColor
#endif
            outlineLayer.strokeColor = accent
            outlineLayer.fillColor = nil
            outlineLayer.lineWidth = 2
            outlineLayer.lineDashPattern = [6, 4]
            outlineLayer.zPosition = 10_000
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
        }

        func updateGestureAvailability() {
#if os(macOS)
            let hasSelectedObject = objectEditingEnabled &&
                selectedObject.wrappedValue != nil
            let hasSelectedAnnotation = annotationEditingEnabled &&
                selectedAnnotation.wrappedValue != nil
            for gesture in gestures {
                if gesture is NSRotationGestureRecognizer {
                    gesture.isEnabled = hasSelectedObject && !hasSelectedAnnotation
                } else if gesture is NSMagnificationGestureRecognizer {
                    gesture.isEnabled = hasSelectedObject || hasSelectedAnnotation
                } else {
                    gesture.isEnabled = hasSelectedObject || hasSelectedAnnotation
                }
            }
#else
            for gesture in gestures {
                if gesture is UITapGestureRecognizer {
                    gesture.isEnabled = commentPlacementEnabled ||
                        objectEditingEnabled || annotationEditingEnabled
                } else {
                    gesture.isEnabled = objectEditingEnabled || annotationEditingEnabled
                }
            }
#endif
            scheduleOverlayRefresh()
        }

        private func selectTarget(at viewPoint: CGPoint) {
            guard prepareForCanvasInteraction(at: viewPoint),
                  let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false),
                  let document = pdfView.document else { return }
            pendingTextActivation = nil
            let pageIndex = document.index(for: page)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            if commentPlacementEnabled {
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = nil
                selectedPageIndex.wrappedValue = pageIndex
                onPlaceComment(pageIndex, pagePoint)
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
                onOpenAnnotation(annotation)
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
                    onOpenAnnotation(annotation)
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
                draftText: nil
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
                displayFontSize: max(frame.height * 0.82, 6),
                fontData: nil,
                frame: frame,
                maskFrame: textMaskFrame(pageIndex: pageIndex, bounds: selectionBounds),
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
            self.pendingTextActivation = nil
            selectedObject.wrappedValue = resolvedObject
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
                applyResolvedTextStyle(resolvedObject, to: field)
            } else if let draft, draft != pendingTextActivation.originalText {
                onReplaceTextObject(resolvedObject, draft)
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
            guard let inlineTextField else { return true }
            if inlineTextField.frame.contains(viewPoint) { return false }
            finishInlineTextEditing(commit: true)
            return true
        }

        private func beginInlineTextEditing(_ object: PDFPageObjectSnapshot) {
            guard object.kind == .text,
                  let frame = inlineTextEditorFrame(for: object) else { return }
#if os(macOS)
            let editableText = stagedTextByObjectID[object.id]?.text ?? object.text ?? ""
#else
            let editableText = object.text ?? ""
#endif
            beginInlineTextEditing(
                text: editableText,
                color: object.fillColor,
                fontName: object.fontName,
                displayFontSize: displayFontSize(for: object),
                fontData: object.fontData,
                frame: frame,
                maskFrame: textMaskFrame(for: object),
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
            object: PDFPageObjectSnapshot?,
            annotation: PDFAnnotationSnapshot?
        ) {
            guard let pdfView else { return }
            finishInlineTextEditing(commit: false)
            inlineEditingObject = object
            inlineEditingAnnotation = annotation

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
            field.drawsBackground = maskFrame == nil
            field.backgroundColor = maskFrame == nil
                ? NSColor.textBackgroundColor.withAlphaComponent(0.98)
                : .clear
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
            field.font = resolvedStyle.font(at: pdfView.scaleFactor)
            field.isEditable = true
            field.isSelectable = true
            field.isRichText = false
            field.importsGraphics = false
            field.allowsUndo = true
            field.textContainerInset = .zero
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
            adjustInlineEditorWidth(field)
            adjustInlineEditorHeight(field)
            alignInlineTextBaseline(field, object: object, annotation: annotation)
            focusInlineTextField(field, in: pdfView, attempt: 0)
#elseif os(iOS)
            let field = UITextField(frame: frame)
            field.text = text
            field.borderStyle = .none
            field.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
            field.textColor = objectTextColor(color)
            field.font = objectFont(
                named: fontName,
                displayPointSize: displayFontSize,
                fontData: fontData,
                viewHeight: frame.height
            )
            field.returnKeyType = .done
            field.clearButtonMode = .whileEditing
            field.delegate = self
            inlineTextField = field
            pdfView.addSubview(field)
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

        private func finishInlineTextEditing(commit: Bool) {
            guard !isFinishingInlineTextEditing,
                  let field = inlineTextField else { return }
            let object = inlineEditingObject
            let annotation = inlineEditingAnnotation
            guard object != nil || annotation != nil || pendingTextActivation != nil else { return }
            isFinishingInlineTextEditing = true
#if os(macOS)
            let text = field.string
            let textStyle = inlineEditingTextStyle
            field.delegate = nil
            field.discardUndoHistory()
            pdfView?.window?.makeFirstResponder(pdfView)
            field.removeFromSuperview()
            inlineTextMaskView?.removeFromSuperview()
            inlineTextMaskView = nil
            inlineEditorDidGainFocus = false
            inlineEditingTextStyle = nil
#elseif os(iOS)
            let text = field.text ?? ""
            field.delegate = nil
            field.resignFirstResponder()
            field.removeFromSuperview()
#endif
            inlineTextField = nil
            inlineEditingObject = nil
            inlineEditingAnnotation = nil
            isFinishingInlineTextEditing = false
            if object == nil, annotation == nil {
                if commit {
                    pendingTextActivation?.draftText = text
                } else {
                    pendingTextActivation = nil
                }
                refreshOverlay()
                return
            }
#if os(macOS)
            if let object {
                if commit, text != object.text, let textStyle {
                    stagedTextStylesByObjectID[object.id] = textStyle
                    stagedTextByObjectID[object.id] = StagedTextEdit(
                        text: text,
                        style: textStyle
                    )
                } else if commit {
                    stagedTextByObjectID.removeValue(forKey: object.id)
                }
                updateStagedTextOverlays()
            }
#endif
            refreshOverlay()
            if commit, let object {
#if os(macOS)
                DispatchQueue.main.async { [weak self] in
                    self?.onReplaceTextObject(object, text)
                }
#else
                onReplaceTextObject(object, text)
#endif
            }
            if commit, let annotation, text != annotation.contents {
                onReplaceAnnotationText(annotation, text)
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
            } else {
                frame = nil
            }
            guard var frame, let inlineTextField else { return }
#if os(macOS)
            if let object = inlineEditingObject {
                inlineTextMaskView?.frame = textMaskFrame(for: object) ?? .zero
                inlineTextField.frame = frame
                adjustInlineEditorWidth(inlineTextField)
                adjustInlineEditorHeight(inlineTextField)
                alignInlineTextBaseline(
                    inlineTextField,
                    object: object,
                    annotation: nil
                )
                return
            }
#endif
            let current = inlineTextField.frame
            guard abs(current.minX - frame.minX) > 0.5 ||
                    abs(current.minY - frame.minY) > 0.5 ||
                    abs(current.width - frame.width) > 0.5 ||
                    abs(current.height - frame.height) > 0.5 else { return }
            inlineTextField.frame = frame
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
            return converted
        }

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

        private func applyResolvedTextStyle(
            _ object: PDFPageObjectSnapshot,
            to field: NSTextView
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
            inlineEditingTextStyle = style
            field.textColor = color
            field.font = font
            if let frame = inlineTextEditorFrame(for: object) {
                field.frame = frame
            }
            inlineTextMaskView?.frame = textMaskFrame(for: object) ?? .zero
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
                  let object = inlineEditingObject,
                  let baseFrame = inlineTextEditorFrame(for: object),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measuredWidth = layoutManager.usedRect(for: textContainer).width + 4
            let availableWidth = max(pdfView.bounds.maxX - baseFrame.minX - 8, baseFrame.width)
            textView.frame.size.width = min(max(baseFrame.width, measuredWidth), availableWidth)
        }

        private func adjustInlineEditorHeight(_ textView: NSTextView) {
            guard let object = inlineEditingObject,
                  let baseFrame = inlineTextEditorFrame(for: object),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measuredHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            guard measuredHeight.isFinite else { return }
            textView.frame.size.height = max(baseFrame.height, measuredHeight)
        }

        private func alignInlineTextBaseline(
            _ textView: NSTextView,
            object: PDFPageObjectSnapshot?,
            annotation: PDFAnnotationSnapshot?
        ) {
            guard annotation == nil else { return }
            let baselineY: CGFloat
            if let object, let objectBaselineY = inlineTextBaselineY(for: object) {
                baselineY = objectBaselineY
            } else {
                guard let font = textView.font else { return }
                baselineY = pdfView?.isFlipped == true
                    ? textView.frame.maxY + font.descender
                    : textView.frame.minY - font.descender
            }
            textView.frame = baselineAlignedFrame(
                for: textView,
                baseFrame: textView.frame,
                baselineY: baselineY
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
            baselineY: CGFloat
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
            alignedFrame.origin.y = pdfView.isFlipped
                ? baselineY - baselineOffsetFromTop
                : baselineY + baselineOffsetFromTop - baseFrame.height
            return alignedFrame
        }

        private func updateStagedTextOverlays() {
            guard let pdfView else { return }
            let liveObjects = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
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
                      let frame = inlineTextEditorFrame(for: object),
                      let maskFrame = textMaskFrame(for: object) else { continue }
                let maskView = stagedTextMaskViews[objectID] ?? PDFTextMaskView(frame: maskFrame)
                if stagedTextMaskViews[objectID] == nil {
                    stagedTextMaskViews[objectID] = maskView
                    pdfView.addSubview(maskView, positioned: .above, relativeTo: nil)
                }
                maskView.frame = maskFrame
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
                    pdfView.addSubview(view, positioned: .above, relativeTo: maskView)
                }
                view.frame = frame
                if view.string != edit.text {
                    view.string = edit.text
                }
                view.textColor = edit.style.color
                view.font = edit.style.font(at: pdfView.scaleFactor)
                if let font = view.font {
                    let measuredWidth = (edit.text as NSString).size(
                        withAttributes: [.font: font]
                    ).width + 4
                    let availableWidth = max(pdfView.bounds.maxX - frame.minX - 8, frame.width)
                    view.frame.size.width = min(max(frame.width, measuredWidth), availableWidth)
                }
                if let layoutManager = view.layoutManager,
                   let textContainer = view.textContainer {
                    textContainer.containerSize = NSSize(
                        width: view.frame.width,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                    layoutManager.ensureLayout(for: textContainer)
                    let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
                    if contentHeight.isFinite {
                        view.frame.size.height = max(frame.height, contentHeight)
                    }
                }
                alignInlineTextBaseline(view, object: object, annotation: nil)
                view.isHidden = inlineEditingObject?.id == objectID
            }
        }

        private func stagedTextTarget(
            at viewPoint: CGPoint,
            pageIndex: Int
        ) -> (object: PDFPageObjectSnapshot, view: PDFPassiveTextView)? {
            guard let objectID = stagedTextViews.first(where: { objectID, view in
                stagedTextByObjectID[objectID] != nil &&
                    !view.isHidden &&
                    view.frame.contains(viewPoint)
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
            for (objectID, text) in pendingStagedTextByObjectID {
                let style = stagedTextStylesByObjectID[objectID] ??
                    stagedTextByObjectID[objectID]?.style ??
                    objects.first(where: { $0.id == objectID }).flatMap(makeInlineTextStyle)
                guard let style else { continue }
                stagedTextStylesByObjectID[objectID] = style
                stagedTextByObjectID[objectID] = StagedTextEdit(text: text, style: style)
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

        private func applyResolvedTextStyle(
            _ object: PDFPageObjectSnapshot,
            to field: UITextField
        ) {
            field.textColor = objectTextColor(object.fillColor)
            field.font = objectFont(
                named: object.fontName,
                displayPointSize: displayFontSize(for: object),
                fontData: object.fontData,
                viewHeight: field.frame.height
            )
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
            annotations
                .filter {
                    $0.reference.pageIndex == pageIndex &&
                    $0.bounds.insetBy(dx: -8, dy: -8).contains(pagePoint)
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
            if annotationEditingEnabled,
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
            if interactionAnnotation?.kind == .note {
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
                refreshOverlay(previewBounds: interactionStartBounds.offsetBy(
                    dx: offset.width,
                    dy: offset.height
                ))
                if finished, abs(offset.width) + abs(offset.height) > 0.01 {
                    if let annotation = interactionAnnotation {
                        onSetAnnotationBounds(
                            annotation,
                            interactionStartBounds.offsetBy(dx: offset.width, dy: offset.height)
                        )
                    } else if let object = interactionObject {
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
                if let annotation = interactionAnnotation {
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
            interactionPage = nil
        }

#if os(macOS)
        private func installGestures(on pdfView: PDFView) {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let magnify = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleMagnification(_:))
            )
            let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            gestures = [pan, magnify, rotate]
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
            let doubleTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleDoubleTap(_:))
            )
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            gestures = [tap, doubleTap, pan, pinch, rotate]
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
extension PDFKitView.Coordinator: PDFInteractionMouseHandling {
    func shouldCaptureMouse(at viewPoint: CGPoint, in pdfView: PDFView) -> Bool {
        if let inlineTextField {
            return !inlineTextField.frame.contains(viewPoint)
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
        if commentPlacementEnabled {
            return true
        }
        if annotationEditingEnabled,
           annotation(at: pagePoint, pageIndex: pageIndex) != nil {
            return true
        }
        if objectEditingEnabled,
           editableObject(at: viewPoint, on: page, pageIndex: pageIndex) != nil ||
            copyableWordSelection(at: pagePoint, on: page) != nil {
            return true
        }
        return false
    }

    func handleMouseDown(_ event: NSEvent, in pdfView: PDFView) -> Bool {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        if let inlineTextField, inlineTextField.frame.contains(viewPoint) {
            return false
        }

        guard let page = pdfView.page(for: viewPoint, nearest: false),
              let document = pdfView.document else {
            finishInlineTextEditing(commit: true)
            return false
        }
        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(viewPoint, to: page)

        if event.clickCount >= 2, !commentPlacementEnabled {
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

        if commentPlacementEnabled {
            selectTarget(at: viewPoint)
            return true
        }
        if annotationEditingEnabled,
           annotation(at: pagePoint, pageIndex: pageIndex) != nil {
            selectTarget(at: viewPoint)
            return true
        }
        if objectEditingEnabled {
            let touchedObject = editableObject(
                at: viewPoint,
                on: page,
                pageIndex: pageIndex
            )
            let touchesText = touchedObject?.kind == .text ||
                copyableWordSelection(at: pagePoint, on: page) != nil
            if touchedObject != nil || touchesText {
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

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard inlineTextField == nil, let pdfView else { return false }
        return shouldBeginInteractionGesture(
            gestureRecognizer,
            at: gestureRecognizer.location(in: pdfView),
            in: pdfView
        )
    }

    private func shouldBeginInteractionGesture(
        _ gestureRecognizer: NSGestureRecognizer,
        at viewPoint: CGPoint,
        in pdfView: PDFView
    ) -> Bool {
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
        if annotationEditingEnabled,
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
        let point = pdfView.convert(event.locationInWindow, from: nil)
        if let inlineTextField, inlineTextField.frame.contains(point) {
            return false
        }
        return shouldBeginInteractionGesture(
            gestureRecognizer,
            at: point,
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
    }

    func textDidEndEditing(_ notification: Notification) {
        guard inlineEditorDidGainFocus else { return }
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
        return false
    }
}
#endif

#if os(iOS)
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate, UITextFieldDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let inlineTextField, let touchedView = touch.view else { return true }
        return touchedView !== inlineTextField && !touchedView.isDescendant(of: inlineTextField)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer {
            return commentPlacementEnabled || objectEditingEnabled || annotationEditingEnabled
        }
        if gestureRecognizer is UIRotationGestureRecognizer,
           selectedAnnotation.wrappedValue != nil {
            return false
        }
        guard let pdfView else { return false }
        let pageIndex: Int
        let bounds: CGRect
        if annotationEditingEnabled,
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
            let point = gestureRecognizer.location(in: pdfView)
            let rect = pdfView.convert(bounds, from: page).standardized
            return rect.insetBy(dx: -18, dy: -18).contains(point)
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        finishInlineTextEditing(commit: true)
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        finishInlineTextEditing(commit: true)
    }
}
#endif
