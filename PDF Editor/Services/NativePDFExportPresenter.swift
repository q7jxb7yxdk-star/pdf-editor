import SwiftUI

#if os(iOS)
import UIKit

struct NativePDFExportPresenter: UIViewControllerRepresentable {
    let sourceURL: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forExporting: [sourceURL],
            asCopy: true
        )
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ viewController: UIDocumentPickerViewController,
        context: Context
    ) {
        context.coordinator.onCompletion = onCompletion
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onCompletion: (Result<URL, Error>) -> Void
        private var didComplete = false

        init(onCompletion: @escaping (Result<URL, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                finish(.failure(CocoaError(.fileWriteUnknown)))
                return
            }
            finish(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.failure(CocoaError(.userCancelled)))
        }

        private func finish(_ result: Result<URL, Error>) {
            guard !didComplete else { return }
            didComplete = true
            onCompletion(result)
        }
    }
}
#endif
