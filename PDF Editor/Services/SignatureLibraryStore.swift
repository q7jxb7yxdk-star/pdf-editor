import Combine
import Foundation

@MainActor
final class SignatureLibraryStore: ObservableObject {
    @Published private(set) var templates: [SignatureLibraryTemplate] = []
    @Published private(set) var lastLoadError: String?

    let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            templates = []
            lastLoadError = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= SignatureLibraryLimits.maximumPayloadBytes else {
                throw SignatureLibraryError.payloadTooLarge
            }
            let decoded = try decoder.decode([SignatureLibraryTemplate].self, from: data)
            try validateLibrary(decoded)
            templates = decoded
            lastLoadError = nil
        } catch {
            templates = []
            lastLoadError = (error as? LocalizedError)?.errorDescription ?? "Could not load saved signatures."
        }
    }

    func add(_ template: SignatureLibraryTemplate) throws {
        load()
        var updated = templates
        updated.append(template)
        try validateLibrary(updated)
        try persist(updated)
        templates = updated
        lastLoadError = nil
    }

    func delete(id: UUID) throws {
        load()
        let updated = templates.filter { $0.id != id }
        guard updated.count != templates.count else { return }
        try persist(updated)
        templates = updated
        lastLoadError = nil
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return directory
            .appendingPathComponent("com.sunny.pdf-editor", isDirectory: true)
            .appendingPathComponent("signature-library.json", isDirectory: false)
    }

    private func validateLibrary(_ library: [SignatureLibraryTemplate]) throws {
        guard library.count <= SignatureLibraryLimits.maximumTemplates else {
            throw SignatureLibraryError.tooManyTemplates
        }
        var identifiers = Set<UUID>()
        for template in library {
            guard identifiers.insert(template.id).inserted else {
                throw SignatureLibraryError.duplicateTemplateIdentifier
            }
            try SignatureLibraryTemplate.validate(strokes: template.strokes)
        }
    }

    private func persist(_ library: [SignatureLibraryTemplate]) throws {
        let data = try encoder.encode(library)
        guard data.count <= SignatureLibraryLimits.maximumPayloadBytes else {
            throw SignatureLibraryError.payloadTooLarge
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}
