import CPDFiumBridge
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest

final class PDFiumBridgeTests: XCTestCase {
    override class func setUp() {
        PEPDFLibraryInitialize()
    }

    override class func tearDown() {
        PEPDFLibraryDestroy()
    }

    func testAnnotationColorAndOpacityRoundTrip() throws {
        let document = try open(makePageAssemblyPDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertTrue(PEPDFAnnotationSetColor(document, 0, 0, 25, 100, 220, 115))
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        XCTAssertTrue(PEPDFAnnotationGetColor(
            document, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 25)
        XCTAssertEqual(green, 100)
        XCTAssertEqual(blue, 220)
        XCTAssertEqual(alpha, 115)

        let saved = try copyData(document)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        let color = try XCTUnwrap(annotation.color.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 25.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 100.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 220.0 / 255.0, accuracy: 0.01)
        let reopenedHandle = try open(saved)
        defer { PEPDFDocumentClose(reopenedHandle) }
        XCTAssertTrue(PEPDFAnnotationGetColor(
            reopenedHandle, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 25)
        XCTAssertEqual(green, 100)
        XCTAssertEqual(blue, 220)
        XCTAssertEqual(alpha, 115)
    }

    func testTextAnnotationColorReplacesAppearanceAndRoundTripsOpacity() throws {
        let document = try open(makeTextCommentWithAppearancePDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertTrue(PEPDFAnnotationSetColor(document, 0, 0, 25, 100, 220, 90))
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        XCTAssertTrue(PEPDFAnnotationGetColor(
            document, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 25)
        XCTAssertEqual(green, 100)
        XCTAssertEqual(blue, 220)
        XCTAssertEqual(alpha, 90)

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertTrue(PEPDFAnnotationGetColor(
            reopened, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 25)
        XCTAssertEqual(green, 100)
        XCTAssertEqual(blue, 220)
        XCTAssertEqual(alpha, 90)
    }

    func testHighlightColorReplacesAppearanceAndPreservesGeometry() throws {
        let document = try open(makeHighlightWithAppearancePDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertTrue(PEPDFAnnotationSetColor(document, 0, 0, 41, 173, 82, 115))
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        XCTAssertTrue(PEPDFAnnotationGetColor(
            document, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 41)
        XCTAssertEqual(green, 173)
        XCTAssertEqual(blue, 82)
        XCTAssertEqual(alpha, 115)

        let saved = try copyData(document)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(annotation.type, "Highlight")
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 8)
        XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP")))

        let reopenedHandle = try open(saved)
        defer { PEPDFDocumentClose(reopenedHandle) }
        XCTAssertTrue(PEPDFAnnotationGetColor(
            reopenedHandle, 0, 0, &red, &green, &blue, &alpha
        ))
        XCTAssertEqual(red, 41)
        XCTAssertEqual(green, 173)
        XCTAssertEqual(blue, 82)
        XCTAssertEqual(alpha, 115)
    }

    func testInkAppearanceColorIsReadFromSerializedAnnotation() throws {
        let data = makeInkWithAppearancePDF()
        let document = try open(data)
        defer { PEPDFDocumentClose(document) }

        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        XCTAssertFalse(PEPDFAnnotationGetColor(
            document, 0, 0, &red, &green, &blue, &alpha
        ))

        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        let color = try XCTUnwrap(annotation.color.usingColorSpace(.deviceRGB))
        XCTAssertEqual(annotation.type, "Ink")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/AP << /N 6 0 R >>"))
        XCTAssertEqual(color.redComponent, 0.9, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.15, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.15, accuracy: 0.01)
    }

    func testDenseMultiStrokeInkStyleSurvivesPDFiumSaveAsCopy() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)

        let bounds = CGRect(x: 90.125, y: 140.375, width: 164.75, height: 58.5)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = .labelColor
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 2
        for strokeIndex in 0..<3 {
            let path = NSBezierPath()
            for pointIndex in 0..<320 {
                let progress = CGFloat(pointIndex) / 319
                let point = CGPoint(
                    x: 3 + progress * (bounds.width - 6),
                    y: 8 + CGFloat(strokeIndex) * 16 + sin(progress * .pi * 8) * 6
                )
                if pointIndex == 0 {
                    path.move(to: point)
                } else {
                    path.line(to: point)
                }
            }
            path.lineWidth = 2
            annotation.add(path)
        }
        page.addAnnotation(annotation)

        let initiallySerialized = try XCTUnwrap(document.dataRepresentation())
        let styledDocument = try XCTUnwrap(PDFDocument(data: initiallySerialized))
        let styledAnnotation = try XCTUnwrap(styledDocument.page(at: 0)?.annotations.first)
        styledAnnotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
        styledAnnotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AS"))
        styledAnnotation.color = .systemBlue
        styledAnnotation.border?.lineWidth = 6
        let styledData = try XCTUnwrap(styledDocument.dataRepresentation())
        let expectedDocument = try XCTUnwrap(PDFDocument(data: styledData))
        let expected = try XCTUnwrap(expectedDocument.page(at: 0)?.annotations.first)

        let pdfiumDocument = try open(styledData)
        defer { PEPDFDocumentClose(pdfiumDocument) }
        let saved = try copyData(pdfiumDocument)
        let reopenedDocument = try XCTUnwrap(PDFDocument(data: saved))
        let actual = try XCTUnwrap(reopenedDocument.page(at: 0)?.annotations.first)

        XCTAssertEqual(actual.bounds.minX, expected.bounds.minX, accuracy: 0.05)
        XCTAssertEqual(actual.bounds.minY, expected.bounds.minY, accuracy: 0.05)
        XCTAssertEqual(actual.bounds.width, expected.bounds.width, accuracy: 0.05)
        XCTAssertEqual(actual.bounds.height, expected.bounds.height, accuracy: 0.05)
        XCTAssertEqual(actual.border?.lineWidth, expected.border?.lineWidth)
        XCTAssertEqual(
            actual.paths?.reduce(0) { $0 + $1.elementCount },
            expected.paths?.reduce(0) { $0 + $1.elementCount }
        )
        let expectedColor = try XCTUnwrap(expected.color.usingColorSpace(.deviceRGB))
        let actualColor = try XCTUnwrap(actual.color.usingColorSpace(.deviceRGB))
        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.01)
    }

    func testExistingTextObjectCanBeRewrittenAndPreservesStyleGeometry() throws {
        let document = try open(makeTextPDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertEqual(PEPDFDocumentPageCount(document), 1)
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 1)

        let before = try objectInfo(document, index: 0)
        XCTAssertEqual(before.type, Int32(PEPDFObjectTypeText.rawValue))
        XCTAssertEqual(try objectText(document, index: 0), "Original Text")

        let replacement = Array("Changed Text".utf16)
        XCTAssertTrue(replacement.withUnsafeBufferPointer {
            PEPDFPageObjectReplaceText(document, 0, 0, $0.baseAddress, $0.count)
        })

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        let after = try objectInfo(reopened, index: 0)

        XCTAssertEqual(try objectText(reopened, index: 0), "Changed Text")
        XCTAssertEqual(after.fontSize, before.fontSize, accuracy: 0.01)
        XCTAssertEqual(after.fillRed, before.fillRed)
        XCTAssertEqual(after.fillGreen, before.fillGreen)
        XCTAssertEqual(after.fillBlue, before.fillBlue)
        XCTAssertEqual(after.matrixA, before.matrixA, accuracy: 0.001)
        XCTAssertEqual(after.matrixD, before.matrixD, accuracy: 0.001)
        XCTAssertEqual(after.matrixE, before.matrixE, accuracy: 0.001)
        XCTAssertEqual(after.matrixF, before.matrixF, accuracy: 0.001)
    }

    func testTextReplacementPreservesEveryUnrelatedTextObject() throws {
        let document = try open(makeTwoTextObjectPDF())
        defer { PEPDFDocumentClose(document) }
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 2)
        XCTAssertEqual(try objectText(document, index: 1), "Untouched Text")

        let replacement = Array("Changed Text".utf16)
        let targetPath: [Int32] = [0]
        XCTAssertTrue(targetPath.withUnsafeBufferPointer { pathBuffer in
            replacement.withUnsafeBufferPointer { textBuffer in
                PEPDFPageObjectReplaceTextAtPath(
                    document,
                    0,
                    pathBuffer.baseAddress,
                    pathBuffer.count,
                    textBuffer.baseAddress,
                    textBuffer.count
                )
            }
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(try objectText(reopened, index: 0), "Changed Text")
        XCTAssertEqual(try objectText(reopened, index: 1), "Untouched Text")
    }

    func testICCPageTextRegenerationPreservesVisibleColor() throws {
        let source = try makeICCColoredTextPDF()
        let beforePixels = try nonWhitePixelCount(source)
        let document = try open(source)
        defer { PEPDFDocumentClose(document) }
        let count = Int(PEPDFPageObjectCountRecursive(document, 0))
        let target = try XCTUnwrap((0..<count).lazy.compactMap { flatIndex -> [Int32]? in
            guard let path = try? self.objectPath(document, flatIndex: Int32(flatIndex)),
                  let info = try? self.objectInfo(document, path: path),
                  info.type == Int32(PEPDFObjectTypeText.rawValue),
                  (try? self.objectText(document, path: path).isEmpty) == false else {
                return nil
            }
            return path
        }.first)
        let replacement = Array("TEST".utf16)
        XCTAssertTrue(target.withUnsafeBufferPointer { path in
            replacement.withUnsafeBufferPointer { text in
                PEPDFPageObjectReplaceTextAtPath(
                    document, 0, path.baseAddress, path.count,
                    text.baseAddress, text.count
                )
            }
        })
        XCTAssertFalse(PEPDFDocumentLastMutationRejectedForAppearance(document))

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(try objectText(reopened, path: target), "TEST")
        let afterPixels = try nonWhitePixelCount(saved)
        XCTAssertGreaterThanOrEqual(afterPixels * 100, beforePixels * 95)
    }

    func testShadingPageTextRegenerationPreservesVisibleGradient() throws {
        let source = makeShadedTextPDF()
        let beforePixels = try nonWhitePixelCount(source)
        let document = try open(source)
        defer { PEPDFDocumentClose(document) }
        let count = Int(PEPDFPageObjectCountRecursive(document, 0))
        let target = try XCTUnwrap((0..<count).lazy.compactMap { flatIndex -> [Int32]? in
            guard let path = try? self.objectPath(document, flatIndex: Int32(flatIndex)),
                  let info = try? self.objectInfo(document, path: path),
                  info.type == Int32(PEPDFObjectTypeText.rawValue),
                  (try? self.objectText(document, path: path).isEmpty) == false else {
                return nil
            }
            return path
        }.first)
        let replacement = Array("TEST".utf16)
        XCTAssertTrue(target.withUnsafeBufferPointer { path in
            replacement.withUnsafeBufferPointer { text in
                PEPDFPageObjectReplaceTextAtPath(
                    document, 0, path.baseAddress, path.count,
                    text.baseAddress, text.count
                )
            }
        })
        XCTAssertFalse(PEPDFDocumentLastMutationRejectedForAppearance(document))

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(try objectText(reopened, path: target), "TEST")
        let afterPixels = try nonWhitePixelCount(saved)
        XCTAssertGreaterThanOrEqual(afterPixels * 100, beforePixels * 95)
    }

    func testColoredTilingPatternTextRegenerationPreservesPaint() throws {
        try assertPatternTextReplacementPreservesPaint(
            makeColoredTilingPatternTextPDF()
        )
    }

    func testUncoloredTilingPatternTextRegenerationPreservesPaint() throws {
        try assertPatternTextReplacementPreservesPaint(
            makeUncoloredTilingPatternTextPDF()
        )
    }

    func testShadingPatternTextRegenerationPreservesPaint() throws {
        try assertPatternTextReplacementPreservesPaint(
            makeShadingPatternTextPDF()
        )
    }

    func testMoveAddDeleteAndUnicodeSearchLayerRoundTrip() throws {
        let document = try open(makeTextPDF())
        defer { PEPDFDocumentClose(document) }

        let original = try objectInfo(document, index: 0)
        XCTAssertTrue(PEPDFPageObjectTranslate(document, 0, 0, 12, -8))
        let moved = try objectInfo(document, index: 0)
        XCTAssertEqual(moved.left, original.left + 12, accuracy: 0.1)
        XCTAssertEqual(moved.bottom, original.bottom - 8, accuracy: 0.1)

        let added = Array("Added".utf16)
        XCTAssertTrue(added.withUnsafeBufferPointer {
            PEPDFPageAddStandardText(
                document, 0, $0.baseAddress, $0.count,
                "Helvetica", 16, 100, 600, 20, 40, 60, 255
            )
        })
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 2)

        let fontData = try Data(contentsOf: notoFontURL())
        let font = fontData.withUnsafeBytes {
            PEPDFFontCreateEmbedded(
                document,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        }
        let unwrappedFont = try XCTUnwrap(font)
        defer { PEPDFFontClose(unwrappedFont) }
        let unicode = Array("掃描文字層".utf16)
        XCTAssertTrue(unicode.withUnsafeBufferPointer {
            PEPDFPageAddEmbeddedText(
                document, unwrappedFont, 0,
                $0.baseAddress, $0.count,
                14, 72, 500, true
            )
        })
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 3)
        XCTAssertEqual(try objectText(document, index: 2), "掃描文字層")

        XCTAssertTrue(PEPDFPageObjectDelete(document, 0, 1))
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 2)

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(PEPDFPageObjectCount(reopened, 0), 2)
        XCTAssertEqual(try objectText(reopened, index: 1), "掃描文字層")
    }

    func testInvisibleOCRTextLayerRemainsSearchableWithoutChangingRendering() throws {
        let source = makeTextPDF(text: "")
        let sourcePixelCount = try nonWhitePixelCount(source)
        let document = try open(source)
        defer { PEPDFDocumentClose(document) }
        let originalObjectCount = PEPDFPageObjectCount(document, 0)

        let fontData = try Data(contentsOf: notoFontURL())
        let font = fontData.withUnsafeBytes {
            PEPDFFontCreateEmbedded(
                document,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        }
        let unwrappedFont = try XCTUnwrap(font)
        defer { PEPDFFontClose(unwrappedFont) }
        let recognizedText = "掃描文字層"
        let utf16 = Array(recognizedText.utf16)
        XCTAssertTrue(utf16.withUnsafeBufferPointer {
            PEPDFPageAddEmbeddedText(
                document,
                unwrappedFont,
                0,
                $0.baseAddress,
                $0.count,
                18,
                72,
                500,
                true
            )
        })
        XCTAssertEqual(PEPDFPageObjectCount(document, 0), originalObjectCount + 1)

        let addedObject = try objectInfo(document, index: originalObjectCount)
        XCTAssertEqual(addedObject.matrixE, 72, accuracy: 0.01)
        XCTAssertEqual(addedObject.matrixF, 500, accuracy: 0.01)
        XCTAssertGreaterThan(addedObject.right, addedObject.left)
        XCTAssertGreaterThan(addedObject.top, addedObject.bottom)

        let saved = try copyData(document)
        XCTAssertEqual(try nonWhitePixelCount(saved), sourcePixelCount)

        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(PEPDFDocumentPageCount(reopened), 1)
        XCTAssertTrue(try recursiveTexts(reopened).contains { $0 == recognizedText })

        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(pdfKitDocument.pageCount, 1)
        let matches = pdfKitDocument.findString(recognizedText, withOptions: [])
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.string, recognizedText)
    }

    func testBitmapAddReplaceTransformAndZOrderRoundTrip() throws {
        let document = try open(makeTextPDF())
        defer { PEPDFDocumentClose(document) }
        let firstPixels: [UInt8] = [
            0, 0, 255, 128,
            0, 255, 0, 255,
        ]

        XCTAssertTrue(firstPixels.withUnsafeBufferPointer {
            PEPDFPageAddBitmapBGRA(
                document, 0, $0.baseAddress, $0.count,
                2, 1, 8, 100, 120, 200, 100
            )
        })

        let imagePath: [Int32] = [1]
        var reopened = try open(copyData(document))
        var info = try objectInfo(reopened, path: imagePath)
        XCTAssertEqual(info.type, Int32(PEPDFObjectTypeImage.rawValue))
        XCTAssertEqual(info.imagePixelWidth, 2)
        XCTAssertEqual(info.imagePixelHeight, 1)
        let firstBitmap = try objectBitmap(reopened, path: imagePath)
        XCTAssertTrue(firstBitmap.format == 4 || firstBitmap.format == 5)
        XCTAssertTrue(firstBitmap.bytes.contains(128))
        PEPDFDocumentClose(reopened)

        let requested: (a: Float, b: Float, c: Float, d: Float, e: Float, f: Float) =
            (0, 150, -75, 0, 320, 240)
        XCTAssertTrue(imagePath.withUnsafeBufferPointer {
            PEPDFPageObjectSetTransformAtPath(
                document, 0, $0.baseAddress, $0.count,
                requested.a, requested.b, requested.c,
                requested.d, requested.e, requested.f
            )
        })
        let replacementPixels: [UInt8] = [
            255, 0, 0, 64,
            255, 255, 255, 255,
        ]
        XCTAssertTrue(imagePath.withUnsafeBufferPointer { path in
            replacementPixels.withUnsafeBufferPointer { pixels in
                PEPDFPageObjectReplaceBitmapBGRAAtPath(
                    document, 0, path.baseAddress, path.count,
                    pixels.baseAddress, pixels.count, 1, 2, 4
                )
            }
        })
        XCTAssertTrue(imagePath.withUnsafeBufferPointer {
            PEPDFPageObjectMoveToIndexAtPath(
                document, 0, $0.baseAddress, $0.count, 0
            )
        })
        reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        info = try objectInfo(reopened, path: [0])
        XCTAssertEqual(info.type, Int32(PEPDFObjectTypeImage.rawValue))
        XCTAssertEqual(info.imagePixelWidth, 1)
        XCTAssertEqual(info.imagePixelHeight, 2)
        XCTAssertEqual(info.matrixA, requested.a, accuracy: 0.001)
        XCTAssertEqual(info.matrixB, requested.b, accuracy: 0.001)
        XCTAssertEqual(info.matrixC, requested.c, accuracy: 0.001)
        XCTAssertEqual(info.matrixD, requested.d, accuracy: 0.001)
        XCTAssertEqual(info.matrixE, requested.e, accuracy: 0.001)
        XCTAssertEqual(info.matrixF, requested.f, accuracy: 0.001)
        let persistedBitmap = try objectBitmap(reopened, path: [0])
        XCTAssertTrue(persistedBitmap.bytes.contains(64))
        XCTAssertEqual(try objectText(reopened, index: 1), "Original Text")
    }

    func testSharedImageXObjectReplacementIsIsolated() throws {
        let document = try open(makeSharedImagePDF())
        defer { PEPDFDocumentClose(document) }
        let firstPath: [Int32] = [0]
        let bluePixel: [UInt8] = [255, 0, 0, 255]

        XCTAssertTrue(firstPath.withUnsafeBufferPointer { path in
            bluePixel.withUnsafeBufferPointer { pixel in
                PEPDFPageObjectReplaceBitmapBGRAAtPath(
                    document, 0, path.baseAddress, path.count,
                    pixel.baseAddress, pixel.count, 1, 1, 4
                )
            }
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        let first = try objectBitmap(reopened, path: [0]).bytes
        let second = try objectBitmap(reopened, path: [1]).bytes
        XCTAssertEqual(Array(first.prefix(3)), [255, 0, 0])
        XCTAssertEqual(
            Array(second.prefix(3)), [0, 0, 255],
            "The unselected use of the shared image must remain red."
        )
    }

    func testSharedImageInsideFormReplacementIsIsolated() throws {
        let document = try open(makeSharedFormImagePDF())
        defer { PEPDFDocumentClose(document) }
        let firstImagePath: [Int32] = [0, 0]
        let bluePixel: [UInt8] = [255, 0, 0, 255]

        XCTAssertTrue(firstImagePath.withUnsafeBufferPointer { path in
            bluePixel.withUnsafeBufferPointer { pixel in
                PEPDFPageObjectReplaceBitmapBGRAAtPath(
                    document, 0, path.baseAddress, path.count,
                    pixel.baseAddress, pixel.count, 1, 1, 4
                )
            }
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(
            Array(try objectBitmap(reopened, path: [0, 0]).bytes.prefix(3)),
            [255, 0, 0]
        )
        XCTAssertEqual(
            Array(try objectBitmap(reopened, path: [1, 0]).bytes.prefix(3)),
            [0, 0, 255],
            "Cloning the selected Form must leave the other Form use red."
        )
    }

    func testZOrderFullRegenerationPreservesClipAndContentMark() throws {
        let document = try open(makeClippedMarkedImagePDF())
        defer { PEPDFDocumentClose(document) }
        let imagePath: [Int32] = [0]

        XCTAssertTrue(imagePath.withUnsafeBufferPointer {
            PEPDFPageObjectMoveToIndexAtPath(
                document, 0, $0.baseAddress, $0.count, 1
            )
        })

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(try objectInfo(reopened, path: [1]).type,
                       Int32(PEPDFObjectTypeImage.rawValue))
        let serialized = String(decoding: try decodedFirstPageContents(saved), as: UTF8.self)
        XCTAssertTrue(serialized.contains("/Artifact BMC"))
        XCTAssertTrue(serialized.contains(" W "))
        XCTAssertTrue(serialized.contains("EMC"))
    }

    func testPageDeleteAndRotationRoundTrip() throws {
        let document = try open(makePageAssemblyPDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertEqual(PEPDFDocumentPageCount(document), 3)
        XCTAssertTrue(PEPDFDocumentDeletePage(document, 1))
        XCTAssertEqual(PEPDFDocumentPageCount(document), 2)
        XCTAssertTrue(PEPDFDocumentSetPageRotation(document, 0, 2))

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(PEPDFDocumentPageCount(reopened), 2)
        XCTAssertEqual(try pageInfo(reopened, pageIndex: 0).rotation, 2)
    }

    func testPageReorderPersistsRequestedOrder() throws {
        let document = try open(makePageAssemblyPDF())
        defer { PEPDFDocumentClose(document) }
        let order: [Int32] = [2, 0, 1]

        XCTAssertTrue(order.withUnsafeBufferPointer {
            PEPDFDocumentMovePages(document, $0.baseAddress, $0.count, 0)
        })

        let saved = try copyData(document)
        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(pdfKitDocument.pageCount, 3)
        XCTAssertTrue(pdfKitDocument.page(at: 0)?.string?.contains("PAGE-C") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 1)?.string?.contains("PAGE-A") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 2)?.string?.contains("PAGE-B") == true)
    }

    func testSinglePageMoveUsesFinalDestinationIndex() throws {
        let document = try open(makePageAssemblyPDF())
        defer { PEPDFDocumentClose(document) }
        let source: [Int32] = [0]

        XCTAssertTrue(source.withUnsafeBufferPointer {
            PEPDFDocumentMovePages(document, $0.baseAddress, $0.count, 2)
        })

        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: copyData(document)))
        XCTAssertTrue(pdfKitDocument.page(at: 0)?.string?.contains("PAGE-B") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 1)?.string?.contains("PAGE-C") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 2)?.string?.contains("PAGE-A") == true)
    }

    func testSplitPreservesBoxesRotationAnnotationsAndSharedResources() throws {
        let document = try open(makePageAssemblyPDF())
        defer { PEPDFDocumentClose(document) }
        let indices: [Int32] = [0, 2]
        let split = try copyPages(document, indices: indices)
        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: split))

        XCTAssertEqual(pdfKitDocument.pageCount, 2)
        let first = try XCTUnwrap(pdfKitDocument.page(at: 0))
        XCTAssertEqual(first.rotation, 90)
        XCTAssertEqual(first.annotations.count, 1)
        XCTAssertNotEqual(first.bounds(for: .cropBox), first.bounds(for: .mediaBox))
        XCTAssertTrue(first.string?.contains("PAGE-A") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 1)?.string?.contains("PAGE-C") == true)
        XCTAssertTrue(pdfKitDocument.page(at: 1)?.string?.contains("SHARED") == true)
    }

    func testMergeAcceptsCorrectPasswordAndRejectsWrongPassword() throws {
        let destination = try open(makeTextPDF())
        defer { PEPDFDocumentClose(destination) }
        let encryptedSource = try makeEncryptedPDF(
            makePageAssemblyPDF(),
            password: "correct-password"
        )

        var errorCode: UInt32 = 0
        XCTAssertFalse(encryptedSource.withUnsafeBytes { bytes in
            "wrong-password".withCString { password in
                PEPDFDocumentImportPages(
                    destination,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    password,
                    1,
                    &errorCode
                )
            }
        })
        XCTAssertEqual(errorCode, 4)
        XCTAssertEqual(PEPDFDocumentPageCount(destination), 1)

        XCTAssertTrue(encryptedSource.withUnsafeBytes { bytes in
            "correct-password".withCString { password in
                PEPDFDocumentImportPages(
                    destination,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    password,
                    1,
                    &errorCode
                )
            }
        })
        let saved = try copyData(destination)
        let merged = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(merged.pageCount, 4)
        XCTAssertTrue(merged.page(at: 1)?.string?.contains("PAGE-A") == true)
        XCTAssertEqual(merged.page(at: 1)?.annotations.count, 1)
        XCTAssertTrue(merged.page(at: 3)?.string?.contains("SHARED") == true)
    }

    func testPageMutationPreservesExistingEncryption() throws {
        let password = "document-password"
        let encrypted = try makeEncryptedPDF(
            makePageAssemblyPDF(),
            password: password
        )
        let document = try open(encrypted, password: password)
        defer { PEPDFDocumentClose(document) }

        XCTAssertTrue(PEPDFDocumentSetPageRotation(document, 0, 1))
        let saved = try copyData(document)
        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertTrue(pdfKitDocument.isEncrypted)
        XCTAssertTrue(pdfKitDocument.isLocked)
        XCTAssertTrue(pdfKitDocument.unlock(withPassword: password))
        XCTAssertEqual(pdfKitDocument.pageCount, 3)
        XCTAssertEqual(pdfKitDocument.page(at: 0)?.rotation, 90)
    }

    func testAuthorizedExportCanRemoveEncryption() throws {
        let password = "document-password"
        let encrypted = try makeEncryptedPDF(
            makePageAssemblyPDF(),
            password: password
        )
        let document = try open(encrypted, password: password)
        defer { PEPDFDocumentClose(document) }

        let saved = try copyData(document, removeSecurity: true)
        let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertFalse(pdfKitDocument.isEncrypted)
        XCTAssertFalse(pdfKitDocument.isLocked)
        XCTAssertEqual(pdfKitDocument.pageCount, 3)
        XCTAssertTrue(pdfKitDocument.page(at: 0)?.string?.contains("PAGE-A") == true)
    }

    func testLargeDocumentPageWorkflowRoundTripsWithinSafetyBudget() throws {
        let startedAt = Date()
        let document = try open(makeLargeTextPDF(pageCount: 120))
        defer { PEPDFDocumentClose(document) }

        XCTAssertEqual(PEPDFDocumentPageCount(document), 120)
        XCTAssertTrue(PEPDFDocumentSetPageRotation(document, 60, 1))

        let lastPage: [Int32] = [119]
        XCTAssertTrue(lastPage.withUnsafeBufferPointer {
            PEPDFDocumentMovePages(document, $0.baseAddress, $0.count, 0)
        })

        let selectedPages: [Int32] = [0, 60, 119]
        let split = try copyPages(document, indices: selectedPages)
        let splitDocument = try XCTUnwrap(PDFDocument(data: split))
        XCTAssertEqual(splitDocument.pageCount, 3)
        XCTAssertTrue(splitDocument.page(at: 0)?.string?.contains("PAGE-120") == true)
        XCTAssertTrue(splitDocument.page(at: 1)?.string?.contains("PAGE-060") == true)
        XCTAssertTrue(splitDocument.page(at: 2)?.string?.contains("PAGE-119") == true)

        let saved = try copyData(document)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(reopened.pageCount, 120)
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("PAGE-120") == true)
        XCTAssertEqual(reopened.page(at: 61)?.rotation, 90)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            30,
            "A 120-page page-management round trip exceeded the safety budget."
        )
    }

    func testMalformedAndTruncatedDocumentsAreRejectedSafely() {
        let malformedDocuments = [
            Data(),
            Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog".utf8),
            Data(repeating: 0xFF, count: 4_096),
        ]

        for data in malformedDocuments {
            var errorCode: UInt32 = 0
            let document = data.withUnsafeBytes {
                PEPDFDocumentCreate(
                    $0.bindMemory(to: UInt8.self).baseAddress,
                    $0.count,
                    nil,
                    &errorCode
                )
            }
            if let document {
                PEPDFDocumentClose(document)
            }
            XCTAssertNil(
                document,
                "Malformed PDF data unexpectedly opened (PDFium error code: \(errorCode))."
            )
        }
    }

    func testRecursiveFormPathsComposeMatricesAndPersistIsolatedMutation() throws {
        let document = try open(makeNestedFormPDF())
        defer { PEPDFDocumentClose(document) }

        XCTAssertEqual(PEPDFPageObjectCount(document, 0), 2)
        XCTAssertEqual(PEPDFPageObjectCountRecursive(document, 0), 6)
        XCTAssertEqual(try objectPath(document, flatIndex: 0), [0])
        XCTAssertEqual(try objectPath(document, flatIndex: 1), [0, 0])
        XCTAssertEqual(try objectPath(document, flatIndex: 2), [0, 0, 0])
        XCTAssertEqual(try objectPath(document, flatIndex: 5), [1, 0, 0])

        let displayObjects = try displayObjects(document)
        XCTAssertEqual(displayObjects.map(\.path), [
            [0], [0, 0], [0, 0, 0],
            [1], [1, 0], [1, 0, 0]
        ])
        XCTAssertEqual(displayObjects[2].info.matrixE, 87, accuracy: 0.01)
        XCTAssertEqual(displayObjects[2].info.matrixF, 627, accuracy: 0.01)
        XCTAssertEqual(displayObjects[5].info.matrixE, 307.5, accuracy: 0.01)
        XCTAssertEqual(displayObjects[5].info.matrixF, 513.5, accuracy: 0.01)

        let firstPath: [Int32] = [0, 0, 0]
        let secondPath: [Int32] = [1, 0, 0]
        let firstInfo = try objectInfo(document, path: firstPath)
        let secondInfo = try objectInfo(document, path: secondPath)
        XCTAssertEqual(firstInfo.matrixE, 87, accuracy: 0.01)
        XCTAssertEqual(firstInfo.matrixF, 627, accuracy: 0.01)
        XCTAssertEqual(secondInfo.matrixE, 307.5, accuracy: 0.01)
        XCTAssertEqual(secondInfo.matrixF, 513.5, accuracy: 0.01)
        XCTAssertEqual(
            try objectText(document, path: firstPath).trimmingCharacters(in: .whitespaces),
            "INNER"
        )
        XCTAssertEqual(
            try objectText(document, path: secondPath).trimmingCharacters(in: .whitespaces),
            "INNER"
        )

        let changed = Array("CHANGED".utf16)
        XCTAssertTrue(firstPath.withUnsafeBufferPointer { pathBuffer in
            changed.withUnsafeBufferPointer { textBuffer in
                PEPDFPageObjectReplaceTextAtPath(
                    document,
                    0,
                    pathBuffer.baseAddress,
                    pathBuffer.count,
                    textBuffer.baseAddress,
                    textBuffer.count
                )
            }
        })

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(
            try objectText(reopened, path: firstPath).trimmingCharacters(in: .whitespaces),
            "CHANGED",
            "The selected Form instance must persist its descendant text mutation."
        )
        XCTAssertEqual(
            try objectText(reopened, path: secondPath).trimmingCharacters(in: .whitespaces),
            "INNER",
            "A shared Form use must remain untouched when persistence cannot be proven."
        )
    }

    func testNestedFormTranslationPersistsWithoutMovingSharedInstance() throws {
        let document = try open(makeNestedFormPDF())
        defer { PEPDFDocumentClose(document) }
        let firstPath: [Int32] = [0, 0, 0]
        let secondPath: [Int32] = [1, 0, 0]
        let firstBefore = try objectInfo(document, path: firstPath)
        let secondBefore = try objectInfo(document, path: secondPath)

        XCTAssertTrue(firstPath.withUnsafeBufferPointer {
            PEPDFPageObjectTranslateAtPath(
                document, 0, $0.baseAddress, $0.count, 18, -9
            )
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        let firstAfter = try objectInfo(reopened, path: firstPath)
        let secondAfter = try objectInfo(reopened, path: secondPath)
        XCTAssertEqual(firstAfter.matrixE, firstBefore.matrixE + 18, accuracy: 0.01)
        XCTAssertEqual(firstAfter.matrixF, firstBefore.matrixF - 9, accuracy: 0.01)
        XCTAssertEqual(secondAfter.matrixE, secondBefore.matrixE, accuracy: 0.01)
        XCTAssertEqual(secondAfter.matrixF, secondBefore.matrixF, accuracy: 0.01)
    }

    func testNestedFormTransformPersistsWithoutChangingSharedInstance() throws {
        let document = try open(makeNestedFormPDF())
        defer { PEPDFDocumentClose(document) }
        let firstPath: [Int32] = [0, 0, 0]
        let secondPath: [Int32] = [1, 0, 0]
        let secondBefore = try objectInfo(document, path: secondPath)
        let requested: (Float, Float, Float, Float, Float, Float) =
            (0, 1.25, -1.25, 0, 160, 420)

        XCTAssertTrue(firstPath.withUnsafeBufferPointer {
            PEPDFPageObjectSetTransformAtPath(
                document, 0, $0.baseAddress, $0.count,
                requested.0, requested.1, requested.2,
                requested.3, requested.4, requested.5
            )
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        let firstAfter = try objectInfo(reopened, path: firstPath)
        let secondAfter = try objectInfo(reopened, path: secondPath)
        XCTAssertEqual(firstAfter.matrixA, requested.0, accuracy: 0.001)
        XCTAssertEqual(firstAfter.matrixB, requested.1, accuracy: 0.001)
        XCTAssertEqual(firstAfter.matrixC, requested.2, accuracy: 0.001)
        XCTAssertEqual(firstAfter.matrixD, requested.3, accuracy: 0.001)
        XCTAssertEqual(firstAfter.matrixE, requested.4, accuracy: 0.001)
        XCTAssertEqual(firstAfter.matrixF, requested.5, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixA, secondBefore.matrixA, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixB, secondBefore.matrixB, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixC, secondBefore.matrixC, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixD, secondBefore.matrixD, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixE, secondBefore.matrixE, accuracy: 0.001)
        XCTAssertEqual(secondAfter.matrixF, secondBefore.matrixF, accuracy: 0.001)
    }

    func testNestedFormZOrderPersistsWithoutChangingSharedInstance() throws {
        let document = try open(makeNestedFormReorderPDF())
        defer { PEPDFDocumentClose(document) }
        let firstChildPath: [Int32] = [0, 0]

        XCTAssertTrue(firstChildPath.withUnsafeBufferPointer {
            PEPDFPageObjectMoveToIndexAtPath(
                document, 0, $0.baseAddress, $0.count, 1
            )
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(
            try objectText(reopened, path: [0, 0]).trimmingCharacters(in: .whitespaces),
            "SECOND"
        )
        XCTAssertEqual(
            try objectText(reopened, path: [0, 1]).trimmingCharacters(in: .whitespaces),
            "FIRST"
        )
        XCTAssertEqual(
            try objectText(reopened, path: [1, 0]).trimmingCharacters(in: .whitespaces),
            "FIRST"
        )
        XCTAssertEqual(
            try objectText(reopened, path: [1, 1]).trimmingCharacters(in: .whitespaces),
            "SECOND"
        )
    }

    func testNestedFormDeletionPersistsWithoutDeletingSharedInstance() throws {
        let document = try open(makeNestedFormPDF())
        defer { PEPDFDocumentClose(document) }
        let firstPath: [Int32] = [0, 0, 0]
        let secondPath: [Int32] = [1, 0, 0]

        XCTAssertTrue(firstPath.withUnsafeBufferPointer {
            PEPDFPageObjectDeleteAtPath(document, 0, $0.baseAddress, $0.count)
        })

        let reopened = try open(copyData(document))
        defer { PEPDFDocumentClose(reopened) }
        var missingInfo = PEPDFObjectInfo()
        XCTAssertFalse(firstPath.withUnsafeBufferPointer {
            PEPDFPageObjectInfoAtPath(
                reopened, 0, $0.baseAddress, $0.count, &missingInfo
            )
        })
        XCTAssertEqual(
            try objectText(reopened, path: secondPath).trimmingCharacters(in: .whitespaces),
            "INNER"
        )
        XCTAssertEqual(PEPDFPageObjectCountRecursive(reopened, 0), 5)
    }

    func testImportedOverlayTextPersistsAsSearchableFormObject() throws {
        let document = try open(makeTextPDF())
        defer { PEPDFDocumentClose(document) }
        let overlay = makeTextPDF(text: "Shaped Overlay")

        XCTAssertTrue(overlay.withUnsafeBytes {
            PEPDFPageImportOverlay(
                document,
                0,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        })

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        let texts = try recursiveTexts(reopened)
        XCTAssertTrue(texts.contains { $0.contains("Original Text") })
        XCTAssertTrue(texts.contains { $0.contains("Shaped Overlay") })
    }

    func testCoreTextShapingCorpusRemainsSearchableAfterPDFiumImport() throws {
        let corpus: [(text: String, searchTerms: [String])] = [
            ("繁體中文測試", ["繁體中文測試"]),
            ("مرحبا بالعالم", ["مرحبا بالعالم"]),
            ("नमस्ते दुनिया", ["नमस्ते"]),
            ("ภาษาไทย", ["ภาษาไทย"]),
            ("Latin 中文 العربية", ["Latin", "中文", "العربية"]),
        ]

        for sample in corpus {
            let document = try open(makeTextPDF())
            defer { PEPDFDocumentClose(document) }
            let overlay = try makeCoreTextOverlay(text: sample.text)

            let actualText = Array(sample.text.utf16)
            XCTAssertTrue(overlay.withUnsafeBytes { overlayBytes in
                actualText.withUnsafeBufferPointer { textBuffer in
                    PEPDFPageImportOverlayWithActualText(
                        document,
                        0,
                        overlayBytes.bindMemory(to: UInt8.self).baseAddress,
                        overlayBytes.count,
                        textBuffer.baseAddress,
                        textBuffer.count
                    )
                }
            }, "Import failed for: \(sample.text)")

            let saved = try copyData(document)
            let reopened = try open(saved)
            defer { PEPDFDocumentClose(reopened) }
            let objectTexts = try recursiveTexts(reopened).joined(separator: " ")
            let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
            let pageText = pdfKitDocument.page(at: 0)?.string ?? ""
            let allTermsSearchable = sample.searchTerms.allSatisfy {
                !pdfKitDocument.findString($0, withOptions: []).isEmpty
            }
            XCTAssertTrue(
                allTermsSearchable || objectTexts.contains(sample.text),
                "Neither PDFKit search nor ActualText round-tripped: \(sample.text); PDFium: \(objectTexts)"
            )
            for searchTerm in sample.searchTerms {
                XCTAssertFalse(
                    pdfKitDocument.findString(searchTerm, withOptions: []).isEmpty,
                    "Sample: \(sample.text); term: \(searchTerm); PDFKit: \(pageText); PDFium objects: \(objectTexts)"
                )
            }
        }
    }

    func testFallbackHidesOriginalTextBeforeImportingSearchableOverlay() throws {
        let source = makeTextPDF()
        XCTAssertGreaterThan(try nonWhitePixelCount(source), 25)

        let document = try open(source)
        defer { PEPDFDocumentClose(document) }
        let path: [Int32] = [0]
        XCTAssertTrue(path.withUnsafeBufferPointer {
            PEPDFPageObjectSetInvisibleAtPath(
                document,
                0,
                $0.baseAddress,
                $0.count
            )
        })

        let blank = Array(" ".utf16)
        XCTAssertTrue(path.withUnsafeBufferPointer { pathBuffer in
            blank.withUnsafeBufferPointer { textBuffer in
                PEPDFPageObjectReplaceTextAtPath(
                    document,
                    0,
                    pathBuffer.baseAddress,
                    pathBuffer.count,
                    textBuffer.baseAddress,
                    textBuffer.count
                )
            }
        })
        XCTAssertLessThanOrEqual(try nonWhitePixelCount(copyData(document)), 8)

        let replacement = "替代文字"
        let overlay = try makeCoreTextOverlay(text: replacement)
        let actualText = Array(replacement.utf16)
        XCTAssertTrue(overlay.withUnsafeBytes { overlayBytes in
            actualText.withUnsafeBufferPointer { textBuffer in
                PEPDFPageImportOverlayWithActualText(
                    document,
                    0,
                    overlayBytes.bindMemory(to: UInt8.self).baseAddress,
                    overlayBytes.count,
                    textBuffer.baseAddress,
                    textBuffer.count
                )
            }
        })

        let saved = try copyData(document)
        XCTAssertGreaterThan(try nonWhitePixelCount(saved), 25)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertFalse(reopened.findString(replacement, withOptions: []).isEmpty)
        XCTAssertTrue(reopened.findString("Original Text", withOptions: []).isEmpty)
    }

    func testLocalSubsetFontFixtureRejectsUnsafePageRegeneration() throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["PE_TEXT_FIXTURE"] else {
            throw XCTSkip("Set PE_TEXT_FIXTURE for the local subset-font regression fixture.")
        }
        let source = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let inspection = try open(source)
        let count = PEPDFPageObjectCountRecursive(inspection, 0)
        let expectedTexts = try recursiveTexts(inspection)
        let textPaths = try (0..<count).compactMap { flatIndex -> [Int32]? in
            let path = try objectPath(inspection, flatIndex: flatIndex)
            return try objectInfo(inspection, path: path).type ==
                Int32(PEPDFObjectTypeText.rawValue) ? path : nil
        }
        PEPDFDocumentClose(inspection)

        var rejectedPath: [Int32]?
        for path in textPaths.prefix(80) {
            let document = try open(source)
            let blank = Array(" ".utf16)
            let replaced = path.withUnsafeBufferPointer { pathBuffer in
                blank.withUnsafeBufferPointer { textBuffer in
                    PEPDFPageObjectReplaceTextAtPath(
                        document,
                        0,
                        pathBuffer.baseAddress,
                        pathBuffer.count,
                        textBuffer.baseAddress,
                        textBuffer.count
                    )
                }
            }
            if !replaced && PEPDFDocumentLastMutationRejectedForAppearance(document) {
                rejectedPath = path
                XCTAssertEqual(try recursiveTexts(document), expectedTexts)
                PEPDFDocumentClose(document)
                break
            }
            PEPDFDocumentClose(document)
        }
        XCTAssertNotNil(
            rejectedPath,
            "The real-world subset-font page should be rejected before unrelated text changes."
        )
    }

    func testBoldItalicCoreTextOverlayRemainsSearchableAfterPDFiumImport() throws {
        let replacement = "Styled 文字"
        let styles: [(bold: Bool, italic: Bool)] = [
            (bold: true, italic: false),
            (bold: false, italic: true),
            (bold: true, italic: true),
        ]
        for style in styles {
            let document = try open(makeTextPDF())
            defer { PEPDFDocumentClose(document) }
            let overlay = try makeCoreTextOverlay(
                text: replacement,
                bold: style.bold,
                italic: style.italic
            )
            let actualText = Array(replacement.utf16)
            XCTAssertTrue(overlay.withUnsafeBytes { overlayBytes in
                actualText.withUnsafeBufferPointer { textBuffer in
                    PEPDFPageImportOverlayWithActualText(
                        document,
                        0,
                        overlayBytes.bindMemory(to: UInt8.self).baseAddress,
                        overlayBytes.count,
                        textBuffer.baseAddress,
                        textBuffer.count
                    )
                }
            })

            let saved = try copyData(document)
            let reopened = try open(saved)
            defer { PEPDFDocumentClose(reopened) }
            let objectTexts = try recursiveTexts(reopened).joined(separator: " ")
            let pdfKitDocument = try XCTUnwrap(PDFDocument(data: saved))
            XCTAssertTrue(
                !pdfKitDocument.findString(replacement, withOptions: []).isEmpty ||
                    objectTexts.contains(replacement)
            )
        }
    }

    private func open(
        _ data: Data,
        password: String? = nil
    ) throws -> PEPDFDocumentRef {
        var error: UInt32 = 0
        let document = data.withUnsafeBytes { dataBuffer in
            let create: (UnsafePointer<CChar>?) -> PEPDFDocumentRef? = { password in
                PEPDFDocumentCreate(
                    dataBuffer.bindMemory(to: UInt8.self).baseAddress,
                    dataBuffer.count,
                    password,
                    &error
                )
            }
            if let password {
                return password.withCString(create)
            }
            return create(nil)
        }
        return try XCTUnwrap(document, "PDFium open failed with code \(error)")
    }

    private func objectInfo(
        _ document: PEPDFDocumentRef,
        index: Int32
    ) throws -> PEPDFObjectInfo {
        var info = PEPDFObjectInfo()
        XCTAssertTrue(PEPDFPageObjectInfo(document, 0, index, &info))
        return info
    }

    private func pageInfo(
        _ document: PEPDFDocumentRef,
        pageIndex: Int32
    ) throws -> PEPDFPageInfo {
        var info = PEPDFPageInfo()
        XCTAssertTrue(PEPDFPageInfoAtIndex(document, pageIndex, &info))
        return info
    }

    private func objectInfo(
        _ document: PEPDFDocumentRef,
        path: [Int32]
    ) throws -> PEPDFObjectInfo {
        var info = PEPDFObjectInfo()
        XCTAssertTrue(path.withUnsafeBufferPointer {
            PEPDFPageObjectInfoAtPath(
                document,
                0,
                $0.baseAddress,
                $0.count,
                &info
            )
        })
        return info
    }

    private func objectText(
        _ document: PEPDFDocumentRef,
        index: Int32
    ) throws -> String {
        var pointer: UnsafeMutablePointer<UInt16>?
        var length = 0
        XCTAssertTrue(PEPDFPageObjectCopyText(document, 0, index, &pointer, &length))
        let text = try XCTUnwrap(pointer)
        defer { PEPDFFree(text) }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }

    private func objectText(
        _ document: PEPDFDocumentRef,
        path: [Int32]
    ) throws -> String {
        var pointer: UnsafeMutablePointer<UInt16>?
        var length = 0
        XCTAssertTrue(path.withUnsafeBufferPointer {
            PEPDFPageObjectCopyTextAtPath(
                document,
                0,
                $0.baseAddress,
                $0.count,
                &pointer,
                &length
            )
        })
        let text = try XCTUnwrap(pointer)
        defer { PEPDFFree(text) }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }

    private func objectPath(
        _ document: PEPDFDocumentRef,
        flatIndex: Int32
    ) throws -> [Int32] {
        var pointer: UnsafeMutablePointer<Int32>?
        var length = 0
        XCTAssertTrue(PEPDFPageObjectCopyPath(document, 0, flatIndex, &pointer, &length))
        let indices = try XCTUnwrap(pointer)
        defer { PEPDFFree(indices) }
        return Array(UnsafeBufferPointer(start: indices, count: length))
    }

    private func displayObjects(
        _ document: PEPDFDocumentRef
    ) throws -> [(path: [Int32], info: PEPDFObjectInfo)] {
        var pathIndices: UnsafeMutablePointer<Int32>?
        var pathOffsets: UnsafeMutablePointer<Int32>?
        var infos: UnsafeMutablePointer<PEPDFObjectInfo>?
        var objectCount = 0
        var pathIndexCount = 0
        XCTAssertTrue(PEPDFPageObjectCopyDisplayList(
            document,
            0,
            &pathIndices,
            &pathOffsets,
            &infos,
            &objectCount,
            &pathIndexCount
        ))
        guard objectCount > 0 else { return [] }
        let indices = try XCTUnwrap(pathIndices)
        let offsets = try XCTUnwrap(pathOffsets)
        let objectInfos = try XCTUnwrap(infos)
        defer {
            PEPDFFree(indices)
            PEPDFFree(offsets)
            PEPDFFree(objectInfos)
        }
        XCTAssertEqual(offsets[objectCount], Int32(pathIndexCount))
        return (0..<objectCount).map { index in
            let start = Int(offsets[index])
            let end = Int(offsets[index + 1])
            return (
                path: Array(UnsafeBufferPointer(
                    start: indices.advanced(by: start),
                    count: end - start
                )),
                info: objectInfos[index]
            )
        }
    }

    private func objectBitmap(
        _ document: PEPDFDocumentRef,
        path: [Int32]
    ) throws -> (bytes: Data, width: Int32, height: Int32, stride: Int32, format: Int32) {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        var width: Int32 = 0
        var height: Int32 = 0
        var stride: Int32 = 0
        var format: Int32 = 0
        XCTAssertTrue(path.withUnsafeBufferPointer {
            PEPDFPageObjectCopyBitmapAtPath(
                document, 0, $0.baseAddress, $0.count,
                &pointer, &length, &width, &height, &stride, &format
            )
        })
        let bytes = try XCTUnwrap(pointer)
        defer { PEPDFFree(bytes) }
        return (Data(bytes: bytes, count: length), width, height, stride, format)
    }

    private func recursiveTexts(_ document: PEPDFDocumentRef) throws -> [String] {
        let count = PEPDFPageObjectCountRecursive(document, 0)
        return try (0..<count).compactMap { flatIndex in
            let path = try objectPath(document, flatIndex: flatIndex)
            var pointer: UnsafeMutablePointer<UInt16>?
            var length = 0
            let success = path.withUnsafeBufferPointer {
                PEPDFPageObjectCopyTextAtPath(
                    document,
                    0,
                    $0.baseAddress,
                    $0.count,
                    &pointer,
                    &length
                )
            }
            guard success, let pointer else { return nil }
            defer { PEPDFFree(pointer) }
            return String(
                decoding: UnsafeBufferPointer(start: pointer, count: length),
                as: UTF16.self
            )
        }
    }

    private func copyData(
        _ document: PEPDFDocumentRef,
        removeSecurity: Bool = false,
        subsetNewFonts: Bool = true
    ) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertTrue(PEPDFDocumentCopyData(
            document,
            removeSecurity,
            subsetNewFonts,
            &pointer,
            &length
        ))
        let bytes = try XCTUnwrap(pointer)
        defer { PEPDFFree(bytes) }
        return Data(bytes: bytes, count: length)
    }

    private func copyPages(
        _ document: PEPDFDocumentRef,
        indices: [Int32]
    ) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertTrue(indices.withUnsafeBufferPointer {
            PEPDFDocumentCopyPages(
                document,
                $0.baseAddress,
                $0.count,
                &pointer,
                &length
            )
        })
        let bytes = try XCTUnwrap(pointer)
        defer { PEPDFFree(bytes) }
        return Data(bytes: bytes, count: length)
    }

    private func decodedFirstPageContents(_ data: Data) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let dictionary = try XCTUnwrap(page.dictionary)
        var contentsObject: CGPDFObjectRef?
        XCTAssertTrue(CGPDFDictionaryGetObject(
            dictionary,
            "Contents",
            &contentsObject
        ))
        let unwrappedContents = try XCTUnwrap(contentsObject)
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFObjectGetValue(unwrappedContents, .stream, &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
    }

    private func makeEncryptedPDF(_ data: Data, password: String) throws -> Data {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(
            to: url,
            withOptions: [
                .ownerPasswordOption: password,
                .userPasswordOption: password,
            ]
        ))
        return try Data(contentsOf: url)
    }

    private func notoFontURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["PE_FALLBACK_FONT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PDF Editor/NotoSansCJKtc-Regular.otf")
    }

    private func makeCoreTextOverlay(
        text: String,
        bold: Bool = false,
        italic: Bool = false
    ) throws -> Data {
        let fontData = try Data(contentsOf: notoFontURL())
        let provider = try XCTUnwrap(CGDataProvider(data: fontData as CFData))
        let graphicsFont = try XCTUnwrap(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 24, nil, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.black,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor.black)
        context.setStrokeColor(CGColor.black)
        context.setLineWidth(0.84)
        context.setTextDrawingMode(bold ? .fillStroke : .fill)
        context.textMatrix = italic
            ? CGAffineTransform(a: 1, b: 0, c: 0.22, d: 1, tx: 0, ty: 0)
            : .identity
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func nonWhitePixelCount(_ data: Data) throws -> Int {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let bounds = page.getBoxRect(.mediaBox).integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.drawPDFPage(page)
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) {
                if bytes[$1] < 245 || bytes[$1 + 1] < 245 || bytes[$1 + 2] < 245 {
                    $0 += 1
                }
            }
        }
    }

    private func makeICCColoredTextPDF() throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(try XCTUnwrap(CGColor(
            colorSpace: colorSpace,
            components: [0.8, 0.1, 0.2, 1]
        )))
        context.fill(CGRect(x: 40, y: 80, width: 240, height: 180))
        context.setFillColor(try XCTUnwrap(CGColor(
            colorSpace: colorSpace,
            components: [0.1, 0.65, 0.25, 1]
        )))
        context.fill(CGRect(x: 320, y: 80, width: 240, height: 180))

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Original Text",
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.black,
            ]
        ))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func makeShadedTextPDF() -> Data {
        let stream = "q 0.7 0 0 0.6 80 90 cm /Sh1 sh Q BT /F1 18 Tf 0 0 0 rg 1 0 0 1 72 700 Tm (Original Text) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /Shading << /Sh1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 612 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ])
    }

    private func assertPatternTextReplacementPreservesPaint(
        _ source: Data
    ) throws {
        let beforePixels = try nonWhitePixelCount(source)
        let document = try open(source)
        defer { PEPDFDocumentClose(document) }
        let count = Int(PEPDFPageObjectCountRecursive(document, 0))
        let target = try XCTUnwrap((0..<count).lazy.compactMap { flatIndex -> [Int32]? in
            guard let path = try? self.objectPath(document, flatIndex: Int32(flatIndex)),
                  let info = try? self.objectInfo(document, path: path),
                  info.type == Int32(PEPDFObjectTypeText.rawValue),
                  (try? self.objectText(document, path: path)) == "Original Text" else {
                return nil
            }
            return path
        }.first)
        let replacement = Array("TEST".utf16)
        XCTAssertTrue(target.withUnsafeBufferPointer { path in
            replacement.withUnsafeBufferPointer { text in
                PEPDFPageObjectReplaceTextAtPath(
                    document, 0, path.baseAddress, path.count,
                    text.baseAddress, text.count
                )
            }
        })
        XCTAssertFalse(PEPDFDocumentLastMutationRejectedForAppearance(document))

        let saved = try copyData(document)
        let reopened = try open(saved)
        defer { PEPDFDocumentClose(reopened) }
        XCTAssertEqual(try objectText(reopened, path: target), "TEST")
        XCTAssertGreaterThanOrEqual(try nonWhitePixelCount(saved) * 100,
                                    beforePixels * 95)
        XCTAssertTrue(String(
            decoding: try decodedFirstPageContents(saved),
            as: UTF8.self
        ).contains("scn"))
    }

    private func makeColoredTilingPatternTextPDF() -> Data {
        let pattern = "1 0 0 rg 0 0 8 8 re f 0 0 1 rg 0 0 4 4 re f"
        let stream =
            "/Pattern cs /P1 scn 40 80 520 180 re f " +
            "BT /F1 18 Tf 0 0 0 rg 1 0 0 1 72 700 Tm (Original Text) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /Pattern << /P1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 8 8] /XStep 8 /YStep 8 /Resources << >> /Length \(pattern.utf8.count) >>\nstream\n\(pattern)\nendstream",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ])
    }

    private func makeUncoloredTilingPatternTextPDF() -> Data {
        let pattern = "0 0 8 8 re f"
        let stream =
            "/PCS cs 0 0.7 0.2 /P1 scn 40 80 520 180 re f " +
            "BT /F1 18 Tf 0 0 0 rg 1 0 0 1 72 700 Tm (Original Text) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /ColorSpace << /PCS [/Pattern /DeviceRGB] >> /Pattern << /P1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Pattern /PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 8 8] /XStep 8 /YStep 8 /Resources << >> /Length \(pattern.utf8.count) >>\nstream\n\(pattern)\nendstream",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ])
    }

    private func makeShadingPatternTextPDF() -> Data {
        let stream =
            "/Pattern cs /P1 scn 40 80 520 180 re f " +
            "BT /F1 18 Tf 0 0 0 rg 1 0 0 1 72 700 Tm (Original Text) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /Pattern << /P1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Pattern /PatternType 2 /Matrix [1 0 0 1 0 0] /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [40 80 560 80] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ])
    }

    private func makeTextPDF(text: String = "Original Text") -> Data {
        let stream = "BT /F1 18 Tf 0 0 1 rg 1 0 0 1 72 700 Tm (\(text)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ]

        var pdf = "%PDF-1.4\n%âãÏÓ\n"
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func makeTwoTextObjectPDF() -> Data {
        let stream =
            "BT /F1 18 Tf 1 0 0 1 72 700 Tm (Original Text) Tj ET " +
            "BT /F1 18 Tf 1 0 0 1 72 650 Tm (Untouched Text) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ])
    }

    private func makeNestedFormPDF() -> Data {
        let outerStream = "q 1 0 0 1 10 20 cm /Inner Do Q"
        let pageStream = "q 1 0 0 1 72 600 cm /Outer Do Q q .5 0 0 .5 300 500 cm /Outer Do Q"
        let innerStream = "BT /F1 12 Tf 1 0 0 1 5 7 Tm (INNER) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Outer 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] /Resources << /XObject << /Inner 7 0 R >> >> /Length \(outerStream.utf8.count) >>\nstream\n\(outerStream)\nendstream",
            "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 40] /Resources << /Font << /F1 4 0 R >> >> /Length \(innerStream.utf8.count) >>\nstream\n\(innerStream)\nendstream",
        ]
        return makePDF(objects: objects)
    }

    private func makeNestedFormReorderPDF() -> Data {
        let pageStream =
            "q 1 0 0 1 72 600 cm /Outer Do Q " +
            "q 1 0 0 1 300 400 cm /Outer Do Q"
        let formStream =
            "BT /F1 12 Tf 1 0 0 1 5 7 Tm (FIRST) Tj ET " +
            "BT /F1 12 Tf 1 0 0 1 5 27 Tm (SECOND) Tj ET"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Outer 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] /Resources << /Font << /F1 4 0 R >> >> /Length \(formStream.utf8.count) >>\nstream\n\(formStream)\nendstream",
            "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
        ])
    }

    private func makeSharedImagePDF() -> Data {
        let pageStream =
            "q 100 0 0 100 50 50 cm /Im1 Do Q " +
            "q 100 0 0 100 200 50 cm /Im1 Do Q"
        let imageStream = "FF0000>"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 250] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(imageStream.utf8.count) >>\nstream\n\(imageStream)\nendstream",
        ])
    }

    private func makeSharedFormImagePDF() -> Data {
        let pageStream =
            "q 1 0 0 1 50 50 cm /Fm1 Do Q " +
            "q 1 0 0 1 200 50 cm /Fm1 Do Q"
        let formStream = "q 100 0 0 100 0 0 cm /Im1 Do Q"
        let imageStream = "FF0000>"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 250] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /XObject << /Im1 6 0 R >> >> /Length \(formStream.utf8.count) >>\nstream\n\(formStream)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(imageStream.utf8.count) >>\nstream\n\(imageStream)\nendstream",
        ])
    }

    private func makeClippedMarkedImagePDF() -> Data {
        let pageStream =
            "/Artifact BMC q 0 0 50 100 re W n " +
            "100 0 0 100 20 20 cm /Im1 Do Q EMC " +
            "BT /F1 12 Tf 1 0 0 1 200 100 Tm (TOP) Tj ET"
        let imageStream = "FF0000>"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 250] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(imageStream.utf8.count) >>\nstream\n\(imageStream)\nendstream",
        ])
    }

    private func makePageAssemblyPDF() -> Data {
        let pageA = "BT /F1 18 Tf 30 300 Td (PAGE-A) Tj ET"
        let pageB = "BT /F1 18 Tf 30 500 Td (PAGE-B) Tj ET /Shared Do"
        let pageC = "BT /F1 18 Tf 30 500 Td (PAGE-C) Tj ET /Shared Do"
        let shared = "BT /F1 12 Tf 1 0 0 1 30 80 Tm (SHARED) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /CropBox [10 20 280 370] /Rotate 90 /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R /Annots [10 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 600] /Resources << /Font << /F1 6 0 R >> /XObject << /Shared 11 0 R >> >> /Contents 8 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 600] /Resources << /Font << /F1 6 0 R >> /XObject << /Shared 11 0 R >> >> /Contents 9 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(pageA.utf8.count) >>\nstream\n\(pageA)\nendstream",
            "<< /Length \(pageB.utf8.count) >>\nstream\n\(pageB)\nendstream",
            "<< /Length \(pageC.utf8.count) >>\nstream\n\(pageC)\nendstream",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (Note A) /P 3 0 R >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] /Resources << /Font << /F1 6 0 R >> >> /Length \(shared.utf8.count) >>\nstream\n\(shared)\nendstream",
        ]
        return makePDF(objects: objects)
    }

    private func makeTextCommentWithAppearancePDF() -> Data {
        let appearance = "1 0.8 0 rg 0 0 24 24 re f"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 44 44] /Contents (Styled note) /Name /Comment /C [1 0.8 0] /P 3 0 R /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 24 24] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
        ])
    }

    private func makeHighlightWithAppearancePDF() -> Data {
        let appearance = "1 0.8 0 rg 0 0 180 24 re f"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Highlight /Rect [40 200 220 224] " +
                "/QuadPoints [40 224 130 224 40 212 130 212 130 212 220 212 130 200 220 200] " +
                "/C [1 0.8 0] /CA 0.45 /P 3 0 R /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 180 24] /Resources << >> " +
                "/Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
        ])
    }

    private func makeInkWithAppearancePDF() -> Data {
        let appearance = "0.9 0.15 0.15 RG 4 w 0 0 m 40 40 l 80 10 l S"
        return makePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Ink /Rect [20 20 100 60] " +
                "/InkList [[20 20 60 60 100 30]] /C [0.9 0.15 0.15] /CA 1 " +
                "/BS << /W 4 >> /P 3 0 R /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 80 40] /Resources << >> " +
                "/Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
        ])
    }

    private func makeLargeTextPDF(pageCount: Int) -> Data {
        precondition(pageCount > 0)
        let pageObjectNumbers = (0..<pageCount).map { 4 + $0 * 2 }
        let kids = pageObjectNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]

        for pageIndex in 0..<pageCount {
            let contentObjectNumber = 5 + pageIndex * 2
            let label = String(format: "PAGE-%03d", pageIndex + 1)
            let stream = "BT /F1 18 Tf 72 720 Td (\(label)) Tj ET"
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
                "/Resources << /Font << /F1 3 0 R >> >> " +
                "/Contents \(contentObjectNumber) 0 R >>"
            )
            objects.append(
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
            )
        }
        return makePDF(objects: objects)
    }

    private func makePDF(objects: [String]) -> Data {
        var pdf = "%PDF-1.4\n%âãÏÓ\n"
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
