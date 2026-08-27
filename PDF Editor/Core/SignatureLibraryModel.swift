import CoreGraphics
import Foundation

nonisolated enum SignatureLibraryLimits {
    static let maximumTemplates = 64
    static let maximumStrokesPerTemplate = 128
    static let maximumPointsPerStroke = 2_048
    static let maximumPointsPerTemplate = 16_384
    static let maximumDisplayNameLength = 80
    static let maximumPayloadBytes = 512_000
}

nonisolated enum SignaturePlacementGeometry {
    static let preferredSize = CGSize(width: 200, height: 80)

    static func bounds(
        centeredAt point: CGPoint,
        pageBounds rawPageBounds: CGRect,
        preferredSize: CGSize = SignaturePlacementGeometry.preferredSize
    ) -> CGRect {
        let pageBounds = rawPageBounds.standardized
        let width = min(max(preferredSize.width, 0), pageBounds.width)
        let height = min(max(preferredSize.height, 0), pageBounds.height)
        let originX = min(
            max(point.x - width / 2, pageBounds.minX),
            pageBounds.maxX - width
        )
        let originY = min(
            max(point.y - height / 2, pageBounds.minY),
            pageBounds.maxY - height
        )
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

nonisolated enum SignatureLibraryError: LocalizedError, Equatable {
    case invalidPoint
    case strokeTooShort
    case tooManyStrokes
    case tooManyPoints
    case displayNameTooLong
    case tooManyTemplates
    case duplicateTemplateIdentifier
    case payloadTooLarge
    case invalidLibrary

    var errorDescription: String? {
        switch self {
        case .invalidPoint:
            "Signature points must be finite and normalized between 0 and 1."
        case .strokeTooShort:
            "Each signature stroke must contain at least two points."
        case .tooManyStrokes:
            "This signature contains too many strokes."
        case .tooManyPoints:
            "This signature contains too many points."
        case .displayNameTooLong:
            "The signature name is too long."
        case .tooManyTemplates:
            "The signature library contains too many saved signatures."
        case .duplicateTemplateIdentifier:
            "The signature library contains duplicate signatures."
        case .payloadTooLarge:
            "The saved signature library is too large."
        case .invalidLibrary:
            "The saved signature library is invalid."
        }
    }
}

nonisolated struct SignatureLibraryPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw SignatureLibraryError.invalidPoint
        }
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) throws {
        try self.init(x: Double(point.x), y: Double(point.y))
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }
}

nonisolated struct SignatureLibraryTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String?
    let createdAt: Date
    let strokes: [[SignatureLibraryPoint]]

    init(
        id: UUID = UUID(),
        displayName: String? = nil,
        createdAt: Date = Date(),
        strokes: [[SignatureLibraryPoint]]
    ) throws {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName?.count ?? 0 <= SignatureLibraryLimits.maximumDisplayNameLength else {
            throw SignatureLibraryError.displayNameTooLong
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SignatureLibraryError.invalidLibrary
        }
        try Self.validate(strokes: strokes)

        self.id = id
        self.displayName = trimmedName?.isEmpty == true ? nil : trimmedName
        self.createdAt = createdAt
        self.strokes = strokes
    }

    init(
        id: UUID = UUID(),
        displayName: String? = nil,
        createdAt: Date = Date(),
        normalizedStrokes: [[CGPoint]]
    ) throws {
        try self.init(
            id: id,
            displayName: displayName,
            createdAt: createdAt,
            strokes: try normalizedStrokes.map { try $0.map(SignatureLibraryPoint.init) }
        )
    }

    var normalizedStrokes: [[CGPoint]] {
        strokes.map { $0.map(\.cgPoint) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case createdAt
        case strokes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            strokes: try container.decode([[SignatureLibraryPoint]].self, forKey: .strokes)
        )
    }

    static func validate(strokes: [[SignatureLibraryPoint]]) throws {
        guard !strokes.isEmpty, strokes.count <= SignatureLibraryLimits.maximumStrokesPerTemplate else {
            throw SignatureLibraryError.tooManyStrokes
        }
        var totalPoints = 0
        for stroke in strokes {
            guard stroke.count >= 2 else {
                throw SignatureLibraryError.strokeTooShort
            }
            guard stroke.count <= SignatureLibraryLimits.maximumPointsPerStroke else {
                throw SignatureLibraryError.tooManyPoints
            }
            totalPoints += stroke.count
            guard totalPoints <= SignatureLibraryLimits.maximumPointsPerTemplate else {
                throw SignatureLibraryError.tooManyPoints
            }
        }
    }
}
