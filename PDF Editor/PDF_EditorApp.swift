//
//  PDF_EditorApp.swift
//  PDF Editor
//
//  Created by Sunny Yu on 12/8/2026.
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct PDF_EditorApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(PDFEditorApplicationDelegate.self)
    private var applicationDelegate
#endif

    @SceneBuilder
    var body: some Scene {
#if os(macOS)
        Settings {
            EmptyView()
        }
        .commands {
            VersionlessPDFDocumentCommands()
        }
#else
        DocumentGroup(newDocument: { PDFEditorDocument() }) { configuration in
            ContentView(
                document: configuration.document,
                fileURL: configuration.fileURL
            )
        }
#endif
    }
}

#if os(macOS)
struct WindowConfigurationView: NSViewRepresentable {
    let fillsWindowOnAttach: Bool

    @MainActor
    private static let filledWindows = NSHashTable<NSWindow>.weakObjects()

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onWindowAttached = { [weak view] window in
            window.tabbingMode = .preferred
            guard fillsWindowOnAttach else { return }
            guard !Self.filledWindows.contains(window) else { return }
            Self.filledWindows.add(window)
            view?.whenWindowBecomesKey { [weak window] _ in
                Task { @MainActor in
                    await Task.yield()
                    guard let window,
                          window.isKeyWindow,
                          window.attachedSheet == nil,
                          NSApp.modalWindow == nil,
                          !window.isZoomed else { return }
                    fill(window)
                    NSCursor.arrow.set()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}

    private func fill(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: false)
    }
}

final class WindowAttachmentView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAttached?(window)
        } else {
            removeWindowDidBecomeKeyObserver()
        }
    }

    func whenWindowBecomesKey(
        _ action: @escaping @MainActor @Sendable (NSWindow) -> Void
    ) {
        removeWindowDidBecomeKeyObserver()
        guard let window else { return }
        guard !window.isKeyWindow else {
            action(window)
            return
        }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                self?.removeWindowDidBecomeKeyObserver()
                guard let window else { return }
                action(window)
            }
        }
    }

    private func removeWindowDidBecomeKeyObserver() {
        guard let windowDidBecomeKeyObserver else { return }
        NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
        self.windowDidBecomeKeyObserver = nil
    }

    deinit {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
        }
    }
}
#endif
