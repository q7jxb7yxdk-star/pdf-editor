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
extension Notification.Name {
    static let pdfEditorWindowDidFinishInitialConfiguration = Notification.Name(
        "PDFEditorWindowDidFinishInitialConfiguration"
    )
}

struct WindowConfigurationView: NSViewRepresentable {
    let postsInitialConfigurationWhenReady: Bool

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onWindowAttached = { [weak view] window in
            window.tabbingMode = .preferred
            guard postsInitialConfigurationWhenReady else { return }
            view?.whenWindowBecomesKey { [weak window] _ in
                Task { @MainActor in
                    await Task.yield()
                    guard let window,
                          window.isKeyWindow,
                          window.attachedSheet == nil,
                          NSApp.modalWindow == nil else { return }
                    await Task.yield()
                    NotificationCenter.default.post(
                        name: .pdfEditorWindowDidFinishInitialConfiguration,
                        object: window
                    )
                    NSCursor.arrow.set()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}
}

final class WindowAttachmentView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var tabBarObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            startHidingNewTabButton(in: window)
            onWindowAttached?(window)
        } else {
            removeWindowDidBecomeKeyObserver()
            removeTabBarObservers()
        }
    }

    private func startHidingNewTabButton(in window: NSWindow) {
        removeTabBarObservers()
        PDFEditorWindowTabBar.hideNewTabButton(in: window)

        let center = NotificationCenter.default
        tabBarObservers = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification
        ].map { name in
            center.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window else { return }
                    PDFEditorWindowTabBar.hideNewTabButton(in: window)
                }
            }
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

    private func removeTabBarObservers() {
        let center = NotificationCenter.default
        tabBarObservers.forEach(center.removeObserver)
        tabBarObservers.removeAll()
    }

    deinit {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
        }
        tabBarObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

@MainActor
enum PDFEditorWindowTabBar {
    static func hideNewTabButton(in window: NSWindow) {
        guard let titlebarRootView = window.contentView?.superview else { return }
        titlebarRootView.layoutSubtreeIfNeeded()
        hideNewTabButton(in: titlebarRootView)
    }

    private static func hideNewTabButton(in view: NSView) {
        if view.accessibilityRole() == .tabGroup {
            for case let button as NSButton in view.subviews where !button.isHidden {
                button.isHidden = true
            }
        }
        view.subviews.forEach(hideNewTabButton(in:))
    }
}
#endif
