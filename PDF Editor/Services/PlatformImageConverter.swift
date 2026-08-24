import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PDFBitmapPayload: Equatable, Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let bytesPerRow: Int
    let hasAlpha: Bool

    var aspectRatio: CGFloat {
        CGFloat(pixelWidth) / CGFloat(max(pixelHeight, 1))
    }
}

nonisolated enum PlatformImageConverter {
    static func jpegData(
        from data: Data,
        compressionQuality: CGFloat = 0.9
    ) -> Data? {
        guard let payloadImageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  payloadImageSource,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 8_192,
                  ] as CFDictionary
              ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// ImageIO handles JPEG, PNG, HEIC and their EXIF orientation on both platforms.
    /// The size cap prevents a single camera image from exhausting an iOS process.
    static func bitmapPayload(
        from data: Data,
        maximumPixelDimension: Int = 8_192
    ) -> PDFBitmapPayload? {
        guard maximumPixelDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= Int.max / 4 else { return nil }
        let bytesPerRow = width * 4
        guard height <= Int.max / bytesPerRow else { return nil }

        var bytes = Data(count: bytesPerRow * height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                          CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // PDFium's stable BGRA format requires independent (not premultiplied) RGB.
        var hasAlpha = false
        bytes.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[offset + 3])
                if alpha < 255 { hasAlpha = true }
                guard alpha > 0, alpha < 255 else {
                    if alpha == 0 {
                        pixels[offset] = 0
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = 0
                    }
                    continue
                }
                for component in 0..<3 {
                    pixels[offset + component] = UInt8(min(
                        255,
                        (Int(pixels[offset + component]) * 255 + alpha / 2) / alpha
                    ))
                }
            }
        }
        return PDFBitmapPayload(
            data: bytes,
            pixelWidth: width,
            pixelHeight: height,
            bytesPerRow: bytesPerRow,
            hasAlpha: hasAlpha
        )
    }
}
