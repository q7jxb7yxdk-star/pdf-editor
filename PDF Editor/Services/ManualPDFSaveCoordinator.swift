import Foundation
import SwiftUI

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

extension FocusedValues {
    var manualPDFSaveAction: (() -> Void)? {
        get { self[ManualPDFSaveActionKey.self] }
        set { self[ManualPDFSaveActionKey.self] = newValue }
    }
}

#if os(macOS)
struct ManualPDFSaveCommands: Commands {
    @FocusedValue(\.manualPDFSaveAction) private var saveAction

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                saveAction?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveAction == nil)
        }
    }
}
#endif
