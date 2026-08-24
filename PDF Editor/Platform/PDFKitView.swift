import PDFKit
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit

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
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
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
    @Binding var selectedObject: PDFPageObjectSnapshot?
    let objectEditingEnabled: Bool
    let onTranslateObject: (PDFPageObjectSnapshot, CGSize) -> Void
    let onSetObjectTransform: (PDFPageObjectSnapshot, CGAffineTransform) -> Void
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let annotationEditingEnabled: Bool
    let onSetAnnotationBounds: (PDFAnnotationSnapshot, CGRect) -> Void
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
            selectedObject: $selectedObject,
            objectEditingEnabled: objectEditingEnabled,
            onTranslateObject: onTranslateObject,
            onSetObjectTransform: onSetObjectTransform,
            annotations: annotations,
            selectedAnnotation: $selectedAnnotation,
            annotationEditingEnabled: annotationEditingEnabled,
            onSetAnnotationBounds: onSetAnnotationBounds
        )
    }

    func makePDFView() -> PDFView {
        let pdfView = PDFView()
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
            pdfView.document = document
        }
        goToSelectedPage(in: pdfView)
        applyViewerMode(to: pdfView)
        applyViewerCommand(to: pdfView, coordinator: coordinator)
    }

    func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.selectedPageIndex = $selectedPageIndex
        coordinator.selection = $selection
        coordinator.objects = objects
        coordinator.selectedObject = $selectedObject
        coordinator.objectEditingEnabled = objectEditingEnabled
        coordinator.onTranslateObject = onTranslateObject
        coordinator.onSetObjectTransform = onSetObjectTransform
        coordinator.annotations = annotations
        coordinator.selectedAnnotation = $selectedAnnotation
        coordinator.annotationEditingEnabled = annotationEditingEnabled
        coordinator.onSetAnnotationBounds = onSetAnnotationBounds
        coordinator.refreshOverlay()
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

    func goToSelectedPage(in pdfView: PDFView) {
        guard let selectedPageIndex,
              let page = document.page(at: selectedPageIndex),
              pdfView.currentPage !== page else { return }
        pdfView.go(to: page)
    }
}

extension PDFKitView {
    final class Coordinator: NSObject {
        enum DragMode { case move, scale }

        var selectedPageIndex: Binding<Int?>
        var selection: Binding<PDFSelection?>
        var objects: [PDFPageObjectSnapshot]
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
        var lastViewerCommandID: UUID?

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

#if os(macOS)
        private var gestures: [NSGestureRecognizer] = []
#elseif os(iOS)
        private var gestures: [UIGestureRecognizer] = []
#endif

        init(
            selectedPageIndex: Binding<Int?>,
            selection: Binding<PDFSelection?>,
            objects: [PDFPageObjectSnapshot],
            selectedObject: Binding<PDFPageObjectSnapshot?>,
            objectEditingEnabled: Bool,
            onTranslateObject: @escaping (PDFPageObjectSnapshot, CGSize) -> Void,
            onSetObjectTransform: @escaping (PDFPageObjectSnapshot, CGAffineTransform) -> Void,
            annotations: [PDFAnnotationSnapshot],
            selectedAnnotation: Binding<PDFAnnotationSnapshot?>,
            annotationEditingEnabled: Bool,
            onSetAnnotationBounds: @escaping (PDFAnnotationSnapshot, CGRect) -> Void
        ) {
            self.selectedPageIndex = selectedPageIndex
            self.selection = selection
            self.objects = objects
            self.selectedObject = selectedObject
            self.objectEditingEnabled = objectEditingEnabled
            self.onTranslateObject = onTranslateObject
            self.onSetObjectTransform = onSetObjectTransform
            self.annotations = annotations
            self.selectedAnnotation = selectedAnnotation
            self.annotationEditingEnabled = annotationEditingEnabled
            self.onSetAnnotationBounds = onSetAnnotationBounds
            super.init()
            configureOverlay()
        }

