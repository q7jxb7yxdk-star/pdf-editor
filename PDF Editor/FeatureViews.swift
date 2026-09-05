import PDFKit
import SwiftUI

#if os(macOS)
import AppKit
import Combine
import QuickLookThumbnailing
#endif

enum PDFToolAction: Equatable {
    case addComment
    case editComments
    case highlight
    case drawFreehand
    case deletePage
    case movePageEarlier
    case movePageLater
    case rotateLeft
    case rotateRight
    case combineFiles
    case exportImage
    case addSignature
    case addCheckmark
    case addCrossmark
    case fillFormFields
    case designForm(PDFFormDesignKind)
    case protectPDF
    case removePassword
}

extension PDFToolAction {
    var isESignAction: Bool {
        switch self {
        case .addSignature, .addCheckmark, .addCrossmark, .fillFormFields: true
        default: false
        }
    }
}

struct PDFToolSidebar: View {
    private static let expandedSectionsDefaultsKey = "com.sunny.pdf-editor.tool-sidebar.expanded-sections.v2"
    private static let legacyExpandedSectionsDefaultsKey = "com.sunny.pdf-editor.tool-sidebar.expanded-sections.v1"
    private static var sectionTitles: Set<String> {
        var titles: Set<String> = [
            "Edit text",
            "Organize a PDF",
            "Export PDF to",
            "E-sign",
            "Acroform",
            "Secure PDF"
        ]
#if os(macOS)
        titles.insert("Recent files")
#endif
        return titles
    }

    let pageCount: Int
    let hasSelectedPage: Bool
    let isEncrypted: Bool
    let isLocked: Bool
    let removesPasswordProtectionOnSave: Bool
    let canDesignForm: Bool
    let recentDocumentURLs: [URL]
    let onOpenRecentDocument: (URL) -> Void
    let onClearRecentDocuments: () -> Void
    let onRefreshRecentDocuments: () -> Void
    let onAction: (PDFToolAction) -> Void

    @State private var expandedSections: Set<String>

    init(
        pageCount: Int,
        hasSelectedPage: Bool,
        isEncrypted: Bool,
        isLocked: Bool,
        removesPasswordProtectionOnSave: Bool,
        canDesignForm: Bool = true,
        recentDocumentURLs: [URL] = [],
        onOpenRecentDocument: @escaping (URL) -> Void = { _ in },
        onClearRecentDocuments: @escaping () -> Void = {},
        onRefreshRecentDocuments: @escaping () -> Void = {},
        onAction: @escaping (PDFToolAction) -> Void
    ) {
        self.pageCount = pageCount
        self.hasSelectedPage = hasSelectedPage
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.removesPasswordProtectionOnSave = removesPasswordProtectionOnSave
        self.canDesignForm = canDesignForm
        self.recentDocumentURLs = recentDocumentURLs
        self.onOpenRecentDocument = onOpenRecentDocument
        self.onClearRecentDocuments = onClearRecentDocuments
        self.onRefreshRecentDocuments = onRefreshRecentDocuments
        self.onAction = onAction
        _expandedSections = State(initialValue: Self.loadExpandedSections())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.tint)
                Text("All tools")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    section("Edit text") {
                        tool("Add a comment", icon: "note.text.badge.plus", action: .addComment)
                        tool(
                            "Edit comment",
                            icon: "text.bubble",
                            action: .editComments,
                            enabled: hasSelectedPage
                        )
                        tool("Highlight", icon: "highlighter", action: .highlight)
                        tool("Draw freehand", icon: "pencil.and.outline", action: .drawFreehand)
                    }

                    section("Organize a PDF") {
                        tool("Combine files", icon: "doc.on.doc", action: .combineFiles)
                    }

                    section("Export PDF to") {
                        tool("Image format", icon: "photo", action: .exportImage)
                    }

                    section("Acroform") {
                        tool(
                            "Textbox",
                            icon: "character.textbox",
                            action: .designForm(.text),
                            enabled: canDesignForm && !isLocked && pageCount > 0
                        )
                        tool(
                            "Checkbox",
                            icon: "checkmark.square",
                            action: .designForm(.checkBox),
                            enabled: canDesignForm && !isLocked && pageCount > 0
                        )
                        tool(
                            "Radio Button",
                            icon: "smallcircle.filled.circle",
                            action: .designForm(.radioButton),
                            enabled: canDesignForm && !isLocked && pageCount > 0
                        )
                        tool(
                            "Dropdown",
                            icon: "chevron.down.square",
                            action: .designForm(.dropdown),
                            enabled: canDesignForm && !isLocked && pageCount > 0
                        )
                        tool(
                            "List Box",
                            icon: "list.bullet.rectangle",
                            action: .designForm(.listBox),
                            enabled: canDesignForm && !isLocked && pageCount > 0
                        )
                    }

                    section("E-sign") {
                        tool(
                            "Fill in form fields",
                            icon: "character.cursor.ibeam",
                            action: .fillFormFields
                        )
                        tool("Add a signature", icon: "signature", action: .addSignature)
                        tool("Add a checkmark", icon: "checkmark", action: .addCheckmark)
                        tool("Add a crossmark", icon: "xmark", action: .addCrossmark)
                    }

