#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PDFEditorNativeSavePreparation {
    let data: Data
    let commit: @MainActor (URL) async throws -> Void
}

@MainActor
final class PDFEditorNativeDocumentReference {
    weak var document: PDFEditorNSDocument?

    init(_ document: PDFEditorNSDocument) {
        self.document = document
    }
}

private final class PDFEditorDocumentWindow: NSWindow {
    override func addTabbedWindow(
        _ window: NSWindow,
        ordered: NSWindow.OrderingMode
    ) {
        super.addTabbedWindow(window, ordered: ordered)
        PDFEditorWindowTabBar.hideNewTabButton(in: self)
    }
}

@objc(PDFEditorNSDocument)
final class PDFEditorNSDocument: NSDocument {
    nonisolated override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }

    private(set) var editorDocument = PDFEditorDocument()
    private var preparedWriteData: Data?

    var prepareSave: (@MainActor () async throws -> PDFEditorNativeSavePreparation)?
    var saveActivityDidChange: (@MainActor (Bool) -> Void)?

    override init() {
        super.init()
        hasUndoManager = true
    }

    override func makeWindowControllers() {
        let documentReference = PDFEditorNativeDocumentReference(self)
        let rootView = ContentView(
            document: editorDocument,
            fileURL: fileURL,
            nativeDocumentReference: documentReference
        )
        .background {
            WindowConfigurationView(postsInitialConfigurationWhenReady: fileURL != nil)
        }
        let hostingController = NSHostingController(rootView: rootView)
        // The resizable document window controls its size; SwiftUI content
        // must not impose its measured minimum, ideal, or maximum dimensions.
        hostingController.sizingOptions = []
        let window = PDFEditorDocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        if fileURL != nil, let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false, animate: false)
        } else {
            window.setContentSize(NSSize(width: 1100, height: 760))
        }
        // Give SwiftUI the configured window size before it installs its
        // toolbar and evaluates the compact layout's Tools sheet.
        window.contentViewController = hostingController
        if fileURL != nil, let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false, animate: false)
        } else {
            window.setContentSize(NSSize(width: 1100, height: 760))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        addWindowController(NSWindowController(window: window))
        window.isRestorable = false

        if let existingWindow = existingDocumentWindow(excluding: window) {
            existingWindow.addTabbedWindow(window, ordered: .above)
            PDFEditorWindowTabBar.hideNewTabButton(in: existingWindow)
        } else {
            PDFEditorWindowTabBar.hideNewTabButton(in: window)
        }
    }

    private func existingDocumentWindow(
        excluding window: NSWindow
    ) -> PDFEditorDocumentWindow? {
        let candidates = NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap(\.window)
            .compactMap { $0 as? PDFEditorDocumentWindow }
            .filter { $0 !== window }

        return candidates.first { $0 === NSApp.mainWindow }
            ?? candidates.first(where: \.isVisible)
            ?? candidates.first
    }

    nonisolated override func read(
        from data: Data,
        ofType typeName: String
    ) throws {
        try MainActor.assumeIsolated {
            editorDocument = try PDFEditorDocument(data: data)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        if let preparedWriteData {
            return preparedWriteData
        }
        return try editorDocument.dataForManualSave()
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let prepareSave else {
            super.save(
                to: url,
                ofType: typeName,
                for: saveOperation,
                completionHandler: completionHandler
            )
            return
        }

        saveActivityDidChange?(true)
        Task { @MainActor in
            do {
                let preparation = try await prepareSave()
                preparedWriteData = preparation.data
                super.save(
                    to: url,
                    ofType: typeName,
                    for: saveOperation
                ) { [self] error in
                    Task { @MainActor in
                        self.preparedWriteData = nil
                        if let error {
                            self.saveActivityDidChange?(false)
                            completionHandler(error)
                            return
                        }
                        do {
                            try await preparation.commit(url)
                            self.saveActivityDidChange?(false)
                            completionHandler(nil)
                        } catch {
                            self.saveActivityDidChange?(false)
                            completionHandler(error)
                        }
                    }
                }
            } catch {
                preparedWriteData = nil
                saveActivityDidChange?(false)
                completionHandler(error)
            }
        }
    }

    func synchronizeEditedState(_ hasUnsavedChanges: Bool) {
        guard hasUnsavedChanges != isDocumentEdited else { return }
        updateChangeCount(hasUnsavedChanges ? .changeDone : .changeCleared)
    }
}

@MainActor
final class PDFEditorDocumentController: NSDocumentController {
    private(set) var didReceiveExplicitOpenRequest = false

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        didReceiveExplicitOpenRequest = true
        super.openDocument(
            withContentsOf: url,
            display: displayDocument,
            completionHandler: completionHandler
        )
    }

    override func reopenDocument(
        for urlOrNil: URL?,
        withContentsOf contentsURL: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        completionHandler(nil, false, nil)
    }
}

@MainActor
final class PDFEditorApplicationDelegate: NSObject, NSApplicationDelegate {
    private var documentController: PDFEditorDocumentController?
    private var didScheduleInitialOpenPanel = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Document windows are grouped explicitly with addTabbedWindow.
        NSWindow.allowsAutomaticWindowTabbing = false
        documentController = PDFEditorDocumentController()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleInitialOpenPanelIfNeeded()
    }

    private func scheduleInitialOpenPanelIfNeeded() {
        guard !didScheduleInitialOpenPanel,
              documentController?.didReceiveExplicitOpenRequest != true,
              NSDocumentController.shared.documents.isEmpty else { return }
        didScheduleInitialOpenPanel = true
        DispatchQueue.main.async { [weak self] in
            guard self?.documentController?.didReceiveExplicitOpenRequest != true else {
                return
            }
            guard NSDocumentController.shared.documents.isEmpty else { return }
            NSDocumentController.shared.openDocument(nil)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        let hasVisibleOpenPanel = sender.windows.contains { window in
            window is NSOpenPanel && window.isVisible
        }
        guard !hasVisibleOpenPanel, !hasVisibleWindows else { return false }

        let documents = NSDocumentController.shared.documents
        if documents.isEmpty {
            NSDocumentController.shared.openDocument(nil)
        } else {
            documents.forEach { $0.showWindows() }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
#endif
