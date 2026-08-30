import Foundation

nonisolated struct PDFBookmarkPath: Hashable, Sendable {
    let indices: [Int]
}

nonisolated struct PDFBookmarkSnapshot: Equatable, Identifiable, Sendable {
    let path: PDFBookmarkPath
    var title: String
    let pageIndex: Int?
    let children: [PDFBookmarkSnapshot]

    var id: PDFBookmarkPath { path }

    var outlineChildren: [PDFBookmarkSnapshot]? {
        children.isEmpty ? nil : children
    }
}
