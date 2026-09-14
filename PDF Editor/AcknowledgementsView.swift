import SwiftUI

struct PDFEditorAcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let noticeText: String = {
        guard let url = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "txt"
        ),
        let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party notices could not be loaded."
        }
        return text
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(Self.noticeText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Acknowledgements")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
#endif
    }
}
