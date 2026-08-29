#if OBM_COLOR_SAFETY_STANDALONE_VALIDATION
import CoreGraphics
import Foundation
import PDFKit

@main
struct OBMColorSafetyValidation {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["PE_OBM_FIXTURE"],
              let fallbackFontPath = environment["PE_FALLBACK_FONT"] else {
            fatalError("Set PE_OBM_FIXTURE and PE_FALLBACK_FONT.")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let targetText = environment["PE_OBM_TARGET"]
        let originalData = try Data(contentsOf: fixtureURL)
        let fallbackFontData = try Data(
            contentsOf: URL(fileURLWithPath: fallbackFontPath)
        )

        let originalSignature = try requireSignature(originalData, pageIndex: 0)
        precondition(
            originalSignature.colorSpaceCount +
                originalSignature.patternCount +
                originalSignature.shadingCount > 0
        )
        precondition(!originalSignature.preventsSafePageContentRegeneration)

        let session = try PDFiumEditingEngine().makeSession(
            data: originalData,
            password: nil
        )
        guard let objectSession = session as? any PDFObjectEditingSession else {
            throw PDFObjectEditingError.objectInspectionFailed
        }
        let objects = try objectSession.objects(onPage: 0)
        guard let title = objects.first(where: { object in
            object.kind == .text &&
                (targetText.map { target in
                    object.text?.contains(target) == true
                } ?? ((object.text?.contains("時刻表") == true) ||
                    (object.text?.contains("时刻表") == true) ||
                    (object.text?.contains("OBM") == true)))
        }) else {
            fatalError("The OBM title text object was not found.")
        }
        let replacementText = environment["PE_OBM_REPLACEMENT"] ??
            (title.text ?? "時刻表") + "XYZ"

        let started = ContinuousClock.now
        let preparation = try PDFManualSavePreparationService.prepare(
            originalData: originalData,
            password: nil,
            replacements: [PDFManualTextReplacement(
                object: title,
                text: replacementText,
                style: PDFTextStyle.inferred(fromFontName: title.fontName)
            )],
            fallbackFontData: fallbackFontData,
            exportOptions: PDFExportOptions()
        )
        let elapsed = started.duration(to: .now)

        precondition(preparation.replacementResults.count == 1)
        let outputSignature = try requireSignature(preparation.data, pageIndex: 0)
        precondition(PDFPageResourceIntegrityService.preservesPageResources(
            from: originalData,
            to: preparation.data,
            pageIndex: 0
        ))

        let beforeChroma = try chromaticPixelCount(in: originalData, pageIndex: 0)
        let afterChroma = try chromaticPixelCount(in: preparation.data, pageIndex: 0)
        precondition(beforeChroma > 100)
        precondition(afterChroma * 100 >= beforeChroma * 95)

        guard let reopened = PDFDocument(data: preparation.data),
              let reopenedPage = reopened.page(at: 0) else {
            throw PDFEditingError.invalidDocument
        }
        precondition(reopenedPage.string?.contains(replacementText) == true)
        precondition(!reopenedPage.annotations.contains(where: {
            $0.type == "FreeText"
        }))

        let outputURL = URL(fileURLWithPath: "/tmp/PDFEditor-OBM-Pattern-Preserved.pdf")
        try preparation.data.write(to: outputURL, options: .atomic)
        print(
            "OBM Pattern page-content replacement passed " +
                "(resources \(originalSignature)->\(outputSignature), " +
                "chroma \(beforeChroma)->\(afterChroma), elapsed \(elapsed))."
        )
    }

    private static func requireSignature(
        _ data: Data,
        pageIndex: Int
    ) throws -> PDFPageResourceSignature {
        guard let signature = PDFPageResourceIntegrityService.signature(
            in: data,
            pageIndex: pageIndex
        ) else {
            throw PDFEditingError.invalidDocument
        }
        return signature
    }

    private static func chromaticPixelCount(
        in data: Data,
        pageIndex: Int
    ) throws -> Int {
        guard let document = PDFDocument(data: data),
              let page = document.page(at: pageIndex) else {
            throw PDFEditingError.invalidDocument
        }
        let bounds = page.bounds(for: .mediaBox)
        let maximumDimension = 512
        let scale = CGFloat(maximumDimension) / max(bounds.width, bounds.height)
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw PDFEditingError.exportFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)

        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if max(red, green, blue) - min(red, green, blue) >= 12 {
                count += 1
            }
        }
        return count
    }
}
#endif
