// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import Quartz

/// Which captures the grid is showing. Recordings and stills are different enough
/// errands — one gets trimmed and shared, the other pinned and marked up — that
/// narrowing to one kind is worth a control.
private enum HistoryFilter: Int, CaseIterable {
    case all, images, videos
    var label: String {
        switch self {
        case .all:    return L("All")
        case .images: return L("Images")
        case .videos: return L("Videos")
        }
    }
}

/// Which way an arrow key moves the selection.
private enum HistoryMove { case left, right, up, down }

/// Capture history: a brand panel showing the most recent captures from the save
/// folder as a thumbnail grid, grouped by the day they were taken. Hovering a cell
/// reveals its actions — Copy, Pin (images) or Trim (recordings), Reveal in Finder,
/// Delete (to Trash); double-click opens the file, and a cell can be dragged straight
/// into another app.
///
/// It's a live view over the folder (rebuilt on every open), not a database —
/// captures saved elsewhere, renamed off the capture prefix, or moved away simply
/// don't appear, and unrelated images sharing the folder are filtered out.
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: PanelWindow?
    private var stack: NSStackView!
    private var gridView: HistoryGridView!
    private var emptyView: NSView!
    private var filterBar: HistoryFilterBar!

    private var filter: HistoryFilter = .all
    /// Cells in display order, and the visual rows they sit in — the arrow keys walk
    /// the rows, not the flat order, so a short last row in one day's group doesn't
    /// send Down into the wrong column of the next day's.
    private var cells: [HistoryCell] = []
    private var rows: [[Int]] = []
    private var selection: Int?

    private static let maxItems = 24
    private static let columns = 4
    private static let cellSize = NSSize(width: 152, height: 132)
    private static let gap: CGFloat = 12
    private static let headingHeight: CGFloat = 14
    /// Air above a day heading that follows another group, so the heading reads as
    /// belonging to the run under it rather than floating between two.
    private static let headingTopGap: CGFloat = 10

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    private static let videoExts: Set<String> = ["mp4", "mov"]

    func show() {
        rebuild(keepPosition: false)
        AppPanels.closeAll(except: window)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(gridView)
    }

    /// The panel is rebuilt on every open (and after a delete or a filter change),
    /// sized to what's actually in the folder: fewer files → fewer columns/rows, no sea
    /// of empty gradient around three thumbnails. Caps at 4×3 cells; more files scroll.
    private func rebuild(keepPosition: Bool) {
        let files = Self.captureFiles(filter: filter)
        let groups = Self.grouped(files)
        let previousFrame = window?.frame
        let wasVisible = window?.isVisible ?? false
        let previousFilter = filter
        window?.orderOut(nil)

        let widest = groups.map { $0.items.count }.max() ?? 0
        let cols = max(1, min(Self.columns, widest))
        build(columns: max(2, cols), gridHeight: Self.gridHeight(groups, columns: cols))
        filterBar.selected = previousFilter.rawValue
        populate(groups, columns: cols)

        if keepPosition, let prev = previousFrame, let w = window {
            // Keep the top-left corner planted through the resize.
            var f = w.frame
            f.origin = CGPoint(x: prev.minX, y: prev.maxY - f.height)
            w.setFrame(f, display: true)
        } else {
            window?.centerOnActiveScreen()
        }
        if wasVisible || !keepPosition {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(gridView)
        }
    }

    /// The save folder's capture files, newest first, capped at `maxItems`.
    /// Only files this app named (`Settings.isCaptureFile`) — the save folder is
    /// the Desktop by default, and everything else living there is not history.
    private static func captureFiles(filter: HistoryFilter) -> [URL] {
        let dir = Settings.shared.saveDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return Array(files
            .filter { url in
                guard Settings.shared.isCaptureFile(url) else { return false }
                let ext = url.pathExtension.lowercased()
                switch filter {
                case .all:    return imageExts.contains(ext) || videoExts.contains(ext)
                case .images: return imageExts.contains(ext)
                case .videos: return videoExts.contains(ext)
                }
            }
            .sorted { modified($0) > modified($1) }
            .prefix(maxItems))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Split the (already newest-first) files into day runs. Naming the day once per run
    /// is what lets a cell's own caption shrink to a bare time — the date it belongs to is
    /// already overhead, so every cell repeating it was noise.
    private static func grouped(_ files: [URL]) -> [(title: String, items: [URL])] {
        let cal = Calendar.current
        var out: [(title: String, items: [URL])] = []
        for url in files {
            let date = modified(url)
            let title: String
            if cal.isDateInToday(date) {
                title = L("Today")
            } else if cal.isDateInYesterday(date) {
                title = L("Yesterday")
            } else {
                let df = DateFormatter()
                df.setLocalizedDateFormatFromTemplate("d MMM")
                title = df.string(from: date)
            }
            if out.last?.title == title {
                out[out.count - 1].items.append(url)
            } else {
                out.append((title, [url]))
            }
        }
        return out
    }

    /// How tall the grid wants to be, capped at three rows' worth so a full folder
    /// scrolls instead of growing a panel taller than the screen.
    private static func gridHeight(_ groups: [(title: String, items: [URL])], columns: Int) -> CGFloat {
        guard columns > 0 else { return cellSize.height }
        var total: CGFloat = 0
        for (index, group) in groups.enumerated() {
            if index > 0 { total += gap + headingTopGap }
            total += headingHeight + gap
            let rowCount = CGFloat(Int(ceil(Double(group.items.count) / Double(columns))))
            total += rowCount * cellSize.height + (rowCount - 1) * gap
        }
        let cap = 3 * cellSize.height + 2 * gap + headingHeight + gap
        return max(cellSize.height, min(total, cap))
    }

    private func build(columns: Int, gridHeight: CGFloat) {
        let side: CGFloat = 24
        let cols = CGFloat(columns)
        let contentW = cols * Self.cellSize.width + (cols - 1) * Self.gap
        let size = NSSize(width: contentW + side * 2, height: gridHeight + 96)

        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isMovableByWindowBackground = true
        w.backgroundColor = Theme.surfaceBase
        w.onClose = { [weak w] in w?.orderOut(nil) }

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        _ = Theme.applyPanelGradient(to: content)

        let title = NSTextField(labelWithString: "")
        Theme.styleEyebrow(title, L("HISTORY"))
        title.sizeToFit()
        title.frame.origin = CGPoint(x: side, y: size.height - 42)
        content.addSubview(title)

        // Filter tabs share the header line with the eyebrow, right-aligned so they sit
        // clear of the close button's column and read as a control on the title row
        // rather than as a second heading.
        let bar = HistoryFilterBar(titles: HistoryFilter.allCases.map { $0.label })
        bar.onSelect = { [weak self] index in
            guard let self, let picked = HistoryFilter(rawValue: index), picked != self.filter else { return }
            self.filter = picked
            self.rebuild(keepPosition: true)
        }
        bar.layoutSubtreeIfNeeded()
        let barSize = bar.fittingSize
        bar.frame = NSRect(x: size.width - side - barSize.width - 26,
                           y: size.height - 52, width: barSize.width, height: barSize.height)
        content.addSubview(bar)
        filterBar = bar

        let rowStack = NSStackView(views: [])
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = Self.gap
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        stack = rowStack

        let scroll = NSScrollView(frame: NSRect(x: side, y: 20, width: contentW,
                                                height: size.height - 76))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = HistoryGridView(frame: NSRect(origin: .zero, size: NSSize(width: contentW, height: gridHeight)))
        doc.onMove = { [weak self] in self?.move($0) }
        doc.onOpen = { [weak self] in self?.selectedCell?.openItem() }
        doc.onCopy = { [weak self] in self?.selectedCell?.copyItem() }
        doc.onDelete = { [weak self] in self?.selectedCell?.deleteItem() }
        doc.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        doc.previewURL = { [weak self] in self?.selectedCell?.fileURL }
        doc.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rowStack.topAnchor.constraint(equalTo: doc.topAnchor),
        ])
        scroll.documentView = doc
        content.addSubview(scroll)
        gridView = doc

        content.addSubview(buildEmptyState(width: size.width, height: size.height, side: side))

        w.contentView = content
        w.installChrome(on: content)
        window = w
    }

    /// Empty state: a glyph, the plain fact, and what to do about it. Wrapping and
    /// centered, sized against THIS panel's width — the German and Vietnamese strings
    /// are longer than the English one and a single-line label with a fixed origin
    /// overflows the narrow empty-state panel.
    private func buildEmptyState(width: CGFloat, height: CGFloat, side: CGFloat) -> NSView {
        let box = NSView(frame: NSRect(x: side, y: 0, width: width - side * 2, height: height - 60))
        let maxW = box.bounds.width

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .light))
        glyph.contentTintColor = Theme.textMuted.withAlphaComponent(0.45)
        glyph.imageScaling = .scaleNone

        let title = NSTextField(wrappingLabelWithString: L("No captures yet."))
        title.font = Theme.font(13, .medium)
        title.textColor = Theme.textSecondary
        title.alignment = .center
        title.preferredMaxLayoutWidth = maxW

        let hint = NSTextField(wrappingLabelWithString: L("Screenshots and recordings you take appear here."))
        hint.font = Theme.font(11)
        hint.textColor = Theme.textMuted
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = maxW

        let titleH = title.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude)).height
        let hintH = hint.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude)).height
        let blockH = 30 + 8 + titleH + 4 + hintH
        var y = box.bounds.midY + blockH / 2 - 30
        glyph.frame = NSRect(x: (maxW - 30) / 2, y: y, width: 30, height: 30)
        y -= titleH + 8
        title.frame = NSRect(x: 0, y: y, width: maxW, height: ceil(titleH) + 2)
        y -= hintH + 4
        hint.frame = NSRect(x: 0, y: y, width: maxW, height: ceil(hintH) + 2)

        box.addSubview(glyph); box.addSubview(title); box.addSubview(hint)
        box.isHidden = true
        emptyView = box
        return box
    }

    /// Fill the grid: a day heading per group, then that day's cells `columns` per row.
    private func populate(_ groups: [(title: String, items: [URL])], columns: Int) {
        guard let stack else { return }
        emptyView.isHidden = !groups.isEmpty
        filterBar.isHidden = groups.isEmpty && filter == .all

        cells = []
        rows = []
        var views: [NSView] = []
        // A day heading is just a label in the run — the extra air above one that follows
        // another group is stack spacing, not a padded container, so nothing has to carry
        // a width the grid alone should decide.
        var extraSpacingAfter: [Int] = []
        for (index, group) in groups.enumerated() {
            if index > 0, !views.isEmpty { extraSpacingAfter.append(views.count - 1) }
            let label = NSTextField(labelWithString: "")
            Theme.styleEyebrow(label, group.title, size: 9, color: Theme.textMuted)
            views.append(label)
            for chunk in stride(from: 0, to: group.items.count, by: columns) {
                let slice = group.items[chunk..<min(chunk + columns, group.items.count)]
                var rowIndices: [Int] = []
                let rowCells: [HistoryCell] = slice.map { url in
                    let made = cell(for: url)
                    rowIndices.append(cells.count)
                    cells.append(made)
                    return made
                }
                let row = NSStackView(views: rowCells)
                row.orientation = .horizontal
                row.spacing = Self.gap
                views.append(row)
                rows.append(rowIndices)
            }
        }
        stack.setViews(views, in: .top)
        for index in extraSpacingAfter { stack.setCustomSpacing(Self.gap + Self.headingTopGap, after: views[index]) }
        stack.layoutSubtreeIfNeeded()
        // Size the flipped document view to the grid so scrolling starts at the top.
        if let doc = stack.superview {
            doc.frame.size.height = max(stack.fittingSize.height,
                                        doc.superview?.frame.height ?? 0)
        }
        // Start on the newest capture: it is the one the user just took (History opens
        // after every save), and a live selection is what makes the arrow keys usable
        // without hunting for a click first.
        select(cells.isEmpty ? nil : 0, scroll: false)
    }

    private func cell(for url: URL) -> HistoryCell {
        let isVideo = Self.videoExts.contains(url.pathExtension.lowercased())
        let cell = HistoryCell(url: url, size: Self.cellSize, isVideo: isVideo)
        cell.onChanged = { [weak self] in self?.rebuild(keepPosition: true) }
        cell.onSelect = { [weak self] in
            guard let self, let index = self.cells.firstIndex(where: { $0 === cell }) else { return }
            self.select(index, scroll: false)
        }
        cell.hostWindow = { [weak self] in self?.window }
        return cell
    }

    // MARK: - Selection

    private var selectedCell: HistoryCell? {
        guard let selection, cells.indices.contains(selection) else { return nil }
        return cells[selection]
    }

    private func select(_ index: Int?, scroll: Bool) {
        if let old = selection, cells.indices.contains(old) { cells[old].isSelected = false }
        selection = index
        guard let index, cells.indices.contains(index) else { return }
        let cell = cells[index]
        cell.isSelected = true
        if scroll { cell.scrollToVisible(cell.bounds.insetBy(dx: 0, dy: -Self.gap)) }
    }

    /// Arrow keys walk the visual rows. Left/Right run along the flat order so they
    /// cross a day boundary the way reading order does; Up/Down hold the column and
    /// clamp to the neighbouring row's width, which is what keeps a short final row
    /// from throwing the selection into the wrong column of the next group.
    private func move(_ direction: HistoryMove) {
        guard !cells.isEmpty else { return }
        guard let current = selection else { select(0, scroll: true); return }
        switch direction {
        case .left:  select(max(0, current - 1), scroll: true)
        case .right: select(min(cells.count - 1, current + 1), scroll: true)
        case .up, .down:
            guard let rowIndex = rows.firstIndex(where: { $0.contains(current) }),
                  let column = rows[rowIndex].firstIndex(of: current) else { return }
            let targetRow = direction == .up ? rowIndex - 1 : rowIndex + 1
            guard rows.indices.contains(targetRow) else { return }
            let row = rows[targetRow]
            select(row[min(column, row.count - 1)], scroll: true)
        }
    }

    /// Space previews the selection, and closes the preview if it is already up —
    /// the same toggle Finder gives it.
    private func toggleQuickLook() {
        guard selectedCell != nil else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }
}

