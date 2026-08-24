import Foundation
import PDFKit

private func makePlainPDF() -> Data {
    let stream = "BT /F1 18 Tf 0 0 0 rg 1 0 0 1 72 700 Tm (Protected merge fixture) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
    ]

    var pdf = "%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n"
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xrefOffset = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() {
        pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
    pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
    return Data(pdf.utf8)
}

let outputURL = URL(fileURLWithPath: "/tmp/PDFEditor-Phase5-Protected.pdf")
guard let document = PDFDocument(data: makePlainPDF()) else {
    fatalError("Could not construct the source PDF")
}

let password = "phase5-test"
let options: [PDFDocumentWriteOption: Any] = [
    .userPasswordOption: password,
    .ownerPasswordOption: password,
]
guard document.write(to: outputURL, withOptions: options) else {
    fatalError("Could not write the protected fixture")
}

guard let protectedDocument = PDFDocument(url: outputURL),
      protectedDocument.isLocked,
      !protectedDocument.unlock(withPassword: "wrong-password"),
      protectedDocument.unlock(withPassword: password) else {
    fatalError("Protected fixture verification failed")
}

print(outputURL.path)
