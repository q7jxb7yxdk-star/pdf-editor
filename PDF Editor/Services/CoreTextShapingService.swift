import CoreGraphics
import CoreText
import Foundation

nonisolated struct CoreTextFontAnalysis: Equatable, Sendable {
    let coversAllCharacters: Bool
    let requiresAdvancedShaping: Bool
}

nonisolated enum CoreTextShapingError: LocalizedError, Sendable {
    case fontCreationFailed
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .fontCreationFailed:
            "The PDF font data could not be loaded for glyph validation."
        case .pdfCreationFailed:
            "CoreText could not create the shaped PDF overlay."
        }
    }
}

nonisolated final class CoreTextShapingService {
    func analyze(text: String, fontData: Data?) -> CoreTextFontAnalysis {
        CoreTextFontAnalysis(
            coversAllCharacters: fontData.flatMap {
                makeFont(data: $0, size: 12)
            }.map { fontCovers(text: text, font: $0) } ?? false,
            requiresAdvancedShaping: requiresAdvancedShaping(text)
        )
    }

    func makeOverlayPDF(
        text: String,
        pageBounds: CGRect,
        textTransform: CGAffineTransform,
        fontSize: CGFloat,
        color: PDFObjectColor,
        style: PDFTextStyle,
        preferredFontData: Data?,
        fallbackFontData: Data
    ) throws -> Data {
        let font = preferredFontData.flatMap { makeFont(data: $0, size: fontSize) }
            ?? makeFont(data: fallbackFontData, size: fontSize)
        guard let font else {
            throw CoreTextShapingError.fontCreationFailed
        }

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(
                    red: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: CGFloat(color.alpha) / 255
                ),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        let data = NSMutableData()
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: max(pageBounds.width, 1),
            height: max(pageBounds.height, 1)
        )
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CoreTextShapingError.pdfCreationFailed
        }

        context.beginPDFPage(nil)
        context.saveGState()
        context.concatenate(textTransform)
        let textColor = CGColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
        context.setFillColor(textColor)
        context.setStrokeColor(textColor)
        context.setLineWidth(max(fontSize * 0.035, 0.25))
        context.setTextDrawingMode(style.contains(.bold) ? .fillStroke : .fill)
        context.textMatrix = style.contains(.italic)
            ? CGAffineTransform(a: 1, b: 0, c: 0.22, d: 1, tx: 0, ty: 0)
            : .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        guard !data.isEmpty else {
            throw CoreTextShapingError.pdfCreationFailed
        }
        return data as Data
    }

    private func makeFont(data: Data, size: CGFloat) -> CTFont? {
        guard let provider = CGDataProvider(data: data as CFData),
              let graphicsFont = CGFont(provider) else {
            return nil
        }
        return CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil)
    }

    private func fontCovers(text: String, font: CTFont) -> Bool {
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard !utf16.isEmpty else { continue }
            var glyphs = Array(repeating: CGGlyph(), count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count),
                  glyphs.allSatisfy({ $0 != 0 }) else {
                return false
            }
        }
        return true
    }

    private func requiresAdvancedShaping(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                break
            }

            let value = scalar.value
            return (0x0590...0x08FF).contains(value) ||
                (0x0900...0x0DFF).contains(value) ||
                (0x0E00...0x0EFF).contains(value) ||
                (0x1780...0x17FF).contains(value) ||
                (0x1CD0...0x1CFF).contains(value) ||
                (0x1EE00...0x1EEFF).contains(value)
        }
    }
}
