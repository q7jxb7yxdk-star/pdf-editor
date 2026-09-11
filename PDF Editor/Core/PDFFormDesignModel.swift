import CoreGraphics
import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum PDFFormDesignKind: String, CaseIterable, Identifiable, Sendable {
    case text, checkBox, radioButton, dropdown, listBox, digitalSignature

    var id: Self { self }
    var title: String {
        switch self {
        case .text: "Text Field"
        case .checkBox: "Checkbox"
        case .radioButton: "Radio Button"
        case .dropdown: "Dropdown"
        case .listBox: "List Box"
        case .digitalSignature: "Digital Signature Field"
        }
    }
    var symbol: String {
        switch self {
        case .text: "character.textbox"
        case .checkBox: "checkmark.square"
        case .radioButton: "smallcircle.filled.circle"
        case .dropdown: "chevron.down.square"
        case .listBox: "list.bullet.rectangle"
        case .digitalSignature: "signature"
        }
    }

    var minimumDimension: CGFloat {
        switch self {
        case .checkBox, .radioButton: 11
        case .text, .dropdown, .listBox, .digitalSignature: 12
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .text: CGSize(width: 100, height: 22)
        case .checkBox, .radioButton: CGSize(width: 11, height: 11)
        case .dropdown: CGSize(width: 180, height: 28)
        case .listBox: CGSize(width: 180, height: 72)
        case .digitalSignature: CGSize(width: 180, height: 50)
        }
    }

    func placementSize(choices: [String], fontSize: CGFloat = 11) -> CGSize {
        guard isChoice else { return defaultSize }
#if os(macOS)
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = font.ascender - font.descender + font.leading
#else
        let font = UIFont.systemFont(ofSize: fontSize)
        let lineHeight = font.lineHeight
#endif
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widestOption = choices.reduce(CGFloat.zero) { width, option in
            max(width, (option as NSString).size(withAttributes: attributes).width)
        }
        // Dropdown needs room for its native arrow. List Box also reserves
        // space for PDFKit's scrollbar in addition to its text insets and border.
        let controlSpace: CGFloat = self == .dropdown ? 32 : 36
        let width = max(48, ceil(widestOption) + controlSpace)
        let height: CGFloat
        if self == .listBox {
            let visibleRows = CGFloat(max(choices.count, 1))
            height = max(defaultSize.height, ceil(lineHeight * visibleRows) + 12)
        } else {
            height = defaultSize.height
        }
        return CGSize(width: width, height: height)
    }

    /// Measures an app-authored Textbox in PDF points. Both platform editors
    /// call this so a text or font-size change produces the same content-fit
    /// geometry before page crop clamping is applied.
    func fittedTextSize(
        text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat
    ) -> CGSize {
        guard self == .text else { return defaultSize }
#if os(macOS)
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        // The AppKit editor frame is inset horizontally by three points per
        // side and has a zero text-container inset.
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 0
#else
        let font = UIFont.systemFont(ofSize: fontSize)
        let lineHeight = font.lineHeight
        // The UIKit display/editor uses textContainerInset of 4/6/4/6.
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 8
#endif
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lines = text.components(separatedBy: .newlines)
        let widestLine = lines.reduce(CGFloat.zero) { width, line in
            max(width, (line as NSString).size(withAttributes: attributes).width)
        }
        let width = min(
            max(defaultSize.width, ceil(widestLine) + horizontalPadding),
            max(maximumWidth, minimumDimension)
        )
        let textWidth = max(width - horizontalPadding, 1)
        let roundedLineHeight = max(ceil(lineHeight), 1)
        let lineCount = lines.reduce(0) { count, line in
            guard !line.isEmpty else { return count + 1 }
            let textBounds = (line as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            return count + max(1, Int(ceil(textBounds.height / roundedLineHeight)))
        }
        return CGSize(
            width: width,
            height: max(
                defaultSize.height,
                roundedLineHeight * CGFloat(max(lineCount, 1)) + verticalPadding
            )
        )
    }

    var isChoice: Bool {
        self == .dropdown || self == .listBox
    }

    var isButton: Bool {
        self == .checkBox || self == .radioButton
    }

    var isDigitalSignature: Bool {
        self == .digitalSignature
    }
}

nonisolated struct PDFFormDesignField: Identifiable, Equatable, Sendable {
    var id = UUID()
    var pageIndex: Int
    var kind: PDFFormDesignKind
    var name: String
    var bounds: CGRect
    var value = ""
    var defaultValue = ""
    var fontSize: CGFloat = 11
    var isMultiline = false
    var exportValue = "Yes"
    var isSelected = false
    var isDefaultSelected = false
    var choices: [String] = []
}

/// Presentation boundary around either a verified live Widget mutation or a
/// complete canonical document replacement. PDFKit uses this to shield and
/// redraw the affected presentation without exposing an intermediate frame.
nonisolated struct PDFFormDisplayTransition: Equatable, Sendable {
    let pageIndex: Int
    let beforeBounds: CGRect?
    let afterBounds: CGRect?
    let replacesDocument: Bool
    let minimumShieldDuration: TimeInterval
    let snapshotRevealDuration: TimeInterval

    init(
        pageIndex: Int,
        beforeBounds: CGRect?,
        afterBounds: CGRect?,
        replacesDocument: Bool = false,
        minimumShieldDuration: TimeInterval = 0.05,
        snapshotRevealDuration: TimeInterval = 0
    ) {
        self.pageIndex = pageIndex
        self.beforeBounds = beforeBounds
        self.afterBounds = afterBounds
        self.replacesDocument = replacesDocument
        self.minimumShieldDuration = minimumShieldDuration
        self.snapshotRevealDuration = snapshotRevealDuration
    }
}

nonisolated enum PDFFormDisplayTransitionEvent {
    static let willChange = Notification.Name(
        "PDFEditorFormDisplayTransitionWillChange"
    )
    static let didChange = Notification.Name(
        "PDFEditorFormDisplayTransitionDidChange"
    )
    static let transitionUserInfoKey = "PDFEditorFormDisplayTransition"
}

/// The original bytes are a transaction token, not a file to write on Cancel.
struct PDFFormDesignSession: Identifiable {
    let id = UUID()
    let sourceData: Data
    let sourceDocument: PDFDocument
    let previewDocument: PDFDocument
    let fields: [PDFFormDesignField]
    let initialPageIndex: Int
}

/// PDF crop coordinates (bottom-left) to thumbnail coordinates (top-left),
/// including nonzero crop origins and the page's clockwise /Rotate value.
nonisolated struct PDFFormPageGeometry {
    let cropBox: CGRect
    let rotation: Int

    var transform: CGAffineTransform {
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            CGAffineTransform(a: 0, b: 1, c: 1, d: 0,
                              tx: -cropBox.minY, ty: -cropBox.minX)
        case 180:
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                              tx: cropBox.maxX, ty: -cropBox.minY)
        case 270:
            CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                              tx: cropBox.maxY, ty: cropBox.maxX)
        default:
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                              tx: -cropBox.minX, ty: cropBox.maxY)
        }
    }

    var displaySize: CGSize { cropBox.applying(transform).size }

    func clamped(_ rect: CGRect, minimumDimension: CGFloat = 12) -> CGRect {
        let width = min(max(rect.width, minimumDimension), cropBox.width)
        let height = min(max(rect.height, minimumDimension), cropBox.height)
        return CGRect(x: min(max(rect.minX, cropBox.minX), cropBox.maxX - width),
                      y: min(max(rect.minY, cropBox.minY), cropBox.maxY - height),
                      width: width, height: height)
    }
}
