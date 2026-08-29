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
            let originalFontData = try? objectSession.fontData(
                pageIndex: currentObject.pageIndex,
                path: currentObject.path
            )

            if PDFPageResourceIntegrityService.requiresAppearanceSafeTextReplacement(
                data: workingData,
                pageIndex: currentObject.pageIndex
            ) {
                workingData = try addAppearanceSafeReplacement(
                    replacement.text,
                    object: currentObject,
                    originalFontData: originalFontData ?? nil,
                    style: replacement.style,
                    pageObjects: pageObjects,
                    data: workingData,
                    password: password
                )
                results.append(.usedAppearanceSafeAnnotationFallback(
                    originalFontName: currentObject.fontName
                ))
                continue
            }

            do {
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
            } catch PDFObjectEditingError.pageAppearanceWouldChange {
                workingData = try addAppearanceSafeReplacement(
                    replacement.text,
                    object: currentObject,
                    originalFontData: originalFontData ?? nil,
                    style: replacement.style,
                    pageObjects: pageObjects,
                    data: workingData,
                    password: password
                )
                results.append(.usedAppearanceSafeAnnotationFallback(
                    originalFontName: currentObject.fontName
                ))
            }
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

    private static func addAppearanceSafeReplacement(
        _ text: String,
        object: PDFPageObjectSnapshot,
        originalFontData: Data?,
        style: PDFTextStyle,
        pageObjects: [PDFPageObjectSnapshot],
        data: Data,
        password: String?
    ) throws -> Data {
        guard let document = PDFDocument(data: data) else {
            throw PDFEditingError.invalidDocument
        }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw PDFEditingError.invalidPassword
            }
        }
        guard let page = document.page(at: object.pageIndex) else {
            throw PDFEditingError.invalidPageIndex(
                index: object.pageIndex,
                pageCount: document.pageCount
            )
        }

        let service = PDFAnnotationService()
        let annotation = try service.addAppearanceSafeTextReplacement(
            text: text,
            replacing: object,
            originalFontData: originalFontData,
            style: style,
            minimumBottomY: minimumReplacementBottomY(
                for: object,
                among: pageObjects
            ),
            to: page
        )
        guard let candidateData = document.dataRepresentation(),
              PDFPageResourceIntegrityService.preservesPageResources(
                from: data,
                to: candidateData,
                pageIndex: object.pageIndex
              ),
              let reopened = PDFDocument(data: candidateData) else {
            throw PDFObjectEditingError.pageAppearanceWouldChange
        }
        let reference = PDFAnnotationReference(
            pageIndex: object.pageIndex,
            annotationIndex: page.annotations.firstIndex(of: annotation) ?? 0
        )
        try service.verify(
            service.snapshot(for: reference, in: document),
            in: reopened
        )
        return candidateData
    }

    private static func minimumReplacementBottomY(
        for object: PDFPageObjectSnapshot,
        among objects: [PDFPageObjectSnapshot]
    ) -> CGFloat? {
        let horizontalTolerance = max(object.bounds.height * 0.25, 1)
        let nearestTop = objects.lazy
            .filter { candidate in
                candidate.path != object.path &&
                    candidate.bounds.maxY <= object.bounds.minY + 0.1 &&
                    candidate.bounds.maxX > object.bounds.minX + horizontalTolerance &&
                    candidate.bounds.minX < object.bounds.maxX - horizontalTolerance
            }
            .map(\.bounds.maxY)
            .max()
        return nearestTop.map { $0 + 0.5 }
    }
}
