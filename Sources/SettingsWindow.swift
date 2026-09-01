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
    private var dockCheck: NSButton!
    private var languagePopup: NSPopUpButton!
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
    private var confirmDiscardCheck: NSButton!
    private var videoQualityPopup: NSPopUpButton!
    private var videoAudioSourcePopup: NSPopUpButton!
    private var videoFrameRatePopup: NSPopUpButton!
    private var videoCountdownPopup: NSPopUpButton!
    private var videoClicksCheck: NSButton!
    private var videoBarMinCheck: NSButton!
    private var videoConfirmStopCheck: NSButton!
    private var videoSimulateCheck: NSButton!
    private var videoZoomPopup: NSPopUpButton!
    private var lastCheckedLabel: NSTextField!
    private var drawColorRow: DrawColorRow!
    private var drawStrokePopup: NSPopUpButton!
    private var drawFadePopup: NSPopUpButton!
    private var drawKeyFields: [DrawKeyField] = []
    private var shortcutFields: [HotKeyField] = []
    private var toast: NSWindow?

    /// Background presets offered as the editor default (None + the 10 presets).
    private let bgPresets = Background.presets

    func show() {
        if window == nil { build() }
        AppPanels.closeAll(except: window)
        refresh()
        window?.centerOnActiveScreen()
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

        loginCheck = checkbox(L("Launch m_capture at login"), #selector(loginToggled))
        dockCheck = checkbox(L("Hide the Dock icon"), #selector(dockToggled))
        languagePopup = popup(AppLanguage.allCases.map { $0.label }, #selector(languageChanged))
        delayPopup = popup(CaptureDelay.allCases.map { $0.label }, #selector(delayChanged))
        behaviorPopup = popup(CaptureBehavior.allCases.map { $0.label }, #selector(behaviorChanged))

        shortcutFields = ShortcutAction.allCases
            .map { action in HotKeyField(action: action) { Self.reloadHotKeys() } }

        cursorCheck = checkbox(L("Include the mouse cursor in captures"), #selector(cursorToggled))
        soundCheck = checkbox(L("Play the shutter sound when capturing"), #selector(soundToggled))
        confirmDiscardCheck = checkbox(L("Ask before discarding a capture"), #selector(confirmDiscardToggled))

        pathLabel = valueLabel("")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = BrandPushButton(title: L("Choose…"), target: self, action: #selector(chooseLocation))

        prefixField = textField(#selector(prefixChanged))

        formatPopup = popup(ImageFormat.allCases.map { $0.label }, #selector(formatChanged))

        paddingPopup = popup(PaddingSize.allCases.map { $0.label }, #selector(paddingChanged))
        paddingRow = row(L("Padding"), paddingPopup,
                         tip: L("Space around the screenshot inside a background frame. Applies only when a background is selected."))
        radiusPopup = popup(RadiusSize.allCases.map { $0.label }, #selector(radiusChanged))
        radiusRow = row(L("Corner radius"), radiusPopup,
                        tip: L("Corner rounding when a background frame is applied (Square = none). Applies only when a background is selected."))
        // Display names localize; `name` itself stays English — it's the
        // persistence key for the default-background setting.
        defaultBGPopup = popup(bgPresets.map { L($0.name) }, #selector(defaultBGChanged))
        autoCopyCheck = checkbox(L("Also copy to clipboard when saving"), #selector(autoCopyToggled))

        videoQualityPopup = popup(VideoQuality.allCases.map { $0.label }, #selector(videoQualityChanged))
        videoAudioSourcePopup = popup(VideoAudioSource.allCases.map { $0.label }, #selector(videoAudioSourceChanged))
        videoFrameRatePopup = popup(["30 fps", "60 fps"], #selector(videoFrameRateChanged))
        videoCountdownPopup = popup(CaptureDelay.allCases.map { $0.label }, #selector(videoCountdownChanged))
        videoClicksCheck = checkbox(L("Show mouse clicks in recordings"), #selector(videoClicksToggled))
        videoZoomPopup = popup(VideoZoomFactor.allCases.map { $0.label }, #selector(videoZoomChanged))
        videoBarMinCheck = checkbox(L("Start with the recording bar minimized"), #selector(videoBarMinToggled))
        videoConfirmStopCheck = checkbox(L("Ask before stopping a recording"),
                                         #selector(videoConfirmStopToggled))
        videoSimulateCheck = checkbox(L("Simulate recording (nothing is saved)"),
                                      #selector(videoSimulateToggled))

        drawColorRow = DrawColorRow()
        drawStrokePopup = popup(DrawStroke.allCases.map { $0.label }, #selector(drawStrokeChanged))
        drawFadePopup = popup(DrawFade.allCases.map { $0.label }, #selector(drawFadeChanged))
        drawKeyFields = DrawTool.allCases.map { DrawKeyField(tool: $0) }

        videoSubRows = [
            [
                row(L("Quality"), videoQualityPopup),
                row(L("Audio"), videoAudioSourcePopup),
                row(L("Frame rate"), videoFrameRatePopup,
                    tip: L("60 fps captures motion more smoothly at roughly twice the file size.")),
                row(L("Countdown"), videoCountdownPopup,
                    tip: L("Countdown shown over the selected region before recording starts.")),
                row(L("Zoom level"), videoZoomPopup,
                    tip: L("Magnification when zoom is toggled while recording. Only the video zooms — your screen is untouched.")),
                checkRow(videoClicksCheck),
                checkRow(videoBarMinCheck),
                checkRow(videoConfirmStopCheck),
                checkRow(videoSimulateCheck),
            ],
            // The marks' look, how long they last, and the letters that pick a tool
            // once draw mode is on.
            [
                row(L("Color"), drawColorRow,
                    tip: L("Color of marks drawn on screen while recording.")),
                row(L("Thickness"), drawStrokePopup),
                row(L("Fade after"), drawFadePopup,
                    tip: L("How long a finished mark stays before it fades. “Never” keeps marks until you clear them with ⌫.")),
                groupHeading(L("Drawing keys"), firstInSection: false),
            ] + zip(DrawTool.allCases, drawKeyFields).map { tool, field in
                row(tool.label, field,
                    tip: L("Press this key while drawing to switch to this tool. Draw mode reserves Esc to exit and ⌫ to clear."))
            },
        ]
        videoTabBar = SectionTabBar(titles: [L("Recording"), L("Drawing")],
                                    width: Layout.rowWidth)
        videoTabBar.onSelect = { [weak self] i in self?.selectVideoSubTab(i) }

        // One tab per former section — the flat list had grown too tall to scan.
        sections = [
            (L("General"), [
                checkRow(loginCheck),
                checkRow(dockCheck),
                row(L("Language"), languagePopup,
                    tip: L("Interface language. “System” follows the macOS language; changes apply after a restart.")),
                row(L("Capture delay"), delayPopup,
                    tip: L("Delay before the selection overlay appears — time to open menus or prepare the screen.")),
                row(L("After capture"), behaviorPopup,
                    tip: L("Action performed immediately after capture: open the editor, save to a file, or copy to the clipboard.")),
            ]),
            (L("Shortcuts"), shortcutRows()),
            (L("Capture"), [
                checkRow(cursorCheck, indented: false),
                checkRow(soundCheck, indented: false),
                checkRow(confirmDiscardCheck, indented: false),
            ]),
            (L("Output"), [
                saveRow(pathLabel, choose),
                row(L("Filename prefix"), prefixField),
                row(L("Format"), formatPopup),
                row(L("Background"), defaultBGPopup,
                    tip: L("Background frame preselected when the editor opens; adjustable per capture.")),
                paddingRow,
                radiusRow,
                checkRow(autoCopyCheck),
            ]),
            // Everything about a recording under one sidebar item — drawing does nothing
            // outside a recording, so a tab of its own read as a separate feature. The two
            // halves are each a section's worth of rows, so they sit behind sub-tabs
            // rather than stacked: stacked, every other tab inherited their combined height.
            (L("Video"), [videoTabBar] + videoSubRows[0]),
            // Meta actions that used to crowd the menu-bar menu.
            (L("About"), [aboutCard()]),
        ]

        // Icon sidebar (macOS System Settings shape): section list on the left,
        // the active section's rows on the right.
        let sidebarIcons = ["gearshape", "command", "viewfinder", "tray.and.arrow.down", "video",
                            "info.circle"]
        tabButtons = sections.enumerated().map { i, section in
            let b = SettingsSidebarItem(title: section.title, symbol: sidebarIcons[i])
            b.onClick = { [weak self] in self?.selectTab(i) }
            b.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth - 20).isActive = true
            return b
        }

        // A slightly darker column + hairline divider so the two panes read apart.
        let sidebarBG = NSView()
        sidebarBG.wantsLayer = true
        sidebarBG.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        sidebarBG.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebarBG)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        let sidebar = NSStackView(views: tabButtons)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 3
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let sectionTitle = NSTextField(labelWithString: "")
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sectionTitle)
        sectionTitleLabel = sectionTitle

        let stack = NSStackView(views: [])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.rowGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)

        NSLayoutConstraint.activate([
            sidebarBG.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarBG.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarBG.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarBG.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: sidebarBG.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.topInset + 8),
            sidebar.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth - 20),
            sectionTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                  constant: Layout.sidebarWidth + Layout.sideMargin),
            sectionTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.topInset + 6),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: Layout.sidebarWidth + Layout.sideMargin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.chromeHeight),
        ])
        rowStack = stack
        gradientLayer = gradient

        w.contentView = content
        w.installChrome(on: content)
        window = w
        selectTab(0)
    }

    private var sections: [(title: String, rows: [NSView])] = []
    /// Video's two row sets (recording / drawing) and the bar that switches them.
    private var videoSubRows: [[NSView]] = []
    private var videoTabBar: SectionTabBar!
    private var videoSub = 0
    private var videoSection: Int { sections.firstIndex { $0.title == L("Video") } ?? -1 }
    private var tabButtons: [SettingsSidebarItem] = []
    private var rowStack: NSStackView!
    private var sectionTitleLabel: NSTextField!
    private var gradientLayer: CAGradientLayer?
    private var activeTab = 0

    /// Swap the visible section. The panel keeps one fixed size — measured once against
    /// the tallest row set, sub-tab variants included — so switching never resizes or
    /// shifts it.
    private func selectTab(_ index: Int) {
        guard let w = window, let content = w.contentView else { return }
        activeTab = index
        for (i, b) in tabButtons.enumerated() { b.isSelected = (i == index) }
        hideTip()
        Theme.styleEyebrow(sectionTitleLabel, sections[index].title)
        rowStack.setViews(sections[index].rows, in: .top)
        if fixedHeight == 0 {
            // First layout: measure every section and lock the window to the tallest.
            var tallest: CGFloat = 0
            for (i, _) in sections.enumerated() {
                for variant in rowVariants(i) {
                    rowStack.setViews(variant, in: .top)
                    content.layoutSubtreeIfNeeded()
                    tallest = max(tallest, rowStack.fittingSize.height)
                }
            }
            rowStack.setViews(sections[index].rows, in: .top)
            fixedHeight = ceil(Layout.chromeHeight + tallest + Layout.bottomInset)
            w.setContentSize(NSSize(width: Layout.windowWidth, height: fixedHeight))
            gradientLayer?.frame = content.bounds
        }
        content.layoutSubtreeIfNeeded()
    }
    private var fixedHeight: CGFloat = 0

    /// Swap Video's row set. Only the rows change — the window is already sized to the
    /// taller of the two, so switching sub-tabs never resizes the panel either.
    private func selectVideoSubTab(_ index: Int) {
        guard videoSection >= 0, index < videoSubRows.count else { return }
        videoSub = index
        videoTabBar.selected = index
        hideTip()
        sections[videoSection].rows = [videoTabBar] + videoSubRows[index]
        if activeTab == videoSection {
            rowStack.setViews(sections[activeTab].rows, in: .top)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Every row set a section can show — one, except Video, which has a set per sub-tab.
    /// The panel is measured against all of them so no switch can resize it.
    private func rowVariants(_ index: Int) -> [[NSView]] {
        guard index == videoSection else { return [sections[index].rows] }
        return videoSubRows.map { [videoTabBar] + $0 }
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
        t.layer?.backgroundColor = Theme.controlFill.cgColor
        t.layer?.cornerRadius = Theme.radiusSmall
        t.layer?.borderWidth = 1
        t.layer?.borderColor = Theme.controlStroke.cgColor
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
        static let topInset: CGFloat = 32
        static let bottomInset: CGFloat = 20
        static let sidebarWidth: CGFloat = 156
        static let titleHeight: CGFloat = 16
        static let tabGap: CGFloat = 16
        /// Every row is this tall and this far from the next, whatever it holds — the
        /// form controls are all 24 pt, but a checkbox's own height is 16, so rows sized
        /// to their content gave checkbox blocks a visibly tighter pitch than popup ones.
        static let rowHeight: CGFloat = 24
        static let rowGap: CGFloat = 10
        /// A group heading takes one row's height plus a breath above it, so the heading
        /// sits with the rows it introduces rather than floating between two groups.
        static let headingGap: CGFloat = 12
        static var controlX: CGFloat { labelWidth + gap }
        static let infoCol: CGFloat = 24
        static let sideMargin: CGFloat = 24
        /// Wide enough for the longest checkbox label on one line. Controls span
        /// exactly `controlWidth` from `controlX`, so every popup/field is the
        /// same width and their right edge lines up with the Choose button.
        static let rowWidth: CGFloat = 400
        /// Controls stop short of the right edge, leaving `infoCol` for the ⓘ marker.
        static var controlWidth: CGFloat { rowWidth - controlX - infoCol }
        /// Everything above the rows: the top inset, the section eyebrow, and the gap under it.
        static var chromeHeight: CGFloat { topInset + 6 + titleHeight + tabGap }
        static var windowWidth: CGFloat { sidebarWidth + rowWidth + sideMargin * 2 }
    }

    /// A right-aligned label in the label column.
    private func rowLabel(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = Theme.font(12, .semibold)
        l.textColor = Theme.textPrimary
        l.alignment = .right
        // The column is a fixed width, so an overlong translation has to end in an
        // ellipsis rather than a hard cut mid-word.
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// A labelled row: a right-aligned label, then a control that fills the
    /// control column to the right margin (uniform width across all rows).
    /// Explanatory tip for each rebindable action — the non-obvious ones (Quick
    /// Screen, Force Quit) especially need it.
    private static func shortcutTip(_ a: ShortcutAction) -> String {
        switch a {
        case .screenshot:  return L("Drag to select a region, or press Space to capture a window or screen.")
        case .record:      return L("Drag to select a region, or press Space to record a window or screen.")
        case .stop:        return L("Stops the recording and saves it. Unlike the record shortcut it can only ever stop, never start a new recording.")
        case .draw:        return L("While recording, sketch directly on the screen; strokes fade after a few seconds and appear in the video.")
        case .zoom:        return L("While recording, zoom the video in on the cursor and back out again. Your own screen is not magnified.")
        case .forceQuit:   return L("Force-quits m_capture and any duplicate instances — use if the menu bar icon is stuck or duplicated.")
        }
    }

    /// The Shortcuts section, grouped by when each hotkey applies. Draw and Zoom do
    /// nothing outside a recording, and a heading says that once instead of every label
    /// repeating it — which is also what lets those labels stay inside the label column:
    /// spelled out, "Zoom While Recording" was clipped in all three languages.
    private func shortcutRows() -> [NSView] {
        let fields = Dictionary(uniqueKeysWithValues: zip(ShortcutAction.allCases, shortcutFields))
        let groups: [(String, [ShortcutAction])] = [
            (L("Capture"), [.screenshot, .record]),
            (L("While recording"), [.stop, .draw, .zoom]),
            (L("App"), [.forceQuit]),
        ]
        return groups.enumerated().flatMap { index, group -> [NSView] in
            [groupHeading(group.0, firstInSection: index == 0)]
                + group.1.compactMap { action in
                    fields[action].map { row(action.label, $0, tip: Self.shortcutTip(action)) }
                }
        }
    }

    /// A quiet small-caps heading inside a section: the section eyebrow's little
    /// sibling, at the left margin with air above it, so a group reads as a group
    /// without needing a divider rule.
    private func groupHeading(_ title: String, firstInSection: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        Theme.styleEyebrow(label, title, size: 9, color: Theme.textMuted)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight
                                        + (firstInSection ? 0 : Layout.headingGap)),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    private func row(_ title: String, _ control: NSView, tip: String? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(title)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.controlX),
            control.widthAnchor.constraint(equalToConstant: Layout.controlWidth),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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

    /// A checkbox row. In a mixed form the checkbox aligns with the control column
    /// (`indented`); in a checkbox-only section (Capture) it starts at the left
    /// margin — the empty label column otherwise reads as a layout mistake.
    private func checkRow(_ check: NSButton, indented: Bool = true) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        check.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(check)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            check.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                           constant: indented ? Layout.controlX : 0),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        return row
    }

    /// The Save-to row: a path label that fills the column, with the Choose
    /// button pinned to the right edge.
    private func saveRow(_ pathLabel: NSTextField, _ choose: NSButton, tip: String? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(L("Save to"))
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        choose.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(pathLabel)
        row.addSubview(choose)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.controlX),
            pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: choose.leadingAnchor, constant: -Layout.gap),
            choose.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.infoCol),
            choose.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            choose.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
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
        dockCheck.state = s.hideDockIcon ? .on : .off
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: s.appLanguage) ?? 0)
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
        confirmDiscardCheck.state = s.confirmDiscard ? .on : .off
        videoQualityPopup.selectItem(at: VideoQuality.allCases.firstIndex(of: s.videoQuality) ?? 0)
        videoAudioSourcePopup.selectItem(at: VideoAudioSource.allCases.firstIndex(of: s.videoAudioSource) ?? 0)
        videoFrameRatePopup.selectItem(at: s.videoFrameRate == 60 ? 1 : 0)
        videoCountdownPopup.selectItem(at: CaptureDelay.allCases.firstIndex(of: s.videoCountdown) ?? 0)
        videoClicksCheck.state = s.videoShowClicks ? .on : .off
        videoBarMinCheck.state = s.videoStartBarMinimized ? .on : .off
        videoConfirmStopCheck.state = s.videoConfirmStop ? .on : .off
        videoZoomPopup.selectItem(at: VideoZoomFactor.allCases.firstIndex(of: s.videoZoomFactor) ?? 1)
        videoSimulateCheck.state = s.simulateRecording ? .on : .off
        // `--simulate-recording` pins the mode on for the whole launch, so the checkbox
        // shows the state but can't fight it.
        videoSimulateCheck.isEnabled = !s.launchSimulateOverride
        // The About card is built once and cached, so this would otherwise still show
        // whatever the updater had last done when the panel was first opened.
        lastCheckedLabel.stringValue = String(format: L("Last checked: %@"),
                                              Updater.lastCheckDescription)
        drawColorRow.refresh()
        drawStrokePopup.selectItem(at: DrawStroke.allCases.firstIndex(of: s.drawStroke) ?? 1)
        drawFadePopup.selectItem(at: DrawFade.allCases.firstIndex(of: s.drawFade) ?? 1)
        drawKeyFields.forEach { $0.refreshDisplay() }
    }

    @objc private func loginToggled() {
        Settings.shared.launchAtLogin = (loginCheck.state == .on)
        loginCheck.state = Settings.shared.launchAtLogin ? .on : .off
    }

    /// Dropping the Dock icon switches the app to `.accessory`, which resigns it active
    /// and would leave this very panel stranded behind other windows — re-raise it.
    @objc private func dockToggled() {
        Settings.shared.hideDockIcon = (dockCheck.state == .on)
        AppDelegate.applyDockVisibility()
        DispatchQueue.main.async { [weak self] in self?.window?.makeKeyAndOrderFront(nil) }
    }

    @objc private func delayChanged() {
        Settings.shared.captureDelay = CaptureDelay.allCases[delayPopup.indexOfSelectedItem]
    }

    /// The UI is built with `L(_:)` at construction time, so a language change
    /// needs a relaunch — offer one right away.
    @objc private func languageChanged() {
        let picked = AppLanguage.allCases[languagePopup.indexOfSelectedItem]
        guard picked != Settings.shared.appLanguage else { return }
        Settings.shared.appLanguage = picked
        BrandAlert(title: L("Language changed"),
                   message: L("Restart m_capture to apply the new language."),
                   titles: [L("Restart Now"), L("Later")],
                   primary: 0, cancel: 1, icon: "globe").present { choice in
            if choice == 0 { Updater.relaunch() }
        }
    }

    @objc private func behaviorChanged() {
        Settings.shared.captureBehavior = CaptureBehavior.allCases[behaviorPopup.indexOfSelectedItem]
    }

    @objc private func prefixChanged() {
        Settings.shared.filenamePrefix = prefixField.stringValue
        prefixField.stringValue = Settings.shared.filenamePrefix
        showToast(L("Filename prefix saved"))
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
        pill.layer?.cornerRadius = Theme.radiusSmall
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
        panel.prompt = L("Choose")
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
    /// selected — mute both rows and disable their controls when the default
    /// background is "None".
    ///
    /// The row's `alphaValue` is deliberately left alone. It used to drop to 0.4, and the
    /// popup's own disabled state dropped it another 0.4 on top: the control ended up at
    /// 0.16 and read as missing rather than disabled. Dim the label by colour, and let the
    /// control draw its own disabled state — neither compounds with the other.
    private func updateBackgroundDependentRowsEnabled() {
        let enabled = !bgPresets[defaultBGPopup.indexOfSelectedItem].isNone
        for (row, popup) in [(paddingRow, paddingPopup), (radiusRow, radiusPopup)] {
            row?.subviews.compactMap { $0 as? NSTextField }.first?.textColor =
                enabled ? Theme.textPrimary : Theme.controlTextDisabled
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

    @objc private func confirmDiscardToggled() {
        Settings.shared.confirmDiscard = (confirmDiscardCheck.state == .on)
    }

    @objc private func videoQualityChanged() {
        Settings.shared.videoQuality = VideoQuality.allCases[videoQualityPopup.indexOfSelectedItem]
    }

    @objc private func videoAudioSourceChanged() {
        Settings.shared.videoAudioSource = VideoAudioSource.allCases[videoAudioSourcePopup.indexOfSelectedItem]
    }

    @objc private func videoFrameRateChanged() {
        Settings.shared.videoFrameRate = videoFrameRatePopup.indexOfSelectedItem == 1 ? 60 : 30
    }

    @objc private func videoCountdownChanged() {
        Settings.shared.videoCountdown = CaptureDelay.allCases[videoCountdownPopup.indexOfSelectedItem]
    }

    @objc private func videoClicksToggled() {
        Settings.shared.videoShowClicks = (videoClicksCheck.state == .on)
    }

    @objc private func videoBarMinToggled() {
        Settings.shared.videoStartBarMinimized = (videoBarMinCheck.state == .on)
    }

    @objc private func videoConfirmStopToggled() {
        Settings.shared.videoConfirmStop = (videoConfirmStopCheck.state == .on)
    }

    @objc private func videoZoomChanged() {
        Settings.shared.videoZoomFactor = VideoZoomFactor.allCases[videoZoomPopup.indexOfSelectedItem]
    }

    @objc private func drawStrokeChanged() {
        Settings.shared.drawStroke = DrawStroke.allCases[drawStrokePopup.indexOfSelectedItem]
    }

    @objc private func drawFadeChanged() {
        Settings.shared.drawFade = DrawFade.allCases[drawFadePopup.indexOfSelectedItem]
    }

    /// Simulate mode silently produces no recordings, so switching it on confirms first —
    /// a flag left on by accident would otherwise present as data loss the next time the
    /// user actually recorded something.
    @objc private func videoSimulateToggled() {
        let on = (videoSimulateCheck.state == .on)
        if on {
            let r = BrandAlert(
                title: L("Simulate recordings?"),
                message: L("Recording will run normally — overlay, timer, bar and drawing — but nothing is captured and no file is saved. Useful while the Screen Recording permission is still pending."),
                titles: [L("Simulate"), L("Cancel")],
                primary: 0, cancel: 1, icon: "eye.slash").runModal()
            guard r == 0 else { videoSimulateCheck.state = .off; return }
        }
        Settings.shared.simulateRecording = on
    }

    // MARK: - About section (meta actions relocated from the menu-bar menu)

    /// The About tab's single centered card: logo, name + version (click either to
    /// open the full About panel with the mesoneer credits), the MIT/© line, and
    /// the two help actions side by side — an identity page, not a settings form.
    /// The About card: a centered identity block — who this is, the licence, two
    /// actions. Deliberately sparse. Name and version share a line rather than stacking,
    /// and the updater's status sits under the buttons as a quiet footer, so the card
    /// reads as an identity rather than as a column of five labels.
    private func aboutCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView()
        logo.image = Logo.image(size: 56, onDark: true)
        logo.translatesAutoresizingMaskIntoConstraints = false

        // "m_capture 1.6.7" on one line: the name carries the weight and the version
        // rides along quietly, instead of claiming a row of its own.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let title = NSMutableAttributedString(string: "m_capture", attributes: [
            .font: Theme.font(17, .bold),
            .foregroundColor: Theme.textPrimary,
        ])
        title.append(NSAttributedString(string: "  " + version, attributes: [
            .font: Theme.font(13),
            .foregroundColor: Theme.textSecondary,
        ]))
        let name = NSTextField(labelWithAttributedString: title)
        name.translatesAutoresizingMaskIntoConstraints = false

        // License + maker line; clicking opens the mesoneer site.
        let license = ClickableLabel(L("MIT License · © mesoneer AG"), onClick: {
            if let url = URL(string: "https://www.mesoneer.io/?r=0") { NSWorkspace.shared.open(url) }
        })
        license.translatesAutoresizingMaskIntoConstraints = false

        let guide = actionButton(L("Usage Guide"), #selector(openUsageGuide))
        let bug = actionButton(L("Report a Bug"), #selector(reportBug))
        let buttons = NSStackView(views: [guide, bug])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // When the updater last got an answer. A silent updater that quietly stopped
        // working looks exactly like one with nothing to report, so this is the only
        // place that difference is visible before someone ends up months behind — but it
        // is status, not identity, so it sits below the actions. Filled in by `refresh()`.
        let checked = NSTextField(labelWithString: "")
        checked.font = Theme.font(11)
        checked.textColor = Theme.textSecondary.withAlphaComponent(0.7)
        checked.translatesAutoresizingMaskIntoConstraints = false
        lastCheckedLabel = checked

        // Surfaces a chronically failing silent update check, named by cause (blocked
        // network, rate limit, a bundle we can't write to) — otherwise those users never
        // learn why they're stuck on an old version.
        var updateWarning: NSTextField?
        if let message = Updater.checkFailureMessage {
            let warning = NSTextField(wrappingLabelWithString: message)
            warning.font = Theme.font(11)
            warning.textColor = Theme.accentPurple
            warning.alignment = .center
            warning.translatesAutoresizingMaskIntoConstraints = false
            updateWarning = warning
        }

        ([logo, name, license, buttons, checked] + (updateWarning.map { [$0] } ?? []))
            .forEach { card.addSubview($0) }
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            logo.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            logo.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            logo.widthAnchor.constraint(equalToConstant: 56),
            logo.heightAnchor.constraint(equalToConstant: 56),
            name.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 12),
            name.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            license.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            license.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            buttons.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            checked.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 16),
            checked.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            checked.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        if let warning = updateWarning {
            NSLayoutConstraint.activate([
                warning.topAnchor.constraint(equalTo: license.bottomAnchor, constant: 14),
                warning.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                warning.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.rowWidth - 60),
                buttons.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 16),
            ])
        } else {
            buttons.topAnchor.constraint(equalTo: license.bottomAnchor, constant: 22).isActive = true
        }
        return card
    }

    /// A brand bezel button for the About card's actions, sized like Choose….
    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        return BrandPushButton(title: title, target: self, action: action)
    }

    @objc private func openUsageGuide() { (NSApp.delegate as? AppDelegate)?.openUsageGuide() }
    @objc private func reportBug() { (NSApp.delegate as? AppDelegate)?.reportBug() }
}

/// A muted secondary label that acts as a quiet link: pointing hand, brightens
/// on hover, runs a closure on click.
private final class ClickableLabel: NSTextField {
    private let onClick: () -> Void
    init(_ text: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        stringValue = text
        isEditable = false; isBordered = false; isSelectable = false
        drawsBackground = false
        font = Theme.font(12)
        textColor = Theme.textSecondary
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { textColor = Theme.textPrimary }
    override func mouseExited(with event: NSEvent) { textColor = Theme.textSecondary }
}

/// One row in the Settings sidebar (macOS System Settings style): SF-Symbol icon
/// + label, full-width. Selected = raised pill + lavender icon + white label;
/// unselected = muted, filling on hover.
/// The tab strip that switches between one section's sub-tabs. Underlined tabs on a
/// hairline baseline, not pills: a selected pill alone reads as a toggled button, so the
/// unselected label beside it looked like a stray link rather than the other tab. The
/// baseline is what makes the row a strip — it says both labels belong to one control.
final class SectionTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var selected = 0 { didSet { tabs.enumerated().forEach { $1.isSelected = $0 == selected } } }
    private var tabs: [SectionTab] = []

    init(titles: [String], width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tabs = titles.enumerated().map { index, title in
            let tab = SectionTab(title: title)
            tab.isSelected = index == 0
            tab.onClick = { [weak self] in self?.onSelect?(index) }
            return tab
        }
        let stack = NSStackView(views: tabs)
        stack.orientation = .horizontal
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let baseline = NSView()
        baseline.wantsLayer = true
        baseline.layer?.backgroundColor = Theme.border.cgColor
        baseline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(baseline, positioned: .below, relativeTo: stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: baseline.bottomAnchor),
            baseline.leadingAnchor.constraint(equalTo: leadingAnchor),
            baseline.trailingAnchor.constraint(equalTo: trailingAnchor),
            // A little air under the strip, so the first row reads as content below the
            // tabs rather than as part of the tab bar.
            baseline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            baseline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One tab in a `SectionTabBar`: label above a 2 pt lavender underline that sits on the
/// strip's baseline when selected. Not private — History's filter reuses it, so the
/// underlined-tab look is defined once (see `HistoryFilterBar`).
final class SectionTab: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    private let label = NSTextField(labelWithString: "")

    init(title: String, font: NSFont = Theme.font(12, .semibold)) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = title
        label.font = font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        label.textColor = isSelected ? Theme.textPrimary
            : (hovering ? Theme.textPrimary : Theme.textSecondary)
        needsDisplay = true
    }

    /// The underline is drawn rather than layered so it lands exactly on the baseline
    /// the bar draws behind every tab, selected or not.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected || hovering else { return }
        (isSelected ? Theme.lavender : Theme.textSecondary.withAlphaComponent(0.35)).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 2)).fill()
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class SettingsSidebarItem: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        label.stringValue = title
        label.font = Theme.font(13, .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        label.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
        iconView.contentTintColor = isSelected ? Theme.lavender
            : Theme.textSecondary.withAlphaComponent(0.8)
        layer?.backgroundColor = isSelected ? Theme.surfaceRaised.cgColor
            : (hovering ? Theme.hoverFill.cgColor : NSColor.clear.cgColor)
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A native `NSButton` (checkbox / push button) that shows the pointing-hand
/// cursor on hover, matching the app's custom controls.
private final class PointerButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The Settings panel's push buttons — Choose…, and the About card's Usage Guide / Report
/// a Bug. It draws its own square accent fill rather than taking `bezelStyle = .rounded`,
/// because AppKit rounds a native bezel for us and there is no radius to set to 0; a
/// rounded pill was the last curved chrome in the panel. Mirrors the custom button
/// `BrandAlert` already draws.
///
/// Deliberately *not* a `PointerButton` subclass: `PointerButton` also backs the panel's
/// checkboxes (`NSButton(checkboxWithTitle:)`), and a fill painted in its `draw` lands
/// behind the checkbox label as a purple slab.
private final class BrandPushButton: NSButton {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        self.target = target
        self.action = action
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.font(13, .medium), .foregroundColor: Theme.textPrimary,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 22   // the native bezel's own padding, which we no longer get
        s.height = 24   // `Layout.rowHeight` — private to the controller; every form
                        // control is 24 pt and the row rhythm depends on it
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = hovering
            ? Theme.accentPurple.blended(withFraction: 0.18, of: .white) ?? Theme.accentPurple
            : Theme.accentPurple
        fill.setFill()
        NSBezierPath(rect: bounds).fill()
        Theme.border.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        super.draw(dirtyRect)
    }
}

/// A small lavender ⓘ that marks a row as having help and reveals a brand tooltip
/// on hover. The visible glyph is the affordance — so the help is discoverable.
private final class InfoDot: NSImageView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("Help"))?
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


// MARK: - Drawing controls

/// The drawing palette as clickable chips plus a Custom chip that opens the brand
/// `ColorPickerPanel` — the same picker the annotation editor uses, so colour is chosen the
/// same way on both surfaces. The current colour is marked with a lavender ring.
private final class DrawColorRow: NSView {
    /// The editor's palette, so a mark drawn on screen and one drawn in the editor can be
    /// the same colour by picking the same chip.
    private let palette: [NSColor] = [
        Theme.rgb(0xE5, 0x3E, 0x3E), Theme.rgb(0xF9, 0x73, 0x16), Theme.rgb(0xFA, 0xCC, 0x15),
        Theme.rgb(0x22, 0xC5, 0x5E), Theme.rgb(0x3B, 0x82, 0xF6), Theme.rgb(0xA8, 0x55, 0xF7),
        Theme.rgb(0xEC, 0x48, 0x99), .white, .black,
    ]
    private var picker: ColorPickerPanel?
    private let chipSize: CGFloat = 18
    private let gap: CGFloat = 7

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 246, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        // Width is owned by `row(_:_:tip:)` (Layout.controlWidth); only the height is ours.
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() { needsDisplay = true }

    /// Chip index 0..<palette.count are presets; the last chip is Custom.
    private func chipRect(_ i: Int) -> NSRect {
        NSRect(x: CGFloat(i) * (chipSize + gap), y: (bounds.height - chipSize) / 2,
               width: chipSize, height: chipSize)
    }
    private var customIndex: Int { palette.count }

    override func draw(_ dirtyRect: NSRect) {
        let current = Settings.shared.drawColor
        let currentHex = Settings.hex(current)
        var matchedPreset = false
        for (i, c) in palette.enumerated() {
            let r = chipRect(i)
            let selected = Settings.hex(c) == currentHex
            if selected { matchedPreset = true }
            drawChip(in: r, fill: c, selected: selected)
        }
        // Custom chip: shows the live colour when it isn't one of the presets, otherwise a
        // neutral swatch, so "which chip am I on" is never ambiguous.
        let r = chipRect(customIndex)
        drawChip(in: r, fill: matchedPreset ? Theme.surfaceRaised : current, selected: !matchedPreset)
        let plus = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY), arm: CGFloat = 4
        plus.move(to: NSPoint(x: c.x - arm, y: c.y)); plus.line(to: NSPoint(x: c.x + arm, y: c.y))
        plus.move(to: NSPoint(x: c.x, y: c.y - arm)); plus.line(to: NSPoint(x: c.x, y: c.y + arm))
        plus.lineWidth = 1.5
        (matchedPreset ? Theme.textSecondary : NSColor.white).setStroke()
        plus.stroke()
    }

    private func drawChip(in r: NSRect, fill: NSColor, selected: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall)
        fill.setFill(); path.fill()
        // Every chip gets a hairline so white reads against the dark panel.
        (selected ? Theme.lavender : Theme.border).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0...palette.count where chipRect(i).contains(p) {
            if i == customIndex { showPicker(at: chipRect(i)) } else {
                Settings.shared.drawColor = palette[i]
                needsDisplay = true
            }
            return
        }
    }

    /// The picker writes through on every drag, so the swatch and the next mark track the
    /// hue live rather than waiting for the panel to close.
    private func showPicker(at anchor: NSRect) {
        let host = NSView(frame: anchor)
        addSubview(host)
        let panel = ColorPickerPanel(onPick: { [weak self] color in
            Settings.shared.drawColor = color
            self?.needsDisplay = true
        }, onClose: { [weak self] in
            self?.picker = nil
            host.removeFromSuperview()
        })
        picker = panel
        panel.show(near: host, initial: Settings.shared.drawColor)
    }
}

/// A brand-styled field that records the single letter which selects one drawing tool.
/// Click to arm, then press a letter or digit. Unlike `HotKeyField` these are not global
/// hotkeys — the draw overlay owns the keyboard while it is up — so nothing is registered
/// with Carbon and no modifiers are involved.
private final class DrawKeyField: NSView, KeyRecorder {
    private let tool: DrawTool
    private let keyLabel = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var resignObserver: Any?
    private var recording = false { didSet { needsDisplay = true; refreshDisplay() } }

    init(tool: DrawTool) {
        self.tool = tool
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        wantsLayer = true
        keyLabel.font = Theme.font(12, .semibold)
        keyLabel.textColor = Theme.textPrimary
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyLabel)
        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BrandControl.textInset),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        refreshDisplay()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshDisplay() {
        keyLabel.stringValue = recording ? L("Press a key…") : Settings.shared.drawKey(tool)
        keyLabel.textColor = recording ? Theme.lavender : Theme.textPrimary
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall)
        Theme.controlFill.setFill(); path.fill()
        (recording ? Theme.lavender : Theme.controlStroke).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        // One field armed at a time — see `KeyRecorders`.
        KeyRecorders.arm(self)
        recording = true
        window?.makeFirstResponder(self)
        // The Settings panel is a reused singleton that closes by ordering out, so a field
        // left armed would outlive it — stale prompt on reopen and a monitor eating the
        // next keystroke. Mirrors `HotKeyField`.
        if let win = window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: win, queue: .main
            ) { [weak self] _ in self?.stopRecording() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            guard let self, self.recording else { return ev }
            if ev.keyCode == 53 { self.stopRecording(); return nil }        // Esc cancels
            guard let raw = ev.charactersIgnoringModifiers?.uppercased(), raw.count == 1,
                  let ch = raw.unicodeScalars.first,
                  CharacterSet.alphanumerics.contains(ch) else {
                // Anything that isn't a plain letter or digit would be unreachable or
                // ambiguous as a tool key — ignore it rather than storing it.
                return nil
            }
            if let owner = Settings.shared.drawKeyConflict(raw, excluding: self.tool) {
                self.stopRecording()
                self.reportConflict(raw, owner: owner)
                return nil
            }
            Settings.shared.setDrawKey(raw, for: self.tool)
            self.stopRecording()
            return nil
        }
    }

    /// Non-modal: this runs from inside a local event monitor, where a nested `runModal`
    /// can wedge the run loop (same reason `HotKeyField` presents this way).
    private func reportConflict(_ key: String, owner: String) {
        BrandAlert(title: L("Key already in use"),
                   message: String(format: L("%@ is already used by “%@”. Choose a different key."), key, owner),
                   titles: [L("OK")], primary: 0, cancel: 0,
                   icon: "exclamationmark.triangle").present()
    }

    func disarm() { stopRecording() }

    private func stopRecording() {
        guard recording else { return }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        recording = false
        KeyRecorders.resign(self)
    }

    deinit { stopRecording() }
}
