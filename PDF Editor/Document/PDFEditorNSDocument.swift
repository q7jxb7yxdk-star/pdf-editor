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
            WindowConfigurationView(fillsWindowOnAttach: fileURL != nil)
        }
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask.formUnion([
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ])
        window.tabbingMode = .preferred
        window.setContentSize(NSSize(width: 1100, height: 760))
        addWindowController(NSWindowController(window: window))
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
                ) { [weak self] error in
                    Task { @MainActor in
                        guard let self else {
                            completionHandler(error)
                            return
                        }
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
final class PDFEditorApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        guard NSDocumentController.shared.documents.isEmpty else { return }
        DispatchQueue.main.async {
            guard NSDocumentController.shared.documents.isEmpty else { return }
            NSDocumentController.shared.openDocument(nil)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
#endif
