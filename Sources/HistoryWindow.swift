// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation

/// Capture history: a brand panel showing the most recent captures from the save
/// folder as a thumbnail grid. Hovering a cell reveals its actions — Copy, Pin
/// (images), Reveal in Finder, Delete (to Trash); double-click opens the file.
/// It's a live view over the folder (rebuilt on every open), not a database —
/// captures saved elsewhere or moved away simply don't appear.
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: PanelWindow?
    private var grid: NSStackView!
    private var emptyLabel: NSTextField!

    private static let maxItems = 24
    private static let columns = 4
    private static let cellSize = NSSize(width: 152, height: 140)
    private static let gap: CGFloat = 12

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    private static let videoExts: Set<String> = ["mp4", "mov"]

    func show() {
        rebuild(keepPosition: false)
        AppPanels.closeAll(except: window)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The panel is rebuilt on every open (and after a delete), sized to what's
    /// actually in the folder: fewer files → fewer columns/rows, no sea of empty
    /// gradient around three thumbnails. Caps at 4×3 cells; more files scroll.
    private func rebuild(keepPosition: Bool) {
        let files = Self.captureFiles()
        let previousFrame = window?.frame
        let wasVisible = window?.isVisible ?? false
        window?.orderOut(nil)

        let count = files.count
        let cols = max(1, min(Self.columns, count))
        let totalRows = count == 0 ? 0 : Int(ceil(Double(count) / Double(cols)))
        let visibleRows = max(1, min(3, totalRows))
        build(columns: max(2, cols), visibleRows: visibleRows)
        populate(files, columns: cols)

        if keepPosition, let prev = previousFrame, let w = window {
            // Keep the top-left corner planted through the resize.
            var f = w.frame
            f.origin = CGPoint(x: prev.minX, y: prev.maxY - f.height)
            w.setFrame(f, display: true)
        } else {
            window?.center()
        }
        if wasVisible || !keepPosition { window?.makeKeyAndOrderFront(nil) }
    }

    /// The save folder's capture files, newest first, capped at `maxItems`.
    private static func captureFiles() -> [URL] {
        let dir = Settings.shared.saveDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return Array(files
            .filter { imageExts.contains($0.pathExtension.lowercased())
                   || videoExts.contains($0.pathExtension.lowercased()) }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(maxItems))
    }

    private func build(columns: Int, visibleRows: Int) {
        let side: CGFloat = 24
        let cols = CGFloat(columns)
        let contentW = cols * Self.cellSize.width + (cols - 1) * Self.gap
        let gridH = CGFloat(visibleRows) * Self.cellSize.height
            + CGFloat(max(0, visibleRows - 1)) * Self.gap
        let size = NSSize(width: contentW + side * 2, height: gridH + 96)

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

        let rows = NSStackView(views: [])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.gap
        rows.translatesAutoresizingMaskIntoConstraints = false
        grid = rows

        let scroll = NSScrollView(frame: NSRect(x: side, y: 20, width: contentW,
                                                height: size.height - 76))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let clipDoc = FlippedView(frame: NSRect(origin: .zero, size: NSSize(width: contentW, height: gridH)))
        clipDoc.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: clipDoc.leadingAnchor),
            rows.topAnchor.constraint(equalTo: clipDoc.topAnchor),
        ])
        scroll.documentView = clipDoc
        content.addSubview(scroll)

        // Wrapping + centered, sized against THIS panel's width — the German and
        // Vietnamese strings are longer than the English one and a single-line
        // label with a fixed origin overflows the narrow empty-state panel.
        emptyLabel = NSTextField(wrappingLabelWithString: L("No captures yet."))
        emptyLabel.font = Theme.font(13)
        emptyLabel.textColor = Theme.textSecondary
        emptyLabel.alignment = .center
        let maxW = size.width - side * 2
        emptyLabel.preferredMaxLayoutWidth = maxW
        let labelH = emptyLabel.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude)).height
        emptyLabel.frame = NSRect(x: side, y: (size.height - 40 - labelH) / 2,
                                  width: maxW, height: ceil(labelH) + 2)
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        w.contentView = content
        w.installChrome(on: content)
        window = w
    }

    /// Fill the grid with cells for `files`, `columns` per row.
    private func populate(_ files: [URL], columns: Int) {
        guard let grid else { return }
        emptyLabel.isHidden = !files.isEmpty
        var rowViews: [NSView] = []
        for chunk in stride(from: 0, to: files.count, by: columns) {
            let slice = files[chunk..<min(chunk + columns, files.count)]
            let row = NSStackView(views: slice.map { cell(for: $0) })
            row.orientation = .horizontal
            row.spacing = Self.gap
            rowViews.append(row)
        }
        grid.setViews(rowViews, in: .top)
        grid.layoutSubtreeIfNeeded()
        // Size the flipped document view to the grid so scrolling starts at the top.
        if let doc = grid.superview {
            doc.frame.size.height = max(grid.fittingSize.height,
                                        doc.superview?.frame.height ?? 0)
        }
    }

    private func cell(for url: URL) -> HistoryCell {
        let isVideo = Self.videoExts.contains(url.pathExtension.lowercased())
        let cell = HistoryCell(url: url, size: Self.cellSize, isVideo: isVideo)
        cell.onChanged = { [weak self] in self?.rebuild(keepPosition: true) }
        return cell
    }
}

