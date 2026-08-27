import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A single image payload for SwiftUI's file exporter. Its type is selected per instance.
struct ImageExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png, .jpeg]
    static let writableContentTypes: [UTType] = [.png, .jpeg]

    let data: Data
    let contentType: UTType
    let filename: String?

    init(data: Data, contentType: UTType, filename: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
    }

    init(output: PDFPageImageExportOutput) {
        self.init(data: output.data, contentType: output.contentType, filename: output.filename)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
        filename = configuration.file.preferredFilename
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        return wrapper
    }
}