/// The grid's document view: flipped so the first row sits at the top of the scroller,
/// and the panel's first responder so the keyboard can drive the whole surface. It owns
/// no state — every key is forwarded to the controller, which knows the selection.
private final class HistoryGridView: NSView {
    var onMove: ((HistoryMove) -> Void)?
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var previewURL: (() -> URL?)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Unhandled keys must reach `super` — Esc closing the panel is
    /// `PanelWindow.cancelOperation`, which only runs if nothing here consumes it.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return }
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: onMove?(.left)
        case 124: onMove?(.right)
        case 125: onMove?(.down)
        case 126: onMove?(.up)
        case 36, 76: onOpen?()          // Return / Enter
        case 49: onQuickLook?()         // Space
        case 51, 117: onDelete?()       // Delete / Forward-delete
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension HistoryGridView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL?() as NSURL?
    }
}

/// The header's All / Images / Videos control: the same underlined tabs Settings uses
/// for its sub-sections, without that bar's full-width baseline rule — three short
/// words on a panel header need no rule under them to read as a set.
private final class HistoryFilterBar: NSView {
    var onSelect: ((Int) -> Void)?
    var selected = 0 { didSet { tabs.enumerated().forEach { $1.isSelected = $0 == selected } } }
    private var tabs: [SectionTab] = []

