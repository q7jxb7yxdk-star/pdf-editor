import CoreGraphics
import Foundation

@main
@MainActor
struct SignatureLibraryValidation {
    static func main() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signature-library-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent("signatures.json")

        let template = try SignatureLibraryTemplate(
            displayName: "  Signing name  ",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            normalizedStrokes: [[
                CGPoint(x: 0.1, y: 0.8),
                CGPoint(x: 0.5, y: 0.2),
                CGPoint(x: 0.9, y: 0.75),
            ]]
        )
        precondition(template.displayName == "Signing name")

        let pageBounds = CGRect(x: 20, y: 40, width: 300, height: 200)
        precondition(SignaturePlacementGeometry.bounds(
            centeredAt: CGPoint(x: 170, y: 140),
            pageBounds: pageBounds
        ) == CGRect(x: 70, y: 100, width: 200, height: 80))
        precondition(SignaturePlacementGeometry.bounds(
            centeredAt: CGPoint(x: 20, y: 40),
            pageBounds: pageBounds
        ) == CGRect(x: 20, y: 40, width: 200, height: 80))
        precondition(SignaturePlacementGeometry.bounds(
            centeredAt: CGPoint(x: 320, y: 240),
            pageBounds: pageBounds
        ) == CGRect(x: 120, y: 160, width: 200, height: 80))

        let store = SignatureLibraryStore(fileURL: fileURL)
        try store.add(template)
        precondition(store.templates == [template])

        let reloadedStore = SignatureLibraryStore(fileURL: fileURL)
        precondition(reloadedStore.templates == [template])
        precondition(reloadedStore.lastLoadError == nil)

        let secondTemplate = try SignatureLibraryTemplate(
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            normalizedStrokes: [[
                CGPoint(x: 0.05, y: 0.5),
                CGPoint(x: 0.95, y: 0.5),
            ]]
        )
        try reloadedStore.add(secondTemplate)
        precondition(reloadedStore.templates == [template, secondTemplate])
        let independentlyReloadedStore = SignatureLibraryStore(fileURL: fileURL)
        precondition(independentlyReloadedStore.templates == [template, secondTemplate])
        try independentlyReloadedStore.delete(id: template.id)
        precondition(independentlyReloadedStore.templates == [secondTemplate])

        try expect(SignatureLibraryError.invalidPoint) {
            _ = try SignatureLibraryTemplate(normalizedStrokes: [[
                CGPoint(x: -0.01, y: 0), CGPoint(x: 0.5, y: 0.5),
            ]])
        }
        try expect(SignatureLibraryError.strokeTooShort) {
            _ = try SignatureLibraryTemplate(normalizedStrokes: [[CGPoint(x: 0.5, y: 0.5)]])
        }
        try expect(SignatureLibraryError.tooManyPoints) {
            let points = (0...(SignatureLibraryLimits.maximumPointsPerStroke)).map { index in
                CGPoint(x: Double(index) / Double(SignatureLibraryLimits.maximumPointsPerStroke), y: 0.5)
            }
            _ = try SignatureLibraryTemplate(normalizedStrokes: [points])
        }
        try expect(SignatureLibraryError.tooManyStrokes) {
            let stroke = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
            _ = try SignatureLibraryTemplate(
                normalizedStrokes: Array(repeating: stroke, count: SignatureLibraryLimits.maximumStrokesPerTemplate + 1)
            )
        }

        try Data(repeating: 0, count: SignatureLibraryLimits.maximumPayloadBytes + 1)
            .write(to: fileURL, options: .atomic)
        let oversizedStore = SignatureLibraryStore(fileURL: fileURL)
        precondition(oversizedStore.templates.isEmpty)
        precondition(oversizedStore.lastLoadError != nil)

        try Data("not json".utf8).write(to: fileURL, options: .atomic)
        let corruptStore = SignatureLibraryStore(fileURL: fileURL)
        precondition(corruptStore.templates.isEmpty)
        precondition(corruptStore.lastLoadError != nil)

        let invalidPointJSON = """
        [{"id":"\(UUID().uuidString)","createdAt":"2023-11-14T22:13:20Z","strokes":[[{"x":1.1,"y":0.5},{"x":0.5,"y":0.5}]]}]
        """
        try Data(invalidPointJSON.utf8).write(to: fileURL, options: .atomic)
        let invalidPointStore = SignatureLibraryStore(fileURL: fileURL)
        precondition(invalidPointStore.templates.isEmpty)
        precondition(invalidPointStore.lastLoadError != nil)

        print("SignatureLibraryValidation passed")
    }

    private static func expect(
        _ expected: SignatureLibraryError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw ValidationError.expectedFailure(expected)
        } catch let error as SignatureLibraryError {
            guard error == expected else { throw error }
        }
    }
}

private enum ValidationError: Error {
    case expectedFailure(SignatureLibraryError)
}
