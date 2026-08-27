import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFPageImageFormat: CaseIterable, Sendable {
    case png
    case jpeg

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    var filenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

enum PDFPageImageDPI: Int, CaseIterable, Sendable {
    case dpi72 = 72
    case dpi144 = 144
    case dpi300 = 300
}

struct PDFPageImageExportOptions: Sendable {
    var format: PDFPageImageFormat
    var dpi: PDFPageImageDPI
    var jpegCompressionQuality: CGFloat
    var maximumPixelDimension: Int
    var maximumPixelCount: Int
    var maximumEstimatedBytes: Int

    init(
        format: PDFPageImageFormat = .png,
        dpi: PDFPageImageDPI = .dpi144,
        jpegCompressionQuality: CGFloat = 0.9,
        maximumPixelDimension: Int = 16_384,
        maximumPixelCount: Int = 67_108_864,
        maximumEstimatedBytes: Int = 268_435_456
    ) {
        self.format = format
        self.dpi = dpi
        self.jpegCompressionQuality = jpegCompressionQuality
        self.maximumPixelDimension = maximumPixelDimension
        self.maximumPixelCount = maximumPixelCount
        self.maximumEstimatedBytes = maximumEstimatedBytes
    }
}

struct PDFPageImageExportOutput: Sendable {
    let pageIndex: Int
    let data: Data
    let filename: String
    let contentType: UTType
    let pixelSize: CGSize
}

enum PDFPageImageExportError: LocalizedError {
    case noPages
    case invalidPageIndex(Int)
    case invalidOptions
    case invalidPageBounds(Int)
    case imageTooLarge(pageIndex: Int, pixelWidth: Int, pixelHeight: Int)
    case memoryLimitExceeded(pageIndex: Int, estimatedBytes: Int)
    case renderingFailed(pageIndex: Int)
    case encodingFailed(pageIndex: Int)

    var errorDescription: String? {
        switch self {
        case .noPages:
            "This PDF does not contain any pages to export."
        case let .invalidPageIndex(index):
            "PDF page \(index + 1) is not available for image export."
        case .invalidOptions:
            "The image export options are invalid."
        case let .invalidPageBounds(index):
            "PDF page \(index + 1) does not have renderable crop-box bounds."
        case let .imageTooLarge(index, width, height):
            "PDF page \(index + 1) would render at \(width) by \(height) pixels, exceeding the export limit."
        case let .memoryLimitExceeded(index, bytes):
            "PDF page \(index + 1) needs approximately \(bytes) bytes to render, exceeding the memory limit."
        case let .renderingFailed(index):
            "PDF page \(index + 1) could not be rendered as an image."
        case let .encodingFailed(index):
            "PDF page \(index + 1) could not be encoded as the requested image format."
        }
    }
}

/// Exports each PDF page independently so callers can release each encoded image promptly.
@MainActor
final class PDFPageImageExporter {
    func exportPage(
        _ page: PDFPage,
        pageIndex: Int,
        options: PDFPageImageExportOptions
    ) async throws -> PDFPageImageExportOutput {
        try Task.checkCancellation()
        try validate(options: options)

        let pixelSize = try requestedPixelSize(
            for: page,
            pageIndex: pageIndex,
            options: options
        )
        try Task.checkCancellation()

        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        guard let cgImage = cgImage(from: image) else {
            throw PDFPageImageExportError.renderingFailed(pageIndex: pageIndex)
        }
        try Task.checkCancellation()

        let data = try encode(cgImage, pageIndex: pageIndex, options: options)
        return PDFPageImageExportOutput(
            pageIndex: pageIndex,
            data: data,
            filename: Self.filename(for: pageIndex, format: options.format),
            contentType: options.format.contentType,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    func exportPages(
        in document: PDFDocument,
        pageIndices: [Int]? = nil,
        options: PDFPageImageExportOptions,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [PDFPageImageExportOutput] {
        let indices = pageIndices ?? Array(0..<document.pageCount)
        var outputs: [PDFPageImageExportOutput] = []
        outputs.reserveCapacity(indices.count)

        for (offset, pageIndex) in indices.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PDFPageImageExportError.invalidPageIndex(pageIndex)
            }
            outputs.append(try await exportPage(page, pageIndex: pageIndex, options: options))
            progress?(offset + 1, indices.count)
            await Task.yield()
        }
        return outputs
    }

    static func filename(for pageIndex: Int, format: PDFPageImageFormat) -> String {
        String(format: "page-%04d.%@", pageIndex + 1, format.filenameExtension)
    }

    private func validate(options: PDFPageImageExportOptions) throws {
        guard options.jpegCompressionQuality >= 0, options.jpegCompressionQuality <= 1,
              options.maximumPixelDimension > 0,
              options.maximumPixelCount > 0,
              options.maximumEstimatedBytes >= 4 else {
            throw PDFPageImageExportError.invalidOptions
        }
    }

    private func requestedPixelSize(
        for page: PDFPage,
        pageIndex: Int,
        options: PDFPageImageExportOptions
    ) throws -> CGSize {
        let cropBox = page.bounds(for: .cropBox)
        guard cropBox.width.isFinite, cropBox.height.isFinite,
              cropBox.width > 0, cropBox.height > 0 else {
            throw PDFPageImageExportError.invalidPageBounds(pageIndex)
        }

        let scale = CGFloat(options.dpi.rawValue) / 72
        let rotation = ((page.rotation % 360) + 360) % 360
        let pageSize = rotation == 90 || rotation == 270
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : cropBox.size
        let width = try roundedPixelCount(pageSize.width * scale)
        let height = try roundedPixelCount(pageSize.height * scale)
        guard width <= options.maximumPixelDimension,
              height <= options.maximumPixelDimension else {
            throw PDFPageImageExportError.imageTooLarge(
                pageIndex: pageIndex,
                pixelWidth: width,
                pixelHeight: height
            )
        }
        guard width <= Int.max / height,
              width * height <= options.maximumPixelCount else {
            throw PDFPageImageExportError.imageTooLarge(
                pageIndex: pageIndex,
                pixelWidth: width,
                pixelHeight: height
            )
        }
        let pixelCount = width * height
        guard pixelCount <= Int.max / 4 else {
            throw PDFPageImageExportError.memoryLimitExceeded(
                pageIndex: pageIndex,
                estimatedBytes: Int.max
            )
        }
        let estimatedBytes = pixelCount * 4
        guard estimatedBytes <= options.maximumEstimatedBytes else {
            throw PDFPageImageExportError.memoryLimitExceeded(
                pageIndex: pageIndex,
                estimatedBytes: estimatedBytes
            )
        }
        return CGSize(width: width, height: height)
    }

    private func roundedPixelCount(_ value: CGFloat) throws -> Int {
        guard value.isFinite, value > 0, value <= CGFloat(Int.max) else {
            throw PDFPageImageExportError.invalidOptions
        }
        return max(1, Int(value.rounded(.up)))
    }

    private func encode(
        _ image: CGImage,
        pageIndex: Int,
        options: PDFPageImageExportOptions
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            options.format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw PDFPageImageExportError.encodingFailed(pageIndex: pageIndex)
        }
        var properties: [CFString: Any] = [:]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = options.jpegCompressionQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFPageImageExportError.encodingFailed(pageIndex: pageIndex)
        }
        return data as Data
    }

    private func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        image.cgImage
        #endif
    }
}

#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#else
import UIKit
private typealias PlatformImage = UIImage
#endif
