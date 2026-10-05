#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct IOSDocumentBrowserRootView: View {
    @State private var controller = IOSDocumentBrowserController()

    var body: some View {
        IOSDocumentBrowserContainer(controller: controller)
            .ignoresSafeArea()
            .onOpenURL { url in
                controller.revealAndOpenDocument(at: url)
            }
    }
}

private struct IOSDocumentOpenRequest {
    let url: URL
    let needsReveal: Bool
}

private struct IOSDocumentBrowserContainer: UIViewControllerRepresentable {
    let controller: IOSDocumentBrowserController

    func makeCoordinator() -> IOSDocumentBrowserController {
        controller
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentBrowserViewController {
        context.coordinator.organizeInboxIfNeeded()
        return context.coordinator.browserViewController
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentBrowserViewController,
        context: Context
    ) {
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
    private var inboxOrganizationTask: Task<Void, Never>?
    private var inboxClearTask: Task<Void, Never>?
    private var isClearingInbox = false
    private var didOrganizeInbox = false
    private var isOrganizingInbox = false
    private var inboxRelocations: [URL: URL] = [:]
    private var pendingCreationDirectories: Set<URL> = []
    private var currentOpenRequest: IOSDocumentOpenRequest?
    private var pendingOpenRequest: IOSDocumentOpenRequest?
    private var isClosingDocument = false
    private var closeCompletions: [() -> Void] = []
    private var isShutDown = false
    private lazy var clearInboxButton = UIBarButtonItem(
        title: "Clear Inbox",
        style: .plain,
        target: self,
        action: #selector(confirmClearInbox)
    )

    override init() {
        browserViewController = UIDocumentBrowserViewController(forOpening: [.pdf])
        super.init()

        browserViewController.delegate = self
        browserViewController.allowsDocumentCreation = true
        browserViewController.allowsPickingMultipleItems = false
        browserViewController.localizedCreateDocumentActionTitle = "Create Document"
        browserViewController.defaultDocumentAspectRatio = 1 / sqrt(2)
        browserViewController.additionalTrailingNavigationBarButtonItems = [clearInboxButton]
    }

    func shutdown() {
        isShutDown = true
        pendingOpenRequest = nil
        closeCompletions.removeAll()
        openingTask?.cancel()
        inboxOrganizationTask?.cancel()
        inboxClearTask?.cancel()
        updateInboxClearButton()
        activeNavigationController?.dismiss(animated: false)
        releaseActiveDocument()
        for directoryURL in pendingCreationDirectories {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        pendingCreationDirectories.removeAll()
    }

    func revealAndOpenDocument(at url: URL) {
        enqueueOpenDocument(at: url, needsReveal: true)
    }

    func organizeInboxIfNeeded() {
        guard !isShutDown, !didOrganizeInbox else { return }
        didOrganizeInbox = true
        isOrganizingInbox = true
        updateInboxClearButton()
        inboxOrganizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.inboxRelocations = try await ManualPDFSaveCoordinator.organizeInboxOnIOS()
            } catch {
                // Keep failed Inbox items available for a later startup retry.
            }
            self.inboxOrganizationTask = nil
            self.isOrganizingInbox = false
            self.updateInboxClearButton()
            guard !self.isShutDown else { return }
            self.processNextOpenRequest()
        }
    }

    private var canClearInbox: Bool {
        !isShutDown && !isOrganizingInbox && !isClearingInbox && !isClosingDocument &&
            currentOpenRequest == nil && pendingOpenRequest == nil &&
            activeNavigationController == nil
    }

    private func updateInboxClearButton() {
        clearInboxButton.isEnabled = canClearInbox
        clearInboxButton.title = isClearingInbox ? "Clearing…" : "Clear Inbox"
    }

    @objc private func confirmClearInbox() {
        guard canClearInbox, browserViewController.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Clear Inbox?",
            message: "Permanently delete all files and folders in Inbox, including files that have not been imported? Documents outside Inbox will be kept.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete All", style: .destructive) { [weak self] _ in
            self?.browserViewController.dismiss(animated: false) { [weak self] in
                self?.clearInbox()
            }
        })
        browserViewController.present(alert, animated: true)
    }

    private func clearInbox() {
        guard canClearInbox else { return }
        isClearingInbox = true
        updateInboxClearButton()
        inboxClearTask = Task { [weak self] in
            guard let self else { return }
            let title: String
            let message: String
            do {
                let result = try await ManualPDFSaveCoordinator.clearInboxOnIOS()
                title = result.failures.isEmpty ? "Inbox Cleared" : "Inbox Partially Cleared"
                message = result.failures.isEmpty
                    ? "Deleted \(result.removedCount) Inbox items."
                    : "Deleted \(result.removedCount) Inbox items. Unable to delete:\n" +
                        result.failures.joined(separator: "\n")
            } catch {
                title = "Unable to Clear Inbox"
                message = error.localizedDescription
            }
            self.inboxClearTask = nil
            self.isClearingInbox = false
            self.updateInboxClearButton()
            guard !self.isShutDown else { return }
            if self.pendingOpenRequest != nil {
                self.processNextOpenRequest()
            } else {
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.browserViewController.present(alert, animated: true)
            }
        }
    }

    private func enqueueOpenDocument(at url: URL, needsReveal: Bool) {
        guard !isShutDown else { return }
        let request = IOSDocumentOpenRequest(
            url: url.standardizedFileURL,
            needsReveal: needsReveal
        )
        // Both SwiftUI hosts may receive the same external URL event. Coalesce
        // only requests still in flight; sharing the same file again later works.
        if needsReveal,
           (currentOpenRequest?.needsReveal == true && currentOpenRequest?.url == request.url
            || pendingOpenRequest?.needsReveal == true && pendingOpenRequest?.url == request.url) {
            return
        }
        pendingOpenRequest = request
        updateInboxClearButton()
        processNextOpenRequest()
    }

    private func processNextOpenRequest() {
        guard !isShutDown, !isOrganizingInbox, !isClearingInbox,
              currentOpenRequest == nil else { return }
        // An external URL may arrive before the SwiftUI browser is mounted.
        guard didOrganizeInbox else {
            organizeInboxIfNeeded()
            return
        }
        guard let request = pendingOpenRequest else { return }
        pendingOpenRequest = nil
        currentOpenRequest = request
        updateInboxClearButton()
        closeActiveDocument { [weak self] in
            guard let self, !self.isShutDown else { return }
            if request.needsReveal {
                self.revealDocument(for: request)
            } else {
                let relocatedURL = self.inboxRelocations[
                    request.url.standardizedFileURL.resolvingSymlinksInPath()
                ]
                let url = FileManager.default.fileExists(atPath: request.url.path)
                    ? request.url
                    : relocatedURL ?? request.url
                self.readDocument(at: url)
            }
        }
    }

    private func revealDocument(for request: IOSDocumentOpenRequest) {
        let relocatedURL = inboxRelocations[
            request.url.standardizedFileURL.resolvingSymlinksInPath()
        ]
        openingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Consume our own Inbox delivery before the browser can copy
                // it. Deleting the visible document then frees its name for
                // the next share instead of leaving a hidden naming conflict.
                let url = try await Task.detached(priority: .userInitiated) {
                    // Startup organization may already have moved this delivery
                    // before its URL event reached the browser. A newly delivered
                    // file at a reused Inbox path always takes precedence.
                    let sourceURL = FileManager.default.fileExists(atPath: request.url.path)
                        ? request.url
                        : relocatedURL ?? request.url
                    return try ManualPDFSaveCoordinator.adoptInboxDocumentIfNeeded(
                        from: sourceURL
                    ) ?? sourceURL
                }.value
                try Task.checkCancellation()
                guard !self.isShutDown else { return }
                let revealedURL = try await self.browserViewController.revealDocument(
                    at: url,
                    importIfNeeded: true
                )
                try Task.checkCancellation()
                self.openingTask = nil
                guard !self.isShutDown else { return }
                self.readDocument(at: revealedURL)
            } catch {
                self.openingTask = nil
                guard !self.isShutDown else { return }
                self.failOpenRequest(error)
            }
        }
    }

    private func finishOpenRequest() {
        currentOpenRequest = nil
        updateInboxClearButton()
        processNextOpenRequest()
    }

    private func failOpenRequest(_ error: Error) {
        // A newer request takes precedence over an error from the previous one.
        if pendingOpenRequest == nil {
            present(error)
        }
        finishOpenRequest()
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didPickDocumentsAt documentURLs: [URL]
    ) {
        guard let documentURL = documentURLs.first else { return }
        enqueueOpenDocument(at: documentURL, needsReveal: false)
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
        // revealDocument's completion owns external imports and opens their
        // revealed URL. Do not also open them through the import delegate.
        guard currentOpenRequest?.needsReveal != true else { return }
        enqueueOpenDocument(at: destinationURL, needsReveal: false)
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        failedToImportDocumentAt documentURL: URL,
        error: Error?
    ) {
        removeCreationDirectory(containing: documentURL)
        // The reveal completion reports external import failures. Presenting an
        // alert here as well could interfere with the next document transition.
        guard currentOpenRequest?.needsReveal != true else {
            return
        }
        present(error ?? CocoaError(.fileWriteUnknown))
    }

    private func readDocument(at url: URL) {
        guard !isShutDown else { return }
        if pendingOpenRequest != nil {
            finishOpenRequest()
            return
        }
        let standardizedURL = url.standardizedFileURL
        let usesSecurityScope = standardizedURL.startAccessingSecurityScopedResource()

        openingTask = Task { [weak self] in
            guard let self else {
                if usesSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
                return
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try IOSDocumentFileReader.readData(at: standardizedURL)
                }.value
                try Task.checkCancellation()
                let document = try PDFEditorDocument(data: data)
                self.openingTask = nil
                if self.pendingOpenRequest != nil {
                    if usesSecurityScope {
                        standardizedURL.stopAccessingSecurityScopedResource()
                    }
                    self.finishOpenRequest()
                    return
                }
                self.presentEditor(
                    document: document,
                    url: standardizedURL,
                    usesSecurityScope: usesSecurityScope
                )
            } catch is CancellationError {
                if usesSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
                self.openingTask = nil
                self.finishOpenRequest()
            } catch {
                if usesSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
                self.openingTask = nil
                guard !self.isShutDown else { return }
                self.failOpenRequest(error)
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
        let hostingController = UIHostingController(
            rootView: editorView.onOpenURL { [weak self] url in
                self?.revealAndOpenDocument(at: url)
            }
        )
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
        browserViewController.present(navigationController, animated: false) { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.finishOpenRequest()
        }
    }

    private func closeActiveDocument(completion: (() -> Void)? = nil) {
        if let completion {
            closeCompletions.append(completion)
        }
        guard !isClosingDocument else { return }
        // Dismiss from the browser so any editor sheets/alerts are removed with
        // the old editor. Also clears an open-error alert before another request.
        guard browserViewController.presentedViewController != nil else {
            releaseActiveDocument()
            finishClosingDocument()
            return
        }
        isClosingDocument = true
        browserViewController.dismiss(animated: false) { [weak self] in
            guard let self else { return }
            self.releaseActiveDocument()
            self.finishClosingDocument()
        }
    }

    private func finishClosingDocument() {
        isClosingDocument = false
        let completions = closeCompletions
        closeCompletions.removeAll()
        guard !isShutDown else { return }
        completions.forEach { $0() }
    }

    private func releaseActiveDocument() {
        if activeDocumentUsesSecurityScope, let activeDocumentURL {
            activeDocumentURL.stopAccessingSecurityScopedResource()
        }
        activeNavigationController = nil
        activeDocumentURL = nil
        activeDocumentUsesSecurityScope = false
        updateInboxClearButton()
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
