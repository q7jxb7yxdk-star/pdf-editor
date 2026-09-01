import CoreGraphics
import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum PDFFormDesignKind: String, CaseIterable, Identifiable, Sendable {
    case text, checkBox, radioButton, dropdown, listBox

    var id: Self { self }
    var title: String {
        switch self {
        case .text: "Text Field"
        case .checkBox: "Checkbox"
        case .radioButton: "Radio Button"
        case .dropdown: "Dropdown"
        case .listBox: "List Box"
        }
    }
    var symbol: String {
        switch self {
        case .text: "character.textbox"
        case .checkBox: "checkmark.square"
        case .radioButton: "smallcircle.filled.circle"
        case .dropdown: "chevron.down.square"
        case .listBox: "list.bullet.rectangle"
        }
    }

    var minimumDimension: CGFloat {
        switch self {
        case .checkBox, .radioButton: 11
        case .text, .dropdown, .listBox: 12
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .text: CGSize(width: 180, height: 28)
        case .checkBox, .radioButton: CGSize(width: 11, height: 11)
        case .dropdown: CGSize(width: 180, height: 28)
        case .listBox: CGSize(width: 180, height: 72)
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

    var isChoice: Bool {
        self == .dropdown || self == .listBox
    }

    var isButton: Bool {
        self == .checkBox || self == .radioButton
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

    init(
        pageIndex: Int,
        beforeBounds: CGRect?,
        afterBounds: CGRect?,
        replacesDocument: Bool = false
    ) {
        self.pageIndex = pageIndex
        self.beforeBounds = beforeBounds
        self.afterBounds = afterBounds
        self.replacesDocument = replacesDocument
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
