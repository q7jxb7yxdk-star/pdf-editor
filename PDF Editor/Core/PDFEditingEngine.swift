import Foundation

nonisolated struct PDFTextStyle: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let bold = PDFTextStyle(rawValue: 1 << 0)
    static let italic = PDFTextStyle(rawValue: 1 << 1)

    static func inferred(fromFontName fontName: String?) -> PDFTextStyle {
        guard let fontName else { return [] }
        let normalizedName = fontName.lowercased()
        var style: PDFTextStyle = []
        if normalizedName.contains("bold") || normalizedName.contains("black") {
            style.insert(.bold)
        }
        if normalizedName.contains("italic") || normalizedName.contains("oblique") {
            style.insert(.italic)
        }
        return style
    }
}

nonisolated struct PDFStagedTextEdit: Equatable, Sendable {
    let text: String
    let style: PDFTextStyle
}

/// A platform-neutral snapshot of the document information that the editor can read and write.
nonisolated struct PDFDocumentInfo: Equatable, Sendable {
    var title: String?
    var author: String?
    var subject: String?
    var creator: String?
    var keywords: [String]?
    var creationDate: Date?
    var modificationDate: Date?

    init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        creator: String? = nil,
        keywords: [String]? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.creator = creator
        self.keywords = keywords
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

nonisolated struct PDFDocumentMetadata: Equatable, Sendable {
    let pageCount: Int
    let isEncrypted: Bool
    let isLocked: Bool
    let documentInfo: PDFDocumentInfo
}

/// Page indices in Core editing commands are zero-based. UI code is responsible for converting user-visible page numbers.
nonisolated struct PDFPageRange: Equatable, Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init(_ lowerBound: Int, through upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

nonisolated enum PDFExportSecurityPolicy: Equatable, Sendable {
    /// Uses the PDF implementation's normal export path, which preserves document security when supported.
    case preserve
    /// Creates an export without an encryption dictionary after the document has been successfully unlocked.
    case removeAfterAuthorizedUnlock
}

nonisolated struct PDFExportOptions: Equatable, Sendable {
    var securityPolicy: PDFExportSecurityPolicy = .preserve
}

/// All mutating document actions share one command surface so a PDFium-backed session can replace PDFKit later.
nonisolated enum PDFEditingCommand: Equatable, Sendable {
    case setDocumentInfo(PDFDocumentInfo)
    case deletePage(at: Int)
    case rotatePage(at: Int, byDegrees: Int)
    case movePage(from: Int, to: Int)
    case reorderPages([Int])
    case merge(documentData: Data, password: String?, at: Int)
    case split(ranges: [PDFPageRange])
}

nonisolated enum PDFEditingCommandResult: Equatable, Sendable {
    case updated(PDFDocumentMetadata)
    case split(documents: [Data])
}

nonisolated enum PDFEditingError: Error, Equatable, Sendable, LocalizedError {
    case invalidDocument
    case invalidPassword
    case documentLocked
    case documentPermissionDenied(operation: String)
    case invalidPageIndex(index: Int, pageCount: Int)
    case invalidInsertionIndex(index: Int, pageCount: Int)
    case invalidRotation(degrees: Int)
    case cannotDeleteLastPage
    case invalidPageOrder(expectedPageCount: Int, actualPageCount: Int)
    case duplicatePageIndex(index: Int)
    case invalidPageRange(lowerBound: Int, upperBound: Int, pageCount: Int)
    case overlappingPageRange(PDFPageRange)
    case sourceDocumentLocked
    case sourceDocumentInvalid
    case pageCopyFailed
    case pageMutationFailed
    case exportFailed
    case passwordRemovalFailed
    case passwordProtectionFailed
    case digitalSignatureConsentRequired

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The PDF data could not be opened."
        case .invalidPassword:
            return "The supplied PDF password is not valid."
        case .documentLocked:
            return "Unlock this PDF with its password before editing or exporting it."
        case let .documentPermissionDenied(operation):
            return "This PDF does not permit \(operation)."
        case let .invalidPageIndex(index, pageCount):
            return "Page index \(index) is outside the valid range 0..<\(pageCount)."
        case let .invalidInsertionIndex(index, pageCount):
            return "Insertion index \(index) is outside the valid range 0...\(pageCount)."
        case let .invalidRotation(degrees):
            return "Rotation \(degrees) must be a multiple of 90 degrees."
        case .cannotDeleteLastPage:
            return "A PDF must retain at least one page."
        case let .invalidPageOrder(expectedPageCount, actualPageCount):
            return "A page order must contain exactly \(expectedPageCount) page indices; received \(actualPageCount)."
        case let .duplicatePageIndex(index):
            return "Page index \(index) appears more than once in the requested order."
        case let .invalidPageRange(lowerBound, upperBound, pageCount):
            return "Page range \(lowerBound)...\(upperBound) is outside 0..<\(pageCount)."
        case let .overlappingPageRange(range):
            return "Page range \(range.lowerBound)...\(range.upperBound) overlaps an earlier split range."
        case .sourceDocumentLocked:
            return "The PDF to merge is password-protected and needs a valid password."
        case .sourceDocumentInvalid:
            return "The PDF to merge could not be opened."
        case .pageCopyFailed:
            return "The editor could not make an isolated copy of a PDF page."
        case .pageMutationFailed:
            return "The PDF page operation could not be saved and verified safely."
        case .exportFailed:
            return "The edited PDF could not be exported."
        case .passwordRemovalFailed:
            return "The unlocked PDF could not be exported without password protection."
        case .passwordProtectionFailed:
            return "The PDF could not be saved with the requested password protection."
        case .digitalSignatureConsentRequired:
            return "This PDF contains a digital signature. Editing it will invalidate that signature. Confirm this before making changes."
        }
    }
}

nonisolated protocol PDFEditingSession: AnyObject {
    /// The immutable bytes supplied when the session was created. Commands never mutate this data.
    var originalData: Data { get }
    var metadata: PDFDocumentMetadata { get }

    func unlock(withPassword password: String) throws
    func apply(_ command: PDFEditingCommand) throws -> PDFEditingCommandResult
    func dataRepresentation(options: PDFExportOptions) throws -> Data
}

nonisolated protocol PDFEditingEngine: AnyObject {
    func makeSession(data: Data, password: String?) throws -> any PDFEditingSession
}