/// Document view flipped so the first history row sits at the top of the scroller.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One capture in the history grid: thumbnail, filename, and hover actions.
private final class HistoryCell: NSView {
    private let url: URL
    private let isVideo: Bool
    private let thumb = NSImageView()
    private let actions = NSStackView(views: [])
    private var hovering = false { didSet { actions.isHidden = !hovering } }
    /// Called after an action changed the folder (delete) so the grid reloads.
    var onChanged: (() -> Void)?

    init(url: URL, size: NSSize, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.surfaceRaised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor

        // Thumbnail sits in its own inset, letterboxed frame so mismatched aspect
        // ratios still read as a tidy grid.
        let inset: CGFloat = 6
        let thumbH = size.height - 40 - inset
        let thumbBox = NSView(frame: NSRect(x: inset, y: 34, width: size.width - inset * 2, height: thumbH))
        thumbBox.wantsLayer = true
        thumbBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        thumbBox.layer?.cornerRadius = 4
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

        // A small play badge marks recordings apart from stills at a glance.
        if isVideo {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            let badge = NSImageView(frame: NSRect(x: thumbBox.bounds.maxX - 20, y: 4, width: 16, height: 16))
            badge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: L("Recording"))?
                .withSymbolConfiguration(cfg)
            badge.contentTintColor = Theme.lavender
            badge.autoresizingMask = [.minXMargin]
            thumbBox.addSubview(badge)
        }

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = Theme.font(10, .medium)
        name.textColor = Theme.textPrimary
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: inset, y: 18, width: size.width - inset * 2, height: 13)
        addSubview(name)

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .short
        let date = NSTextField(labelWithString: mtime.map { df.string(from: $0) } ?? "")
        date.font = Theme.font(9)
        date.textColor = Theme.textSecondary
        date.alignment = .center
        date.frame = NSRect(x: inset, y: 5, width: size.width - inset * 2, height: 11)
        addSubview(date)

        buildActions()
        loadThumbnail(fitting: thumbBox.frame.size)
        toolTip = url.lastPathComponent
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Hover: lavender ring on the card, action strip over the thumbnail.
    private func setHighlighted(_ on: Bool) {
        layer?.borderColor = on ? Theme.lavender.withAlphaComponent(0.7).cgColor : Theme.border.cgColor
        layer?.borderWidth = on ? 1.5 : 1
    }

    private func buildActions() {
        func icon(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSView {
            let b = HistoryIconButton(symbol: symbol, tip: tip, onClick: action)
            return b
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
                self.window?.orderOut(nil)
                TrimWindowController.show(url: self.url)
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
        actions.layer?.cornerRadius = 5
        actions.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Centered over the thumbnail area (which spans y 34…top).
            actions.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 14),
        ])
    }

    /// Thumbnail load off the main thread; videos take their first frame. The result is
    /// center-cropped to `fit`'s aspect ratio so every thumbnail — whatever its source
    /// aspect ratio — visually fills the same box (see `imageScaling` above).
    private func loadThumbnail(fitting fit: NSSize) {
        let url = self.url, isVideo = self.isVideo
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

    private func copyItem() {
        NSPasteboard.general.clearContents()
        if !isVideo, let img = NSImage(contentsOf: url) {
            NSPasteboard.general.writeObjects([img])
        } else {
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        BrandToast.show(L("Copied to clipboard"), on: window?.screen)
    }

    private func pinItem() {
        guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        // Place it centered on the panel's screen at roughly half the image's point
        // size, capped so a full-screen capture doesn't pin wall-to-wall.
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxSide: CGFloat = min(screen.visibleFrame.width, screen.visibleFrame.height) * 0.5
        let scale = min(1, maxSide / max(img.size.width, img.size.height, 1))
        let w = img.size.width * scale, h = img.size.height * scale
        let rect = CGRect(x: screen.visibleFrame.midX - w / 2,
                          y: screen.visibleFrame.midY - h / 2, width: w, height: h)
        _ = PinnedWindowController(rep: rep, screenRect: rect)
    }

    private func revealItem() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteItem() {
        // Confirm first — Trash is recoverable, but a mis-hover on a thumbnail grid
        // silently eating a capture still reads as data loss.
        BrandAlert(title: L("Move to Trash?"),
                   message: url.lastPathComponent,
                   titles: [L("Move to Trash"), L("Cancel")],
                   primary: 0, cancel: 1, icon: "trash", destructive: [0]).present { [weak self] choice in
            guard choice == 0, let self else { return }
            NSWorkspace.shared.recycle([self.url]) { _, error in
                DispatchQueue.main.async {
                    if error == nil { BrandToast.show(L("Moved to Trash"), on: self.window?.screen) }
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
    override func mouseEntered(with event: NSEvent) { hovering = true; setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; setHighlighted(false) }
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
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
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
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
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
