//
//  SidebarProjectList.swift
//  kero
//

import AppKit
import SwiftUI

/// The left sidebar's list of projects, AppKit-owned.
///
/// This was a SwiftUI `ForEach` whose rows re-evaluated whenever any terminal
/// published a title — several times a second under an active agent — which
/// is why the old row needed a fixed-width trailing slot to stop the strip
/// reflowing under the pointer. Now a title change writes one label, and a
/// project's activity badge repaints one image view.
///
/// Row content follows `SessionActivityDisplay`, so what the icon means lives
/// with the state machine rather than being restated here.
struct SidebarProjectList: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager
    /// Activity changes and elapsed-time ticks arrive here, not through any
    /// project property.
    @ObservedObject private var activity = SessionStateService.shared
    @ObservedObject private var themeChanges = Theme.changes
    let fontSize: Double

    init(manager: TerminalManager, fontSize: Double) {
        self.manager = manager
        self.fontSize = fontSize
    }

    func makeNSView(context: Context) -> SidebarProjectListView {
        SidebarProjectListView()
    }

    func updateNSView(_ view: SidebarProjectListView, context: Context) {
        _ = themeChanges
        _ = activity.revision
        view.manager = manager
        view.configure(
            rows: manager.projects.enumerated().map { index, project in
                SidebarProjectListView.Row(project: project, index: index, manager: manager)
            },
            fontSize: fontSize
        )
    }
}

@MainActor
final class SidebarProjectListView: NSView {
    /// Everything a row draws, flattened to values so an unchanged strip is
    /// one comparison rather than a walk of every project's sessions.
    struct Row: Equatable {
        let id: UUID
        let name: String
        let subtitle: String?
        /// True when the subtitle is something a session reported rather than
        /// Kero's own session count or directory. Reported text is drawn in
        /// the title's color so a row that has something to say looks brighter
        /// than one that is merely sitting there.
        let subtitleIsReported: Bool
        let activity: SessionActivityKind
        let isSelected: Bool
        /// ⌘1…⌘9 hint, for the first nine projects only.
        let shortcut: String?
        let hasCustomName: Bool
        let hasCustomDirectory: Bool

        @MainActor
        init(project: Project, index: Int, manager: TerminalManager) {
            let display = project.activityDisplay
            id = project.id
            name = project.name
            activity = display.kind
            isSelected = project.id == manager.selectedProjectID
            shortcut = index < 9 ? "⌘\(index + 1)" : nil
            hasCustomName = project.customName != nil
            hasCustomDirectory = project.customDirectory != nil

            // An active state replaces the directory line: what the agent is
            // doing is the more useful thing to know, and the directory is
            // still one hover away in the pane itself.
            if let stateText = display.subtitle() {
                subtitle = stateText
                subtitleIsReported = true
            } else if project.sessions.count > 1 {
                subtitle = String(
                    localized: "\(project.sessions.count) sessions",
                    comment: "Project row subtitle counting its terminal sessions."
                )
                subtitleIsReported = false
            } else {
                subtitle = project.selectedSession?.directoryLabel
                subtitleIsReported = false
            }
        }
    }

    weak var manager: TerminalManager?

    private let scrollView = NSScrollView()
    private let content = FlippedView()
    private var rowViews: [SidebarProjectRowView] = []
    private var rows: [Row] = []
    private var fontSize: Double = AppSettings.defaultSidebarFontSize
    private var draggingProjectID: UUID?

