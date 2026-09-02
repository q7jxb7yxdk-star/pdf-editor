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
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var relocationError: Error?

            coordinator.coordinate(
                writingItemAt: importSourceURL,
                options: .forMoving,
                error: &coordinationError
            ) { coordinatedSourceURL in
                coordinator.item(at: coordinatedSourceURL, willMoveTo: destinationURL)
                do {
                    try fileManager.moveItem(
                        at: coordinatedSourceURL,
                        to: destinationURL
                    )
                    coordinator.item(
                        at: coordinatedSourceURL,
                        didMoveTo: destinationURL
                    )
                } catch {
                    relocationError = error
                }
            }

            if let relocationError {
                throw relocationError
            }
            if let coordinationError {
                throw coordinationError
            }
        } else {
            try write(data, to: destinationURL)
        }

        return destinationURL
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
