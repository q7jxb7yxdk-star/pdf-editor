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
    let fillsWindowOnAttach: Bool

    @MainActor
    private static let filledWindows = NSHashTable<NSWindow>.weakObjects()

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onWindowAttached = { [weak view] window in
            window.tabbingMode = .preferred
            guard fillsWindowOnAttach else { return }
            let shouldFillWindow = !Self.filledWindows.contains(window)
            if shouldFillWindow {
                Self.filledWindows.add(window)
            }
            view?.whenWindowBecomesKey { [weak window] _ in
                Task { @MainActor in
                    await Task.yield()
                    guard let window,
                          window.isKeyWindow,
                          window.attachedSheet == nil,
                          NSApp.modalWindow == nil else { return }
                    if shouldFillWindow, !window.isZoomed {
                        fill(window)
                    }
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

    private func fill(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: false)
    }
}

final class WindowAttachmentView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var tabBarObservers: [NSObjectProtocol] = []
    private var isTabBarUpdateScheduled = false

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
        hideNewTabButton(in: window)
        scheduleTabBarUpdate(in: window)

        let center = NotificationCenter.default
        tabBarObservers = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification
        ].map { name in
            center.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.scheduleTabBarUpdate(in: window)
                }
            }
        }
    }

    private func scheduleTabBarUpdate(in window: NSWindow) {
        guard !isTabBarUpdateScheduled else { return }
        isTabBarUpdateScheduled = true
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self else { return }
            self.isTabBarUpdateScheduled = false
            guard let window, self.window === window else { return }
            self.hideNewTabButton(in: window)
        }
    }

    private func hideNewTabButton(in window: NSWindow) {
        guard let titlebarRootView = window.contentView?.superview else { return }
        hideNewTabButton(in: titlebarRootView)
    }

    private func hideNewTabButton(in view: NSView) {
        if view.accessibilityRole() == .tabGroup {
            for case let button as NSButton in view.subviews where !button.isHidden {
                button.isHidden = true
            }
        }
        view.subviews.forEach(hideNewTabButton(in:))
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
        isTabBarUpdateScheduled = false
    }

    deinit {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
        }
        tabBarObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif
