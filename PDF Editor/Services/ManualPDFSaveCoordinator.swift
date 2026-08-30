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
    static func write(_ data: Data, to url: URL) throws {
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
