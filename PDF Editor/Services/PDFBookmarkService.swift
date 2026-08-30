import PDFKit

enum PDFBookmarkServiceError: Error, LocalizedError {
    case invalidTitle
    case invalidPageIndex
    case bookmarkNotFound
    case roundTripVerificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "Enter a name for the bookmark."
        case .invalidPageIndex:
            return "The bookmark page is no longer available."
        case .bookmarkNotFound:
            return "The bookmark could not be found. Refresh the list and try again."
        case .roundTripVerificationFailed:
            return "The PDF bookmark change did not pass round-trip verification."
        }
    }
}

enum PDFBookmarkDataStage: String {
    case incremental = "incremental update"
    case rewrite = "PDFKit fallback rewrite"
    case exportAfterIncremental = "PDFium export after incremental update"
    case exportAfterRewrite = "PDFium export after PDFKit fallback rewrite"
}

struct PDFBookmarkDataDiagnostics {
    let stage: PDFBookmarkDataStage
    let sourceByteCount: Int
    let candidateByteCount: Int?
    let expectedFieldCount: Int

    // Only structural counts: never include PDF contents, titles, field values,
    // passwords, file paths or document metadata in the error message.
    var summary: String {
        let candidateSize = candidateByteCount.map { String($0) } ?? "unavailable"
        return " Stage: \(stage.rawValue). Source bytes: \(sourceByteCount)." +
            " Candidate bytes: \(candidateSize). Expected form fields: \(expectedFieldCount)."
    }
}

enum PDFBookmarkMutationError: Error, LocalizedError {
    case sourcePDFiumExportFailed
    case sourcePDFKitOpenFailed
    case updatedPDFiumOpenFailed(code: UInt32?, diagnostics: PDFBookmarkDataDiagnostics)
    case updatedPDFKitOpenFailed(diagnostics: PDFBookmarkDataDiagnostics)
    case fallbackRewriteFailed(diagnostics: PDFBookmarkDataDiagnostics)
    case updatedPDFiumExportFailed(diagnostics: PDFBookmarkDataDiagnostics)

    var errorDescription: String? {
        switch self {
        case .sourcePDFiumExportFailed:
            "PDFium could not prepare the PDF data for a bookmark change."
        case .sourcePDFKitOpenFailed:
            "PDFKit could not inspect the PDF data prepared for a bookmark change."
        case let .updatedPDFiumOpenFailed(code, diagnostics):
            "PDFium could not open the bookmark data." +
                diagnostics.summary + Self.pdfiumDiagnostic(code)
        case let .updatedPDFKitOpenFailed(diagnostics):
            "PDFKit could not open the bookmark data." + diagnostics.summary
        case let .fallbackRewriteFailed(diagnostics):
            "PDFKit could not produce the fallback bookmark data." + diagnostics.summary
        case let .updatedPDFiumExportFailed(diagnostics):
            "PDFium could not export the bookmark data for verification." + diagnostics.summary
        }
    }

    private static func pdfiumDiagnostic(_ code: UInt32?) -> String {
        guard let code else { return " PDFium returned no stable error code."
        }
        let category = switch code {
        case 0: "success"
        case 1: "unknown"
        case 2: "file access"
        case 3: "invalid or corrupted PDF format"
        case 4: "password required or incorrect"
        case 5: "unsupported security scheme"
        case 6: "page or page-content error"
        case 7: "XFA load error"
        case 8: "XFA layout error"
        default: "unrecognized"
        }
        return " PDFium error \(code): \(category)."
    }
}

struct PDFBookmarkService {
    func snapshots(in document: PDFDocument) -> [PDFBookmarkSnapshot] {
        guard let root = document.outlineRoot else { return [] }
        return snapshots(in: root, document: document, parentPath: [])
    }

    /// Install only the verified outline, retaining the displayed document,
    /// pages and annotations. Never attach an outline whose destinations still
    /// reference pages owned by the temporary verification document.
    func synchronizeOutline(from source: PDFDocument, to target: PDFDocument) throws {
        guard source.pageCount == target.pageCount else {
            throw PDFBookmarkServiceError.roundTripVerificationFailed
        }
        let expected = snapshots(in: source)
        let replacement = try source.outlineRoot.map {
            try copyOutline($0, from: source, to: target)
        } ?? PDFOutline()
        let previousRoot = target.outlineRoot
        // Build the full replacement before touching the live document. An
        // empty root also avoids PDFKit retaining a deleted final bookmark.
        target.outlineRoot = replacement
        guard snapshots(in: target) == expected else {
            target.outlineRoot = previousRoot ?? PDFOutline()
            throw PDFBookmarkServiceError.roundTripVerificationFailed
        }
    }

