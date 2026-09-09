#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct IOSDocumentBrowserRootView: View {
    @State private var openRequest: IOSDocumentOpenRequest?

    var body: some View {
        IOSDocumentBrowserContainer(openRequest: openRequest)
            .ignoresSafeArea()
            .onOpenURL { url in
                openRequest = IOSDocumentOpenRequest(url: url)
            }
    }
}

fileprivate struct IOSDocumentOpenRequest: Equatable {
    let id = UUID()
    let url: URL
}

private struct IOSDocumentBrowserContainer: UIViewControllerRepresentable {
    let openRequest: IOSDocumentOpenRequest?

    func makeCoordinator() -> IOSDocumentBrowserController {
        IOSDocumentBrowserController()
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentBrowserViewController {
        context.coordinator.browserViewController
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentBrowserViewController,
        context: Context
    ) {
        guard let openRequest else { return }
        context.coordinator.handle(openRequest: openRequest)
    }

    static func dismantleUIViewController(
        _ uiViewController: UIDocumentBrowserViewController,
        coordinator: IOSDocumentBrowserController
    ) {
        coordinator.shutdown()
    }
}

@MainActor
final class IOSDocumentBrowserController: NSObject, UIDocumentBrowserViewControllerDelegate {
    let browserViewController: UIDocumentBrowserViewController

    private var activeNavigationController: UINavigationController?
    private var activeDocumentURL: URL?
    private var activeDocumentUsesSecurityScope = false
    private var openingTask: Task<Void, Never>?
    private var pendingCreationDirectories: Set<URL> = []
    private var lastHandledOpenRequestID: UUID?

    override init() {
        browserViewController = UIDocumentBrowserViewController(forOpening: [.pdf])
        super.init()

        browserViewController.delegate = self
        browserViewController.allowsDocumentCreation = true
        browserViewController.allowsPickingMultipleItems = false
        browserViewController.localizedCreateDocumentActionTitle = "Create Document"
        browserViewController.defaultDocumentAspectRatio = 1 / sqrt(2)
    }

    func shutdown() {
        openingTask?.cancel()
        activeNavigationController?.dismiss(animated: false)
        releaseActiveDocument()
        for directoryURL in pendingCreationDirectories {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        pendingCreationDirectories.removeAll()
    }

    fileprivate func handle(openRequest: IOSDocumentOpenRequest) {
        guard lastHandledOpenRequestID != openRequest.id else { return }
        lastHandledOpenRequestID = openRequest.id
        revealAndOpenDocument(at: openRequest.url)
    }

    func revealAndOpenDocument(at url: URL) {
        closeActiveDocument { [weak self] in
            guard let self else { return }
            self.browserViewController.revealDocument(
                at: url,
                importIfNeeded: true
            ) { [weak self] revealedURL, error in
                guard let self else { return }
                if let error {
                    self.present(error)
                    return
                }
                guard let revealedURL else {
                    self.present(CocoaError(.fileNoSuchFile))
                    return
                }
                self.openDocument(at: revealedURL)
            }
        }
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didPickDocumentsAt documentURLs: [URL]
    ) {
        guard let documentURL = documentURLs.first else { return }
        openDocument(at: documentURL)
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didRequestDocumentCreationWithHandler importHandler:
            @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let fileURL = directoryURL.appendingPathComponent("Untitled.pdf")

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let document = PDFEditorDocument()
            let data = try document.snapshot(contentType: .pdf)
            try data.write(to: fileURL, options: .atomic)
            pendingCreationDirectories.insert(directoryURL)
            importHandler(fileURL, .move)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            importHandler(nil, .none)
            present(error)
        }
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didImportDocumentAt sourceURL: URL,
        toDestinationURL destinationURL: URL
    ) {
        removeCreationDirectory(containing: sourceURL)
        openDocument(at: destinationURL)
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        failedToImportDocumentAt documentURL: URL,
        error: Error?
    ) {
        removeCreationDirectory(containing: documentURL)
        present(error ?? CocoaError(.fileWriteUnknown))
    }

    private func openDocument(at url: URL) {
        guard openingTask == nil else { return }
        if activeNavigationController != nil {
            closeActiveDocument { [weak self] in
                self?.openDocument(at: url)
            }
            return
        }

        let standardizedURL = url.standardizedFileURL
        let usesSecurityScope = standardizedURL.startAccessingSecurityScopedResource()

        openingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.openingTask = nil
            }

            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try IOSDocumentFileReader.readData(at: standardizedURL)
                }.value
                try Task.checkCancellation()

                let document = try PDFEditorDocument(data: data)
                self.presentEditor(
                    document: document,
                    url: standardizedURL,
                    usesSecurityScope: usesSecurityScope
                )
            } catch is CancellationError {
                if usesSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
            } catch {
                if usesSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
                self.present(error)
            }
        }
    }

    private func presentEditor(
        document: PDFEditorDocument,
        url: URL,
        usesSecurityScope: Bool
    ) {
        let editorView = ContentView(
            document: document,
            fileURL: url,
            onClose: { [weak self] in
                self?.closeActiveDocument()
            }
        )
        let hostingController = UIHostingController(rootView: editorView)
        let navigationController = UINavigationController(
            rootViewController: hostingController
        )
        navigationController.modalPresentationStyle = .fullScreen
        navigationController.isModalInPresentation = true
        if UIDevice.current.userInterfaceIdiom == .phone {
            navigationController.setNavigationBarHidden(true, animated: false)
        }

        activeNavigationController = navigationController
        activeDocumentURL = url
        activeDocumentUsesSecurityScope = usesSecurityScope
        browserViewController.present(navigationController, animated: false)
    }

    private func closeActiveDocument(completion: (() -> Void)? = nil) {
        guard let activeNavigationController else {
            completion?()
            return
        }

        activeNavigationController.dismiss(animated: false) { [weak self] in
            self?.releaseActiveDocument()
            completion?()
        }
    }

    private func releaseActiveDocument() {
        if activeDocumentUsesSecurityScope, let activeDocumentURL {
            activeDocumentURL.stopAccessingSecurityScopedResource()
        }
        activeNavigationController = nil
        activeDocumentURL = nil
        activeDocumentUsesSecurityScope = false
    }

    private func removeCreationDirectory(containing sourceURL: URL) {
        let directoryURL = sourceURL.deletingLastPathComponent().standardizedFileURL
        guard pendingCreationDirectories.remove(directoryURL) != nil else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func present(_ error: Error) {
        let alert = UIAlertController(
            title: "Unable to Open PDF",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let presenter = browserViewController.presentedViewController
            ?? browserViewController
        presenter.present(alert, animated: true)
    }
}

nonisolated private enum IOSDocumentFileReader {
    static func readData(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var data: Data?

        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let readError {
            throw readError
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let data else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }
}
#endif
