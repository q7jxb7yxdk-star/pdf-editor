import PDFKit
import SwiftUI

/// One sidebar selection arms exactly one placement; it never edits Widgets.
struct PDFFormPlacementRequest: Identifiable {
    let id = UUID()
    let kind: PDFFormDesignKind
}

struct PDFFormPlacementConfiguration {
    let request: PDFFormPlacementRequest
    let onPlace: (PDFDocument, Int, CGRect) -> Void
    let onCancel: () -> Void
}

#if os(macOS)
import AppKit
typealias PDFFormPlacementNativeView = NSView
#else
import UIKit
typealias PDFFormPlacementNativeView = UIView
#endif

/// Temporary input surface over PDFKit. Removing it immediately returns input
/// to the actual AcroForm controls, without a design/preview mode switch.
final class PDFFormPlacementView: PDFFormPlacementNativeView {
    private weak var pdfView: PDFView?
    private var configuration: PDFFormPlacementConfiguration?
    private var page: PDFPage?
    private var sourceDocument: PDFDocument?
    private var startPoint = CGPoint.zero
    private var outline: CGRect?
    private var isDragging = false
    private var observers: [NSObjectProtocol] = []
#if os(macOS)
    private var trackingArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
#else
    private var scrollStart = CGPoint.zero
    private var zoomStart: CGFloat = 1
#endif

    static func install(on pdfView: PDFView, configuration: PDFFormPlacementConfiguration?) {
        let existing = pdfView.subviews.compactMap { $0 as? PDFFormPlacementView }.first
        guard let configuration else {
            existing?.configuration = nil
            existing?.clearGesture()
#if os(macOS)
            if let existing, existing.window?.firstResponder === existing {
                existing.window?.makeFirstResponder(pdfView)
            }
#endif
            existing?.removeFromSuperview()
            return
        }
        let view = existing ?? PDFFormPlacementView(frame: pdfView.bounds)
        view.pdfView = pdfView
        if view.configuration?.request.id != configuration.request.id ||
            (view.sourceDocument != nil && view.sourceDocument !== pdfView.document) {
            view.clearGesture()
        }
        view.configuration = configuration
#if os(macOS)
        view.autoresizingMask = [.width, .height]
        pdfView.addSubview(view, positioned: .above, relativeTo: nil)
        if existing == nil, let window = view.window, window.isKeyWindow, window.attachedSheet == nil {
            window.makeFirstResponder(view)
        }
        view.window?.invalidateCursorRects(for: view)
#else
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .clear
        view.isOpaque = false
        if existing == nil { pdfView.addSubview(view); view.installGestures() }
        pdfView.bringSubviewToFront(view)
#endif
        if existing == nil { view.observeViewport() }
        view.redraw()
    }

    private func observeViewport() {
        for name: Notification.Name in [.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearGesture() }
            })
        }
#if os(macOS)
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let changed = note.object as? NSClipView,
                      let pdfView = self.pdfView, changed.isDescendant(of: pdfView) else { return }
                self.clearGesture()
            }
        })