    private static let horizontalInset: CGFloat = 8
    private static let topInset: CGFloat = 8
    private static let rowSpacing: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = content
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(rows next: [Row], fontSize: Double) {
        guard next != rows || fontSize != self.fontSize else { return }
        let countChanged = next.count != rows.count
        rows = next
        self.fontSize = fontSize

        while rowViews.count < next.count {
            let row = SidebarProjectRowView()
            row.onSelect = { [weak self] id in self?.select(id) }
            row.onClose = { [weak self] id in self?.close(id) }
            row.onRename = { [weak self] id, name in self?.rename(id, to: name) }
            row.onClearName = { [weak self] id in self?.rename(id, to: nil) }
            row.onPickDirectory = { [weak self] id in self?.pickDirectory(id) }
            row.onClearDirectory = { [weak self] id in self?.clearDirectory(id) }
            row.onDrag = { [weak self] id, point in self?.dragRow(id, to: point) }
            row.onDragEnded = { [weak self] in self?.endDrag() }
            content.addSubview(row)
            rowViews.append(row)
        }
        while rowViews.count > next.count {
            rowViews.removeLast().removeFromSuperview()
        }

        for (view, row) in zip(rowViews, next) {
            view.configure(row: row, fontSize: fontSize)
        }
        if countChanged {
            invalidateIntrinsicContentSize()
        }
        layoutRows()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        let width = max(0, bounds.width - Self.horizontalInset * 2)
        var y = Self.topInset
        for view in rowViews {
            let height = view.preferredHeight
            view.frame = NSRect(x: Self.horizontalInset, y: y, width: width, height: height)
            y += height + Self.rowSpacing
        }
        let total = max(y - Self.rowSpacing + Self.topInset, 0)
        content.frame = NSRect(
            x: 0, y: 0, width: bounds.width, height: max(total, bounds.height)
        )
    }

    // MARK: - Actions

    private func project(_ id: UUID) -> Project? {
        manager?.projects.first { $0.id == id }
    }

    private func select(_ id: UUID) {
        manager?.selectedProjectID = id
    }

    private func close(_ id: UUID) {
        guard let project = project(id) else { return }
        manager?.close(project)
    }

    private func rename(_ id: UUID, to name: String?) {
        project(id)?.customName = Project.normalizedCustomName(name)
    }

    private func clearDirectory(_ id: UUID) {
        project(id)?.customDirectory = nil
    }

    /// Lets the user pin the project's directory — the root the file tree and
    /// git panels anchor to instead of the automatic closest-git-repo.
    private func pickDirectory(_ id: UUID) {
        guard let project = project(id) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(
            localized: "Choose", comment: "Button in the project directory picker."
        )
        panel.message = String(
            localized: "Choose the directory for “\(project.name)”.",
            comment: "Message in the project directory picker. The placeholder is a project name."
        )
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    // MARK: - Reordering

    /// `point` is in window coordinates; the row under it is the drop target,
    /// matching the old frame-intersection drag.
    private func dragRow(_ id: UUID, to point: NSPoint) {
        draggingProjectID = id
        NSCursor.closedHand.set()
        let local = content.convert(point, from: nil)
        guard let targetIndex = rowViews.firstIndex(where: { $0.frame.contains(local) }),
              targetIndex < rows.count
        else { return }
        let target = rows[targetIndex].id
        guard target != id else { return }
        manager?.moveProject(id, to: target)
    }

    private func endDrag() {
        draggingProjectID = nil
        NSCursor.arrow.set()
    }
}

/// The document view of the project list. Sidebars lay out top-down, so it is
/// flipped; without this every row would be positioned from the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

@MainActor
final class SidebarProjectRowView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onClearName: ((UUID) -> Void)?
    var onPickDirectory: ((UUID) -> Void)?
    var onClearDirectory: ((UUID) -> Void)?
    var onDrag: ((UUID, NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    private var row: SidebarProjectListView.Row?
    private var fontSize: Double = AppSettings.defaultSidebarFontSize
    private var isHovering = false
    private var isRenaming = false
    private var dragOrigin: NSPoint?
    /// The project picked up at mouse-down. Row views are positional, so a
    /// reorder mid-drag hands this view a *different* project; without
    /// remembering the original, the second drag step would move whichever
    /// project had just slid underneath.
    private var dragProjectID: UUID?
    private var trackingArea: NSTrackingArea?

    /// Rows lay out top-down like the sidebar they sit in, so the title comes
    /// first and the subtitle sits under it.
    override var isFlipped: Bool { true }

    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 6
    private static let iconSpacing: CGFloat = 8
    /// Close button and ⌘N hint share this width so hover never reflows the
    /// row — the same fixed trailing slot the SwiftUI version needed.
    private static let trailingSlotWidth: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.imageScaling = .scaleProportionallyUpOrDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.cell?.usesSingleLineMode = true
        shortcutField.alignment = .right

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(
                localized: "Close Project",
                comment: "Accessibility label for the button closing a project."
            )
        )
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 9, weight: .bold
        )
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true

