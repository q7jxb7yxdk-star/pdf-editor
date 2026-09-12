import SwiftUI
import UniformTypeIdentifiers

struct PDFDigitalSigningView: View {
    let fieldName: String
    let onSign: @MainActor (Data, String, String?) async throws -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var containerData: Data?
    @State private var containerName = ""
    @State private var password = ""
    @State private var reason = ""
    @State private var reviewedCertificate: PDFSigningCertificateSummary?
    @State private var showsContainerImporter = false
    @State private var isSigning = false
    @State private var errorMessage: String?

    private static let containerTypes: [UTType] = {
        let types = ["p12", "pfx"].compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
        return types.isEmpty ? [.data] : types
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Signature field") {
                    LabeledContent("Field", value: fieldName)
                }

                Section("Digital identity") {
                    Button {
                        showsContainerImporter = true
                    } label: {
                        Label(
                            containerName.isEmpty ? "Choose .p12 or .pfx" : containerName,
                            systemImage: "person.text.rectangle"
                        )
                    }
                    SecureField("Certificate password", text: $password)
                        .textContentType(.password)
                        .onChange(of: password) { _, _ in
                            reviewedCertificate = nil
                        }
                }

                if let certificate = reviewedCertificate {
                    Section("Certificate") {
                        LabeledContent("Signer", value: certificate.signerName)
                        LabeledContent("Algorithm", value: certificate.algorithm)
                        LabeledContent(
                            "Valid",
                            value: "\(certificate.validFrom.formatted(date: .abbreviated, time: .omitted)) - \(certificate.validUntil.formatted(date: .abbreviated, time: .omitted))"
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHA-256 fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(certificate.fingerprintSHA256)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Optional") {
                    TextField("Reason for signing", text: $reason)
                }

                Section {
                    Text("The certificate and private key are used only for this signing operation and are not stored by PDF Editor. After signing, Save As creates a signed copy. Editing that copy later invalidates its signature.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Digitally Sign PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clearSensitiveState()
                        onCancel()
                        dismiss()
                    }
                    .disabled(isSigning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reviewedCertificate == nil ? "Review Certificate" : "Sign") {
                        primaryAction()
                    }
                    .disabled(containerData == nil || password.isEmpty || isSigning)
                }
            }
            .overlay {
                if isSigning {
                    ZStack {
                        Color.black.opacity(0.08).ignoresSafeArea()
                        ProgressView("Applying digital signature…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 390)
        .fileImporter(
            isPresented: $showsContainerImporter,
            allowedContentTypes: Self.containerTypes
        ) { result in
            importContainer(result)
        }
        .alert("Unable to Digitally Sign", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func importContainer(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            containerData = try Data(contentsOf: url, options: .mappedIfSafe)
            containerName = url.lastPathComponent
            password = ""
            reviewedCertificate = nil
            errorMessage = nil
        } catch {
            if !Self.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func primaryAction() {
        guard let containerData, !password.isEmpty else { return }
        if reviewedCertificate == nil {
            do {
                reviewedCertificate = try PDFSigningIdentityService.load(
                    pkcs12: containerData,
                    password: password
                ).summary
                errorMessage = nil
            } catch {
                password = ""
                reviewedCertificate = nil
                errorMessage = error.localizedDescription
            }
            return
        }
        let signingPassword = password
        let signingReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        isSigning = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onSign(
                    containerData,
                    signingPassword,
                    signingReason.isEmpty ? nil : signingReason
                )
                clearSensitiveState()
                dismiss()
            } catch {
                password = ""
                reviewedCertificate = nil
                isSigning = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearSensitiveState() {
        containerData = nil
        password = ""
        reason = ""
        reviewedCertificate = nil
        isSigning = false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}
