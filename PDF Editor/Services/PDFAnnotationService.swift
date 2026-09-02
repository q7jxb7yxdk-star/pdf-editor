import CoreGraphics
import Foundation
import PDFKit

#if os(macOS)
import AppKit
typealias PlatformBezierPath = NSBezierPath
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformBezierPath = UIBezierPath
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

struct SignatureStroke: Equatable, Sendable {
    let points: [CGPoint]
}

nonisolated enum PDFAnnotationServiceError: LocalizedError {
    case emptyText
    case emptySignature
    case emptyInkStroke
    case selectionHasNoPages
    case annotationNotFound
    case invalidBounds
    case appearanceStreamStyleUnsupported
    case roundTripVerificationFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "Enter text before adding the annotation."
        case .emptySignature:
            "Draw a signature before adding it to the PDF."
        case .emptyInkStroke:
            "Draw a line before adding it to the PDF."
        case .selectionHasNoPages:
            "Select PDF text before adding a markup annotation."
        case .annotationNotFound:
            "The annotation no longer exists on this page."
        case .invalidBounds:
            "The annotation must remain at least 4 points wide and high."
        case .appearanceStreamStyleUnsupported:
            "This annotation has a fixed appearance stream, so its style cannot be changed safely."
        case .roundTripVerificationFailed:
            "The PDF could not preserve the annotation geometry and style after reopening."
        }
    }
}