        for subview in [icon, titleField, subtitleField, shortcutField, closeButton] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(row next: SidebarProjectListView.Row, fontSize: Double) {
        let fontChanged = fontSize != self.fontSize
        guard next != row || fontChanged else { return }
        let previous = row
        row = next
        self.fontSize = fontSize

        if fontChanged || previous == nil {
            titleField.font = .systemFont(ofSize: titleFontSize)
            subtitleField.font = .systemFont(ofSize: supportingFontSize)
            shortcutField.font = .systemFont(ofSize: supportingFontSize)
        }

        // Only touch what moved: a live terminal title republishes constantly,
        // and setting an NSTextField's value re-lays out its cell.
        if previous?.name != next.name, !isRenaming {
            titleField.stringValue = next.name
        }
        if previous?.subtitle != next.subtitle {
            subtitleField.stringValue = next.subtitle ?? ""
            subtitleField.isHidden = next.subtitle == nil
        }
        if previous?.shortcut != next.shortcut {
            shortcutField.stringValue = next.shortcut ?? ""
        }
        if previous?.activity != next.activity
            || previous?.isSelected != next.isSelected
            || fontChanged {
            applyIcon(next)
        }
        let titleColor: NSColor = next.isSelected ? .labelColor : .secondaryLabelColor
        if previous?.isSelected != next.isSelected {
            titleField.textColor = titleColor
        }
        // Reported text matches the project name; the standing session count
        // and directory stay quiet. Brightness is what says "something
        // happened here", so it is spent only on that.
        subtitleField.textColor = next.subtitleIsReported ? titleColor : .tertiaryLabelColor
        shortcutField.textColor = .tertiaryLabelColor

        applyBackground()
        applyAccessibility(next)
        needsLayout = true
    }

    private func applyIcon(_ row: SidebarProjectListView.Row) {
        icon.image = NSImage(
            systemSymbolName: row.activity.symbolName,
            accessibilityDescription: row.activity.accessibilityDescription
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: iconPointSize, weight: .medium
        )
        // A state tint is the state's own color; the default and attention
        // states keep the strip's ordinary selected/unselected appearance.
        icon.contentTintColor = row.activity.tint
            ?? (row.isSelected ? Theme.accent : .secondaryLabelColor)
    }

    private func applyAccessibility(_ row: SidebarProjectListView.Row) {
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        // State is spoken as part of the row, so it never depends on noticing
        // a badge or a color.
        if let state = row.activity.accessibilityDescription {
            setAccessibilityLabel("\(row.name) — \(state)")
        } else {
            setAccessibilityLabel(row.name)
        }
    }