#endif
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func redraw() {
#if os(macOS)
        needsDisplay = true
#else
        setNeedsDisplay()
#endif
    }

    private func clearGesture() {
        page = nil
        sourceDocument = nil
        outline = nil
        isDragging = false
        redraw()
    }

    private func pagePoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        return pdfView.convert(convert(point, to: pdfView), to: page)
    }

    private func rectangle(from start: CGPoint, to end: CGPoint, on page: PDFPage) -> CGRect {
        let a = pagePoint(start, on: page), b = pagePoint(end, on: page)
        let bounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let minimumDimension = configuration?.request.kind.minimumDimension ?? 12
        return PDFFormPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            .clamped(bounds, minimumDimension: minimumDimension)
    }

    private func defaultBounds(at point: CGPoint, on page: PDFPage) -> CGRect {
        let isText = configuration?.request.kind == .text
        let scale = max(pdfView?.scaleFactor ?? 1, 0.01)
        return rectangle(from: point, to: CGPoint(x: point.x + (isText ? 180 : 11) * scale,
                                                  y: point.y + (isText ? 28 : 11) * scale), on: page)
    }

    private func begin(at point: CGPoint) {
        clearGesture()
        guard configuration != nil, let pdfView, let document = pdfView.document,
              let page = pdfView.page(for: convert(point, to: pdfView), nearest: false) else { return }
        self.page = page
        sourceDocument = document
        startPoint = point
        outline = defaultBounds(at: point, on: page)
        redraw()
    }

    private func drag(to point: CGPoint) {
        guard let page, sourceDocument === pdfView?.document else { clearGesture(); return }
        isDragging = isDragging || hypot(point.x - startPoint.x, point.y - startPoint.y) >= 3
        if isDragging { outline = rectangle(from: startPoint, to: point, on: page) }
        redraw()
    }

    private func finish(at point: CGPoint) {
        drag(to: point)
        guard let sourceDocument, sourceDocument === pdfView?.document,
              let page, let outline, let configuration else { clearGesture(); return }
        let pageIndex = sourceDocument.index(for: page)
        clearGesture()
        // Disarm before calling into SwiftUI: a second event cannot duplicate
        // an accepted field while document revision publication is pending.
        self.configuration = nil
        configuration.onPlace(sourceDocument, pageIndex, outline)
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let pdfView, let page, let outline, sourceDocument === pdfView.document else { return }
        let rect = convert(pdfView.convert(outline, from: page), from: pdfView).standardized
#if os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor.systemBlue
#else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let color = UIColor.systemBlue
#endif
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(0.12).cgColor)
        context.fill(rect)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.restoreGState()
    }

#if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let pdfView else { return nil }
        func hitsScroller(_ view: NSView) -> Bool {
            if view is NSScroller, !view.isHidden,
               view.convert(view.bounds, to: self).contains(local) { return true }
            return view.subviews.contains(where: hitsScroller)
        }
        guard !hitsScroller(pdfView), pdfView.page(for: convert(local, to: pdfView), nearest: false) != nil else { return nil }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        guard let pdfView else { return }
        for page in pdfView.visiblePages {
            let rect = convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView).intersection(bounds)
            if !rect.isNull { addCursorRect(rect, cursor: .crosshair) }
        }
    }
    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: .zero,
                                     options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                                     owner: self)
        if let trackingArea { addTrackingArea(trackingArea) }
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { updatePointer(with: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }
    func updatePointer(with event: NSEvent) {
        guard configuration != nil, let pdfView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let isOnPage = pdfView.page(for: convert(point, to: pdfView), nearest: false) != nil
        (isOnPage ? NSCursor.crosshair : .arrow).set()
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        begin(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { finish(at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) { clearGesture(); pdfView?.scrollWheel(with: event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            clearGesture()
            let onCancel = configuration?.onCancel
            configuration = nil
            NSCursor.arrow.set()
            onCancel?()
        } else { super.keyDown(with: event) }
    }
#else
    private func installGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
        let navigation = UIPanGestureRecognizer(target: self, action: #selector(navigate(_:)))
        navigation.minimumNumberOfTouches = 2
        addGestureRecognizer(navigation)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:))))
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        begin(at: point)
        finish(at: point)
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let delta = gesture.translation(in: self)
            begin(at: CGPoint(x: point.x - delta.x, y: point.y - delta.y))
            drag(to: point)
        case .changed: drag(to: point)
        case .ended: finish(at: point)
        case .cancelled, .failed: clearGesture()
        default: break
        }
    }
    private func documentScrollView() -> UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews { if let scroll = find(child) { return scroll } }
            return nil
        }
        return pdfView.flatMap(find)
    }
    @objc private func navigate(_ gesture: UIPanGestureRecognizer) {
        clearGesture()
        guard let scroll = documentScrollView() else { return }
        if gesture.state == .began { scrollStart = scroll.contentOffset }
        let translation = gesture.translation(in: self), inset = scroll.adjustedContentInset
        let minX = -inset.left, minY = -inset.top
        let maxX = max(minX, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        scroll.setContentOffset(CGPoint(x: min(max(scrollStart.x - translation.x, minX), maxX),
                                        y: min(max(scrollStart.y - translation.y, minY), maxY)), animated: false)
    }
    @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
        clearGesture()
        guard let pdfView else { return }
        if gesture.state == .began { zoomStart = pdfView.scaleFactor }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(zoomStart * gesture.scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }
#endif
}
