import CoreGraphics
import Foundation

nonisolated struct PDFPageResourceSignature: Equatable, Sendable {
    let colorSpaceCount: Int
    let patternCount: Int
    let shadingCount: Int

    var requiresAppearanceSafeTextReplacement: Bool {
        colorSpaceCount > 0 || patternCount > 0 || shadingCount > 0
    }
}

nonisolated enum PDFPageResourceIntegrityService {
    static func requiresAppearanceSafeTextReplacement(
        data: Data,
        pageIndex: Int
    ) -> Bool {
        // A named ColorSpace, Pattern, or Shading resource can be rewritten or
        // discarded by FPDFPage_GenerateContent even when PDFium's own raster
        // comparison sees little chroma. Fail closed before mutating the page.
        guard let signature = signature(in: data, pageIndex: pageIndex) else {
            return true
        }
        return signature.requiresAppearanceSafeTextReplacement
    }

    static func signature(in data: Data, pageIndex: Int) -> PDFPageResourceSignature? {
        guard pageIndex >= 0,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              pageIndex < document.numberOfPages,
              let page = document.page(at: pageIndex + 1),
              let pageDictionary = page.dictionary else {
            return nil
        }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
              let resources else {
            return PDFPageResourceSignature(
                colorSpaceCount: 0,
                patternCount: 0,
                shadingCount: 0
            )
        }

        return PDFPageResourceSignature(
            colorSpaceCount: dictionaryCount(named: "ColorSpace", in: resources),
            patternCount: dictionaryCount(named: "Pattern", in: resources),
            shadingCount: dictionaryCount(named: "Shading", in: resources)
        )
    }

    static func preservesPageResources(
        from beforeData: Data,
        to afterData: Data,
        pageIndex: Int
    ) -> Bool {
        guard let before = signature(in: beforeData, pageIndex: pageIndex),
              let after = signature(in: afterData, pageIndex: pageIndex) else {
            return false
        }
        // PDFKit may add a page color space while generating an annotation
        // appearance. Additive resources are safe; losing any existing
        // ColorSpace, Pattern, or Shading entry is not.
        return after.colorSpaceCount >= before.colorSpaceCount &&
            after.patternCount >= before.patternCount &&
            after.shadingCount >= before.shadingCount
    }

    private static func dictionaryCount(
        named name: String,
        in resources: CGPDFDictionaryRef
    ) -> Int {
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, name, &dictionary),
              let dictionary else {
            return 0
        }
        return CGPDFDictionaryGetCount(dictionary)
    }
}