                    section("Secure PDF") {
                        tool("Protect PDF", icon: "lock", action: .protectPDF)
                        if removesPasswordProtectionOnSave {
                            tool(
                                "Password Will Be Removed",
                                icon: "checkmark.circle",
                                action: .removePassword,
                                enabled: false
                            )
                        } else {
                            tool(
                                "Remove Password",
                                icon: "lock.open",
                                action: .removePassword,
                                enabled: isEncrypted && !isLocked
                            )
                        }
                    }

#if os(macOS)
                    section("Recent files") {
                        if recentDocumentURLs.isEmpty {
                            sidebarMessage("No recent files", icon: "clock")
                        } else {
                            ForEach(recentDocumentURLs, id: \.self) { url in
                                recentDocument(url)
                            }
                        }
                        sidebarButton(
                            "Clear recent files",
                            icon: "trash",
                            enabled: !recentDocumentURLs.isEmpty,
                            action: onClearRecentDocuments
                        )
                    }
#endif
                }
                .padding(.bottom, 18)
            }
#if os(macOS)
            .onAppear(perform: onRefreshRecentDocuments)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )
            ) { _ in
                onRefreshRecentDocuments()
            }
#endif
        }
        .background(.background)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = Binding(
            get: { expandedSections.contains(title) },
            set: { expanded in
                var updatedSections = expandedSections
                if expanded { updatedSections.insert(title) }
                else { updatedSections.remove(title) }
                expandedSections = updatedSections
                saveExpandedSections(updatedSections)
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(spacing: 2) { content() }
                .padding(.top, 6)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    private static func loadExpandedSections() -> Set<String> {
        if let storedTitles = UserDefaults.standard.array(forKey: expandedSectionsDefaultsKey) as? [String] {
            return Set(storedTitles).intersection(sectionTitles)
        }
        if let legacyTitles = UserDefaults.standard.array(forKey: legacyExpandedSectionsDefaultsKey) as? [String] {
            // Expose the new category without reopening previously collapsed sections.
            return Set(legacyTitles).intersection(sectionTitles).union(["Acroform"])
        }
        return sectionTitles
    }

    private func saveExpandedSections(_ sections: Set<String>) {
        UserDefaults.standard.set(sections.sorted(), forKey: Self.expandedSectionsDefaultsKey)
    }

    private func tool(
        _ title: String,
        icon: String,
        action: PDFToolAction,
        enabled: Bool = true
    ) -> some View {
        Button { onAction(action) } label: {
            ToolRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

#if os(macOS)
    private func recentDocument(_ url: URL) -> some View {
        Button { onOpenRecentDocument(url) } label: {
            VStack(spacing: 8) {
                RecentDocumentThumbnail(url: url)

                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 140)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help(url.path(percentEncoded: false))
    }

    private func sidebarButton(
        _ title: String,
        icon: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ToolRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func sidebarMessage(_ title: String, icon: String) -> some View {
        ToolRowLabel(title: title, icon: icon)
            .foregroundStyle(.secondary)
    }
#endif

    private func menuTool<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Menu(content: content) {
            ToolRowLabel(title: title, icon: icon, showsDisclosure: true)
        }
        .menuStyle(.borderlessButton)
        .disabled(!hasSelectedPage)
    }
}

#if os(macOS)
@MainActor
private enum RecentDocumentThumbnailCache {
    static let images = NSCache<NSURL, NSImage>()
}

private struct RecentDocumentThumbnail: View {
    let url: URL

    @State private var image: NSImage?
    @State private var request: QLThumbnailGenerator.Request?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 140, maxHeight: 180)
        .aspectRatio(7 / 9, contentMode: .fit)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        .onAppear(perform: loadThumbnail)
        .onDisappear(perform: cancelThumbnailRequest)
    }

    private func loadThumbnail() {
        if let cachedImage = RecentDocumentThumbnailCache.images.object(
            forKey: url as NSURL
        ) {
            image = cachedImage
            return
        }

        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 280, height: 360),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        self.request = request

        QLThumbnailGenerator.shared.generateBestRepresentation(
            for: request
        ) { representation, _ in
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            guard let thumbnailImage = representation?.nsImage else { return }
            Task { @MainActor in
                RecentDocumentThumbnailCache.images.setObject(
                    thumbnailImage,
                    forKey: url as NSURL
                )
                image = thumbnailImage
                self.request = nil
            }
        }
    }

    private func cancelThumbnailRequest() {
        guard let request else { return }
        QLThumbnailGenerator.shared.cancel(request)
        self.request = nil
    }
}
#endif

struct PDFProtectView: View {
    let onProtect: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $confirmation)
                } header: {
                    Text("PDF password")
                } footer: {
                    Text("The password will be required after the PDF is saved. It is kept only for this open document and is not stored separately.")
                }

                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 28)
            .navigationTitle("Protect PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Protect", action: protect)
                        .disabled(password.isEmpty || confirmation.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func protect() {
        guard !password.isEmpty else {
            validationMessage = "Enter a password."
            return
        }
        guard password == confirmation else {
            validationMessage = "The passwords do not match."
            return
        }
        onProtect(password)
    }
}

enum PDFImageExportPageScope: String, CaseIterable, Identifiable {
    case currentPage
    case allPages

    var id: Self { self }

    var title: String {
        switch self {
        case .currentPage: "Current page"
        case .allPages: "All pages"
        }
    }
}

struct PDFImageExportOptionsView: View {
    private enum FormatChoice: String, CaseIterable, Identifiable {
        case png
        case jpeg

