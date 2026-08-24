import SwiftUI
import UniformTypeIdentifiers

struct PDFExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data
    let filename: String?

    init(data: Data, filename: String? = nil) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        return wrapper
    }
}
