import CoreGraphics
import CoreText
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

final class PDFAnnotationService {
    func snapshots(on page: PDFPage, pageIndex: Int) -> [PDFAnnotationSnapshot] {
        page.annotations.enumerated().compactMap { index, annotation in
            guard annotation.type != "Popup" else { return nil }
            return snapshot(
                annotation,
                reference: PDFAnnotationReference(
                    pageIndex: pageIndex,
                    annotationIndex: index
                )
            )
        }
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

        let requestsStyleChange = update.color != nil || update.fontColor != nil ||
            update.fontSize != nil || update.lineWidth != nil
        let regeneratesFreeTextContents = annotation.type == "FreeText" &&
            update.contents != nil
        if annotation.hasAppearanceStream, regeneratesFreeTextContents {
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
            guard canRegenerateNoteAppearance || canRegenerateHighlightAppearance else {
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
        fontSize: CGFloat = 16,
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
        page.addAnnotation(annotation)
        return annotation
    }

    @discardableResult
    func addAppearanceSafeTextReplacement(
        text: String,
        replacing object: PDFPageObjectSnapshot,
        originalFontData: Data?,
        style: PDFTextStyle,
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let text = try validated(text)
        let padding = max(1, min(object.bounds.height * 0.08, 3))
        let visualHeight = max(object.bounds.height, 6)
        let fontSize = min(max(object.fontSize ?? visualHeight * 0.82, 6), visualHeight)
        let width = max(
            object.bounds.width + padding * 2,
            fontSize * 0.72 * CGFloat(max(text.count, 1)) + fontSize
        )
        let height = max(object.bounds.height + padding * 2, fontSize * 1.2)
        let bounds = CGRect(
            x: object.bounds.minX - padding,
            y: object.bounds.maxY + padding - height,
            width: width,
            height: height
        ).standardized
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = appearanceSafeReplacementFont(
            for: object,
            size: fontSize,
            originalFontData: originalFontData,
            style: style
        )
        annotation.fontColor = platformColor(PDFAnnotationColor(
            red: CGFloat(object.fillColor.red) / 255,
            green: CGFloat(object.fillColor.green) / 255,
            blue: CGFloat(object.fillColor.blue) / 255,
            alpha: CGFloat(object.fillColor.alpha) / 255
        ))
        annotation.color = .white
        annotation.alignment = .left
        page.addAnnotation(annotation)
        return annotation
    }

    private func appearanceSafeReplacementFont(
        for object: PDFPageObjectSnapshot,
        size: CGFloat,
        originalFontData: Data?,
        style: PDFTextStyle
    ) -> PlatformFont {
        let baseFont: PlatformFont
        if let originalFontData,
           let provider = CGDataProvider(data: originalFontData as CFData),
           let graphicsFont = CGFont(provider) {
            let coreTextFont = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil)
#if os(macOS)
            baseFont = coreTextFont as NSFont
#else
            baseFont = coreTextFont as UIFont
#endif
        } else {
            baseFont = .systemFont(ofSize: size, weight: .regular)
        }
#if os(macOS)
        var traits = baseFont.fontDescriptor.symbolicTraits
        if style.contains(.bold) {
            traits.insert(.bold)
        } else {
            traits.remove(.bold)
        }
        if style.contains(.italic) {
            traits.insert(.italic)
        } else {
            traits.remove(.italic)
        }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        if let styledFont = NSFont(descriptor: descriptor, size: size) {
            return styledFont
        }
        var fallbackFont = style.contains(.bold)
            ? NSFont.boldSystemFont(ofSize: size)
            : NSFont.systemFont(ofSize: size)
        if style.contains(.italic) {
            fallbackFont = NSFontManager.shared.convert(
                fallbackFont,
                toHaveTrait: .italicFontMask
            )
        }
        return fallbackFont
#else
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
                ofSize: size,
                weight: style.contains(.bold) ? .bold : .regular
            )
            guard let fallbackDescriptor = systemFont.fontDescriptor
                .withSymbolicTraits(fallbackTraits) else { return systemFont }
            return UIFont(descriptor: fallbackDescriptor, size: size)
        }
        return UIFont(descriptor: descriptor, size: size)
#endif
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
        to page: PDFPage
    ) throws -> PDFAnnotation {
        let drawableStrokes = strokes.filter { $0.points.count > 1 }
        guard !drawableStrokes.isEmpty else {
            throw PDFAnnotationServiceError.emptySignature
        }

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .ink,
            withProperties: nil
        )
        setPrimaryColor(components(of: labelColor), on: annotation)
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 2

        for stroke in drawableStrokes {
            annotation.add(makePath(from: stroke.points, in: bounds))
        }

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

    private func makePath(
        from normalizedPoints: [CGPoint],
        in bounds: CGRect
    ) -> PlatformBezierPath {
        let points = normalizedPoints.map { point in
            CGPoint(
                x: bounds.minX + min(max(point.x, 0), 1) * bounds.width,
                y: bounds.minY + (1 - min(max(point.y, 0), 1)) * bounds.height
            )
        }
        let path = PlatformBezierPath()

        guard let first = points.first else {
            return path
        }

        path.move(to: first)
        for point in points.dropFirst() {
            #if os(macOS)
            path.line(to: point)
            #else
            path.addLine(to: point)
            #endif
        }
        path.lineWidth = 2
        return path
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
                tx: newBounds.minX - oldBounds.minX * scaleX,
                ty: newBounds.minY - oldBounds.minY * scaleY
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

    private func platformColor(_ color: PDFAnnotationColor) -> PlatformColor {
        PlatformColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    private var opacityKey: PDFAnnotationKey { PDFAnnotationKey(rawValue: "/CA") }
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
