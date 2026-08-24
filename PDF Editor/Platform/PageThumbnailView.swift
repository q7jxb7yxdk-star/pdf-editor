import PDFKit
import SwiftUI

struct PageThumbnailView: View {
    let page: PDFPage
    let pageNumber: Int

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 180)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            Text("Page \(pageNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var thumbnail: Image {
        let image = page.thumbnail(
            of: CGSize(width: 280, height: 360),
            for: .cropBox
        )

        #if os(macOS)
        return Image(nsImage: image)
        #else
        return Image(uiImage: image)
        #endif
    }
}