    init(titles: [String]) {
        super.init(frame: .zero)
        tabs = titles.enumerated().map { index, title in
            let tab = SectionTab(title: title, font: Theme.font(11, .medium))
            tab.isSelected = index == 0
            tab.onClick = { [weak self] in
                self?.selected = index
                self?.onSelect?(index)
            }
            return tab
        }
        let stack = NSStackView(views: tabs)
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One capture in the history grid: thumbnail, one quiet caption, and hover actions.
private final class HistoryCell: NSView {
    let fileURL: URL
    private let isVideo: Bool
    private let thumb = NSImageView()
    private let thumbBox = NSView()
    private let durationPill = NSTextField(labelWithString: "")
    private let actions = NSStackView(views: [])
    private var hovering = false { didSet { actions.isHidden = !hovering; restyle() } }
    var isSelected = false { didSet { restyle() } }
    /// Called after an action changed the folder (delete) so the grid reloads.
    var onChanged: (() -> Void)?
    /// Called when a click lands on this cell, so the controller can move the selection.
    var onSelect: (() -> Void)?
    /// The panel this cell lives in — toasts and the trim panel need it, and it is
    /// resolved lazily because the cell is built before the window is finished.
    var hostWindow: (() -> PanelWindow?)?

    /// Where a press started, for telling a click apart from the beginning of a drag.
    private var pressOrigin: NSPoint?

    init(url: URL, size: NSSize, isVideo: Bool) {
        self.fileURL = url
        self.isVideo = isVideo
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall
        layer?.backgroundColor = Theme.surfaceRaised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor

        // Thumbnail sits in its own inset, letterboxed frame so mismatched aspect
        // ratios still read as a tidy grid.
        let inset: CGFloat = 6
        let captionH: CGFloat = 14
        let thumbH = size.height - captionH - inset * 2 - 4
        thumbBox.frame = NSRect(x: inset, y: captionH + inset + 2, width: size.width - inset * 2, height: thumbH)
        thumbBox.wantsLayer = true
        thumbBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        thumbBox.layer?.cornerRadius = Theme.radiusSmall
        thumbBox.layer?.masksToBounds = true
        addSubview(thumbBox)
        thumb.frame = thumbBox.bounds
        thumb.autoresizingMask = [.width, .height]
        // Center-cropped to the box's aspect ratio (not proportional fit): a fit would
        // letterbox a portrait screenshot down to a sliver next to a landscape one that
        // fills its box, reading as "different sizes" even though every card is the same
        // fixed size. Cropping first makes every thumbnail actually fill the same area.
        thumb.imageScaling = .scaleAxesIndependently
        thumbBox.addSubview(thumb)

        // Recordings carry their length on the thumbnail. It is the one thing about a
        // capture you cannot read off the picture, and it tells the two kinds apart at a
        // glance better than a bare play badge did.
        if isVideo {
            durationPill.font = Theme.font(9, .semibold)
            durationPill.textColor = Theme.textPrimary
            durationPill.alignment = .center
            durationPill.wantsLayer = true
            durationPill.drawsBackground = false
            durationPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            durationPill.layer?.cornerRadius = Theme.radiusSmall
            durationPill.stringValue = "–:––"
            durationPill.sizeToFit()
            durationPill.frame = NSRect(x: thumbBox.bounds.maxX - 42, y: 5, width: 37, height: 14)
            durationPill.autoresizingMask = [.minXMargin]
            thumbBox.addSubview(durationPill)
            loadDuration()
        }

        let caption = NSTextField(labelWithString: Self.caption(for: url))
        caption.font = Theme.font(10, .medium)
        caption.textColor = Theme.textSecondary
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.frame = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: captionH)
        addSubview(caption)

        buildActions()
        loadThumbnail(fitting: thumbBox.frame.size)
        toolTip = url.lastPathComponent
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(url.lastPathComponent)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A bare time inside a day's run — the day itself is already the heading above,
    /// and something taken minutes ago reads better as an age than as a clock reading.
    private static func caption(for url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return "" }
        let age = Date().timeIntervalSince(date)
        if age < 60 { return L("Just now") }
        if age < 3600 {
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated
            f.allowedUnits = [.minute]
            let minutes = f.string(from: age) ?? ""
            return String(format: L("%@ ago"), minutes)
        }
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }

    /// Hover and selection share the ring but not its weight: hover is a hint that the
    /// pointer is here, selection is where the keyboard is and has to survive the
    /// pointer moving away.
    private func restyle() {
        if isSelected {
            layer?.borderColor = Theme.lavender.cgColor
            layer?.borderWidth = 2
        } else if hovering {
            layer?.borderColor = Theme.lavender.withAlphaComponent(0.7).cgColor
            layer?.borderWidth = 1.5
        } else {
            layer?.borderColor = Theme.border.cgColor
            layer?.borderWidth = 1
        }
    }

    private func buildActions() {
        func icon(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSView {
            HistoryIconButton(symbol: symbol, tip: tip, onClick: action)
        }
        actions.orientation = .horizontal
        actions.spacing = 4
        var views: [NSView] = [
            icon("doc.on.doc", L("Copy"), { [weak self] in self?.copyItem() }),
        ]
        if !isVideo {
            views.append(icon("pin", L("Pin to screen"), { [weak self] in self?.pinItem() }))
        } else {
            // Recordings can be trimmed in place; the trim panel overwrites the
            // file losslessly and reopens History when it saves.
            views.append(icon("scissors", L("Trim"), { [weak self] in
                guard let self else { return }
                self.hostWindow?()?.orderOut(nil)
                TrimWindowController.show(url: self.fileURL)
            }))
        }
        views += [
            icon("magnifyingglass", L("Reveal in Finder"), { [weak self] in self?.revealItem() }),
            icon("trash", L("Move to Trash"), { [weak self] in self?.deleteItem() }),
        ]
        actions.setViews(views, in: .center)
        actions.isHidden = true
        actions.wantsLayer = true
        actions.layer?.backgroundColor = Theme.surfaceBase.withAlphaComponent(0.85).cgColor
        actions.layer?.cornerRadius = Theme.radiusSmall
        actions.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerXAnchor.constraint(equalTo: centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: thumbBox.centerYAnchor),
        ])
    }

