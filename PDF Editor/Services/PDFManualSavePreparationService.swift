import Foundation

nonisolated struct PDFManualTextReplacement: Sendable {
    let object: PDFPageObjectSnapshot
    let text: String
    let style: PDFTextStyle
}

nonisolated struct PDFManualSavePreparation: Sendable {
    let originalData: Data
    let data: Data
    let replacementResults: [PDFTextReplacementResult]
}

nonisolated enum PDFManualSavePreparationService {
    static func prepare(
        originalData: Data,
        password: String?,
        replacements: [PDFManualTextReplacement],
        fallbackFontData: Data,
        exportOptions: PDFExportOptions
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

        return PDFManualSavePreparation(
            originalData: originalData,
            data: workingData,
            replacementResults: results
        )
    }
}
