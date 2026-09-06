import SwiftUI

#if os(iOS)
import UIKit

struct NativePDFExportPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let sourceURL: URL?
    let onCompletion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.onCompletion = onCompletion
        context.coordinator.presentIfNeeded(from: viewController, sourceURL: sourceURL)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var isPresented: Binding<Bool>
        var onCompletion: (Result<URL, Error>) -> Void
        private var isPresenting = false
        private var didComplete = false

        init(
            isPresented: Binding<Bool>,
            onCompletion: @escaping (Result<URL, Error>) -> Void
        ) {
            self.isPresented = isPresented
            self.onCompletion = onCompletion
        }

        func presentIfNeeded(from host: UIViewController, sourceURL: URL?) {
            guard isPresented.wrappedValue, !isPresenting, let sourceURL else { return }
            isPresenting = true
            didComplete = false
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host else { return }
                let picker = UIDocumentPickerViewController(
                    forExporting: [sourceURL],
                    asCopy: true
                )
                picker.delegate = self
                host.present(picker, animated: true)
            }
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
            isPresenting = false
            isPresented.wrappedValue = false
            onCompletion(result)
        }
    }
}
#endif
