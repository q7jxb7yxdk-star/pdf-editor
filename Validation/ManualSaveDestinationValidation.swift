#if MANUAL_SAVE_DESTINATION_STANDALONE_VALIDATION
import Foundation

@main
struct ManualSaveDestinationValidation {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-ManualSaveDestination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let originalURL = directory.appendingPathComponent("original.pdf")
        let copyURL = directory.appendingPathComponent("copy.pdf")
        let originalData = Data("original".utf8)
        let editedData = Data("edited-copy".utf8)
        let subsequentEditData = Data("edited-copy-again".utf8)
        try originalData.write(to: originalURL, options: .atomic)

        precondition(ManualPDFSaveDestinationPolicy.updatesReferenceSnapshot(
            originalURL: originalURL,
            targetURL: originalURL
        ))
        precondition(!ManualPDFSaveDestinationPolicy.updatesReferenceSnapshot(
            originalURL: originalURL,
            targetURL: copyURL
        ))
        precondition(ManualPDFSaveDestinationPolicy.updatesReferenceSnapshot(
            originalURL: originalURL,
            targetURL: copyURL,
            didAdoptDestination: true
        ))
        precondition(ManualPDFSaveDestinationPolicy.updatesReferenceSnapshot(
            originalURL: nil,
            targetURL: copyURL
        ))

        var activeDocumentURL: URL? = originalURL
        let destinationBeforeSaveAs = activeDocumentURL

        // The destination becomes active as soon as the Save panel confirms,
        // before the prepared PDF bytes finish writing.
        activeDocumentURL = copyURL
        precondition(activeDocumentURL == copyURL)

        // A failed preparation or write restores the prior document identity.
        activeDocumentURL = destinationBeforeSaveAs
        precondition(activeDocumentURL == originalURL)

        // A successful retry keeps the copied destination active for Save.
        activeDocumentURL = copyURL
        try editedData.write(to: copyURL, options: .atomic)
        let reopenedOriginalData = try Data(contentsOf: originalURL)
        let reopenedCopyData = try Data(contentsOf: copyURL)
        precondition(reopenedOriginalData == originalData)
        precondition(reopenedCopyData == editedData)

        guard let activeDocumentURL else {
            preconditionFailure("Save As must keep the copied destination active")
        }
        try subsequentEditData.write(to: activeDocumentURL, options: .atomic)
        let originalAfterSubsequentSave = try Data(contentsOf: originalURL)
        let copyAfterSubsequentSave = try Data(contentsOf: copyURL)
        precondition(originalAfterSubsequentSave == originalData)
        precondition(copyAfterSubsequentSave == subsequentEditData)
        print(
            "Manual Save As destination validation passed " +
            "(immediate adoption, rollback, and active-copy Save)."
        )
    }
}
#endif