        var id: Self { self }
        var title: String { rawValue.uppercased() }
    }

    let hasCurrentPage: Bool
    let pageCount: Int
    let onExport: (PDFPageImageFormat, PDFPageImageDPI, PDFImageExportPageScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: FormatChoice = .png
    @State private var dpi: PDFPageImageDPI = .dpi300
    @State private var pageScope: PDFImageExportPageScope = .currentPage

    var body: some View {
        Group {
#if os(macOS)
            macOSSheetContent
#else
            iOSSheetContent
#endif
        }
        .frame(minWidth: minimumSheetWidth, minHeight: 340)
        .onAppear {
            if !hasCurrentPage {
                pageScope = .allPages
            }
        }
    }

#if os(macOS)
    private var macOSSheetContent: some View {
        VStack(spacing: 0) {
            Text("Export PDF to Images")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalContentMargin)
                .padding(.vertical, 18)

            Divider()
            macOSOptionsContent
            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export", action: exportImages)
                    .keyboardShortcut(.defaultAction)
                    .disabled(exportDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var macOSOptionsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: optionColumnSpacing) {
                    optionLabel("Format")
                    optionControl {
                        Picker("Format", selection: $format) {
                            ForEach(FormatChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }

                HStack(spacing: optionColumnSpacing) {
                    optionLabel("Pages")
                    optionControl {
                        Picker("Pages", selection: $pageScope) {
                            ForEach(PDFImageExportPageScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }

                HStack(spacing: optionColumnSpacing) {
                    optionLabel("Resolution")
                    optionControl {
                        Picker("Resolution", selection: $dpi) {
                            ForEach(PDFPageImageDPI.allCases, id: \.self) { value in
                                Text("\(value.rawValue) DPI").tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                HStack(alignment: .top, spacing: optionColumnSpacing) {
                    Color.clear
                        .frame(width: optionLabelWidth, height: 1)
                    Text(exportSummary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalContentMargin)
            .padding(.vertical, 20)
        }
    }

    private func optionLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: optionLabelWidth, alignment: .trailing)
    }

    private func optionControl<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            content()
        }
        .frame(width: optionControlColumnWidth, alignment: .leading)
    }

    private var optionLabelWidth: CGFloat { 100 }
    private var optionColumnSpacing: CGFloat { 20 }
    private var optionControlColumnWidth: CGFloat { 200 }
#else
    private var iOSSheetContent: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(FormatChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Pages", selection: $pageScope) {
                    ForEach(PDFImageExportPageScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Resolution", selection: $dpi) {
                    ForEach(PDFPageImageDPI.allCases, id: \.self) { value in
                        Text("\(value.rawValue) DPI").tag(value)
                    }
                }

                Section {
                    Text(exportSummary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentMargins(.horizontal, horizontalContentMargin, for: .scrollContent)
            .contentMargins(.vertical, 20, for: .scrollContent)
            .navigationTitle("Export PDF to Images")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export", action: exportImages)
                        .disabled(exportDisabled)
                }
            }
        }
    }
#endif

    private var exportDisabled: Bool {
        pageCount == 0 || (pageScope == .currentPage && !hasCurrentPage)
    }

    private func exportImages() {
        let imageFormat: PDFPageImageFormat = switch format {
        case .png: .png
        case .jpeg: .jpeg
        }
        dismiss()
        onExport(imageFormat, dpi, pageScope)
    }

    private var exportSummary: String {
        let pages = pageScope == .currentPage ? "the current page" : "all \(pageCount) pages"
        return "Exports \(pages) as \(format.title) at \(dpi.rawValue) DPI. Each PDF page becomes a separate image file."
    }

    private var minimumSheetWidth: CGFloat {
#if os(macOS)
        400
#else
        320
#endif
    }

    private var horizontalContentMargin: CGFloat {
#if os(macOS)
        28
#else
        20
#endif
    }
}

struct PDFCommentList: View {
    let annotations: [PDFAnnotationSnapshot]
    let pageNumber: Int?
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let onApply: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDelete: (PDFAnnotationSnapshot) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comment List")
                        .font(.headline)
                    if let pageNumber {
                        Text("Page \(pageNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Comment List")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            List(annotations) { annotation in
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: selectedAnnotation?.reference == annotation.reference,
                    onSelect: { selectedAnnotation = annotation },
                    onApply: { onApply(annotation, $0) },
                    onDelete: { onDelete(annotation) }
                )
            }
            .listStyle(.inset)
            .overlay {
                if annotations.isEmpty {
                    ContentUnavailableView(
                        "No comments on this page",
                        systemImage: "text.bubble"
                    )
                }
            }
        }
        .background(.background)
    }
}

private struct ToolRowLabel: View {
    let title: String
    let icon: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 6)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

#if os(iOS)
/// Overlays the document so showing the controls never changes PDF layout or zoom.
struct PDFPhoneViewerControls<Controls: View>: View {
    @ViewBuilder let controls: (@escaping () -> Void, @escaping (Bool) -> Void) -> Controls

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var isPageNumberFocused = false
    @State private var idleRevision = 0
    @GestureState private var isDragging = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                setExpanded(!isExpanded)
            } label: {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 4, height: 36)
                    .frame(width: 24, height: 64)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide view controls" : "Show view controls")
            .disabled(isPageNumberFocused)

            if isExpanded {
                controls(recordInteraction, pageNumberFocusChanged)
                    .frame(width: 52)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The gesture is confined to the controls and handle, leaving PDF gestures alone.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($isDragging) { _, active, _ in active = true }
                .onEnded { value in
                    let delta = value.translation
                    guard abs(delta.width) > abs(delta.height), abs(delta.width) > 24 else {
                        recordInteraction()
                        return
                    }
                    setExpanded(delta.width < 0)
                }
        )
        .onChange(of: isDragging) { _, _ in recordInteraction() }
        .onChange(of: voiceOverEnabled) { _, _ in recordInteraction() }
        .task(id: idleRevision) {
            guard isExpanded, !isPageNumberFocused, !isDragging, !voiceOverEnabled else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, !isPageNumberFocused, !isDragging, !voiceOverEnabled else { return }
            setExpanded(false)
        }
    }

    private func recordInteraction() {
        idleRevision += 1
    }

    private func pageNumberFocusChanged(_ focused: Bool) {
        isPageNumberFocused = focused
        recordInteraction()
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded || !isPageNumberFocused else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isExpanded = expanded
        }
        recordInteraction()
    }
}
#endif

struct PDFRightPanel: View {
    @Binding var viewerMode: PDFViewerMode
    @Binding var selectedPageIndex: Int?
    let pageCount: Int
    let isPagesPanelPresented: Bool
    let isBookmarksPanelPresented: Bool
    let onTogglePages: () -> Void
    let onToggleBookmarks: () -> Void
    let onViewerCommand: (PDFViewerCommand.Action) -> Void
    let onFullScreen: () -> Void
    var onInteraction: () -> Void = {}
    var onPageNumberFocusChange: (Bool) -> Void = { _ in }

