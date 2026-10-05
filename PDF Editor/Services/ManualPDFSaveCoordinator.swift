import Foundation
import Combine
import SwiftUI

#if os(macOS)
import AppKit
#endif

nonisolated enum ManualPDFSaveDestinationPolicy {
    static func updatesReferenceSnapshot(
        originalURL: URL?,
        targetURL: URL,
        didAdoptDestination: Bool = false
    ) -> Bool {
        if didAdoptDestination {
            return true
        }
        // A new untitled document has no existing file that could be
        // overwritten. Existing documents advance their ReferenceFileDocument
        // snapshot only when saving back to that same original URL.
        guard let originalURL else { return true }
        return originalURL.standardizedFileURL.resolvingSymlinksInPath() ==
            targetURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

enum ManualPDFSaveCoordinator {
#if os(iOS)
    // NSFileCoordinator may synchronously wait for a Files provider (for
    // example, iCloud Drive). Keep that wait off Swift's cooperative executor
    // and serialize writes so a document cannot be coordinated concurrently.
    nonisolated private static let iOSExistingDocumentWriteQueue = DispatchQueue(
        label: "com.sunnyyu.PDFEditor.existing-document-write"
    )

    nonisolated static func writeExistingDocumentOnIOS(
        _ data: Data,
        to url: URL
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            iOSExistingDocumentWriteQueue.async {
                do {
                    try write(data, to: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static func organizeInboxOnIOS() async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[URL: URL], Error>) in
            iOSExistingDocumentWriteQueue.async {
                do {
                    continuation.resume(returning: try organizeInbox())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated struct InboxClearResult: Sendable {
        let removedCount: Int
        let failures: [String]
    }

    nonisolated static func clearInboxOnIOS() async throws -> InboxClearResult {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<InboxClearResult, Error>) in
            iOSExistingDocumentWriteQueue.async {
                do {
                    continuation.resume(returning: try clearInbox())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func clearInbox() throws -> InboxClearResult {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL.resolvingSymlinksInPath()
        let inboxURL = documentsURL.appendingPathComponent("Inbox", isDirectory: true)
        guard fileManager.fileExists(atPath: inboxURL.path) else {
            return InboxClearResult(removedCount: 0, failures: [])
        }
        // Do not follow a substituted Inbox symlink into another directory.
        guard inboxURL.resolvingSymlinksInPath() == inboxURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Snapshot all entries, including hidden files and directories. New
        // deliveries arriving after this snapshot are left for their import.
        let entries = try fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removedCount = 0
        var failures: [String] = []
        for entryURL in entries {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var deletionError: Error?
            var removed = false
            coordinator.coordinate(
                writingItemAt: entryURL,
                options: .forDeleting,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    guard coordinatedURL.standardizedFileURL.deletingLastPathComponent()
                        .resolvingSymlinksInPath() == inboxURL else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    // removeItem also removes a directory's contents, but
                    // deleting a symlink removes the link rather than its target.
                    try fileManager.removeItem(at: coordinatedURL)
                    removed = true
                } catch {
                    deletionError = error
                }
            }
            if removed {
                removedCount += 1
            } else {
                let error: Error = deletionError ?? coordinationError ?? CocoaError(.fileWriteUnknown)
                failures.append(entryURL.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return InboxClearResult(removedCount: removedCount, failures: failures)
    }

    nonisolated private static func organizeInbox() throws -> [URL: URL] {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL.resolvingSymlinksInPath()
        let inboxURL = documentsURL.appendingPathComponent("Inbox", isDirectory: true)
        guard fileManager.fileExists(atPath: inboxURL.path) else { return [:] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        func pdfFiles(in directory: URL) throws -> [URL] {
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: .skipsHiddenFiles
            ).filter { url in
                guard url.pathExtension.lowercased() == "pdf",
                      let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
        }

        // Process original names before numbered variants so an identical
        // family without a visible copy keeps its original name where possible.
        let inboxFiles = try pdfFiles(in: inboxURL).sorted { lhs, rhs in
            let lhsIsNumbered = basenameWithoutImportSuffix(
                lhs.deletingPathExtension().lastPathComponent
            ) != nil
            let rhsIsNumbered = basenameWithoutImportSuffix(
                rhs.deletingPathExtension().lastPathComponent
            ) != nil
            if lhsIsNumbered != rhsIsNumbered { return !lhsIsNumbered }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        var visibleFiles = try pdfFiles(in: documentsURL)
        var relocations: [URL: URL] = [:]
        for sourceURL in inboxFiles {
            do {
                let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                var duplicateDestination: URL?
                for visibleURL in visibleFiles {
                    let sourceBasename = sourceURL.deletingPathExtension().lastPathComponent
                    let visibleBasename = visibleURL.deletingPathExtension().lastPathComponent
                    let sourceOriginal = basenameWithoutImportSuffix(sourceBasename)
                    let visibleOriginal = basenameWithoutImportSuffix(visibleBasename)
                    // Preserve distinct document names, even if their bytes
                    // happen to match. Only deduplicate the same name family.
                    let sameNameFamily = sourceBasename == visibleBasename ||
                        sourceOriginal == visibleBasename || visibleOriginal == sourceBasename ||
                        (sourceOriginal != nil && sourceOriginal == visibleOriginal)
                    guard sameNameFamily, let sourceSize,
                          let values = try? visibleURL.resourceValues(forKeys: [.fileSizeKey]),
                          values.fileSize == sourceSize else { continue }
                    // Size only filters candidates. Deletion requires a fresh,
                    // coordinated byte comparison with the visible saved file.
                    if removeIdenticalInboxDuplicate(at: sourceURL, savedAt: visibleURL) {
                        duplicateDestination = visibleURL
                        break
                    }
                }
                if let duplicateDestination {
                    relocations[sourceURL.standardizedFileURL] = duplicateDestination
                    continue
                }
                let destinationURL = availableImportDestination(
                    for: sourceURL,
                    in: documentsURL,
                    fileManager: fileManager
                )
                try relocateInboxDocument(from: sourceURL, to: destinationURL)
                relocations[sourceURL.standardizedFileURL] = destinationURL
                visibleFiles.append(destinationURL)
            } catch {
                // Keep any failed source in Inbox and continue with other PDFs.
            }
        }
        return relocations
    }

    nonisolated static func adoptInboxDocumentIfNeeded(
        from sourceURL: URL
    ) throws -> URL? {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL.resolvingSymlinksInPath()
        let inboxURL = documentsURL.appendingPathComponent("Inbox", isDirectory: true)
        let standardizedSourceURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        // Only relocate deliveries inside this app's Inbox. Provider URLs and
        // documents already stored elsewhere retain their existing behavior.
        guard standardizedSourceURL.deletingLastPathComponent() == inboxURL else {
            return nil
        }
        let recoveredSourceURL = recoverOriginalInboxName(
            for: standardizedSourceURL,
            in: documentsURL,
            fileManager: fileManager
        )
        // A numeric suffix alone is not evidence of an import collision.
        // Recovery requires an identical original Inbox file and a free name.
        let destinationURL = availableImportDestination(
            for: recoveredSourceURL ?? standardizedSourceURL,
            in: documentsURL,
            fileManager: fileManager
        )
        let duplicateURLs = recoveredSourceURL.map {
            matchingInboxNameFamily(for: $0, fileManager: fileManager)
        } ?? []
        try relocateInboxDocument(from: standardizedSourceURL, to: destinationURL)
        // Cleanup is limited to the recovered name family present before the
        // move. Each file is compared again with the saved copy before deletion.
        for duplicateURL in duplicateURLs where duplicateURL != standardizedSourceURL {
            removeIdenticalInboxDuplicate(at: duplicateURL, savedAt: destinationURL)
        }
        return destinationURL
    }

    nonisolated private static func basenameWithoutImportSuffix(_ basename: String) -> String? {
        guard let separator = basename.lastIndex(of: "-") else { return nil }
        let suffix = basename[basename.index(after: separator)...]
        guard !suffix.isEmpty,
              suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              suffix.contains(where: { $0 != "0" }) else { return nil }
        let original = String(basename[..<separator])
        return original.isEmpty ? nil : original
    }

    nonisolated private static func recoverOriginalInboxName(
        for sourceURL: URL,
        in documentsURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let originalBasename = basenameWithoutImportSuffix(
            sourceURL.deletingPathExtension().lastPathComponent
        ) else { return nil }
        let originalFilename = sourceURL.pathExtension.isEmpty
            ? originalBasename
            : originalBasename + "." + sourceURL.pathExtension
        let originalInboxURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(originalFilename)
        let originalDestinationURL = documentsURL.appendingPathComponent(originalFilename)
        guard !fileManager.fileExists(atPath: originalDestinationURL.path) else { return nil }

        guard let originalValues = try? originalInboxURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), originalValues.isRegularFile == true, originalValues.isSymbolicLink != true,
              let sourceData = coordinatedInboxContents(at: sourceURL),
              let originalData = coordinatedInboxContents(at: originalInboxURL),
              sourceData == originalData else { return nil }
        return originalInboxURL
    }

    nonisolated private static func coordinatedInboxContents(at url: URL) -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var data: Data?
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            data = try? Data(contentsOf: coordinatedURL)
        }
        return coordinationError == nil ? data : nil
    }

    nonisolated private static func matchingInboxNameFamily(
        for originalURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let originalBasename = originalURL.deletingPathExtension().lastPathComponent
        let inboxURL = originalURL.deletingLastPathComponent()
        let entries = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
        return entries.filter { candidate in
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            let basename = candidate.deletingPathExtension().lastPathComponent
            return candidate.pathExtension == originalURL.pathExtension &&
                (basename == originalBasename ||
                 basenameWithoutImportSuffix(basename) == originalBasename)
        }
    }

    @discardableResult
    nonisolated private static func removeIdenticalInboxDuplicate(
        at duplicateURL: URL,
        savedAt destinationURL: URL
    ) -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var removed = false
        coordinator.coordinate(
            readingItemAt: destinationURL,
            options: [],
            writingItemAt: duplicateURL,
            options: .forDeleting,
            error: nil
        ) { coordinatedDestinationURL, coordinatedDuplicateURL in
            do {
                let values = try coordinatedDuplicateURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                let savedValues = try coordinatedDestinationURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      savedValues.isRegularFile == true, savedValues.isSymbolicLink != true else { return }
                let savedData = try Data(contentsOf: coordinatedDestinationURL)
                let duplicateData = try Data(contentsOf: coordinatedDuplicateURL)
                guard savedData == duplicateData else { return }
                try FileManager.default.removeItem(at: coordinatedDuplicateURL)
                removed = true
            } catch {
                // Leave the duplicate in Inbox if it cannot be read or removed.
            }
        }
        // A failed cleanup must not invalidate a successfully imported PDF.
        return removed
    }

    nonisolated static func adoptImportedDocumentIfNeeded(
        from sourceURL: URL,
        data: Data
    ) throws -> URL? {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL
        let inboxURL = documentsURL
            .appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let sourceParentURL = standardizedSourceURL.deletingLastPathComponent()
        let isInboxDocument = sourceParentURL == inboxURL
        let isInsideDocuments = standardizedSourceURL.pathComponents.starts(
            with: documentsURL.pathComponents
        )

        guard isInboxDocument || !isInsideDocuments else {
            return nil
        }

        let inboxCandidateURL = inboxURL.appendingPathComponent(
            standardizedSourceURL.lastPathComponent
        )
        let matchingInboxURL = !isInboxDocument &&
            contents(at: inboxCandidateURL, match: data)
            ? inboxCandidateURL
            : nil
        let importSourceURL = matchingInboxURL ?? standardizedSourceURL
        let relocatesInboxDocument = isInboxDocument || matchingInboxURL != nil
        let destinationURL = availableImportDestination(
            for: importSourceURL,
            in: documentsURL,
            fileManager: fileManager
        )
        if relocatesInboxDocument {
            try relocateInboxDocument(from: importSourceURL, to: destinationURL)
        } else {
            try write(data, to: destinationURL)
        }

        return destinationURL
    }


    nonisolated private static func relocateInboxDocument(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var relocationError: Error?

        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: [],
            error: &coordinationError
        ) { coordinatedSourceURL, coordinatedDestinationURL in
            coordinator.item(at: coordinatedSourceURL, willMoveTo: coordinatedDestinationURL)
            do {
                // moveItem fails if the destination appeared during coordination;
                // never replace another document to preserve an incoming name.
                try FileManager.default.moveItem(
                    at: coordinatedSourceURL,
                    to: coordinatedDestinationURL
                )
                coordinator.item(
                    at: coordinatedSourceURL,
                    didMoveTo: coordinatedDestinationURL
                )
            } catch {
                relocationError = error
            }
        }

        if let relocationError { throw relocationError }
        if let coordinationError { throw coordinationError }
    }

    nonisolated private static func contents(
        at candidateURL: URL,
        match data: Data
    ) -> Bool {
        guard let candidateData = try? Data(
            contentsOf: candidateURL,
            options: .mappedIfSafe
        ) else {
            return false
        }
        return candidateData == data
    }

    nonisolated private static func availableImportDestination(
        for sourceURL: URL,
        in documentsURL: URL,
        fileManager: FileManager
    ) -> URL {
        let basename = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension

        func destinationURL(suffix: String) -> URL {
            let destination = documentsURL.appendingPathComponent(basename + suffix)
            guard !pathExtension.isEmpty else { return destination }
            return destination.appendingPathExtension(pathExtension)
        }

        var destination = destinationURL(suffix: "")
        var duplicateIndex = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = destinationURL(suffix: "-\(duplicateIndex)")
            duplicateIndex += 1
        }
        return destination
    }
#endif

    nonisolated static func write(_ data: Data, to url: URL) throws {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writingError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writingError = error
            }
        }

        if let writingError {
            throw writingError
        }
        if let coordinationError {
            throw coordinationError
        }
    }
}

struct ManualPDFSaveActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ManualPDFSaveAsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var manualPDFSaveAction: (() -> Void)? {
        get { self[ManualPDFSaveActionKey.self] }
        set { self[ManualPDFSaveActionKey.self] = newValue }
    }

    var manualPDFSaveAsAction: (() -> Void)? {
        get { self[ManualPDFSaveAsActionKey.self] }
        set { self[ManualPDFSaveAsActionKey.self] = newValue }
    }
}

#if os(macOS)
@MainActor
final class RecentPDFDocuments: ObservableObject {
    @Published private(set) var urls: [URL] = []

    init() {
        refresh()
    }

    func refresh() {
        let documentController = NSDocumentController.shared
        let recentURLs = documentController.recentDocumentURLs
        let existingURLs = recentURLs.filter { url in
            !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
        }

        if existingURLs.count != recentURLs.count {
            documentController.clearRecentDocuments(nil)
            for url in existingURLs.reversed() {
                documentController.noteNewRecentDocumentURL(url)
            }
        }

        urls = documentController.recentDocumentURLs
    }

    func open(_ url: URL) {
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { [weak self] _, _, error in
            if let error {
                NSApp.presentError(error)
            }
            self?.refresh()
        }
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
}

private struct RecentPDFDocumentsMenu: View {
    @StateObject private var recentDocuments = RecentPDFDocuments()

    var body: some View {
        Group {
            if recentDocuments.urls.isEmpty {
                Button("No Recent Documents") {}
                    .disabled(true)
            } else {
                ForEach(recentDocuments.urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        recentDocuments.open(url)
                    }
                    .help(url.path(percentEncoded: false))
                }
            }

            Divider()

            Button("Clear Menu") {
                recentDocuments.clear()
            }
            .disabled(recentDocuments.urls.isEmpty)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSMenu.didBeginTrackingNotification
            )
        ) { _ in
            recentDocuments.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )
        ) { _ in
            recentDocuments.refresh()
        }
    }
}

struct VersionlessPDFDocumentCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                do {
                    try NSDocumentController.shared
                        .openUntitledDocumentAndDisplay(true)
                } catch {
                    NSApp.presentError(error)
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open…") {
                NSDocumentController.shared.openDocument(nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                RecentPDFDocumentsMenu()
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NSDocumentController.shared.currentDocument?.save(nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(NSDocumentController.shared.currentDocument == nil)

            Button("Save As…") {
                NSDocumentController.shared.currentDocument?.saveAs(nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(NSDocumentController.shared.currentDocument == nil)

            Button("Close") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
#endif
