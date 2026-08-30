import Foundation
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
