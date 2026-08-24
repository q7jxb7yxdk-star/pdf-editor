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
            ContentView(document: configuration.document)
#if os(macOS)
                .background {
                    if configuration.fileURL != nil {
                        FillWindowView()
                    }
                }
#endif
        }
    }
}

#if os(macOS)
private struct FillWindowView: NSViewRepresentable {
    final class Coordinator {
        var didFillWindow = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onWindowAttached = { [weak coordinator = context.coordinator] window in
            guard let coordinator, !coordinator.didFillWindow else { return }
            coordinator.didFillWindow = true
            if !window.isZoomed {
                window.performZoom(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}
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
