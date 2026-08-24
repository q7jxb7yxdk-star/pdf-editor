import Foundation

private func makePDF(objects: [String]) -> Data {
    var pdf = "%PDF-1.4\n%âãÏÓ\n"
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

private func nestedFormPDF() -> Data {
    let outerStream = "q 1 0 0 1 10 20 cm /Inner Do Q"
    let pageStream = "q 1 0 0 1 72 600 cm /Outer Do Q q .5 0 0 .5 300 500 cm /Outer Do Q"
    let innerStream = "BT /F1 12 Tf 1 0 0 1 5 7 Tm (INNER) Tj ET"
    return makePDF(objects: [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Outer 5 0 R >> >> /Contents 6 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] /Resources << /XObject << /Inner 7 0 R >> >> /Length \(outerStream.utf8.count) >>\nstream\n\(outerStream)\nendstream",
        "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 100 40] /Resources << /Font << /F1 4 0 R >> >> /Length \(innerStream.utf8.count) >>\nstream\n\(innerStream)\nendstream",
    ])
}

private func topLevelTextPDF() -> Data {
    let stream = "BT /F1 18 Tf 0 0 1 rg 1 0 0 1 72 700 Tm (Original Text) Tj ET"
    return makePDF(objects: [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
    ])
}

let fixtures = [
    (URL(fileURLWithPath: "/tmp/PDFEditor-NestedForm.pdf"), nestedFormPDF()),
    (URL(fileURLWithPath: "/tmp/PDFEditor-TopLevelText.pdf"), topLevelTextPDF()),
]
for (url, data) in fixtures {
    try data.write(to: url, options: .atomic)
    print(url.path)
}
