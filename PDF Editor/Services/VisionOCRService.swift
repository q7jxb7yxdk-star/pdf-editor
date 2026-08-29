import CoreGraphics
import Foundation
import PDFKit
import Vision

struct OCRTextObservation: Equatable, Sendable {
    let text: String
    let confidence: Float
    let normalizedBounds: CGRect
    let pageBounds: CGRect
}

struct OCRRecognizedPage: Equatable, Identifiable, Sendable {
    var id: Int { pageIndex }

    let pageIndex: Int
    let observations: [OCRTextObservation]
}

struct OCRBatchResult: Equatable, Sendable {
    let recognizedPages: [OCRRecognizedPage]
    let skippedTextPageIndices: [Int]
    let emptyPageIndices: [Int]

    var recognizedPageCount: Int { recognizedPages.count }
    var recognizedItemCount: Int {
        recognizedPages.reduce(0) { $0 + $1.observations.count }
    }
}

struct OCRRunContext: Equatable, Sendable {
    let pageIndices: [Int]
    let documentRevision: Int

    init(pageIndex: Int, documentRevision: Int) {
        pageIndices = [pageIndex]
        self.documentRevision = documentRevision
    }

    init(pageIndices: [Int], documentRevision: Int) {
        self.pageIndices = pageIndices
        self.documentRevision = documentRevision
    }

    var singlePageIndex: Int? {
        guard pageIndices.count == 1 else { return nil }
        return pageIndices[0]
    }

    func isCurrent(documentRevision: Int) -> Bool {
        self.documentRevision == documentRevision
    }
}

enum OCRPageResult: Equatable, Sendable {
    case existingText(String)
    case recognized([OCRTextObservation])
}

enum VisionOCRError: LocalizedError {
    case renderingFailed
    case textLayerAlreadyExists
    case fontResourceMissing
    case invalidPageIndex(Int)
    case documentChanged

    var errorDescription: String? {
        switch self {
        case .renderingFailed:
            "The PDF page could not be rendered for text recognition."
        case .textLayerAlreadyExists:
            "This page already contains selectable text, so OCR was not added."
        case .fontResourceMissing:
            "The Unicode OCR font resource is missing from the app bundle."
        case let .invalidPageIndex(index):
            "Page index \(index) is not available for OCR."
        case .documentChanged:
            "The document changed during OCR. Run text recognition again before adding a searchable text layer."
        }
    }
}

final class VisionOCRService {
    private let maximumImageDimension: CGFloat

    init(maximumImageDimension: CGFloat = 3_000) {
        self.maximumImageDimension = maximumImageDimension
    }

    func recognizeText(on page: PDFPage) async throws -> OCRPageResult {
        if let text = selectableText(on: page) {
            return .existingText(text)
        }

        try Task.checkCancellation()

        let pageBox = page.bounds(for: .cropBox)
        let rotation = normalizedRotation(page.rotation)
        let image = try render(page: page, pageBox: pageBox, rotation: rotation)

        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.performRecognition(
                image: image,
                pageBox: pageBox,
                rotation: rotation
            )
        }.value
    }

    func recognizePages(
        in document: PDFDocument,
        pageIndices: [Int],
        progress: (Int, Int) -> Void
    ) async throws -> OCRBatchResult {
        var recognizedPages: [OCRRecognizedPage] = []
        var skippedTextPageIndices: [Int] = []
        var emptyPageIndices: [Int] = []

        for (offset, pageIndex) in pageIndices.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw VisionOCRError.invalidPageIndex(pageIndex)
            }

            switch try await recognizeText(on: page) {
            case .existingText:
                skippedTextPageIndices.append(pageIndex)
            case let .recognized(observations):
                if observations.isEmpty {
                    emptyPageIndices.append(pageIndex)
                } else {
                    recognizedPages.append(
                        OCRRecognizedPage(pageIndex: pageIndex, observations: observations)
                    )
                }
            }
            progress(offset + 1, pageIndices.count)
        }

        return OCRBatchResult(
            recognizedPages: recognizedPages,
            skippedTextPageIndices: skippedTextPageIndices,
            emptyPageIndices: emptyPageIndices
        )
    }

    func requiresOCR(_ page: PDFPage) -> Bool {
        selectableText(on: page) == nil
    }

    private func selectableText(on page: PDFPage) -> String? {
        guard let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        return text
    }

    private func render(
        page: PDFPage,
        pageBox: CGRect,
        rotation: Int
    ) throws -> CGImage {
        let rotatedSize = rotation.isQuarterTurn
            ? CGSize(width: pageBox.height, height: pageBox.width)
            : pageBox.size
        let longestSide = max(rotatedSize.width, rotatedSize.height)
        let scale = max(1, maximumImageDimension / max(longestSide, 1))
        let thumbnailSize = CGSize(
            width: max(1, rotatedSize.width * scale),
            height: max(1, rotatedSize.height * scale)
        )
        let thumbnail = page.thumbnail(of: thumbnailSize, for: .cropBox)

        #if os(macOS)
        guard let cgImage = thumbnail.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw VisionOCRError.renderingFailed
        }
        #else
        guard let cgImage = thumbnail.cgImage else {
            throw VisionOCRError.renderingFailed
        }
        #endif

        return cgImage
    }

    nonisolated private static func performRecognition(
        image: CGImage,
        pageBox: CGRect,
        rotation: Int
    ) throws -> OCRPageResult {
        var observations: [OCRTextObservation] = []
        var recognitionError: Error?
        let request = VNRecognizeTextRequest { request, error in
            recognitionError = error
            observations = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap {
                guard let candidate = $0.topCandidates(1).first else {
                    return nil
                }

                return OCRTextObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    normalizedBounds: $0.boundingBox,
                    pageBounds: mapToPage(
                        normalizedBounds: $0.boundingBox,
                        pageBox: pageBox,
                        rotation: rotation
                    )
                )
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try VNImageRequestHandler(cgImage: image).perform([request])

        if let recognitionError {
            throw recognitionError
        }

        return .recognized(observations)
    }

    nonisolated static func mapToPage(
        normalizedBounds: CGRect,
        pageBox: CGRect,
        rotation: Int
    ) -> CGRect {
        let corners = [
            CGPoint(x: normalizedBounds.minX, y: normalizedBounds.minY),
            CGPoint(x: normalizedBounds.maxX, y: normalizedBounds.minY),
            CGPoint(x: normalizedBounds.minX, y: normalizedBounds.maxY),
            CGPoint(x: normalizedBounds.maxX, y: normalizedBounds.maxY),
        ].map { normalizedPagePoint(fromDisplayPoint: $0, rotation: rotation) }

        let xValues = corners.map(\.x)
        let yValues = corners.map(\.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max() else {
            return .zero
        }

        return CGRect(
            x: pageBox.minX + minX * pageBox.width,
            y: pageBox.minY + minY * pageBox.height,
            width: (maxX - minX) * pageBox.width,
            height: (maxY - minY) * pageBox.height
        )
    }

    nonisolated private static func normalizedPagePoint(
        fromDisplayPoint point: CGPoint,
        rotation: Int
    ) -> CGPoint {
        switch rotation {
        case 90:
            CGPoint(x: 1 - point.y, y: point.x)
        case 180:
            CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270:
            CGPoint(x: point.y, y: 1 - point.x)
        default:
            point
        }
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        (rotation % 360 + 360) % 360
    }
}

private extension Int {
    var isQuarterTurn: Bool {
        self == 90 || self == 270
    }
}
