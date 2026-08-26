import Foundation
import PDFKit

/// The first editing backend. It provides page-level operations only; it deliberately does not claim to rewrite
/// existing PDF text objects. A PDFium-backed session can conform to the same `PDFEditingSession` protocol later.
nonisolated final class PDFKitEditingEngine: PDFEditingEngine {
    func makeSession(data: Data, password: String? = nil) throws -> any PDFEditingSession {
        guard let document = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }

        if document.isLocked, let password, !document.unlock(withPassword: password) {
            throw PDFEditingError.invalidPassword
        }

        return PDFKitEditingSession(originalData: data, document: document)
    }
}

nonisolated final class PDFKitEditingSession: PDFEditingSession {
    let originalData: Data
    private var document: PDFDocument
    /// PDFKit pages retain their backing document weakly. Keep detached one-page sources alive for the session.
    private var retainedPageDocuments: [PDFDocument] = []

    init(originalData: Data, document: PDFDocument) {
        self.originalData = originalData
        self.document = document
    }

    var metadata: PDFDocumentMetadata {
        PDFDocumentMetadata(
            pageCount: document.pageCount,
            isEncrypted: document.isEncrypted,
            isLocked: document.isLocked,
            documentInfo: documentInfo
        )
    }

    func unlock(withPassword password: String) throws {
        guard document.isLocked else {
            return
        }

        guard document.unlock(withPassword: password) else {
            throw PDFEditingError.invalidPassword
        }
    }

    func apply(_ command: PDFEditingCommand) throws -> PDFEditingCommandResult {
        try requireUnlocked()

        switch command {
        case let .setDocumentInfo(info):
            try requirePermission(for: "document metadata changes", isAllowed: document.allowsDocumentChanges)
            setDocumentInfo(info)
            return .updated(metadata)

        case let .deletePage(index):
            try requirePageAssemblyPermission()
            try validatePageIndex(index)
            guard document.pageCount > 1 else {
                throw PDFEditingError.cannotDeleteLastPage
            }
            document.removePage(at: index)
            return .updated(metadata)

        case let .rotatePage(index, degrees):
            try requirePageAssemblyPermission()
            try validatePageIndex(index)
            guard degrees.isMultiple(of: 90) else {
                throw PDFEditingError.invalidRotation(degrees: degrees)
            }
            guard let page = document.page(at: index) else {
                throw PDFEditingError.invalidPageIndex(index: index, pageCount: document.pageCount)
            }
            page.rotation = normalizedRotation(page.rotation + degrees)
            return .updated(metadata)

        case let .movePage(sourceIndex, destinationIndex):
            try requirePageAssemblyPermission()
            try validatePageIndex(sourceIndex)
            try validatePageIndex(destinationIndex)
            try movePage(from: sourceIndex, to: destinationIndex)
            return .updated(metadata)

        case let .reorderPages(order):
            try requirePageAssemblyPermission()
            try reorderPages(order)
            return .updated(metadata)

        case let .merge(sourceData, password, index):
            try requirePageAssemblyPermission()
            try validateInsertionIndex(index)
            try merge(documentData: sourceData, password: password, at: index)
            return .updated(metadata)

        case let .split(ranges):
            return .split(documents: try split(ranges: ranges))
        }
    }

    func dataRepresentation(options: PDFExportOptions = PDFExportOptions()) throws -> Data {
        try requireUnlocked()

        let exportedData: Data?
        switch options.securityPolicy {
        case .preserve:
            exportedData = document.dataRepresentation()

        case .removeAfterAuthorizedUnlock:
            // PDFKit's direct data representation may retain the source encryption dictionary. Rebuilding a document
            // from unlocked pages produces an explicit unencrypted export, which is verified below.
            exportedData = try makeUnencryptedDocumentCopy().dataRepresentation()
        }

        guard let exportedData else {
            throw PDFEditingError.exportFailed
        }

        if options.securityPolicy == .removeAfterAuthorizedUnlock,
           PDFDocument(data: exportedData)?.isEncrypted != false {
            throw PDFEditingError.passwordRemovalFailed
        }

        return exportedData
    }

    private var documentInfo: PDFDocumentInfo {
        let attributes = document.documentAttributes ?? [:]
        return PDFDocumentInfo(
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
            creator: attributes[PDFDocumentAttribute.creatorAttribute] as? String,
            keywords: attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
            creationDate: attributes[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
    }

    private func setDocumentInfo(_ info: PDFDocumentInfo) {
        var attributes = document.documentAttributes ?? [:]
        set(info.title, for: .titleAttribute, in: &attributes)
        set(info.author, for: .authorAttribute, in: &attributes)
        set(info.subject, for: .subjectAttribute, in: &attributes)
        set(info.creator, for: .creatorAttribute, in: &attributes)
        set(info.keywords, for: .keywordsAttribute, in: &attributes)
        set(info.creationDate, for: .creationDateAttribute, in: &attributes)
        set(info.modificationDate, for: .modificationDateAttribute, in: &attributes)
        document.documentAttributes = attributes
    }

    private func set(_ value: Any?, for key: PDFDocumentAttribute, in attributes: inout [AnyHashable: Any]) {
        if let value {
            attributes[key] = value
        } else {
            attributes.removeValue(forKey: key)
        }
    }

    private func requireUnlocked() throws {
        guard !document.isLocked else {
            throw PDFEditingError.documentLocked
        }
    }

    private func requirePageAssemblyPermission() throws {
        try requirePermission(for: "page assembly", isAllowed: document.allowsDocumentAssembly)
    }

    private func requirePermission(for operation: String, isAllowed: Bool) throws {
        guard isAllowed else {
            throw PDFEditingError.documentPermissionDenied(operation: operation)
        }
    }

    private func validatePageIndex(_ index: Int) throws {
        guard document.pageCount > 0, (0..<document.pageCount).contains(index) else {
            throw PDFEditingError.invalidPageIndex(index: index, pageCount: document.pageCount)
        }
    }

    private func validateInsertionIndex(_ index: Int) throws {
        guard (0...document.pageCount).contains(index) else {
            throw PDFEditingError.invalidInsertionIndex(index: index, pageCount: document.pageCount)
        }
    }

    private func movePage(from sourceIndex: Int, to destinationIndex: Int) throws {
        guard sourceIndex != destinationIndex, let page = document.page(at: sourceIndex) else {
            return
        }

        let detachedPage = try makeDetachedPage(from: page)
        document.removePage(at: sourceIndex)
        document.insert(detachedPage, at: destinationIndex)
    }

    private func reorderPages(_ order: [Int]) throws {
        guard order.count == document.pageCount else {
            throw PDFEditingError.invalidPageOrder(
                expectedPageCount: document.pageCount,
                actualPageCount: order.count
            )
        }

        var seen = Set<Int>()
        for index in order {
            try validatePageIndex(index)
            guard seen.insert(index).inserted else {
                throw PDFEditingError.duplicatePageIndex(index: index)
            }
        }

        let reorderedDocument = PDFDocument()
        reorderedDocument.documentAttributes = document.documentAttributes
        for sourceIndex in order {
            guard let page = document.page(at: sourceIndex) else {
                throw PDFEditingError.invalidPageIndex(index: sourceIndex, pageCount: document.pageCount)
            }
            reorderedDocument.insert(try makeDetachedPage(from: page), at: reorderedDocument.pageCount)
        }
        document = reorderedDocument
    }

    private func merge(documentData: Data, password: String?, at insertionIndex: Int) throws {
        guard let sourceDocument = PDFDocument(data: documentData) else {
            throw PDFEditingError.sourceDocumentInvalid
        }

        if sourceDocument.isLocked {
            guard let password, sourceDocument.unlock(withPassword: password) else {
                throw PDFEditingError.sourceDocumentLocked
            }
        }

        var index = insertionIndex
        for sourceIndex in 0..<sourceDocument.pageCount {
            guard let page = sourceDocument.page(at: sourceIndex) else {
                throw PDFEditingError.sourceDocumentInvalid
            }
            document.insert(try makeDetachedPage(from: page), at: index)
            index += 1
        }
    }

    private func split(ranges: [PDFPageRange]) throws -> [Data] {
        guard !ranges.isEmpty else {
            return []
        }

        var coveredPageIndices = Set<Int>()
        for range in ranges {
            guard range.lowerBound >= 0,
                  range.upperBound >= range.lowerBound,
                  range.upperBound < document.pageCount else {
                throw PDFEditingError.invalidPageRange(
                    lowerBound: range.lowerBound,
                    upperBound: range.upperBound,
                    pageCount: document.pageCount
                )
            }

            for pageIndex in range.lowerBound...range.upperBound {
                guard coveredPageIndices.insert(pageIndex).inserted else {
                    throw PDFEditingError.overlappingPageRange(range)
                }
            }
        }

        return try ranges.map { range in
            let splitDocument = PDFDocument()
            splitDocument.documentAttributes = document.documentAttributes
            for pageIndex in range.lowerBound...range.upperBound {
                guard let page = document.page(at: pageIndex) else {
                    throw PDFEditingError.invalidPageIndex(index: pageIndex, pageCount: document.pageCount)
                }
                splitDocument.insert(try makeDetachedPage(from: page), at: splitDocument.pageCount)
            }
            guard let data = splitDocument.dataRepresentation() else {
                throw PDFEditingError.exportFailed
            }
            return data
        }
    }

    private func makeUnencryptedDocumentCopy() throws -> PDFDocument {
        let unencryptedDocument = PDFDocument()
        unencryptedDocument.documentAttributes = document.documentAttributes

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw PDFEditingError.invalidPageIndex(index: pageIndex, pageCount: document.pageCount)
            }
            unencryptedDocument.insert(try makeDetachedPage(from: page), at: unencryptedDocument.pageCount)
        }

        return unencryptedDocument
    }

    private func makeDetachedPage(from page: PDFPage) throws -> PDFPage {
        guard let pageData = page.dataRepresentation,
              let sourceDocument = PDFDocument(data: pageData),
              let detachedPage = sourceDocument.page(at: 0) else {
            throw PDFEditingError.pageCopyFailed
        }
        retainedPageDocuments.append(sourceDocument)
        return detachedPage
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        let normalized = rotation % 360
        return normalized >= 0 ? normalized : normalized + 360
    }
}