        func observe(_ pdfView: PDFView) {
            self.pdfView = pdfView
#if os(macOS)
            pdfView.wantsLayer = true
            pdfView.layer?.addSublayer(outlineLayer)
            handleLayers.forEach { pdfView.layer?.addSublayer($0) }
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
                    if selectedPageIndex.wrappedValue != pageIndex {
                        selectedPageIndex.wrappedValue = pageIndex
                        selectedObject.wrappedValue = nil
                        selectedAnnotation.wrappedValue = nil
                    }
                    refreshOverlay()
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
                ) { [weak self] _ in self?.refreshOverlay() },
                center.addObserver(
                    forName: .PDFViewVisiblePagesChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in self?.refreshOverlay() },
            ]
            updateGestureAvailability()
            refreshOverlay()
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            outlineLayer.removeFromSuperlayer()
            handleLayers.forEach { $0.removeFromSuperlayer() }
            if let pdfView {
                gestures.forEach(pdfView.removeGestureRecognizer)
            }
            gestures.removeAll()
        }

        func refreshOverlay(previewBounds: CGRect? = nil) {
            guard let pdfView else {
                setOverlayHidden(true)
                return
            }
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
            setOverlayHidden(false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outlineLayer.frame = pdfView.bounds
            outlineLayer.path = CGPath(rect: viewBounds, transform: nil)
            let points = [
                CGPoint(x: viewBounds.minX, y: viewBounds.minY),
                CGPoint(x: viewBounds.maxX, y: viewBounds.minY),
                CGPoint(x: viewBounds.maxX, y: viewBounds.maxY),
                CGPoint(x: viewBounds.minX, y: viewBounds.maxY),
            ]
            for (layer, point) in zip(handleLayers, points) {
                layer.frame = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            }
            CATransaction.commit()
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

        private func updateGestureAvailability() {
            gestures.forEach { $0.isEnabled = objectEditingEnabled || annotationEditingEnabled }
            refreshOverlay()
        }

        private func selectTarget(at viewPoint: CGPoint) {
            guard let pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false),
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            if annotationEditingEnabled {
                selectedObject.wrappedValue = nil
                selectedAnnotation.wrappedValue = annotations
                    .filter {
                        $0.reference.pageIndex == pageIndex &&
                        $0.bounds.insetBy(dx: -3, dy: -3).contains(pagePoint)
                    }
                    .min { lhs, rhs in
                        lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
                    }
                if selectedAnnotation.wrappedValue != nil {
                    selectedPageIndex.wrappedValue = pageIndex
                }
                refreshOverlay()
                return
            }
            guard objectEditingEnabled else { return }
            let candidates = objects.filter {
                $0.pageIndex == pageIndex && $0.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
            }.sorted { lhs, rhs in
                let leftPriority = objectPriority(lhs)
                let rightPriority = objectPriority(rhs)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
            selectedObject.wrappedValue = candidates.first
            if let first = candidates.first {
                selectedPageIndex.wrappedValue = first.pageIndex
            }
            refreshOverlay()
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
            guard let pdfView else { return }
            let pageIndex: Int
            let bounds: CGRect
            if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
                interactionAnnotation = annotation
                pageIndex = annotation.reference.pageIndex
                bounds = annotation.bounds
            } else if objectEditingEnabled, let object = selectedObject.wrappedValue {
                interactionObject = object
                pageIndex = object.pageIndex
                bounds = object.bounds
                interactionStartTransform = object.transform
            } else { return }
            guard let page = pdfView.document?.page(at: pageIndex) else { return }
            let selectionRect = pdfView.convert(bounds, from: page).standardized
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
            dragMode = corners.contains { hypot($0.x - viewPoint.x, $0.y - viewPoint.y) <= 20 }
                ? .scale : .move
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
            guard let pdfView else { return }
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
            guard !annotationEditingEnabled else {
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
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let magnify = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleMagnification(_:))
            )
            let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            gestures = [click, pan, magnify, rotate]
            gestures.forEach(pdfView.addGestureRecognizer)
        }

        @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let pdfView else { return }
            selectTarget(at: recognizer.location(in: pdfView))
        }

        @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began: beginPan(at: point)
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
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            gestures = [tap, pan, pinch, rotate]
            gestures.forEach {
                $0.delegate = self
                pdfView.addGestureRecognizer($0)
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView else { return }
            selectTarget(at: recognizer.location(in: pdfView))
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let pdfView else { return }
            let point = recognizer.location(in: pdfView)
            switch recognizer.state {
            case .began: beginPan(at: point)
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

#if os(iOS)
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer {
            return objectEditingEnabled || annotationEditingEnabled
        }
        if gestureRecognizer is UIRotationGestureRecognizer, annotationEditingEnabled {
            return false
        }
        guard let pdfView else { return false }
        let pageIndex: Int
        let bounds: CGRect
        if annotationEditingEnabled, let annotation = selectedAnnotation.wrappedValue {
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
        false
    }
}
#endif