    private func copyOutline(
        _ outline: PDFOutline,
        from source: PDFDocument,
        to target: PDFDocument
    ) throws -> PDFOutline {
        let copy = PDFOutline()
        copy.label = outline.label
        if let action = outline.action as? PDFActionGoTo {
            copy.action = PDFActionGoTo(destination: try copyDestination(
                action.destination, from: source, to: target
            ))
        } else if let action = outline.action {
            guard let copiedAction = action.copy() as? PDFAction else {
                throw PDFBookmarkServiceError.roundTripVerificationFailed
            }
            copy.action = copiedAction
        } else if let destination = outline.destination {
            copy.destination = try copyDestination(destination, from: source, to: target)
        }
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else {
                throw PDFBookmarkServiceError.roundTripVerificationFailed
            }
            copy.insertChild(try copyOutline(child, from: source, to: target), at: index)
        }
        copy.isOpen = outline.isOpen
        return copy
    }

    private func copyDestination(
        _ destination: PDFDestination,
        from source: PDFDocument,
        to target: PDFDocument
    ) throws -> PDFDestination {
        guard let sourcePage = destination.page else {
            throw PDFBookmarkServiceError.invalidPageIndex
        }
        let pageIndex = source.index(for: sourcePage)
        guard pageIndex != NSNotFound, let page = target.page(at: pageIndex) else {
            throw PDFBookmarkServiceError.invalidPageIndex
        }
        let copy = PDFDestination(page: page, at: destination.point)
        copy.zoom = destination.zoom
        return copy
    }

    func addBookmark(
        title: String,
        pageIndex: Int,
        to document: PDFDocument
    ) throws {
        let title = try validatedTitle(title)
        guard let page = document.page(at: pageIndex) else {
            throw PDFBookmarkServiceError.invalidPageIndex
        }

        let root: PDFOutline
        if let existingRoot = document.outlineRoot {
            root = existingRoot
        } else {
            root = PDFOutline()
            document.outlineRoot = root
        }

        let bookmark = PDFOutline()
        bookmark.label = title
        let bounds = page.bounds(for: .cropBox)
        bookmark.destination = PDFDestination(
            page: page,
            at: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        root.insertChild(bookmark, at: root.numberOfChildren)
    }

    func renameBookmark(
        at path: PDFBookmarkPath,
        title: String,
        in document: PDFDocument
    ) throws {
        let bookmark = try outline(at: path, in: document)
        bookmark.label = try validatedTitle(title)
    }

    func deleteBookmark(
        at path: PDFBookmarkPath,
        in document: PDFDocument
    ) throws {
        if path.indices.count == 1,
           path.indices[0] == 0,
           document.outlineRoot?.numberOfChildren == 1 {
            // PDFKit can retain the old outline when nil is assigned to a
            // reopened incremental document. Replacing it with an empty root
            // gives the writer an unambiguous empty tree.
            document.outlineRoot = PDFOutline()
            return
        }
        let bookmark = try outline(at: path, in: document)
        bookmark.removeFromParent()
        if document.outlineRoot?.numberOfChildren == 0 {
            document.outlineRoot = PDFOutline()
        }
    }

    private func snapshots(
        in parent: PDFOutline,
        document: PDFDocument,
        parentPath: [Int]
    ) -> [PDFBookmarkSnapshot] {
        (0..<parent.numberOfChildren).compactMap { index in
            guard let child = parent.child(at: index) else { return nil }
            let path = parentPath + [index]
            return PDFBookmarkSnapshot(
                path: PDFBookmarkPath(indices: path),
                title: normalizedDisplayTitle(child.label),
                pageIndex: pageIndex(for: child, fallbackDocument: document),
                children: snapshots(
                    in: child,
                    document: document,
                    parentPath: path
                )
            )
        }
    }

    private func pageIndex(
        for outline: PDFOutline,
        fallbackDocument: PDFDocument
    ) -> Int? {
        guard let page = outline.destination?.page else { return nil }
        let owner = outline.document ?? fallbackDocument
        let index = owner.index(for: page)
        guard index != NSNotFound else { return nil }
        return index
    }

    private func outline(
        at path: PDFBookmarkPath,
        in document: PDFDocument
    ) throws -> PDFOutline {
        guard !path.indices.isEmpty, var current = document.outlineRoot else {
            throw PDFBookmarkServiceError.bookmarkNotFound
        }
        for index in path.indices {
            guard index >= 0,
                  index < current.numberOfChildren,
                  let child = current.child(at: index) else {
                throw PDFBookmarkServiceError.bookmarkNotFound
            }
            current = child
        }
        return current
    }

    private func validatedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PDFBookmarkServiceError.invalidTitle
        }
        return trimmed
    }

    private func normalizedDisplayTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled Bookmark" : trimmed
    }
}