    private func applyBackground() {
        let selected = row?.isSelected == true
        let alpha: CGFloat = selected ? 0.09 : (isHovering ? 0.04 : 0)
        layer?.backgroundColor = alpha > 0
            ? NSColor.labelColor.withAlphaComponent(alpha).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Layout

    private var sidebarFontScale: Double {
        fontSize / AppSettings.defaultSidebarFontSize
    }

    /// Matches the file-tree label's designed 11.5 pt while following the
    /// shared sidebar font-size setting.
    private var titleFontSize: Double { 11.5 * sidebarFontScale }
    private var supportingFontSize: Double { 10 * sidebarFontScale }
    /// The activity glyph reads as a peer of the title rather than a footnote,
    /// so it sits a touch above it and follows the same font-size setting.
    private var iconPointSize: Double { 13 * sidebarFontScale }

    var preferredHeight: CGFloat {
        let title = ceil(titleField.font?.boundingRectForFont.height ?? 14)
        guard row?.subtitle != nil else {
            return title + Self.verticalPadding * 2
        }
        let subtitle = ceil(subtitleField.font?.boundingRectForFont.height ?? 12)
        return title + 1 + subtitle + Self.verticalPadding * 2
    }

    override func layout() {
        super.layout()
        // Square, and sized from the glyph rather than the row: the image view
        // scales to fill its frame, so the box is what the eye actually reads
        // as the icon's size.
        let iconBox = ceil(CGFloat(iconPointSize) * 1.3)
        var x = Self.horizontalPadding
        let titleHeight = ceil(titleField.font?.boundingRectForFont.height ?? 14)
        let subtitleHeight = ceil(subtitleField.font?.boundingRectForFont.height ?? 12)
        let hasSubtitle = row?.subtitle != nil

        icon.frame = NSRect(
            x: x,
            y: (bounds.height - iconBox) / 2,
            width: iconBox,
            height: iconBox
        )
        x += iconBox + Self.iconSpacing

        let textWidth = max(
            0,
            bounds.width - x - Self.trailingSlotWidth - Self.horizontalPadding
        )
        let blockHeight = hasSubtitle ? titleHeight + 1 + subtitleHeight : titleHeight
        let top = (bounds.height - blockHeight) / 2

        titleField.frame = NSRect(x: x, y: top, width: textWidth, height: titleHeight)
        subtitleField.frame = NSRect(
            x: x, y: top + titleHeight + 1, width: textWidth, height: subtitleHeight
        )

        let slotX = bounds.width - Self.horizontalPadding - Self.trailingSlotWidth
        let slot = NSRect(
            x: slotX, y: (bounds.height - 16) / 2,
            width: Self.trailingSlotWidth, height: 16
        )
        closeButton.frame = slot
        shortcutField.frame = slot
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyBackground()
        updateTrailingSlot()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyBackground()
        updateTrailingSlot()
    }

    private func updateTrailingSlot() {
        let showClose = isHovering && !isRenaming
        closeButton.isHidden = !showClose
        shortcutField.isHidden = showClose || isRenaming || row?.shortcut == nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming, let id = row?.id else { return }
        dragOrigin = event.locationInWindow
        dragProjectID = id
        onSelect?(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let dragProjectID else { return }
        let distance = hypot(
            event.locationInWindow.x - dragOrigin.x,
            event.locationInWindow.y - dragOrigin.y
        )
        guard distance >= 4 else { return }
        // Window coordinates: the list converts once, into the coordinate
        // space its row frames actually live in.
        onDrag?(dragProjectID, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        if dragProjectID != nil {
            onDragEnded?()
        }
        dragOrigin = nil
        dragProjectID = nil
    }

    @objc private func closeClicked() {
        guard let id = row?.id else { return }
        onClose?(id)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row else { return nil }
        let menu = NSMenu()
        menu.addItem(
            item(
                String(localized: "Rename…", comment: "Project row context menu item."),
                #selector(beginRename)
            )
        )
        if row.hasCustomName {
            menu.addItem(
                item(
                    String(
                        localized: "Use Automatic Title",
                        comment: "Project row context menu item restoring the terminal-derived title."
                    ),
                    #selector(clearName)
                )
            )
        }
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(
                    localized: "Set Project Directory…",
                    comment: "Project row context menu item pinning the project's directory."
                ),
                #selector(pickDirectory)
            )
        )
        if row.hasCustomDirectory {
            menu.addItem(
                item(
                    String(
                        localized: "Use Automatic Directory",
                        comment: "Project row context menu item restoring the automatic project directory."
                    ),
                    #selector(clearDirectory)
                )
            )
        }
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(
                    localized: "Close Project",
                    comment: "Project row context menu item."
                ),
                #selector(closeClicked)
            )
        )
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func clearName() {
        guard let id = row?.id else { return }
        onClearName?(id)
    }

    @objc private func pickDirectory() {
        guard let id = row?.id else { return }
        onPickDirectory?(id)
    }

    @objc private func clearDirectory() {
        guard let id = row?.id else { return }
        onClearDirectory?(id)
    }

    // MARK: - Rename

    @objc private func beginRename() {
        guard let row else { return }
        isRenaming = true
        titleField.stringValue = row.name
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        updateTrailingSlot()
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard isRenaming, let row else { return }
        isRenaming = false
        titleField.isEditable = false
        titleField.isSelectable = false
        if commit {
            onRename?(row.id, titleField.stringValue)
        } else {
            titleField.stringValue = row.name
        }
        updateTrailingSlot()
        window?.makeFirstResponder(nil)
    }
}

extension SidebarProjectRowView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }
}
