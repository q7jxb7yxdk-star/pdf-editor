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
    var body: some Scene {
        DocumentGroup(newDocument: { PDFEditorDocument() }) { configuration in
            ContentView(
                document: configuration.document,
                fileURL: configuration.fileURL
            )
#if os(macOS)
                .background {
                    if configuration.fileURL != nil {
                        FillWindowView()
                    }
                }
#endif
        }
#if os(macOS)
        .commands {
            ManualPDFSaveCommands()
        }
#endif
    }
}

#if os(macOS)
private struct FillWindowView: NSViewRepresentable {
    @MainActor
    private static let filledWindows = NSHashTable<NSWindow>.weakObjects()

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onWindowAttached = { window in
            guard !Self.filledWindows.contains(window) else { return }
            Self.filledWindows.add(window)
            guard !window.isZoomed else { return }
            fill(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}

    private func fill(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: false)
    }
}

private final class WindowAttachmentView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAttached?(window)
        }
    }
}
#endif
