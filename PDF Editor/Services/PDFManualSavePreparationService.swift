import Foundation
import PDFKit

nonisolated struct PDFManualTextReplacement: Sendable {
    let object: PDFPageObjectSnapshot
    let text: String
    let style: PDFTextStyle
}

nonisolated struct PDFManualSavePreparation: Sendable {
    let originalData: Data
    let data: Data
    let replacementResults: [PDFTextReplacementResult]
    let openingPassword: String?
    let requiresInstallation: Bool
    let isSecurityOnlyPresentationUpdate: Bool
}

nonisolated enum PDFPasswordProtectionService {
    static func protect(
        data: Data,
        sourcePassword: String?,
        newPassword: String
    ) throws -> Data {
        guard !newPassword.isEmpty,
              let document = PDFDocument(data: data) else {
            throw PDFEditingError.passwordProtectionFailed
        }
        if document.isLocked {
            guard let sourcePassword,
                  document.unlock(withPassword: sourcePassword) else {
                throw PDFEditingError.passwordProtectionFailed
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-Protected-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: newPassword,
            .ownerPasswordOption: newPassword,
        ]
        guard document.write(to: outputURL, withOptions: options),
              let protectedData = try? Data(contentsOf: outputURL),
              let verificationDocument = PDFDocument(data: protectedData),
              verificationDocument.isEncrypted,
              verificationDocument.isLocked else {
            throw PDFEditingError.passwordProtectionFailed
        }

        var incorrectPassword = "PDFEditor-Verification-\(UUID().uuidString)"
        if incorrectPassword == newPassword {
            incorrectPassword.append("-Incorrect")
        }
        guard !verificationDocument.unlock(withPassword: incorrectPassword),
              verificationDocument.unlock(withPassword: newPassword) else {
            throw PDFEditingError.passwordProtectionFailed
        }
        return protectedData
    }
}

nonisolated enum PDFManualSavePreparationService {
    static func prepare(
        originalData: Data,
        password: String?,
        replacements: [PDFManualTextReplacement],
        fallbackFontData: Data,
        exportOptions: PDFExportOptions,
        protectionPassword: String? = nil
    ) throws -> PDFManualSavePreparation {
        var workingData = originalData
        var results: [PDFTextReplacementResult] = []

        for replacement in replacements {
            let session = try PDFiumEditingEngine().makeSession(
                data: workingData,
                password: password
            )
            guard let objectSession = session as? any PDFObjectEditingSession else {
                throw PDFObjectEditingError.objectMutationFailed
            }
            let pageObjects = try objectSession.objects(
                onPage: replacement.object.pageIndex
            )
            guard let currentObject = pageObjects.first(where: {
                $0.path == replacement.object.path
            }) else {
                throw PDFObjectEditingError.objectInspectionFailed
            }
            if PDFPageResourceIntegrityService.preventsSafePageContentRegeneration(
                data: workingData,
                pageIndex: currentObject.pageIndex
            ) {
                throw PDFObjectEditingError.pageAppearanceWouldChange
            }

            let result = try objectSession.replaceText(
                pageIndex: currentObject.pageIndex,
                path: currentObject.path,
                with: replacement.text,
                style: replacement.style,
                fallbackFontData: fallbackFontData
            )
            let candidateData = try session.dataRepresentation(
                options: PDFExportOptions()
            )
            guard PDFPageResourceIntegrityService.preservesPageResources(
                from: workingData,
                to: candidateData,
                pageIndex: currentObject.pageIndex
            ) else {
                throw PDFObjectEditingError.pageAppearanceWouldChange
            }
            workingData = candidateData
            results.append(result)
        }

        if exportOptions.securityPolicy != .preserve {
            let finalSession = try PDFiumEditingEngine().makeSession(
                data: workingData,
                password: password
            )
            workingData = try finalSession.dataRepresentation(options: exportOptions)
        }

        if let protectionPassword {
            workingData = try PDFPasswordProtectionService.protect(
                data: workingData,
                sourcePassword: password,
                newPassword: protectionPassword
            )
        }

        return PDFManualSavePreparation(
            originalData: originalData,
            data: workingData,
            replacementResults: results,
            openingPassword: protectionPassword ?? (
                exportOptions.securityPolicy == .removeAfterAuthorizedUnlock
                    ? nil
                    : password
            ),
            requiresInstallation: !replacements.isEmpty ||
                exportOptions.securityPolicy != .preserve ||
                protectionPassword != nil,
            isSecurityOnlyPresentationUpdate: replacements.isEmpty && (
                exportOptions.securityPolicy != .preserve ||
                    protectionPassword != nil
            )
        )
    }
}