    /// Thumbnail load off the main thread; videos take their first frame. The result is
    /// center-cropped to `fit`'s aspect ratio so every thumbnail — whatever its source
    /// aspect ratio — visually fills the same box (see `imageScaling` above).
    private func loadThumbnail(fitting fit: NSSize) {
        let url = self.fileURL, isVideo = self.isVideo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cg: CGImage?
            if isVideo {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: fit.width * 2, height: fit.height * 2)
                cg = try? gen.copyCGImage(at: .zero, actualTime: nil)
            } else if let src = NSImage(contentsOf: url) {
                var rect = NSRect(origin: .zero, size: src.size)
                cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            let image = cg.map { NSImage(cgImage: Self.centerCropped($0, toAspect: fit.width / fit.height), size: .zero) }
            DispatchQueue.main.async { self?.thumb.image = image }
        }
    }

    private func loadDuration() {
        let url = self.fileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            guard seconds.isFinite, seconds >= 0 else { return }
            let text = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            DispatchQueue.main.async { self?.durationPill.stringValue = text }
        }
    }

    /// Crops `cg` to `aspect` (width/height), keeping its center — the larger of the
    /// two axes is trimmed down until the ratio matches, so nothing is stretched.
    private static func centerCropped(_ cg: CGImage, toAspect aspect: CGFloat) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0, aspect > 0 else { return cg }
        let currentAspect = w / h
        var cropRect = CGRect(x: 0, y: 0, width: w, height: h)
        if currentAspect > aspect {
            // Too wide — trim the sides.
            let targetW = h * aspect
            cropRect = CGRect(x: (w - targetW) / 2, y: 0, width: targetW, height: h)
        } else if currentAspect < aspect {
            // Too tall — trim top/bottom.
            let targetH = w / aspect
            cropRect = CGRect(x: 0, y: (h - targetH) / 2, width: w, height: targetH)
        }
        return cg.cropping(to: cropRect) ?? cg
    }

    // MARK: - Actions

    func openItem() { NSWorkspace.shared.open(fileURL) }

    func copyItem() {
        NSPasteboard.general.clearContents()
        if !isVideo, let img = NSImage(contentsOf: fileURL) {
            NSPasteboard.general.writeObjects([img])
        } else {
            NSPasteboard.general.writeObjects([fileURL as NSURL])
        }
        BrandToast.show(L("Copied to clipboard"), on: hostWindow?()?.screen)
    }

    private func pinItem() {
        guard let img = NSImage(contentsOf: fileURL), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        // Place it centered on the panel's screen at roughly half the image's point
        // size, capped so a full-screen capture doesn't pin wall-to-wall.
        let screen = hostWindow?()?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxSide: CGFloat = min(screen.visibleFrame.width, screen.visibleFrame.height) * 0.5
        let scale = min(1, maxSide / max(img.size.width, img.size.height, 1))
        let w = img.size.width * scale, h = img.size.height * scale
        let rect = CGRect(x: screen.visibleFrame.midX - w / 2,
                          y: screen.visibleFrame.midY - h / 2, width: w, height: h)
        _ = PinnedWindowController(rep: rep, screenRect: rect)
    }

    private func revealItem() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func deleteItem() {
        // Confirm first — Trash is recoverable, but a mis-hover on a thumbnail grid
        // silently eating a capture still reads as data loss.
        BrandAlert(title: L("Move to Trash?"),
                   message: fileURL.lastPathComponent,
                   titles: [L("Move to Trash"), L("Cancel")],
                   primary: 0, cancel: 1, icon: "trash", destructive: [0]).present { [weak self] choice in
            guard choice == 0, let self else { return }
            NSWorkspace.shared.recycle([self.fileURL]) { _, error in
                DispatchQueue.main.async {
                    if error == nil { BrandToast.show(L("Moved to Trash"), on: self.hostWindow?()?.screen) }
                    self.onChanged?()
                }
            }
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A cell claims its press, which is what lets it start a file drag — so History is
    /// no longer draggable by its thumbnails, only by its header and the space around
    /// them. That is the trade: dragging a capture out into Slack or Mail is the errand
    /// this panel exists to serve, and every other Mac grid of files behaves this way.
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        onSelect?()
    }

    /// Past a few pixels of travel the gesture is a drag, not a click: hand the file to
    /// the drag session and let the receiving app copy it.
    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let here = event.locationInWindow
        guard hypot(here.x - origin.x, here.y - origin.y) > 4 else { return }
        pressOrigin = nil
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(thumbBox.frame, contents: thumb.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        if event.clickCount == 2 { openItem() }
    }
}

extension HistoryCell: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }
}

/// Small square icon button used in a history cell's hover action strip.
private final class HistoryIconButton: NSView {
    private let onClick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private let symbol: String

    init(symbol: String, tip: String, onClick: @escaping () -> Void) {
        self.symbol = symbol
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: img.size)
        tinted.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        (hovering ? Theme.textPrimary : Theme.textSecondary).set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: (bounds.width - img.size.width) / 2,
                               y: (bounds.height - img.size.height) / 2,
                               width: img.size.width, height: img.size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Consume the press so neither the panel's drag nor the cell's file drag claims it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