    @State private var pageNumberText = ""
    @FocusState private var isPageNumberFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                iconButton(
                    "Pages",
                    systemImage: "rectangle.stack",
                    isSelected: isPagesPanelPresented,
                    action: onTogglePages
                )
                iconButton(
                    "Bookmarks",
                    systemImage: "bookmark",
                    isSelected: isBookmarksPanelPresented,
                    action: onToggleBookmarks
                )
                iconButton(
                    "Single-page view",
                    systemImage: "doc",
                    isSelected: viewerMode == .singlePage
                ) {
                    viewerMode = .singlePage
                }
                iconButton(
                    "Two-page view",
                    systemImage: "book.pages",
                    isSelected: viewerMode == .twoPage
                ) {
                    viewerMode = .twoPage
                }
                iconButton(
                    "View with scrolling",
                    systemImage: "scroll",
                    isSelected: viewerMode == .scrolling
                ) {
                    viewerMode = .scrolling
                }
                iconButton("Fit one page", systemImage: "rectangle.inset.filled") {
                    onViewerCommand(.fitPage)
                }
                iconButton("Fit to width", systemImage: "arrow.left.and.right") {
                    onViewerCommand(.fitWidth)
                }
#if os(macOS)
                iconButton(
                    "Full screen",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    action: onFullScreen
                )
#endif
                iconButton("Zoom in", systemImage: "plus.magnifyingglass") {
                    onViewerCommand(.zoomIn)
                }
                iconButton("Zoom out", systemImage: "minus.magnifyingglass") {
                    onViewerCommand(.zoomOut)
                }
                Divider()
                    .padding(.vertical, 4)
                pageNavigation
            }
            .padding(.vertical, 8)
        }
        .background(.background)
    }

    private var pageNavigation: some View {
        VStack(spacing: 4) {
            TextField("Page", text: $pageNumberText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 44, height: 44)
                .background(
                    isPageNumberFocused ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isPageNumberFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: 1
                        )
                }
                .disabled(pageCount == 0)
                .focused($isPageNumberFocused)
                .onSubmit(commitPageNumber)
                .accessibilityLabel("Page number")

            Text("\(pageCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Total pages \(pageCount)")

            iconButton("Previous page", systemImage: "chevron.left") {
                selectPage((selectedPageIndex ?? 0) - 1)
            }
            .disabled(selectedPageIndex == nil || selectedPageIndex == 0)

            iconButton("Next page", systemImage: "chevron.right") {
                selectPage((selectedPageIndex ?? -1) + 1)
            }
            .disabled(
                selectedPageIndex == nil ||
                selectedPageIndex == pageCount - 1
            )
        }
        .onChange(of: selectedPageIndex, initial: true) { _, pageIndex in
            guard !isPageNumberFocused else { return }
            pageNumberText = pageIndex.map { String($0 + 1) } ?? ""
        }
        .onChange(of: pageNumberText) { _, newValue in
            onInteraction()
            let digits = newValue.filter(\.isNumber)
            guard digits == newValue else {
                pageNumberText = digits
                return
            }
            guard let pageNumber = Int(digits),
                  (1...pageCount).contains(pageNumber) else { return }
            selectedPageIndex = pageNumber - 1
        }
        .onChange(of: isPageNumberFocused) { _, isFocused in
            onPageNumberFocusChange(isFocused)
            if !isFocused {
                commitPageNumber()
            }
        }
    }

    private func commitPageNumber() {
        guard pageCount > 0 else {
            pageNumberText = ""
            return
        }
        let requestedPage = Int(pageNumberText) ?? ((selectedPageIndex ?? 0) + 1)
        selectPage(min(max(requestedPage - 1, 0), pageCount - 1))
    }

    private func selectPage(_ pageIndex: Int) {
        guard (0..<pageCount).contains(pageIndex) else { return }
        pageNumberText = String(pageIndex + 1)
        selectedPageIndex = pageIndex
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 28)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct PDFBookmarksPanel: View {
    let bookmarks: [PDFBookmarkSnapshot]
    let selectedPageIndex: Int?
    let onNavigate: (Int) -> Void
    let onAdd: () -> Void
    let onRename: (PDFBookmarkSnapshot, String) -> Bool
    let onDelete: (PDFBookmarkSnapshot) -> Void
    let onClose: () -> Void

    @State private var bookmarkBeingRenamed: PDFBookmarkSnapshot?
    @State private var renameDraft = ""
    @State private var renameSourceBookmarks: [PDFBookmarkSnapshot] = []
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bookmark")
                    .foregroundStyle(.tint)
                Text("Bookmarks")
                    .font(.headline)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(selectedPageIndex == nil || bookmarkBeingRenamed != nil)
                .help("Add Bookmark for Current Page")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Bookmarks")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            List {
                OutlineGroup(bookmarks, children: \.outlineChildren) { bookmark in
                    bookmarkRow(bookmark)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Add a bookmark for the current page.")
                    )
                }
            }
        }
        .background(.background)
        .onChange(of: bookmarks) { _, updatedBookmarks in
            // Paths are positional: an outline change can make the draft target another bookmark.
            if bookmarkBeingRenamed != nil, updatedBookmarks != renameSourceBookmarks {
                cancelRenaming()
            }
        }
        .onDisappear(perform: cancelRenaming)
    }

    private func bookmarkRow(_ bookmark: PDFBookmarkSnapshot) -> some View {
        HStack(spacing: 4) {
            if bookmarkBeingRenamed?.path == bookmark.path {
                bookmarkLabel(bookmark, isEditing: true)

                Button(action: commitRenaming) {
                    Image(systemName: "checkmark")
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save Bookmark Name")
                .help("Save Bookmark Name")

                Button(action: cancelRenaming) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Rename")
                .help("Cancel Rename")
            } else {
                Button {
                    if let pageIndex = bookmark.pageIndex {
                        onNavigate(pageIndex)
                    }
                } label: {
                    bookmarkLabel(bookmark)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bookmark.pageIndex == nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Menu {
                Button("Rename") { beginRenaming(bookmark) }
                    .disabled(bookmarkBeingRenamed != nil)
                Button("Delete", role: .destructive) { onDelete(bookmark) }
                    .disabled(bookmarkBeingRenamed != nil)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .layoutPriority(1)
            .help("Bookmark Actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func bookmarkLabel(_ bookmark: PDFBookmarkSnapshot, isEditing: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.pageIndex == nil ? "bookmark.slash" : "bookmark.fill")
                .foregroundStyle(bookmark.pageIndex == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Bookmark name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Bookmark name")
                        .focused($isRenameFocused)
                        .onSubmit(commitRenaming)
#if os(macOS)
                        .onExitCommand(perform: cancelRenaming)
#endif
                        .task { isRenameFocused = true }
                } else {
                    Text(bookmark.title)
                        .lineLimit(2)
                }
                if let pageIndex = bookmark.pageIndex {
                    Text("Page \(pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("External or unavailable destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginRenaming(_ bookmark: PDFBookmarkSnapshot) {
        renameDraft = bookmark.title
        renameSourceBookmarks = bookmarks
        bookmarkBeingRenamed = bookmark
    }

    private func commitRenaming() {
        guard let bookmark = bookmarkBeingRenamed else { return }
        guard bookmarks == renameSourceBookmarks else {
            cancelRenaming()
            return
        }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if title == bookmark.title || onRename(bookmark, title) {
            cancelRenaming()
        }
    }

    private func cancelRenaming() {
        isRenameFocused = false
        bookmarkBeingRenamed = nil
        renameDraft = ""
        renameSourceBookmarks = []
    }
}

struct PDFPagesPanel: View {
    let document: PDFDocument
    @Binding var selectedPageIndex: Int?
    let onMove: (IndexSet, Int) -> Void
    let onExtract: (Int) -> Void
    let onRotate: (Int, Int) -> Void
    let onDelete: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.tint)
                Text("Pages")
                    .font(.headline)
                Spacer()
#if os(iOS)
                EditButton()
#endif
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pages")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            List(selection: $selectedPageIndex) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    if let page = document.page(at: index) {
                        pageRow(page, at: index)
                            .tag(index)
                    }
                }
                .onMove(perform: onMove)
            }
            .listStyle(.sidebar)
        }
        .background(.background)
    }

    private func pageRow(_ page: PDFPage, at index: Int) -> some View {
        VStack(spacing: 4) {
            PageThumbnailView(page: page, pageNumber: index + 1)

            HStack(spacing: 12) {
                pageButton("Extract page", systemImage: "doc.badge.arrow.up") {
                    onExtract(index)
                }
                pageButton("Rotate left", systemImage: "rotate.left") {
                    onRotate(index, -90)
                }
                pageButton("Rotate right", systemImage: "rotate.right") {
                    onRotate(index, 90)
                }
                pageButton("Delete page", systemImage: "trash", role: .destructive) {
                    onDelete(index)
                }
                .disabled(document.pageCount <= 1)
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .contextMenu {
            Button("Rotate Left") { onRotate(index, -90) }
            Button("Rotate Right") { onRotate(index, 90) }
            Divider()
            Button("Delete Page", role: .destructive) { onDelete(index) }
                .disabled(document.pageCount <= 1)
        }
    }

    private func pageButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .help(title)
    }
}

struct ProtectedPDFMergeView: View {
    let filename: String
    let onMerge: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PDF password", text: $password)
                        .onSubmit(merge)
                } header: {
                    Text(filename)
                } footer: {
                    Text("The password is used only for this import and is not stored.")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Combine Protected PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock and Combine", action: merge)
                        .disabled(password.isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 220)
    }

    private func merge() {
        guard !password.isEmpty else { return }
        do {
            try onMerge(password)
            password = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            password = ""
        }
    }
}

struct OCRBatchResultView: View {
    let result: OCRBatchResult
    let onAddTextLayers: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Recognized pages", value: "\(result.recognizedPageCount)")
                LabeledContent("Text blocks", value: "\(result.recognizedItemCount)")
                LabeledContent("Skipped text pages", value: "\(result.skippedTextPageIndices.count)")
                LabeledContent("No recognition result", value: "\(result.emptyPageIndices.count)")

                if !result.recognizedPages.isEmpty {
                    Section("Searchable text layers to add") {
                        ForEach(result.recognizedPages) { page in
                            Text("Page \(page.pageIndex + 1) · \(page.observations.count) text blocks")
                        }
                    }
                }
            }
            .navigationTitle("Document OCR Results")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !result.recognizedPages.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add Searchable Text Layers") {
                            onAddTextLayers()
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}

struct PageObjectInspectorView: View {
    @Binding var objects: [PDFPageObjectSnapshot]
    let onReplaceText: (PDFPageObjectSnapshot, String, PDFTextStyle) -> Void
    let onReplaceImage: (PDFPageObjectSnapshot) -> Void
    let onMove: (PDFPageObjectSnapshot, CGSize) -> Void
    let onMoveToIndex: (PDFPageObjectSnapshot, Int) -> Void
    let onDelete: (PDFPageObjectSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replacementText: [String: String] = [:]
    @State private var replacementStyle: [String: PDFTextStyle] = [:]

    var body: some View {
        NavigationStack {
            List(objects) { object in
                VStack(alignment: .leading, spacing: 8) {
                    Text(objectTitle(object))
                        .font(.headline)
                    Text(boundsDescription(object.bounds))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if object.kind == .text {
                        TextField(
                            "Text",
                            text: Binding(
                                get: { replacementText[object.id] ?? object.text ?? "" },
                                set: { replacementText[object.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Bold") { toggle(.bold, for: object) }
                                .buttonStyle(.borderedProminent)
                                .tint(style(for: object).contains(.bold) ? .accentColor : .gray)
                            Button("Italic") { toggle(.italic, for: object) }
                                .buttonStyle(.borderedProminent)
                                .tint(style(for: object).contains(.italic) ? .accentColor : .gray)
                        }
                        Button("Apply Text Change") {
                            onReplaceText(
                                object,
                                replacementText[object.id] ?? object.text ?? "",
                                style(for: object)
                            )
                        }
                    }

                    if object.kind == .image {
                        Button("Replace Image…") { onReplaceImage(object) }
                    }

                    HStack {
                        Button("←") { onMove(object, CGSize(width: -5, height: 0)) }
                        Button("→") { onMove(object, CGSize(width: 5, height: 0)) }
                        Button("↑") { onMove(object, CGSize(width: 0, height: 5)) }
                        Button("↓") { onMove(object, CGSize(width: 0, height: -5)) }
                        Menu("Layer") {
                            Button("Bring to Front") {
                                onMoveToIndex(object, siblingCount(for: object) - 1)
                            }
                            Button("Send to Back") { onMoveToIndex(object, 0) }
                        }
                        .disabled(siblingCount(for: object) < 2)
                        Spacer()
                        Button("Delete", role: .destructive) { onDelete(object) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("PDF Objects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func style(for object: PDFPageObjectSnapshot) -> PDFTextStyle {
        replacementStyle[object.id] ?? PDFTextStyle.inferred(fromFontName: object.fontName)
    }

    private func toggle(_ style: PDFTextStyle, for object: PDFPageObjectSnapshot) {
        var updatedStyle = self.style(for: object)
        updatedStyle.formSymmetricDifference(style)
        replacementStyle[object.id] = updatedStyle
    }

    private func objectTitle(_ object: PDFPageObjectSnapshot) -> String {
        let type: String
        switch object.kind {
        case .text: type = "Text"
        case .image: type = "Image"
        case .path: type = "Vector Path"
        case .form: type = "Form Object"
        case .shading: type = "Gradient"
        case .unknown: type = "Unknown Object"
        }
        if let fontName = object.fontName, let fontSize = object.fontSize {
            let nesting = object.isNestedInForm ? " · Form \(object.path.displayValue)" : ""
            return "\(type) · \(fontName) · \(fontSize.formatted()) pt\(nesting)"
        }
        return object.isNestedInForm ? "\(type) · Form \(object.path.displayValue)" : type
    }

    private func boundsDescription(_ bounds: CGRect) -> String {
        "x \(Int(bounds.minX)), y \(Int(bounds.minY)), w \(Int(bounds.width)), h \(Int(bounds.height))"
    }

    private func siblingCount(for object: PDFPageObjectSnapshot) -> Int {
        let parent = object.path.indices.dropLast()
        return objects.count {
            $0.pageIndex == object.pageIndex && $0.path.indices.dropLast() == parent
        }
    }
}

struct SignatureLibraryView: View {
    @ObservedObject var store: SignatureLibraryStore
    let onSelect: (SignatureLibraryTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsSignaturePad = false
    @State private var signaturePendingDeletion: SignatureLibraryTemplate?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.templates.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Signatures", systemImage: "signature")
                    } description: {
                        Text("Create a signature once, then reuse it in any PDF.")
                    } actions: {
                        Button("Create Signature") { showsSignaturePad = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(store.templates) { template in
                        HStack(spacing: 14) {
                            Button {
                                onSelect(template)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    SignaturePreview(strokes: template.normalizedStrokes)
                                        .frame(width: 140, height: 72)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.displayName ?? "Saved Signature")
                                            .font(.headline)
                                        Text(template.createdAt, format: .dateTime.year().month().day())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Use")
                                        .font(.callout.weight(.semibold))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                signaturePendingDeletion = template
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete signature")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Signatures")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Signature", systemImage: "plus") {
                        showsSignaturePad = true
                    }
                }
            }
        }
        .sheet(isPresented: $showsSignaturePad) {
            SignaturePadView(onSave: saveSignature)
        }
        .confirmationDialog(
            "Delete Signature?",
            isPresented: Binding(
                get: { signaturePendingDeletion != nil },
                set: { if !$0 { signaturePendingDeletion = nil } }
            ),
            presenting: signaturePendingDeletion
        ) { template in
            Button("Delete Signature", role: .destructive) {
                signaturePendingDeletion = nil
                delete(template)
            }
            Button("Cancel", role: .cancel) {
                signaturePendingDeletion = nil
            }
        } message: { _ in
            Text("This saved signature cannot be recovered after deletion.")
        }
        .alert("Signature Library", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            store.load()
            if let loadError = store.lastLoadError {
                errorMessage = loadError
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 360)
#else
        .frame(minHeight: 360)
#endif
    }

    private func saveSignature(_ strokes: [SignatureStroke]) {
        do {
            let template = try SignatureLibraryTemplate(
                normalizedStrokes: strokes.map(\.points)
            )
            try store.add(template)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ template: SignatureLibraryTemplate) {
        do {
            try store.delete(id: template.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SignaturePreview: View {
    let strokes: [[CGPoint]]

    var body: some View {
        Canvas { context, size in
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                var path = Path()
                path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for point in stroke.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.stroke(path, with: .color(.primary), lineWidth: 2)
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.35)))
        .accessibilityHidden(true)
    }
}

struct SignaturePadView: View {
    let onSave: ([SignatureStroke]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Canvas { context, size in
                    for stroke in strokes + (currentStroke.isEmpty ? [] : [currentStroke]) {
                        guard let first = stroke.first else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.primary), lineWidth: 2)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            currentStroke.append(
                                CGPoint(
                                    x: min(max(value.location.x / max(proxy.size.width, 1), 0), 1),
                                    y: min(max(value.location.y / max(proxy.size.height, 1), 0), 1)
                                )
                            )
                        }
                        .onEnded { _ in
                            if currentStroke.count > 1 { strokes.append(currentStroke) }
                            currentStroke.removeAll()
                        }
                )
                .padding()
            }
            .navigationTitle("Handwritten Signature")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { strokes.removeAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Signature") {
                        onSave(strokes.map(SignatureStroke.init(points:)))
                        dismiss()
                    }
                    .disabled(strokes.isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
#else
        .frame(minHeight: 260)
#endif
    }
}

struct AnnotationInspectorView: View {
    let annotations: [PDFAnnotationSnapshot]
    @Binding var selectedAnnotation: PDFAnnotationSnapshot?
    let onApply: (PDFAnnotationSnapshot, PDFAnnotationUpdate) -> Void
    let onDelete: (PDFAnnotationSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(annotations) { annotation in
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: selectedAnnotation?.reference == annotation.reference,
                    onSelect: { selectedAnnotation = annotation },
                    onApply: { onApply(annotation, $0) },
                    onDelete: { onDelete(annotation) }
                )
            }
            .overlay {
                if annotations.isEmpty {
                    ContentUnavailableView("No annotations on this page", systemImage: "note.text")
                }
            }
            .navigationTitle("Page Annotations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

struct PDFCommentEditor: View {
    let annotation: PDFAnnotationSnapshot
    let onApply: (PDFAnnotationUpdate) -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                AnnotationEditorRow(
                    annotation: annotation,
                    isSelected: true,
                    onSelect: {},
                    onApply: onApply,
                    onDelete: {
                        onDelete()
                        onDismiss()
                    },
                    usesExpandedContentsEditor: true
                )
                .padding()
            }
            .navigationTitle("Comment Editor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
#if os(macOS)
        .onHover(perform: onHoverChanged)
#endif
    }
}

struct PDFAddCommentView: View {
    @Binding var text: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the message for the selected document location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.body)
                    .focused($isEditorFocused)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        guard keyPress.modifiers.contains(.shift), canAdd else {
                            return .ignored
                        }
                        onAdd()
                        dismiss()
                        return .handled
                    }
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Add a comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd()
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
            .onAppear { isEditorFocused = true }
        }
        .frame(minWidth: 320, idealWidth: 440, minHeight: 280, idealHeight: 320)
    }
}

private struct AnnotationEditorRow: View {
    let annotation: PDFAnnotationSnapshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onApply: (PDFAnnotationUpdate) -> Void
    let onDelete: () -> Void
    let usesExpandedContentsEditor: Bool

    @State private var contents: String
    @State private var color: PDFAnnotationColor
    @State private var opacity: Double
    @State private var fontSize: Double
    @State private var lineWidth: Double

    init(
        annotation: PDFAnnotationSnapshot,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onApply: @escaping (PDFAnnotationUpdate) -> Void,
        onDelete: @escaping () -> Void,
        usesExpandedContentsEditor: Bool = false
    ) {
        self.annotation = annotation
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onApply = onApply
        self.onDelete = onDelete
        self.usesExpandedContentsEditor = usesExpandedContentsEditor
        _contents = State(initialValue: annotation.contents)
        _color = State(initialValue: annotation.color)
        _opacity = State(initialValue: Double(annotation.color.alpha))
        _fontSize = State(initialValue: Double(annotation.fontSize ?? 11))
        _lineWidth = State(initialValue: Double(annotation.lineWidth))
    }

    private var supportsStyleChanges: Bool {
        !annotation.hasAppearanceStream || annotation.kind == .note ||
            annotation.kind == .freeText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(annotationTitle, systemImage: iconName)
                    .font(.headline)
                Spacer()
                Button(isSelected ? "Selected" : "Select on Page", action: onSelect)
                    .buttonStyle(.bordered)
                    .disabled(isSelected)
            }

            if annotation.kind == .note || annotation.kind == .freeText {
                if usesExpandedContentsEditor {
                    ZStack(alignment: .topLeading) {
                        Text(contents.isEmpty ? " " : contents)
                            .font(.body)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()

                        TextEditor(text: $contents)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 150)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
                } else {
                    TextField("Contents", text: $contents, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Text("Color")
                ForEach(colorPresets.indices, id: \.self) { index in
                    let preset = colorPresets[index]
                    Button {
                        color = preset.color.withAlpha(CGFloat(opacity))
                    } label: {
                        Circle()
                            .fill(swiftUIColor(preset.color))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if approximatelySameRGB(color, preset.color) {
                                    Circle().stroke(.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel("Change color to \(preset.name)")
                }
            }
            .disabled(!supportsStyleChanges)

            HStack {
                Text("Opacity")
                Slider(value: $opacity, in: 0.05...1)
                Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!supportsStyleChanges)

            if annotation.kind == .freeText {
                Stepper("Font size \(Int(fontSize)) pt", value: $fontSize, in: 6...144)
            }
            if annotation.kind == .ink {
                Stepper("Line width \(lineWidth.formatted(.number.precision(.fractionLength(1)))) pt", value: $lineWidth, in: 0.5...24, step: 0.5)
            }

            if !supportsStyleChanges {
                Label("This annotation has a fixed appearance. Only moving, resizing, and content changes are allowed.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Apply") {
                    onApply(PDFAnnotationUpdate(
                        contents: contents,
                        color: supportsStyleChanges ? color.withAlpha(CGFloat(opacity)) : nil,
                        fontColor: annotation.kind == .freeText && supportsStyleChanges
                            ? color.withAlpha(CGFloat(opacity))
                            : nil,
                        fontSize: annotation.kind == .freeText && supportsStyleChanges
                            ? CGFloat(fontSize)
                            : nil,
                        lineWidth: annotation.kind == .ink && supportsStyleChanges
                            ? CGFloat(lineWidth)
                            : nil
                    ))
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, 6)
    }

    private var colorPresets: [(name: String, color: PDFAnnotationColor)] {
        guard annotation.kind == .note else {
            return [
                ("Yellow", .yellow),
                ("Red", .red),
                ("Blue", .blue),
                ("Black", .black),
            ]
        }
        return [
            ("Red", .red),
            ("Orange", PDFAnnotationColor(
                red: 1,
                green: 0.5,
                blue: 0.05,
                alpha: 1
            )),
            ("Yellow", .yellow),
            ("Green", PDFAnnotationColor(
                red: 0.16,
                green: 0.68,
                blue: 0.32,
                alpha: 1
            )),
            ("Blue", .blue),
            ("Indigo", PDFAnnotationColor(
                red: 0.29,
                green: 0.25,
                blue: 0.78,
                alpha: 1
            )),
            ("Purple", PDFAnnotationColor(
                red: 0.63,
                green: 0.25,
                blue: 0.82,
                alpha: 1
            )),
        ]
    }

    private var annotationTitle: String {
        switch annotation.kind {
        case .note: "Comment"
        case .freeText: "Free Text"
        case .highlight: "Highlight"
        case .ink: "Signature / Ink"
        case .other: "Annotation"
        }
    }

    private var iconName: String {
        switch annotation.kind {
        case .note: "note.text"
        case .freeText: "textformat"
        case .highlight: "highlighter"
        case .ink: "signature"
        case .other: "square.and.pencil"
        }
    }

    private func swiftUIColor(_ color: PDFAnnotationColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func approximatelySameRGB(
        _ lhs: PDFAnnotationColor,
        _ rhs: PDFAnnotationColor
    ) -> Bool {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue) < 0.1
    }
}
