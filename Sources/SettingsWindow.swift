// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A small dark, mesoneer-styled Settings panel that edits `Settings`. Controls
/// are organized into labeled groups (General / Capture / Output) so the panel
/// stays scannable as settings grow.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private var loginCheck: NSButton!
    private var delayPopup: NSPopUpButton!
    private var behaviorPopup: NSPopUpButton!
    private var pathLabel: NSTextField!
    private var prefixField: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var paddingPopup: NSPopUpButton!
    private var paddingRow: NSView!
    private var radiusPopup: NSPopUpButton!
    private var radiusRow: NSView!
    private var defaultBGPopup: NSPopUpButton!
    private var autoCopyCheck: NSButton!
    private var cursorCheck: NSButton!
    private var soundCheck: NSButton!
    private var videoQualityPopup: NSPopUpButton!
    private var videoAudioSourcePopup: NSPopUpButton!
    private var shortcutFields: [HotKeyField] = []
    private var toast: NSWindow?

    /// Background presets offered as the editor default (None + the 10 presets).
    private let bgPresets = Background.presets

    func show() {
        if window == nil { build() }
        refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let size = NSSize(width: Layout.windowWidth, height: 484)
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isMovableByWindowBackground = true
        w.backgroundColor = Theme.surfaceBase
        w.onClose = { [weak w] in w?.orderOut(nil) }

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let gradient = Theme.applyPanelGradient(to: content)

        loginCheck = checkbox("Launch m_capture at login", #selector(loginToggled))
        delayPopup = popup(CaptureDelay.allCases.map { $0.label }, #selector(delayChanged))
        behaviorPopup = popup(CaptureBehavior.allCases.map { $0.label }, #selector(behaviorChanged))

        shortcutFields = ShortcutAction.allCases
            .map { action in HotKeyField(action: action) { Self.reloadHotKeys() } }

        cursorCheck = checkbox("Include the mouse cursor in captures", #selector(cursorToggled))
        soundCheck = checkbox("Play the shutter sound when capturing", #selector(soundToggled))

        pathLabel = valueLabel("")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = PointerButton(title: "Choose…", target: self, action: #selector(chooseLocation))
        choose.bezelStyle = .rounded
        choose.bezelColor = Theme.accentPurple

        prefixField = textField(#selector(prefixChanged))

        formatPopup = popup(ImageFormat.allCases.map { $0.label }, #selector(formatChanged))

        paddingPopup = popup(PaddingSize.allCases.map { $0.label }, #selector(paddingChanged))
        paddingRow = row("Padding", paddingPopup,
                         tip: "How much space surrounds the screenshot inside a share-ready background frame. Only applies when a background is selected.")
        radiusPopup = popup(RadiusSize.allCases.map { $0.label }, #selector(radiusChanged))
        radiusRow = row("Corner radius", radiusPopup,
                        tip: "How rounded the screenshot's corners are when a background frame is applied (Square = no rounding). Only applies when a background is selected.")
        defaultBGPopup = popup(bgPresets.map { $0.name }, #selector(defaultBGChanged))
        autoCopyCheck = checkbox("Also copy to clipboard when saving", #selector(autoCopyToggled))

        videoQualityPopup = popup(VideoQuality.allCases.map { $0.label }, #selector(videoQualityChanged))
        videoAudioSourcePopup = popup(VideoAudioSource.allCases.map { $0.label }, #selector(videoAudioSourceChanged))

        var rows: [NSView] = [
            sectionHeader("General"),
            checkRow(loginCheck),
            row("Capture delay", delayPopup),
            row("After capture", behaviorPopup),
            sectionHeader("Shortcuts"),
        ]
        rows += zip(ShortcutAction.allCases, shortcutFields)
            .map { action, field in row(action.label, field) }
        rows += [
            sectionHeader("Capture"),
            checkRow(cursorCheck),
            checkRow(soundCheck),
            sectionHeader("Output"),
            saveRow(pathLabel, choose),
            row("Filename prefix", prefixField),
            row("Format", formatPopup),
            row("Background", defaultBGPopup,
                tip: "The background frame pre-selected when the editor opens; you can still change it per capture."),
            paddingRow,
            radiusRow,
            checkRow(autoCopyCheck),
            sectionHeader("Video"),
            row("Quality", videoQualityPopup),
            row("Audio", videoAudioSourcePopup),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        for (i, view) in rows.enumerated() where view is SectionHeader && i > 0 {
            stack.setCustomSpacing(22, after: rows[i - 1])
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let topInset: CGFloat = 44, bottomInset: CGFloat = 24
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.sideMargin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: topInset),
        ])

        w.contentView = content
        content.layoutSubtreeIfNeeded()
        let height = ceil(topInset + stack.fittingSize.height + bottomInset)
        w.setContentSize(NSSize(width: size.width, height: height))
        gradient.frame = content.bounds
        w.installChrome(on: content)
        window = w
    }

    /// A section header: small, letter-spaced uppercase in the muted secondary
    /// tone — a quiet group marker, not a third competing text color.
    private func sectionHeader(_ title: String) -> SectionHeader {
        let l = SectionHeader(labelWithString: "")
        Theme.styleEyebrow(l, title)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        let b = PointerButton(checkboxWithTitle: title, target: self, action: action)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Theme.textPrimary,
            .font: Theme.font(12),
        ])
        b.contentTintColor = Theme.lavender
        b.lineBreakMode = .byClipping
        (b.cell as? NSButtonCell)?.wraps = false
        return b
    }

    private func popup(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = BrandPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.target = self; p.action = action
        return p
    }

    /// A brand-styled editable text field (dark raised fill, hairline border,
    /// padded + vertically-centered text via `BrandTextField`).
    private func textField(_ action: Selector) -> NSTextField {
        let t = BrandTextField(string: "")
        t.font = Theme.font(12)
        t.textColor = Theme.textPrimary
        t.drawsBackground = false
        t.isBezeled = false
        t.isBordered = false
        t.focusRingType = .none
        t.wantsLayer = true
        t.layer?.backgroundColor = Theme.surfaceRaised.cgColor
        t.layer?.cornerRadius = Theme.radiusSmall
        t.layer?.borderWidth = 1
        t.layer?.borderColor = Theme.border.cgColor
        t.target = self; t.action = action
        t.translatesAutoresizingMaskIntoConstraints = false
        t.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return t
    }

    /// Re-register the app's global hotkeys after a rebind.
    private static func reloadHotKeys() {
        (NSApp.delegate as? AppDelegate)?.reloadHotKeys()
    }

    /// Two-column form geometry (macOS System Settings style): a right-aligned
    /// label column, then a fixed-width left-aligned control column that doesn't
    /// stretch to fill the row.
    private enum Layout {
        static let labelWidth: CGFloat = 116
        static let gap: CGFloat = 14
        static var controlX: CGFloat { labelWidth + gap }
        static let infoCol: CGFloat = 24
        static let sideMargin: CGFloat = 24
        /// Wide enough for the longest checkbox label on one line. Controls span
        /// exactly `controlWidth` from `controlX`, so every popup/field is the
        /// same width and their right edge lines up with the Choose button.
        static let rowWidth: CGFloat = 400
        /// Controls stop short of the right edge, leaving `infoCol` for the ⓘ marker.
        static var controlWidth: CGFloat { rowWidth - controlX - infoCol }
        static var windowWidth: CGFloat { rowWidth + sideMargin * 2 }
    }

    /// A right-aligned label in the label column.
    private func rowLabel(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = Theme.font(12, .semibold)
        l.textColor = Theme.textPrimary
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// A labelled row: a right-aligned label, then a control that fills the
    /// control column to the right margin (uniform width across all rows).
    private func row(_ title: String, _ control: NSView, tip: String? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(title)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.controlX),
            control.widthAnchor.constraint(equalToConstant: Layout.controlWidth),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        attachInfo(tip, to: row, alignedTo: control)
        return row
    }

    /// Add the brand info indicator (a lavender ⓘ) in the right-side help column,
    /// vertically centered on the row's control, with a brand-styled hover tooltip.
    private func attachInfo(_ tip: String?, to row: NSView, alignedTo control: NSView) {
        guard let tip else { return }
        let dot = InfoDot()
        dot.onEnter = { [weak self, weak dot] in if let dot { self?.showTip(tip, near: dot) } }
        dot.onExit = { [weak self] in self?.hideTip() }
        row.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: control.trailingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
    }

    private lazy var tipText: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = Theme.font(11, .medium)
        l.textColor = Theme.ink
        l.isSelectable = false
        l.preferredMaxLayoutWidth = 220
        return l
    }()
    private lazy var tipBox: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.surfaceBase.cgColor
        v.layer?.cornerRadius = Theme.radiusSmall
        v.layer?.borderWidth = 1
        v.layer?.borderColor = Theme.border.cgColor
        v.isHidden = true
        v.addSubview(tipText)
        return v
    }()

    private func showTip(_ text: String, near view: NSView) {
        guard let content = window?.contentView else { return }
        tipText.stringValue = text
        tipText.preferredMaxLayoutWidth = 220
        let ts = tipText.fittingSize
        let padX: CGFloat = 9, padY: CGFloat = 6
        let w = ts.width + padX * 2, h = ts.height + padY * 2
        let vf = content.convert(view.bounds, from: view)
        var x = vf.midX - w / 2
        x = max(8, min(x, content.bounds.width - w - 8))
        var y = vf.minY - h - 6
        if y < 8 { y = vf.maxY + 6 }
        content.addSubview(tipBox, positioned: .above, relativeTo: nil)
        tipBox.frame = NSRect(x: x, y: y, width: w, height: h)
        tipText.frame = NSRect(x: padX, y: padY, width: ts.width, height: ts.height)
        tipBox.isHidden = false
    }
    private func hideTip() { tipBox.isHidden = true }

    /// A checkbox row: the checkbox aligns its leading edge with the control column.
    private func checkRow(_ check: NSButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        check.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(check)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            check.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.controlX),
            check.topAnchor.constraint(equalTo: row.topAnchor),
            check.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            check.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        return row
    }

    /// The Save-to row: a path label that fills the column, with the Choose
    /// button pinned to the right edge.
    private func saveRow(_ pathLabel: NSTextField, _ choose: NSButton, tip: String? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel("Save to")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        choose.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(pathLabel)
        row.addSubview(choose)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            label.centerYAnchor.constraint(equalTo: choose.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.controlX),
            pathLabel.centerYAnchor.constraint(equalTo: choose.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: choose.leadingAnchor, constant: -Layout.gap),
            choose.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.infoCol),
            choose.topAnchor.constraint(equalTo: row.topAnchor),
            choose.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        attachInfo(tip, to: row, alignedTo: choose)
        return row
    }

    /// Secondary read-only values (the save path): muted tone so they sit below
    /// the white row labels in the hierarchy.
    private func valueLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.font(12)
        l.textColor = Theme.textSecondary
        return l
    }

    /// Load current Settings into the controls.
    private func refresh() {
        let s = Settings.shared
        loginCheck.state = s.launchAtLogin ? .on : .off
        delayPopup.selectItem(at: CaptureDelay.allCases.firstIndex(of: s.captureDelay) ?? 0)
        behaviorPopup.selectItem(at: CaptureBehavior.allCases.firstIndex(of: s.captureBehavior) ?? 0)
        shortcutFields.forEach { $0.refreshDisplay() }
        pathLabel.stringValue = (s.saveDirectory.path as NSString).abbreviatingWithTildeInPath
        prefixField.stringValue = s.filenamePrefix
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: s.format) ?? 0)
        paddingPopup.selectItem(at: PaddingSize.allCases.firstIndex(of: s.paddingSize) ?? 1)
        radiusPopup.selectItem(at: RadiusSize.allCases.firstIndex(of: s.radiusSize) ?? 2)
        defaultBGPopup.selectItem(at: bgPresets.firstIndex { $0.name == s.defaultBackground.name } ?? 0)
        updateBackgroundDependentRowsEnabled()
        autoCopyCheck.state = s.autoCopyOnSave ? .on : .off
        cursorCheck.state = s.captureCursor ? .on : .off
        soundCheck.state = s.playSound ? .on : .off
        videoQualityPopup.selectItem(at: VideoQuality.allCases.firstIndex(of: s.videoQuality) ?? 0)
        videoAudioSourcePopup.selectItem(at: VideoAudioSource.allCases.firstIndex(of: s.videoAudioSource) ?? 0)
    }

    @objc private func loginToggled() {
        Settings.shared.launchAtLogin = (loginCheck.state == .on)
        loginCheck.state = Settings.shared.launchAtLogin ? .on : .off
    }

    @objc private func delayChanged() {
        Settings.shared.captureDelay = CaptureDelay.allCases[delayPopup.indexOfSelectedItem]
    }

    @objc private func behaviorChanged() {
        Settings.shared.captureBehavior = CaptureBehavior.allCases[behaviorPopup.indexOfSelectedItem]
    }

    @objc private func prefixChanged() {
        Settings.shared.filenamePrefix = prefixField.stringValue
        prefixField.stringValue = Settings.shared.filenamePrefix
        showToast("Filename prefix saved")
    }

    /// A brief brand-styled toast centered near the top of the screen that
    /// auto-fades — same flat accent-purple pill as the editor's OCR confirmation.
    /// The Settings panel is small, so the toast rides in its own borderless
    /// window to reach the screen-top position the OCR toast uses.
    private func showToast(_ message: String) {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        toast?.orderOut(nil); toast = nil

        let label = NSTextField(labelWithString: message)
        label.font = Theme.font(13, .semibold); label.textColor = .white
        let ts = label.intrinsicContentSize
        let pad: CGFloat = 12
        let size = NSSize(width: ts.width + pad * 2, height: ts.height + pad)

        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.accentPurple.withAlphaComponent(0.95).cgColor
        pill.layer?.cornerRadius = 8
        label.frame = NSRect(x: pad, y: pad / 2, width: ts.width, height: ts.height)
        pill.addSubview(label)

        let vf = screen.visibleFrame
        let win = NSWindow(contentRect: NSRect(x: vf.midX - size.width / 2,
                                               y: vf.maxY - 30 - size.height,
                                               width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.ignoresMouseEvents = true
        win.contentView = pill
        win.orderFront(nil)

        toast = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.toast === win else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
                if self?.toast === win { self?.toast = nil }
            })
        }
    }

    @objc private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.shared.saveDirectory
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Settings.shared.saveDirectory = url
            self?.pathLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func formatChanged() {
        Settings.shared.format = ImageFormat.allCases[formatPopup.indexOfSelectedItem]
    }

    @objc private func radiusChanged() {
        Settings.shared.radiusSize = RadiusSize.allCases[radiusPopup.indexOfSelectedItem]
    }
    @objc private func paddingChanged() {
        Settings.shared.paddingSize = PaddingSize.allCases[paddingPopup.indexOfSelectedItem]
    }

    @objc private func defaultBGChanged() {
        Settings.shared.defaultBackground = bgPresets[defaultBGPopup.indexOfSelectedItem]
        updateBackgroundDependentRowsEnabled()
    }

    /// Padding and corner radius only have an effect when a background frame is
    /// selected — grey out and disable both rows (and their controls) when the
    /// default background is "None".
    private func updateBackgroundDependentRowsEnabled() {
        let enabled = !bgPresets[defaultBGPopup.indexOfSelectedItem].isNone
        for (row, popup) in [(paddingRow, paddingPopup), (radiusRow, radiusPopup)] {
            row?.alphaValue = enabled ? 1 : 0.4
            popup?.isEnabled = enabled
        }
    }

    @objc private func autoCopyToggled() {
        Settings.shared.autoCopyOnSave = (autoCopyCheck.state == .on)
    }

    @objc private func cursorToggled() {
        Settings.shared.captureCursor = (cursorCheck.state == .on)
    }

    @objc private func soundToggled() {
        Settings.shared.playSound = (soundCheck.state == .on)
    }

    @objc private func videoQualityChanged() {
        Settings.shared.videoQuality = VideoQuality.allCases[videoQualityPopup.indexOfSelectedItem]
    }

    @objc private func videoAudioSourceChanged() {
        Settings.shared.videoAudioSource = VideoAudioSource.allCases[videoAudioSourcePopup.indexOfSelectedItem]
    }
}

/// Marker subclass so section-header rows can be told apart from setting rows
/// when applying group spacing.
private final class SectionHeader: NSTextField {}

/// A native `NSButton` (checkbox / push button) that shows the pointing-hand
/// cursor on hover, matching the app's custom controls.
private final class PointerButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A small lavender ⓘ that marks a row as having help and reveals a brand tooltip
/// on hover. The visible glyph is the affordance — so the help is discoverable.
private final class InfoDot: NSImageView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Help")?
            .withSymbolConfiguration(cfg)
        contentTintColor = Theme.lavender.withAlphaComponent(0.9)
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = Theme.lavender; onEnter?() }
    override func mouseExited(with event: NSEvent) { contentTintColor = Theme.lavender.withAlphaComponent(0.9); onExit?() }
}

/// A text field whose cell pads and vertically-centers its text, so the value
/// sits cleanly inside the rounded brand field instead of clipping at the edge.
private final class BrandTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { BrandTextFieldCell.self }
        set {}
    }
}

private final class BrandTextFieldCell: NSTextFieldCell {
    private let xInset = BrandControl.textInset

    private func adjusted(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        let dy = max(0, (rect.height - textHeight) / 2)
        return NSRect(x: rect.minX + xInset, y: rect.minY + dy,
                      width: max(0, rect.width - xInset * 2), height: textHeight)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: adjusted(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjusted(rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjusted(rect), in: controlView, editor: editor,
                     delegate: delegate, start: selStart, length: selLength)
    }
}