nonisolated final class PDFAnnotationService {
    func snapshots(on page: PDFPage, pageIndex: Int) -> [PDFAnnotationSnapshot] {
        page.annotations.enumerated().compactMap { index, annotation in
            // Keep replacement masks created by older app versions out of the
            // annotation editing UI. New text edits never create these masks.
            guard annotation.type != "Popup",
                  annotation.type != "Widget",
                  annotation.value(forAnnotationKey: replacementMaskSubjectKey)
                    as? String != "Text Replacement Mask" else {
                return nil
            }
            return snapshot(
                annotation,
                reference: PDFAnnotationReference(
                    pageIndex: pageIndex,
                    annotationIndex: index
                )
            )
        }
    }

    func snapshot(
        for reference: PDFAnnotationReference,
        in document: PDFDocument
    ) throws -> PDFAnnotationSnapshot {
        let resolved = try resolve(reference, in: document)
        return snapshot(resolved.annotation, reference: reference)
    }

    func resolve(
        _ reference: PDFAnnotationReference,
        in document: PDFDocument
    ) throws -> (page: PDFPage, annotation: PDFAnnotation) {
        guard let page = document.page(at: reference.pageIndex),
              page.annotations.indices.contains(reference.annotationIndex) else {
            throw PDFAnnotationServiceError.annotationNotFound
        }
        return (page, page.annotations[reference.annotationIndex])
    }

    @discardableResult
    func update(
        _ reference: PDFAnnotationReference,
        with update: PDFAnnotationUpdate,
        in document: PDFDocument
    ) throws -> PDFAnnotationSnapshot {
        let resolved = try resolve(reference, in: document)
        let annotation = resolved.annotation
        var update = update
        if annotation.type == "FreeText",
           let requestedFontSize = update.fontSize,
           update.bounds == nil {
            let fontSize = min(max(requestedFontSize, 6), 144)
            update.fontSize = fontSize
            update.bounds = fittedFreeTextBounds(
                annotation,
                on: resolved.page,
                text: update.contents ?? annotation.contents ?? "",
                fontSize: fontSize
            )
        }

        let requestsStyleChange = update.color != nil || update.fontColor != nil ||
            update.fontSize != nil || update.lineWidth != nil
        let regeneratesFreeTextLayout = annotation.type == "FreeText" &&
            (update.bounds != nil || update.contents != nil || update.fontSize != nil)
        if annotation.hasAppearanceStream, regeneratesFreeTextLayout {
            annotation.removeValue(forAnnotationKey: appearanceDictionaryKey)
            annotation.removeValue(forAnnotationKey: appearanceStateKey)
        }
        if annotation.hasAppearanceStream, requestsStyleChange {
            let canRegenerateNoteAppearance = annotation.type == "Text" &&
                update.color != nil && update.fontColor == nil &&
                update.fontSize == nil && update.lineWidth == nil
            let canRegenerateHighlightAppearance = annotation.type == "Highlight" &&
                update.color != nil && update.fontColor == nil &&
                update.fontSize == nil && update.lineWidth == nil
            let canRegenerateInkAppearance = annotation.type == "Ink" &&
                update.contents == nil && update.fontColor == nil &&
                update.fontSize == nil &&
                (update.color != nil || update.lineWidth != nil)
            let canRegenerateFreeTextAppearance = annotation.type == "FreeText" &&
                update.contents == nil && update.lineWidth == nil &&
                (update.color != nil || update.fontColor != nil || update.fontSize != nil)
            guard canRegenerateNoteAppearance || canRegenerateHighlightAppearance ||
                canRegenerateInkAppearance || canRegenerateFreeTextAppearance else {
                throw PDFAnnotationServiceError.appearanceStreamStyleUnsupported
            }
            annotation.removeValue(forAnnotationKey: appearanceDictionaryKey)
            annotation.removeValue(forAnnotationKey: appearanceStateKey)
        }

        if let bounds = update.bounds {
            let bounds = bounds.standardized
            guard bounds.width >= 4, bounds.height >= 4 else {
                throw PDFAnnotationServiceError.invalidBounds
            }
            transformGeometry(of: annotation, from: annotation.bounds, to: bounds)
            annotation.bounds = bounds
        }
        if let contents = update.contents {
            annotation.contents = contents
        }
        if let color = update.color {
            setPrimaryColor(color, on: annotation)
        }
        if let fontColor = update.fontColor {
            annotation.fontColor = platformColor(fontColor)
        }
        if let fontSize = update.fontSize {
            annotation.font = resizedFont(annotation.font, size: min(max(fontSize, 6), 144))
        }
        if let lineWidth = update.lineWidth {
            let border = annotation.border ?? PDFBorder()
            border.lineWidth = min(max(lineWidth, 0.5), 24)
            annotation.border = border
        }
        if annotation.type == "FreeText", regeneratesFreeTextLayout {
            applyFreeTextContentInsets(to: annotation)
        }
        annotation.modificationDate = Date()
        return snapshot(annotation, reference: reference)
    }

    @discardableResult
    func addNote(
        text: String,
        at point: CGPoint,
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let text = try validated(text)
        let iconSize: CGFloat = 24
        let pageBounds = page.bounds(for: .cropBox).standardized
        let proposedOrigin = CGPoint(
            x: point.x - iconSize / 2,
            y: point.y - iconSize / 2
        )
        let maximumX = max(pageBounds.minX, pageBounds.maxX - iconSize)
        let maximumY = max(pageBounds.minY, pageBounds.maxY - iconSize)
        let bounds = CGRect(
            x: min(max(proposedOrigin.x, pageBounds.minX), maximumX),
            y: min(max(proposedOrigin.y, pageBounds.minY), maximumY),
            width: iconSize,
            height: iconSize
        )
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .text,
            withProperties: nil
        )
        annotation.iconType = .comment
        annotation.contents = text
        setPrimaryColor(components(of: .systemYellow), on: annotation)
        page.addAnnotation(annotation)
        return annotation
    }

    @discardableResult
    func addFreeText(
        text: String,
        bounds: CGRect,
        fontSize: CGFloat = 11,
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let text = try validated(text)
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = .systemFont(ofSize: fontSize)
        annotation.fontColor = labelColor
        annotation.color = .clear
        annotation.alignment = .left
        applyFreeTextContentInsets(to: annotation)
        page.addAnnotation(annotation)
        return annotation
    }

    func addHighlight(
        to selection: PDFSelection,
        color: PlatformColor = .systemYellow
    ) throws -> [PDFAnnotation] {
        guard !selection.pages.isEmpty else {
            throw PDFAnnotationServiceError.selectionHasNoPages
        }

        return selection.pages.compactMap { page in
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else {
                return nil
            }

            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .highlight,
                withProperties: nil
            )
            setPrimaryColor(components(of: color.withAlphaComponent(0.45)), on: annotation)
            annotation.quadrilateralPoints = selection.selectionsByLine()
                .filter { $0.pages.contains(page) }
                .flatMap { lineSelection -> [NSValue] in
                    let line = lineSelection.bounds(for: page)
                    return [
                        CGPoint(x: line.minX - bounds.minX, y: line.maxY - bounds.minY),
                        CGPoint(x: line.maxX - bounds.minX, y: line.maxY - bounds.minY),
                        CGPoint(x: line.minX - bounds.minX, y: line.minY - bounds.minY),
                        CGPoint(x: line.maxX - bounds.minX, y: line.minY - bounds.minY),
                    ].map(pointValue)
                }
            page.addAnnotation(annotation)
            return annotation
        }
    }

    @discardableResult
    func addSignature(
        strokes: [SignatureStroke],
        bounds: CGRect,
        lineWidth requestedLineWidth: CGFloat = 2,
        minimumPadding: CGFloat = 2,
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let placementBounds = bounds.standardized
        let drawableStrokes = strokes.filter {
            $0.points.count > 1 && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
        guard !drawableStrokes.isEmpty else {
            throw PDFAnnotationServiceError.emptySignature
        }

        // Signature strokes are normalized to their requested placement container.
        // Keep that visual mapping, but make the annotation itself hug the actual ink
        // so selection and editing controls do not include unused canvas whitespace.
        let pageStrokes = drawableStrokes.map { stroke in
            stroke.points.map { point in
                CGPoint(
                    x: placementBounds.minX + min(max(point.x, 0), 1) * placementBounds.width,
                    y: placementBounds.minY + (1 - min(max(point.y, 0), 1)) * placementBounds.height
                )
            }
        }
        let pagePoints = pageStrokes.flatMap { $0 }
        guard let minimumX = pagePoints.map(\.x).min(),
              let maximumX = pagePoints.map(\.x).max(),
              let minimumY = pagePoints.map(\.y).min(),
              let maximumY = pagePoints.map(\.y).max() else {
            throw PDFAnnotationServiceError.emptySignature
        }
        let lineWidth = min(max(requestedLineWidth, 0.5), 24)
        let padding = max(lineWidth, minimumPadding)
        var tightBounds = CGRect(
            x: minimumX - padding,
            y: minimumY - padding,
            width: maximumX - minimumX + padding * 2,
            height: maximumY - minimumY + padding * 2
        ).standardized
        if tightBounds.width < 4 {
            tightBounds = tightBounds.insetBy(dx: -(4 - tightBounds.width) / 2, dy: 0)
        }
        if tightBounds.height < 4 {
            tightBounds = tightBounds.insetBy(dx: 0, dy: -(4 - tightBounds.height) / 2)
        }

        let annotation = PDFAnnotation(
            bounds: tightBounds,
            forType: .ink,
            withProperties: nil
        )
        setPrimaryColor(.black, on: annotation)
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = lineWidth

        for stroke in pageStrokes {
            let localPoints = stroke.map {
                CGPoint(x: $0.x - tightBounds.minX, y: $0.y - tightBounds.minY)
            }
            let path = PlatformBezierPath()
            path.move(to: localPoints[0])
            for point in localPoints.dropFirst() {
#if os(macOS)
                path.line(to: point)
#else
                path.addLine(to: point)
#endif
            }
            path.lineWidth = lineWidth
            annotation.add(path)
        }

        page.addAnnotation(annotation)
        return annotation
    }

    @discardableResult
    func addInkStroke(
        points: [CGPoint],
        color: PDFAnnotationColor = .black,
        lineWidth: CGFloat = 2,
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let points = points.filter { point in
            point.x.isFinite && point.y.isFinite
        }
        guard points.count > 1 else {
            throw PDFAnnotationServiceError.emptyInkStroke
        }

        let clampedLineWidth = min(max(lineWidth, 0.5), 24)
        let minimumX = points.map(\.x).min() ?? 0
        let maximumX = points.map(\.x).max() ?? minimumX
        let minimumY = points.map(\.y).min() ?? 0
        let maximumY = points.map(\.y).max() ?? minimumY
        let padding = max(clampedLineWidth, 2)
        var bounds = CGRect(
            x: minimumX - padding,
            y: minimumY - padding,
            width: maximumX - minimumX + padding * 2,
            height: maximumY - minimumY + padding * 2
        ).standardized
        if bounds.width < 4 {
            bounds = bounds.insetBy(dx: -(4 - bounds.width) / 2, dy: 0)
        }
        if bounds.height < 4 {
            bounds = bounds.insetBy(dx: 0, dy: -(4 - bounds.height) / 2)
        }

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .ink,
            withProperties: nil
        )
        setPrimaryColor(color, on: annotation)
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = clampedLineWidth

        let localPoints = points.map { point in
            CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        }
        let path = PlatformBezierPath()
        path.move(to: localPoints[0])
        for point in localPoints.dropFirst() {
#if os(macOS)
            path.line(to: point)
#else
            path.addLine(to: point)
#endif
        }
        path.lineWidth = clampedLineWidth
        annotation.add(path)
        page.addAnnotation(annotation)
        return annotation
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
    }

    func remove(
        _ reference: PDFAnnotationReference,
        from document: PDFDocument
    ) throws {
        let resolved = try resolve(reference, in: document)
        resolved.page.removeAnnotation(resolved.annotation)
    }

    func verify(
        _ expected: PDFAnnotationSnapshot,
        in document: PDFDocument
    ) throws {
        let resolved = try resolve(expected.reference, in: document)
        let actual = snapshot(resolved.annotation, reference: expected.reference)
        guard actual.kind == expected.kind,
              actual.contents == expected.contents,
              approximatelyEqual(actual.bounds, expected.bounds),
              approximatelyEqual(actual.color, expected.color),
              approximatelyEqual(actual.fontSize, expected.fontSize),
              abs(actual.lineWidth - expected.lineWidth) < 0.05,
              actual.geometryPointCount == expected.geometryPointCount else {
            throw PDFAnnotationServiceError.roundTripVerificationFailed
        }
    }

    private func validated(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw PDFAnnotationServiceError.emptyText
        }
        return text
    }

    private func snapshot(
        _ annotation: PDFAnnotation,
        reference: PDFAnnotationReference
    ) -> PDFAnnotationSnapshot {
        PDFAnnotationSnapshot(
            reference: reference,
            kind: PDFEditableAnnotationKind(pdfSubtype: annotation.type),
            bounds: annotation.bounds,
            contents: annotation.contents ?? "",
            color: primaryColor(of: annotation),
            fontColor: annotation.type == "FreeText"
                ? annotation.fontColor.map { color in
                    components(of: color).withAlpha(opacity(of: annotation))
                }
                : nil,
            fontSize: annotation.type == "FreeText"
                ? annotation.font?.pointSize
                : nil,
            lineWidth: annotation.type == "Ink"
                ? (annotation.border?.lineWidth ?? 1)
                : 0,
            geometryPointCount: geometryPointCount(of: annotation),
            hasAppearanceStream: annotation.hasAppearanceStream
        )
    }

    private func geometryPointCount(of annotation: PDFAnnotation) -> Int {
        let inkCount = annotation.paths?.reduce(0) { count, path in
            #if os(macOS)
            count + path.elementCount
            #else
            var elementCount = 0
            path.cgPath.applyWithBlock { _ in elementCount += 1 }
            return count + elementCount
            #endif
        } ?? 0
        return inkCount + (annotation.quadrilateralPoints?.count ?? 0)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.05 && abs(lhs.minY - rhs.minY) < 0.05 &&
        abs(lhs.width - rhs.width) < 0.05 && abs(lhs.height - rhs.height) < 0.05
    }

    private func approximatelyEqual(
        _ lhs: PDFAnnotationColor,
        _ rhs: PDFAnnotationColor
    ) -> Bool {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) +
        abs(lhs.blue - rhs.blue) < 0.06
    }

    private func approximatelyEqual(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs - rhs) < 0.05
        default: false
        }
    }

    private func transformGeometry(
        of annotation: PDFAnnotation,
        from oldBounds: CGRect,
        to newBounds: CGRect
    ) {
        guard oldBounds.width != 0, oldBounds.height != 0 else { return }
        let transformPoint: (CGPoint) -> CGPoint = { point in
            CGPoint(
                x: newBounds.minX + (point.x - oldBounds.minX) / oldBounds.width * newBounds.width,
                y: newBounds.minY + (point.y - oldBounds.minY) / oldBounds.height * newBounds.height
            )
        }

        if let paths = annotation.paths, !paths.isEmpty {
            let scaleX = newBounds.width / oldBounds.width
            let scaleY = newBounds.height / oldBounds.height
            let transform = CGAffineTransform(
                a: scaleX,
                b: 0,
                c: 0,
                d: scaleY,
                tx: 0,
                ty: 0
            )
            for path in paths {
                annotation.remove(path)
                guard let copy = path.copy() as? PlatformBezierPath else { continue }
                #if os(macOS)
                copy.transform(using: AffineTransform(
                    m11: transform.a,
                    m12: transform.b,
                    m21: transform.c,
                    m22: transform.d,
                    tX: transform.tx,
                    tY: transform.ty
                ))
                #else
                copy.apply(transform)
                #endif
                annotation.add(copy)
            }
        }

        if let points = annotation.quadrilateralPoints {
            annotation.quadrilateralPoints = points.map { pointValue(transformPoint(platformPoint($0))) }
        }
    }

    private func resizedFont(_ font: PlatformFont?, size: CGFloat) -> PlatformFont {
        guard let font else { return .systemFont(ofSize: size) }
        #if os(macOS)
        return PlatformFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
        #else
        return PlatformFont(descriptor: font.fontDescriptor, size: size)
        #endif
    }

    private func fittedFreeTextBounds(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        text: String,
        fontSize: CGFloat
    ) -> CGRect {
        let currentBounds = annotation.bounds.standardized
        let pageBounds = page.bounds(for: .cropBox).standardized
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return currentBounds
        }

        let font = resizedFont(annotation.font, size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lines = text.components(separatedBy: "\n")
        let widestLine = lines.reduce(CGFloat.zero) { width, line in
            max(width, (line as NSString).size(withAttributes: attributes).width)
        }
        let minimumWidth = min(24, pageBounds.width)
        let width = min(
            max(minimumWidth, ceil(widestLine) + 12),
            pageBounds.width
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
#if os(macOS)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
#else
        let lineHeight = ceil(font.lineHeight)
#endif
        let contentHeight = max(
            lineHeight * CGFloat(max(lines.count, 1)),
            ceil(renderedHeight)
        )
        let height = min(
            max(8, contentHeight + 8),
            pageBounds.height
        )
        let maximumX = max(pageBounds.minX, pageBounds.maxX - width)
        let maximumY = max(pageBounds.minY, pageBounds.maxY - height)
        let x = min(max(currentBounds.minX, pageBounds.minX), maximumX)
        let preferredY = currentBounds.maxY - height
        let y = min(max(preferredY, pageBounds.minY), maximumY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func applyFreeTextContentInsets(to annotation: PDFAnnotation) {
        let bounds = annotation.bounds.standardized
        guard bounds.width > 0, bounds.height > 0 else { return }
        let font = annotation.font ?? .systemFont(ofSize: 11)
        let text = annotation.contents ?? ""
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lines = text.components(separatedBy: "\n")
        let renderedHeight = (text as NSString).boundingRect(
            with: CGSize(
                width: max(bounds.width - 12, 1),
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).height
#if os(macOS)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
#else
        let lineHeight = ceil(font.lineHeight)
#endif
        let contentHeight = max(
            lineHeight * CGFloat(max(lines.count, 1)),
            ceil(renderedHeight)
        )
        let horizontalInset = min(6, max(bounds.width / 2 - 0.01, 0))
        let verticalInset = min(
            max((bounds.height - contentHeight) / 2, 0),
            max(bounds.height / 2 - 0.01, 0)
        )
        annotation.setValue(
            [
                NSNumber(value: Double(horizontalInset)),
                NSNumber(value: Double(verticalInset)),
                NSNumber(value: Double(horizontalInset)),
                NSNumber(value: Double(verticalInset)),
            ],
            forAnnotationKey: differenceRectangleKey
        )
    }

    private func platformColor(_ color: PDFAnnotationColor) -> PlatformColor {
        PlatformColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    private var opacityKey: PDFAnnotationKey { PDFAnnotationKey(rawValue: "/CA") }
    private var replacementMaskSubjectKey: PDFAnnotationKey {
        PDFAnnotationKey(rawValue: "/Subj")
    }
    private var differenceRectangleKey: PDFAnnotationKey { PDFAnnotationKey(rawValue: "/RD") }
    private var appearanceDictionaryKey: PDFAnnotationKey { PDFAnnotationKey(rawValue: "/AP") }
    private var appearanceStateKey: PDFAnnotationKey { PDFAnnotationKey(rawValue: "/AS") }

    private func opacity(of annotation: PDFAnnotation) -> CGFloat {
        if let number = annotation.value(forAnnotationKey: opacityKey) as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        if annotation.type == "FreeText",
           let fontColor = annotation.fontColor {
            return components(of: fontColor).alpha
        }
        return components(of: annotation.color).alpha
    }

    private func setPrimaryColor(_ color: PDFAnnotationColor, on annotation: PDFAnnotation) {
        if annotation.type == "FreeText" {
            annotation.fontColor = platformColor(color)
        } else {
            annotation.color = platformColor(color)
        }
    }

    private func primaryColor(of annotation: PDFAnnotation) -> PDFAnnotationColor {
        let color = annotation.type == "FreeText"
            ? (annotation.fontColor ?? annotation.color)
            : annotation.color
        return components(of: color).withAlpha(opacity(of: annotation))
    }

    private func components(of color: PlatformColor) -> PDFAnnotationColor {
        #if os(macOS)
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return PDFAnnotationColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return PDFAnnotationColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    private func platformPoint(_ value: NSValue) -> CGPoint {
        #if os(macOS)
        value.pointValue
        #else
        value.cgPointValue
        #endif
    }

    private var labelColor: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    private func pointValue(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        NSValue(point: point)
        #else
        NSValue(cgPoint: point)
        #endif
    }
}
