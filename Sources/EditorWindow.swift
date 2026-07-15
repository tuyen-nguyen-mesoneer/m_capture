// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import UniformTypeIdentifiers

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A card/panel the user can drag (clicks on tool buttons still work; clicks on
/// the card background move it). Lets the user reposition tools off the capture.
private final class DraggablePanel: NSView {
    private var grabOffset: CGPoint?
    override func mouseDown(with event: NSEvent) {
        guard let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        grabOffset = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let off = grabOffset, let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        let x = min(max(0, p.x - off.x), sv.bounds.width - frame.width)
        let y = min(max(0, p.y - off.y), sv.bounds.height - frame.height)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Live preview of a share-ready background: painted behind the canvas, extended
/// by the padding, with a soft shadow under the (rounded) image area. The canvas
/// sits on top at `innerRect`, so only the frame + shadow show around it.
private final class BackgroundView: NSView {
    var background: Background = .none
    var innerRect: CGRect = .zero
    var cornerRadius: CGFloat = 0
    var shadowPad: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !background.isNone else { return }
        background.fill(bounds, in: ctx)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -shadowPad * 0.12), blur: shadowPad * 0.5,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
        let path = CGPath(roundedRect: innerRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
}

/// One of eight draggable knobs around the capture — four corners trim both axes, four
/// edge midpoints a single axis. Dragging trims the capture region inward (a crop of the
/// captured pixels, never a grow); the controller previews and commits the crop. Reports
/// the drag as a screen-space delta so the controller can move the grabbed edge(s) and
/// hold the opposite ones.
private final class ResizeHandle: NSView {
    enum Edge: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    let edge: Edge
    var onBegin: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?
    private var start: NSPoint = .zero

    init(edge: Edge) { self.edge = edge; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(Theme.accentPurple.cgColor); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: r)
    }
    private var cursor: NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:            return .openHand   // no system diagonal cursor
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func mouseDown(with e: NSEvent) {
        start = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        onBegin?()
    }
    override func mouseDragged(with e: NSEvent) {
        let m = NSEvent.mouseLocation
        onDrag?(CGSize(width: m.x - start.x, height: m.y - start.y))
    }
    override func mouseUp(with e: NSEvent) { NSCursor.pop(); onEnd?() }
}

/// A brand-styled horizontal slider: lavender fill + knob on a dark track, with a
/// pointing-hand cursor (the system slider's blue accent reads wrong on the dark
/// editor panels — see Theme/styleguide notes).
private final class BrandSliderCell: NSSliderCell {
    override func barRect(flipped: Bool) -> NSRect {
        let full = super.barRect(flipped: flipped)
        let h: CGFloat = 4
        return NSRect(x: full.minX, y: full.midY - h / 2, width: full.width, height: h)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let radius = rect.height / 2
        Theme.border.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let frac = CGFloat((doubleValue - minValue) / max(0.0001, maxValue - minValue))
        var fill = rect; fill.size.width = max(rect.height, rect.width * frac)
        Theme.lavender.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 14
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r)
        Theme.lavender.setFill(); path.fill()
        NSColor(white: 0, alpha: 0.25).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override var knobThickness: CGFloat { 14 }
}

private final class BrandSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { BrandSliderCell.self }
        set {}
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
}

/// In-place annotation editor: the captured region stays put over a dimmed
/// backdrop, with the tools shown as tile clusters scattered around the
/// image, animating into place.
final class EditorWindowController: NSObject {
    private static var open: [EditorWindowController] = []

    /// Whether any editor is on screen. The menu disables Screenshot / Record
    /// while an editor is open (both no-op in that state anyway).
    static var hasOpenWindows: Bool { !open.isEmpty }

    private let window: KeyableWindow
    /// Fallback ⌘V handler: `CanvasView.performKeyEquivalent` catches paste when the key
    /// routing cooperates, but that isn't guaranteed for a promoted menu-bar agent's
    /// borderless window — this local monitor catches the same event once it's dispatched
    /// as a keyDown, so ⌘V pastes an image overlay reliably. (No double-paste: a handled
    /// key equivalent is consumed before it ever becomes a keyDown.)
    private var pasteMonitor: Any?
    private let canvas: CanvasView
    /// Capture context, kept so the resize handles can re-grab a larger region from the
    /// same display (excluding this editor window so it sees the real screen behind).
    private let captureScreen: NSScreen
    private var reGrabbing = false
    private var toolButtons: [Tool: ToolButton] = [:]
    private var swatchButtons: [ToolButton] = []
    /// Stroke-width presets, exposed via ONE cycling tile (Thin → Medium → Thick) so the
    /// Style cluster stays a clean 3×4 like every other cluster. The tile's bar previews
    /// the current width. `widthDisplay` is the on-tile bar thickness for each preset.
    private let widths: [CGFloat] = [3, 6, 11]
    private let widthDisplay: [CGFloat] = [2, 4, 7]
    private let widthLabels = ["Thin", "Medium", "Thick"]
    private weak var widthButton: ToolButton?
    private var currentWidth = 1   // 6 pt — matches the editor's default stroke
    private weak var plusButton: ToolButton?
    private weak var counterFormatButton: ToolButton?
    private weak var emojiButton: ToolButton?
    private var colorPicker: ColorPickerPanel?
    private var emojiPicker: EmojiPickerPanel?
    private var formatPicker: CounterFormatPicker?

    private var clusterViews: [NSView] = []
    private var ring: NSView!
    private var cropButtons: [NSView] = []
    private var currentSwatch: Int? = 0

    private var currentBackground: Background = Settings.shared.defaultBackground
    private var bgButtons: [ToolButton] = []

    private var resizeHandles: [ResizeHandle] = []
    private var resizePreview: NSView?
    private var resizeBaseFrame: NSRect = .zero
    private var activeResizeEdge: ResizeHandle.Edge = .bottomRight
    private weak var bgPlusButton: ToolButton?
    private var bgColorPicker: ColorPickerPanel?
    private var bgView: BackgroundView?

    private var opacityCard: NSView?
    private weak var opacitySlider: NSSlider?


    private let palette: [(NSColor, String)] = [
        (Theme.rgb(0xE5, 0x3E, 0x3E), "Red"),
        (Theme.rgb(0xF9, 0x73, 0x16), "Orange"),
        (Theme.rgb(0xFA, 0xCC, 0x15), "Yellow"),
        (Theme.rgb(0x22, 0xC5, 0x5E), "Green"),
        (Theme.rgb(0x3B, 0x82, 0xF6), "Blue"),
        (Theme.rgb(0xA8, 0x55, 0xF7), "Purple"),
        (Theme.rgb(0xEC, 0x48, 0x99), "Pink"),
        (.white, "White"),
        (.black, "Black"),
    ]

    /// - Parameter captureScale: The display's exact pixels-per-point density used to
    ///   capture `image` (e.g. 2.0 on Retina, 1.0 on a plain external). The canvas's
    ///   on-screen scale is `1 / captureScale` — an exact reciprocal of a known-good
    ///   constant. Deriving it instead from `selectionRect.width / image.size.width`
    ///   divides two independently-rounded numbers (a fractional trackpad-drag point
    ///   width against an already-rounded pixel width): the ratio lands a hair off
    ///   exact integers/halves, and that sub-percent error forces CoreGraphics to
    ///   bilinear-resample the *entire* image on every redraw — invisible on a dense
    ///   Retina panel, visibly soft on a 1x external display.
    init(image: NSImage, selectionRect: CGRect, screen: NSScreen, captureScale: CGFloat = 1) {
        let scale = captureScale > 0 ? 1 / captureScale : 1
        canvas = CanvasView(image: image, displayScale: scale)
        captureScreen = screen
        window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true

        let dim = NSView(frame: content.bounds)
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        content.addSubview(dim)

        let local = NSRect(x: selectionRect.minX - screen.frame.minX,
                           y: selectionRect.minY - screen.frame.minY,
                           width: selectionRect.width, height: selectionRect.height)
        canvas.setFrameOrigin(local.origin)
        content.addSubview(canvas)

        let ring = NSView(frame: local.insetBy(dx: -1, dy: -1))
        ring.wantsLayer = true
        ring.layer?.borderColor = Theme.lavender.cgColor
        ring.layer?.borderWidth = 1
        ring.layer?.backgroundColor = NSColor.clear.cgColor
        content.addSubview(ring, positioned: .below, relativeTo: canvas)
        self.ring = ring

        window.contentView = content
        tipBox.addSubview(tipText)

        clusterViews = buildClusters(around: local, in: content)
        animateIn(clusterViews)
        placeResizeHandle(in: content)
        applyBackgroundPreview()

        canvas.onColorPicked = { [weak self] _ in self?.deselectSwatches() }
        canvas.onShortcut = { [weak self] key in self?.handleShortcut(key) }
        canvas.onCancel = { [weak self] in self?.attemptClose() }
        canvas.onCropBegin = { [weak self] in self?.hideCropConfirm() }
        canvas.onCropReady = { [weak self] in self?.showCropConfirm() }
        canvas.onCropConfirm = { [weak self] in self?.applyCrop() }
        canvas.onOCR = { [weak self] cg in self?.recognizeAndCopy(cg) }
        canvas.onOverlaySelected = { [weak self] a in self?.showOpacity(for: a) }
        canvas.onToolChange = { [weak self] t in
            guard let self else { return }
            for (tool, b) in self.toolButtons { b.selectedState = (tool == t) }
        }
        canvas.onPaste = { [weak self] in self?.pasteOverlay() }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window, !self.canvas.isEditingText,
                  event.modifierFlags.intersection([.command, .option, .control]) == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            self.pasteOverlay()
            return nil   // consume
        }
        selectTool(.pencil)
        selectSwatch(0)
        canvas.style.lineWidth = 6

        EditorWindowController.open.append(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        window.delegate = self
    }

    private func buildClusters(around sel: NSRect, in content: NSView) -> [NSView] {
        let bgPad = currentBackground.isNone ? 0 : Background.padding(maxDim: max(sel.width, sel.height))
        let sel = sel.insetBy(dx: 8 - bgPad, dy: 8 - bgPad)
        func toolButton(_ t: Tool, _ symbol: String, _ tip: String) -> ToolButton {
            let b = ToolButton(style: .tool(symbol), target: self, action: #selector(toolPressed(_:)))
            b.tip = tip; wireHover(b); toolButtons[t] = b; return b
        }
        func toolButton(_ t: Tool, _ style: ToolButton.Style, _ tip: String) -> ToolButton {
            let b = ToolButton(style: style, target: self, action: #selector(toolPressed(_:)))
            b.tip = tip; wireHover(b); toolButtons[t] = b; return b
        }
        func actionButton(_ symbol: String, _ tip: String, key: String, mods: NSEvent.ModifierFlags, _ sel: Selector) -> ToolButton {
            let b = ToolButton(style: .tool(symbol), target: self, action: sel)
            b.tip = tip; b.keyEquivalent = key; b.keyEquivalentModifierMask = mods; wireHover(b); return b
        }

        let overlayBtn = ToolButton(style: .tool("photo"), target: self, action: #selector(overlayPressed))
        overlayBtn.tip = "Overlay image — paste (⌘V), drop a file, or click to choose"
        wireHover(overlayBtn); toolButtons[.overlay] = overlayBtn

        let counterBtn = ToolButton(style: .counterGlyph, target: self, action: #selector(counterPressed))
        counterBtn.tip = "Counter — place numbered badges (click again to change format)  (C)"
        wireHover(counterBtn); toolButtons[.counter] = counterBtn; counterFormatButton = counterBtn
        let emojiBtn = ToolButton(style: .text(canvas.currentEmoji), target: self, action: #selector(emojiPressed))
        emojiBtn.tip = "Emoji — stamp an emoji (click to choose)"; wireHover(emojiBtn)
        emojiButton = emojiBtn; toolButtons[.emoji] = emojiBtn

        let draw = makeCluster("Markup", [
            toolButton(.pencil, "pencil", "Pencil — freehand draw  (P)"),
            toolButton(.marker, "highlighter", "Highlighter — translucent highlight  (H)"),
            toolButton(.eraser, "eraser", "Eraser — click a mark to remove it  (E)"),
            toolButton(.text, .text("T"), "Text — click and type a label  (T)"),
            toolButton(.blur, .mosaic, "Blur — soften an area to hide sensitive info  (B)"),
            toolButton(.spotlight, .spotlightGlyph, "Spotlight — dim everything around an area  (S)"),
            counterBtn,
            emojiBtn,
            toolButton(.zoom, "plus.magnifyingglass", "Zoom — magnify a region into a callout  (Z)"),
            toolButton(.ruler, "ruler", "Ruler — press ↑↓ or ←→, move to measure, click to imprint"),
            overlayBtn,
            actionButton("text.viewfinder", "Copy text / QR (OCR) — drag over text or a QR code  (⌘T)", key: "t", mods: [.command], #selector(copyTextPressed))], perRow: 4)
        let shapes = makeCluster("Shape", [
            toolButton(.arrow, "arrow.up.right", "Arrow — point at something  (A)"),
            toolButton(.line, "line.diagonal", "Line — straight line  (L)"),
            toolButton(.rect, "rectangle", "Rectangle — box outline  (R)"),
            toolButton(.ellipse, "circle", "Ellipse — oval outline  (O)"),
            toolButton(.roundedRect, .roundedSquare, "Rounded rectangle — rounded box  (U)"),
            toolButton(.triangle, "triangle", "Triangle — triangle outline  (G)"),
            toolButton(.diamond, "diamond", "Diamond — diamond outline  (D)"),
            toolButton(.star, "star", "Star — 5-point star outline  (Y)"),
            toolButton(.checkmark, "checkmark", "Checkmark — check mark  (K)"),
            toolButton(.pentagon, "pentagon", "Pentagon — 5-sided outline  (5)"),
            toolButton(.hexagon, "hexagon", "Hexagon — 6-sided outline  (6)"),
            toolButton(.octagon, "octagon", "Octagon — 8-sided outline  (8)")], perRow: 4)

        let colorR: CGFloat = 14
        let eyedropper = ToolButton(style: .tool("eyedropper"), radius: colorR,
                                   target: self, action: #selector(toolPressed(_:)))
        eyedropper.tip = "Eyedropper — pick a color from the image  (I)"; wireHover(eyedropper)
        toolButtons[.eyedropper] = eyedropper
        var colorTiles: [ToolButton] = [eyedropper]
        for (i, entry) in palette.enumerated() {
            let b = ToolButton(style: .swatch(entry.0), radius: colorR, target: self, action: #selector(swatchPressed(_:)))
            b.tag = i; b.tip = "\(entry.1) color"; wireHover(b)
            swatchButtons.append(b); colorTiles.append(b)
        }
        let plus = ToolButton(style: .plusGlyph, radius: colorR, target: self, action: #selector(customColorPressed))
        plus.tip = "Custom color — pick any hue"; wireHover(plus)
        plusButton = plus
        colorTiles.append(plus)
        // One cycling stroke-width tile completes a tidy 3×4 grid (9 swatches +
        // eyedropper + custom + width), matching every other cluster's footprint.
        let widthTile = ToolButton(style: .lineWeight(widthDisplay[currentWidth]), radius: colorR,
                                   target: self, action: #selector(widthPressed))
        widthTile.tip = "Stroke width: \(widthLabels[currentWidth]) — click to cycle"
        widthTile.activeLineWeightIndex = currentWidth
        wireHover(widthTile); widthButton = widthTile; colorTiles.append(widthTile)
        let color = makeCluster("Style", colorTiles, perRow: 4, radius: colorR)

        let actions = makeCluster("Action", [
            toolButton(.select, "cursorarrow", "Move — drag an object to reposition, drag its corner to resize, ⌫ to delete  (V)"),
            toolButton(.crop, "crop", "Crop — drag a region, then ↵ or ✓"),
            actionButton("rotate.right", "Rotate right 90°", key: "", mods: [], #selector(rotateRightPressed)),
            actionButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal", key: "", mods: [], #selector(flipHorizontalPressed)),
            actionButton("arrow.uturn.backward", "Undo  (⌘Z)", key: "z", mods: [.command], #selector(undoPressed)),
            actionButton("arrow.uturn.forward", "Redo  (⇧⌘Z)", key: "z", mods: [.command, .shift], #selector(redoPressed)),
            actionButton("pin", "Pin to screen — keep on top  (⌘P)", key: "p", mods: [.command], #selector(pinPressed)),
            actionButton("photo.stack", "Before/After GIF — animate overlays on/off", key: "", mods: [], #selector(beforeAfterPressed)),
            actionButton("doc.on.doc", "Copy & close  (⌘C)", key: "c", mods: [.command], #selector(copyPressed)),
            actionButton("square.and.arrow.down", "Save & close  (⌘S)", key: "s", mods: [.command], #selector(savePressed)),
            actionButton("square.and.arrow.down.on.square", "Save As… — choose location  (⇧⌘S)", key: "s", mods: [.command, .shift], #selector(saveAsPressed)),
            actionButton("xmark", "Cancel  (Esc)", key: "\u{1b}", mods: [], #selector(closePressed))], perRow: 4)

        let bgR: CGFloat = 14
        var bgTiles: [ToolButton] = []
        for (i, style) in Background.presets.enumerated() {
            let tileStyle: ToolButton.Style = style.isNone ? .noneGlyph : .swatch(style.swatch)
            let b = ToolButton(style: tileStyle, radius: bgR, target: self, action: #selector(backgroundPressed(_:)))
            b.tag = i
            b.tip = style.isNone ? "None" : style.name
            b.selectedState = (style.name == currentBackground.name)
            wireHover(b); bgButtons.append(b); bgTiles.append(b)
        }
        let bgPlus = ToolButton(style: .plusGlyph, radius: bgR, target: self, action: #selector(backgroundCustomPressed))
        bgPlus.tip = "Custom color"
        bgPlus.selectedState = currentBackground.isSolid
        wireHover(bgPlus); bgPlusButton = bgPlus; bgTiles.append(bgPlus)
        let background = makeCluster("Background", bgTiles, perRow: 4, radius: bgR)

        let cs = content.bounds.size
        let g: CGFloat = 16

        let cp: CGFloat = 9
        let leftW = draw.frame.width + 2 * cp
        let leftH = draw.frame.height + 2 * cp
        let rightW = shapes.frame.width + 2 * cp
        let rightH = shapes.frame.height + 2 * cp
        let rowH = [color.frame.height, background.frame.height, actions.frame.height].max()! + 2 * cp
        let topFits = cs.height - sel.maxY >= rowH + 2 * g
        let bottomFits = sel.minY >= rowH + 2 * g
        let canScatter =
            sel.minX >= leftW + 2 * g &&
            cs.width - sel.maxX >= rightW + 2 * g &&
            (topFits || bottomFits) &&
            sel.height >= max(leftH, rightH) * 0.7

        if canScatter {
            let d = cardFit(draw), s = cardFit(shapes)
            let co = cardFit(color), bgc = cardFit(background), ac = cardFit(actions)
            stackVertically([d], onLeft: true, sel: sel, gap: g, cs: cs, content)
            stackVertically([s], onLeft: false, sel: sel, gap: g, cs: cs, content)
            if topFits && bottomFits {
                rowOutside([co, bgc], above: true, sel: sel, gap: g, cs: cs, content)
                rowOutside([ac], above: false, sel: sel, gap: g, cs: cs, content)
            } else {
                rowOutside([co, bgc, ac], above: topFits, sel: sel, gap: g, cs: cs, content)
            }
            return [d, s, co, bgc, ac]
        } else {
            let panel = makePanel([[draw, shapes], [color, background, actions]])
            positionPanel(panel, sel: sel, cs: cs, content)
            return [panel]
        }
    }

    /// Center the cluster in its card on both axes (uniform panel cards leave
    /// extra space around smaller clusters; this keeps them centered).
    private func placeInner(_ inner: NSView, in size: NSSize) {
        inner.setFrameOrigin(NSPoint(x: (size.width - inner.frame.width) / 2,
                                     y: (size.height - inner.frame.height) / 2))
    }

    /// A draggable, free-floating cluster card. It has to stay legible over any
    /// wallpaper — a bright capture or a near-black desktop — so it gets a solid
    /// brand-gradient fill, the brand hairline edge, and a soft drop shadow to lift
    /// it off the backdrop (the shadow, not the edge, is what carries the contrast).
    /// Square corners + `Theme.border` match the Settings / About panels.
    private func cardFit(_ inner: NSView) -> NSView {
        let pad: CGFloat = 5, radius: CGFloat = 0
        let size = NSSize(width: inner.frame.width + pad * 2, height: inner.frame.height + pad * 2)
        let c = DraggablePanel(frame: NSRect(origin: .zero, size: size))
        c.wantsLayer = true
        guard let layer = c.layer else { return c }
        layer.cornerRadius = radius
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: -5)
        Theme.applyPanelGradient(to: c, cornerRadius: radius)
        placeInner(inner, in: size)
        c.addSubview(inner)
        return c
    }

    /// A uniform-size tile used *inside* the gathered panel. The panel has no
    /// background of its own, so each card is solid (brand gradient + edge +
    /// shadow), the same as a floating scatter card, to read on any backdrop.
    private func styleCard(_ c: NSView, _ inner: NSView, _ size: NSSize, topPad: CGFloat) {
        c.frame = NSRect(origin: .zero, size: size)
        c.wantsLayer = true
        guard let layer = c.layer else { return }
        let radius: CGFloat = 0
        layer.cornerRadius = radius
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: -5)
        Theme.applyPanelGradient(to: c, cornerRadius: radius)
        inner.setFrameOrigin(NSPoint(x: (size.width - inner.frame.width) / 2,
                                     y: size.height - inner.frame.height - topPad))
        c.addSubview(inner)
    }

    /// A static uniform-size card (used inside the gathered panel).
    private func card(_ inner: NSView, size: NSSize, topPad: CGFloat) -> NSView {
        let c = NSView(); styleCard(c, inner, size, topPad: topPad); return c
    }

    /// Gather all clusters into one draggable group of equal-size cards (used when
    /// the selection is too small or too large to scatter cleanly). The group has
    /// no background slab of its own — the cards stand on their own gradient fill.
    private func makePanel(_ rows: [[NSView]]) -> NSView {
        let pad: CGFloat = 7, hgap: CGFloat = 6, vgap: CGFloat = 6
        let innerPad: CGFloat = 5
        let all = rows.flatMap { $0 }
        let cardW = (all.map { $0.frame.width }.max() ?? 0) + innerPad * 2
        let cardH = (all.map { $0.frame.height }.max() ?? 0) + innerPad * 2
        let cardSize = NSSize(width: cardW, height: cardH)
        let cardRows = rows.map { $0.map { card($0, size: cardSize, topPad: innerPad) } }
        let rowW = cardRows.map { row in
            row.reduce(0) { $0 + $1.frame.width } + hgap * CGFloat(row.count - 1)
        }
        let rowH = cardRows.map { row in row.map { $0.frame.height }.max() ?? 0 }
        let panelW = (rowW.max() ?? 0) + pad * 2
        let panelH = rowH.reduce(0, +) + vgap * CGFloat(cardRows.count - 1) + pad * 2

        let panel = DraggablePanel(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        panel.wantsLayer = true
        panel.layer?.masksToBounds = false

        var yTop = pad
        for (i, row) in cardRows.enumerated() {
            let h = rowH[i]
            var x = (panelW - rowW[i]) / 2
            for v in row {
                let y = panelH - yTop - h + (h - v.frame.height) / 2
                v.setFrameOrigin(NSPoint(x: x, y: y))
                panel.addSubview(v)
                x += v.frame.width + hgap
            }
            yTop += h + vgap
        }
        return panel
    }

    /// Place the gathered panel on whichever side of the selection has the most
    /// free space (below / above / left / right), rather than always below.
    private func positionPanel(_ p: NSView, sel: NSRect, cs: CGSize, _ content: NSView) {
        let g: CGFloat = 16, m: CGFloat = 8
        let w = p.frame.width, h = p.frame.height
        let cx = min(max(m, sel.midX - w / 2), cs.width - w - m)
        let cy = min(max(m, sel.midY - h / 2), cs.height - h - m)

        let candidates: [(CGPoint, CGFloat)] = [
            (CGPoint(x: cx, y: sel.minY - g - h),   sel.minY - g - h - m),
            (CGPoint(x: cx, y: sel.maxY + g),       cs.height - (sel.maxY + g + h) - m),
            (CGPoint(x: sel.minX - g - w, y: cy),   sel.minX - g - w - m),
            (CGPoint(x: sel.maxX + g, y: cy),       cs.width - (sel.maxX + g + w) - m),
        ]
        let best = candidates.max { $0.1 < $1.1 }!
        // A selection spanning the whole screen (e.g. Quick Screen) leaves no side
        // with real room — every candidate is a negative-margin worst-fit clamped to
        // an edge. Center the panel instead of pinning it to whichever edge lost least.
        if best.1 < 0 {
            p.setFrameOrigin(NSPoint(x: (cs.width - w) / 2, y: (cs.height - h) / 2))
            content.addSubview(p)
            return
        }
        let fx = min(max(m, best.0.x), cs.width - w - m)
        let fy = min(max(m, best.0.y), cs.height - h - m)
        p.setFrameOrigin(NSPoint(x: fx, y: fy))
        content.addSubview(p)
    }

    /// Stack clusters in a column beside the selection, centered vertically,
    /// keeping the whole column out of the selection rectangle when possible.
    private func stackVertically(_ views: [NSView], onLeft: Bool, sel: NSRect,
                                 gap: CGFloat, cs: CGSize, _ content: NSView) {
        let maxW = views.map { $0.frame.width }.max() ?? 0
        let totalH = views.reduce(0) { $0 + $1.frame.height } + gap * CGFloat(views.count - 1)
        var topY = sel.midY + totalH / 2
        topY = min(topY, cs.height - 8)
        if topY - totalH < 8 { topY = totalH + 8 }
        let x = onLeft ? max(8, sel.minX - gap - maxW)
                       : min(cs.width - 8 - maxW, sel.maxX + gap)
        var y = topY
        for v in views {
            y -= v.frame.height
            v.setFrameOrigin(NSPoint(x: x + (maxW - v.frame.width) / 2, y: y))
            content.addSubview(v)
            y -= gap
        }
    }

    /// Lay clusters in a single row just outside the selection — `above` it when
    /// the top has more room, otherwise below. Cards top-align across the row.
    private func rowOutside(_ views: [NSView], above: Bool, sel: NSRect, gap: CGFloat, cs: CGSize, _ content: NSView) {
        let totalW = views.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(views.count - 1)
        let maxH = views.map { $0.frame.height }.max() ?? 0
        var x = min(max(8, sel.midX - totalW / 2), cs.width - totalW - 8)
        let y = above ? min(cs.height - 8 - maxH, sel.maxY + gap)
                      : max(8, sel.minY - gap - maxH)
        for v in views {
            v.setFrameOrigin(NSPoint(x: x, y: y + (maxH - v.frame.height)))
            content.addSubview(v)
            x += v.frame.width + gap
        }
    }

    private func makeCluster(_ name: String, _ buttons: [ToolButton], perRow: Int, radius r: CGFloat = 14) -> NSView {
        let side = ToolButton.size(radius: r).width
        let hgap: CGFloat = 4, vgap: CGFloat = 4
        let stepX = side + hgap, rowVStep = side + vgap
        let rows = Int(ceil(Double(buttons.count) / Double(perRow)))

        let capH: CGFloat = 17, capToGrid: CGFloat = 22
        let gridW = CGFloat(perRow - 1) * stepX + side
        let gridH = CGFloat(rows - 1) * rowVStep + side
        let totalH = capH + capToGrid + gridH

        let cap = groupLabel(name)
        cap.alignment = .center
        let contentW = max(gridW, ceil(cap.intrinsicContentSize.width) + 10)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: totalH))
        container.wantsLayer = true

        cap.frame = NSRect(x: 0, y: totalH - capH, width: contentW, height: capH)
        container.addSubview(cap)

        let divider = NSView(frame: NSRect(x: contentW * 0.14, y: totalH - capH - 6,
                                           width: contentW * 0.72, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        container.addSubview(divider)

        for (i, b) in buttons.enumerated() {
            let row = i / perRow, col = i % perRow
            let inThisRow = min(perRow, buttons.count - row * perRow)
            let rowW = CGFloat(inThisRow - 1) * stepX + side
            let x = (contentW - rowW) / 2 + CGFloat(col) * stepX
            let yTop = capH + capToGrid + CGFloat(row) * rowVStep
            b.frame = NSRect(x: x, y: totalH - yTop - side, width: side, height: side)
            container.addSubview(b)
        }
        return container
    }

    private func animateIn(_ views: [NSView]) {
        for (i, v) in views.enumerated() {
            guard let layer = v.layer else { continue }
            let f = v.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: f.midX, y: f.midY)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.2; scale.toValue = 1
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = 0; op.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [scale, op]
            group.duration = 0.3
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.045
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .backwards
            layer.add(group, forKey: "popin")
        }
    }

    private func groupLabel(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        Theme.styleEyebrow(l, title)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let s = NSMutableAttributedString(attributedString: l.attributedStringValue)
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        l.attributedStringValue = s
        l.alignment = .center
        let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.6)
        sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -1)
        l.shadow = sh
        return l
    }

    private func wireHover(_ b: ToolButton) {
        b.onEnter = { [weak self] btn in self?.showTip(btn) }
        b.onExit = { [weak self] in self?.hideTip() }
    }

    private lazy var tipText: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.font(11, .medium); l.textColor = Theme.ink
        return l
    }()
    private lazy var tipBox: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.surfaceBase.cgColor
        v.layer?.cornerRadius = 0
        v.isHidden = true
        return v
    }()

    private func showTip(_ button: ToolButton) {
        guard let tip = button.tip, let content = window.contentView else { return }
        tipText.stringValue = tip
        tipText.sizeToFit()
        let ts = tipText.frame.size
        let padX: CGFloat = 9, padY: CGFloat = 5
        let w = ts.width + padX * 2, h = ts.height + padY * 2
        let bf = content.convert(button.bounds, from: button)
        var x = bf.midX - w / 2
        x = max(6, min(x, content.bounds.width - w - 6))
        content.addSubview(tipBox, positioned: .above, relativeTo: nil)
        tipBox.frame = NSRect(x: x, y: bf.maxY + 6, width: w, height: h)
        tipText.frame = NSRect(x: padX, y: padY, width: ts.width, height: ts.height)
        tipBox.isHidden = false
    }
    private func hideTip() { tipBox.isHidden = true }

    @objc private func toolPressed(_ sender: ToolButton) {
        if let t = toolButtons.first(where: { $0.value === sender })?.key { selectTool(t) }
    }
    private func selectTool(_ t: Tool) {
        if t != .crop, canvas.pendingCrop != nil {
            canvas.pendingCrop = nil; canvas.needsDisplay = true; hideCropConfirm()
        }
        canvas.tool = t
        for (tool, b) in toolButtons { b.selectedState = (tool == t) }
        if t == .ruler { flashMessage("Press ↑↓ or ←→, then move to measure") }
    }

    @objc private func swatchPressed(_ sender: ToolButton) { selectSwatch(sender.tag) }
    private func selectSwatch(_ index: Int) {
        guard index < palette.count else { return }
        canvas.style.color = palette[index].0
        canvas.recolorSelection(palette[index].0)
        currentSwatch = index
        for (i, b) in swatchButtons.enumerated() { b.selectedState = (i == index) }
        plusButton?.selectedState = false
    }
    private func deselectSwatches() { swatchButtons.forEach { $0.selectedState = false } }

    /// Cycle the stroke width Thin → Medium → Thick, updating the tile's bar preview and
    /// applying it live to the selected/active mark.
    @objc private func widthPressed() {
        currentWidth = (currentWidth + 1) % widths.count
        canvas.restrokeSelection(widths[currentWidth])
        widthButton?.tip = "Stroke width: \(widthLabels[currentWidth]) — click to cycle"
        widthButton?.activeLineWeightIndex = currentWidth
    }

    @objc private func counterPressed() {
        if canvas.tool == .counter { formatPressed() }
        else { selectTool(.counter) }
    }
    @objc private func formatPressed() {
        formatPicker = CounterFormatPicker(
            current: canvas.counterFormat,
            onPick: { [weak self] f in
                self?.canvas.counterFormat = f
                self?.selectTool(.counter)
            },
            onClose: { [weak self] in
                self?.window.makeKeyAndOrderFront(nil)
                self?.window.makeFirstResponder(self?.canvas)
            })
        let card = counterFormatButton?.superview?.superview
        var avoid: CGRect?
        if let v = card, v.window != nil { avoid = window.convertToScreen(v.convert(v.bounds, to: nil)) }
        formatPicker?.show(near: counterFormatButton ?? canvas, avoiding: avoid)
    }

    @objc private func emojiPressed() {
        if emojiPicker == nil {
            emojiPicker = EmojiPickerPanel(
                onPick: { [weak self] e in
                    self?.canvas.currentEmoji = e
                    self?.emojiButton?.overrideText = e
                    self?.selectTool(.emoji)
                },
                onClose: { [weak self] in
                    self?.window.makeKeyAndOrderFront(nil)
                    self?.window.makeFirstResponder(self?.canvas)
                })
        }
        emojiPicker?.show(near: emojiButton ?? canvas, current: canvas.currentEmoji)
    }

    @objc private func customColorPressed() {
        if colorPicker == nil {
            colorPicker = ColorPickerPanel(
                onPick: { [weak self] c in
                    self?.canvas.style.color = c
                    self?.canvas.recolorSelection(c)
                    self?.currentSwatch = nil
                    self?.deselectSwatches()
                    self?.plusButton?.selectedState = true
                },
                onClose: { [weak self] in
                    self?.window.makeKeyAndOrderFront(nil)
                    self?.window.makeFirstResponder(self?.canvas)
                })
        }
        guard let picker = colorPicker, let plus = plusButton else { return }
        picker.show(near: plus, initial: canvas.style.color)
    }

    private static let shortcutMap: [String: Tool] = [
        "p": .pencil, "h": .marker, "l": .line, "a": .arrow, "r": .rect, "o": .ellipse,
        "g": .triangle, "d": .diamond, "y": .star, "u": .roundedRect, "k": .checkmark,
        "5": .pentagon, "6": .hexagon, "8": .octagon,
        "t": .text, "c": .counter, "b": .blur, "s": .spotlight, "i": .eyedropper, "e": .eraser,
        "z": .zoom, "v": .select,
    ]
    private func handleShortcut(_ key: String) {
        if let t = EditorWindowController.shortcutMap[key] { selectTool(t) }
    }

    @objc private func undoPressed() { canvas.undo() }
    @objc private func redoPressed() { canvas.redo() }

    @objc private func copyPressed() {
        guard let rep = exportRep() else { return }
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        close()
    }
    @objc private func savePressed() {
        guard let rep = exportRep() else { return }
        if Settings.shared.autoCopyOnSave {
            let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            img.addRepresentation(rep)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
        }
        let fellBack = !Settings.shared.saveDirectoryAvailable
        writeCapture(rep, to: Settings.shared.fileURL(), fellBack: fellBack) { [weak self] in self?.close() }
    }

    /// Encode and write `rep` off the main thread, then act on the result:
    /// - success: if the save folder was unavailable and we fell back to the Desktop,
    ///   tell the user where it went; then run `onSuccess` (closing the editor).
    /// - failure: keep the window open and show a brand alert, so a full disk / encode
    ///   failure can't silently throw the capture away.
    private func writeCapture(_ rep: NSBitmapImageRep, to url: URL,
                              fellBack: Bool = false, onSuccess: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Settings.shared.encode(rep).map { (try? $0.write(to: url)) != nil } ?? false
            DispatchQueue.main.async {
                if ok {
                    if fellBack {
                        _ = BrandAlert(title: "Saved to the Desktop",
                                       message: "Your save folder wasn't available, so this went to the Desktop. Update it in Settings → Output.",
                                       titles: ["OK"], primary: 0, cancel: 0,
                                       icon: "folder.badge.questionmark").runModal()
                    }
                    onSuccess()
                } else {
                    _ = BrandAlert(title: "Couldn't save the capture",
                                   message: "Saving failed. Your capture is still open — try Save As.",
                                   titles: ["OK"], primary: 0, cancel: 0,
                                   icon: "exclamationmark.triangle").runModal()
                }
            }
        }
    }
    /// Save with a chooser: pick the location/name via an NSSavePanel (shown as a
    /// sheet so it surfaces above the screen-saver-level editor), in the configured
    /// image format. Closes on save, stays open on cancel.
    @objc private func saveAsPressed() {
        guard let rep = exportRep() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Settings.shared.format.utType]
        panel.nameFieldStringValue = Settings.shared.fileURL().lastPathComponent
        panel.directoryURL = Settings.shared.resolvedSaveDirectory()
        panel.message = "Save the capture"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url else {
                self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.canvas); return
            }
            if Settings.shared.autoCopyOnSave {
                let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
                img.addRepresentation(rep)
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
            }
            self.writeCapture(rep, to: url) { self.close() }
        }
    }
    @objc private func copyTextPressed() {
        selectTool(.ocr)
        flashMessage("Drag over text or a QR code to copy it")
    }

    /// Recognize text (or decode a QR / barcode) in the dragged region and copy it
    /// to the clipboard. Async (Vision); the editor stays open so several regions
    /// can be grabbed in turn.
    private func recognizeAndCopy(_ cg: CGImage) {
        TextRecognizer.recognize(cg) { [weak self] result in
            switch result {
            case .none:
                self?.flashMessage("No text or code found")
            case let .code(payload):
                self?.copyToClipboard(payload); self?.flashMessage("QR code copied")
            case let .text(text):
                self?.copyToClipboard(text); self?.flashMessage("Text copied")
            }
        }
    }
    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// A brief brand-styled toast near the top of the overlay (auto-fades).
    private func flashMessage(_ text: String) {
        guard let content = window.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.font = Theme.font(13, .semibold); label.textColor = .white
        let ts = label.intrinsicContentSize
        let pad: CGFloat = 12
        let box = NSView(frame: NSRect(x: (content.bounds.width - ts.width - pad * 2) / 2,
                                       y: content.bounds.height - 90,
                                       width: ts.width + pad * 2, height: ts.height + pad))
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.accentPurple.withAlphaComponent(0.95).cgColor
        box.layer?.cornerRadius = 8
        label.frame = NSRect(x: pad, y: pad / 2, width: ts.width, height: ts.height)
        box.addSubview(label)
        content.addSubview(box)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; box.animator().alphaValue = 0 },
                                                 completionHandler: { box.removeFromSuperview() })
        }
    }
    @objc private func pinPressed() {
        guard let rep = exportRep() else { return }
        var viewRect = canvas.convert(canvas.bounds, to: nil)
        if !currentBackground.isNone {
            let pad = Background.padding(maxDim: max(canvas.frame.width, canvas.frame.height))
            viewRect = viewRect.insetBy(dx: -pad, dy: -pad)
        }
        _ = PinnedWindowController(rep: rep, screenRect: window.convertToScreen(viewRect))
        close()
    }

    /// Open a file picker for an image to overlay. Runs modal so the panel sits
    /// above the screen-saver-level editor window; paste (⌘V) / drag-drop are the
    /// other two entry points (handled in `CanvasView`).
    @objc private func overlayPressed() {
        selectTool(.overlay)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to overlay"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            if resp == .OK, let url = panel.url, let img = NSImage(contentsOf: url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.canvas.insertOverlay(cg)
            }
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.canvas)
        }
    }

    /// Paste an image from the clipboard as an overlay (⌘V in the canvas).
    private func pasteOverlay() {
        // Image wins when present; otherwise fall back to pasting clipboard text as a
        // text box (⌘V is shared between the two).
        guard let cg = CanvasView.cgImage(from: .general) else {
            if let s = NSPasteboard.general.string(forType: .string),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                canvas.insertTextBox(s)
            } else {
                flashMessage("No image or text on the clipboard")
            }
            return
        }
        selectTool(.overlay)
        canvas.insertOverlay(cg)
    }

    /// Export a 2-frame looping GIF: the capture without overlays, then with them,
    /// both wrapped in the current background. Writes to the configured save folder.
    @objc private func beforeAfterPressed() {
        guard canvas.hasOverlays else { flashMessage("Add an overlay image first"); return }
        guard let beforeRep = canvas.flatten(includingOverlays: false),
              let afterRep = canvas.flatten(includingOverlays: true),
              let before = currentBackground.compose(beforeRep)?.cgImage,
              let after = currentBackground.compose(afterRep)?.cgImage else {
            flashMessage("Couldn't build animation"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = Settings.shared.fileURL(ext: "gif").lastPathComponent
        panel.directoryURL = Settings.shared.resolvedSaveDirectory()
        panel.message = "Save the before/after animation"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            if resp == .OK, let url = panel.url {
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = AnimatedGIF.write(frames: [before, after], frameDuration: 1.2, to: url)
                    DispatchQueue.main.async { self.flashMessage(ok ? "Saved before/after GIF" : "Couldn't save GIF") }
                }
            }
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.canvas)
        }
    }

    /// Show (or move) the opacity slider above the selected overlay; `nil` hides it.
    private func showOpacity(for overlay: ImageOverlayAnnotation?) {
        guard let overlay, let content = window.contentView else {
            opacityCard?.removeFromSuperview(); opacityCard = nil; return
        }
        selectTool(.overlay)
        let card = opacityCard ?? buildOpacityCard()
        opacityCard = card
        opacitySlider?.doubleValue = Double(overlay.opacity)
        if card.superview == nil { content.addSubview(card) }
        let vx = overlay.rect.midX * canvas.displayScale + canvas.frame.minX
        let vy = overlay.rect.maxY * canvas.displayScale + canvas.frame.minY
        var x = vx - card.frame.width / 2, y = vy + 12
        x = min(max(8, x), content.bounds.width - card.frame.width - 8)
        y = min(max(8, y), content.bounds.height - card.frame.height - 8)
        card.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func buildOpacityCard() -> NSView {
        let w: CGFloat = 200, h: CGFloat = 56
        let card = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.surfaceRaised.withAlphaComponent(0.97).cgColor
        card.layer?.cornerRadius = 0
        let label = NSTextField(labelWithString: "")
        Theme.styleEyebrow(label, "Opacity")
        label.frame = NSRect(x: 14, y: h - 23, width: w - 28, height: 14)
        card.addSubview(label)
        let slider = BrandSlider(value: 1, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(opacityChanged(_:)))
        slider.frame = NSRect(x: 14, y: 10, width: w - 28, height: 20)
        card.addSubview(slider)
        opacitySlider = slider
        return card
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        canvas.setSelectedOverlayOpacity(CGFloat(sender.doubleValue))
    }


    /// The flattened capture wrapped in the selected background (or just the
    /// flattened capture when `.none`). Used by Copy / Save / Pin (not OCR).
    private func exportRep() -> NSBitmapImageRep? {
        guard let inner = canvas.flatten() else { return nil }
        return currentBackground.compose(inner)
    }

    @objc private func backgroundPressed(_ sender: ToolButton) {
        currentBackground = Background.presets[sender.tag]
        relayout(canvasFrame: canvas.frame)
    }

    @objc private func backgroundCustomPressed() {
        if bgColorPicker == nil {
            bgColorPicker = ColorPickerPanel(
                onPick: { [weak self] c in
                    guard let self else { return }
                    let wasFramed = !self.currentBackground.isNone
                    self.currentBackground = .solid(c)
                    if wasFramed {
                        self.applyBackgroundPreview()
                        self.bgButtons.forEach { $0.selectedState = false }
                        self.bgPlusButton?.selectedState = true
                    } else {
                        self.relayout(canvasFrame: self.canvas.frame)
                    }
                },
                onClose: { [weak self] in
                    self?.window.makeKeyAndOrderFront(nil)
                    self?.window.makeFirstResponder(self?.canvas)
                })
        }
        guard let picker = bgColorPicker, let plus = bgPlusButton else { return }
        picker.show(near: plus, initial: currentBackground.solidColor ?? .white)
    }

    /// Position the live background preview behind the canvas and round the
    /// canvas corners to match the baked export (shadow lives on the bgView,
    /// since a layer can't both clip rounded content and cast an outer shadow).
    private func applyBackgroundPreview() {
        guard let content = window.contentView else { return }
        if currentBackground.isNone {
            bgView?.removeFromSuperview(); bgView = nil
            canvas.layer?.cornerRadius = 0
            canvas.layer?.masksToBounds = false
            ring.isHidden = false
            return
        }
        let fr = canvas.frame
        let pad = Background.padding(maxDim: max(fr.width, fr.height))
        let radius = Background.cornerRadius(minDim: min(fr.width, fr.height), pad: pad)
        let v = bgView ?? BackgroundView(frame: .zero)
        v.wantsLayer = true
        v.background = currentBackground
        v.frame = fr.insetBy(dx: -pad, dy: -pad)
        v.innerRect = CGRect(x: pad, y: pad, width: fr.width, height: fr.height)
        v.cornerRadius = radius
        v.shadowPad = pad
        v.needsDisplay = true
        if v.superview == nil { content.addSubview(v, positioned: .below, relativeTo: canvas) }
        bgView = v
        canvas.layer?.cornerRadius = radius
        canvas.layer?.masksToBounds = true
        ring.isHidden = true
    }
    @objc private func closePressed() { attemptClose() }

    private func attemptClose() {
        guard Settings.shared.confirmDiscard else { close(); return }
        let choice = BrandAlert(title: "Discard capture?",
                                message: "Your screenshot and edits will be deleted permanently.",
                                titles: ["Keep Editing", "Discard"],
                                primary: 0, cancel: 0,
                                icon: "trash.fill", destructive: [1]).runModal()
        if choice == 1 { close() }
    }
    private func close() { colorPicker?.close(); bgColorPicker?.close(); window.close() }

    @objc private func rotateRightPressed() { rotate(left: false) }

    private func rotate(left: Bool) {
        guard let newImg = canvas.rotatedImage(left: left) else { return }
        let W = canvas.image.size.width, H = canvas.image.size.height
        let remap: (CGPoint) -> CGPoint = left
            ? { CGPoint(x: H - $0.y, y: $0.x) }
            : { CGPoint(x: $0.y, y: W - $0.x) }
        let scale = canvas.displayScale
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        cancelCrop()
        canvas.applyTransform(newImage: newImg, remap: remap)
        let newSize = NSSize(width: newImg.size.width * scale, height: newImg.size.height * scale)
        relayout(canvasFrame: NSRect(x: center.x - newSize.width / 2,
                                     y: center.y - newSize.height / 2,
                                     width: newSize.width, height: newSize.height))
    }

    @objc private func flipHorizontalPressed() { flip(horizontal: true) }

    private func flip(horizontal: Bool) {
        guard let newImg = canvas.flippedImage(horizontal: horizontal) else { return }
        let W = canvas.image.size.width, H = canvas.image.size.height
        let remap: (CGPoint) -> CGPoint = horizontal
            ? { CGPoint(x: W - $0.x, y: $0.y) }
            : { CGPoint(x: $0.x, y: H - $0.y) }
        let scale = canvas.displayScale
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        cancelCrop()
        canvas.applyTransform(newImage: newImg, remap: remap)
        let newSize = NSSize(width: newImg.size.width * scale, height: newImg.size.height * scale)
        relayout(canvasFrame: NSRect(x: center.x - newSize.width / 2,
                                     y: center.y - newSize.height / 2,
                                     width: newSize.width, height: newSize.height))
    }

    @objc private func applyCropPressed()  { applyCrop() }
    @objc private func cancelCropPressed() { cancelCrop() }

    private func applyCrop() {
        guard let pc = canvas.pendingCrop, pc.width >= 5, pc.height >= 5,
              let newImg = canvas.croppedImage(rect: pc) else { cancelCrop(); return }
        let scale = canvas.displayScale
        let oldOrigin = canvas.frame.origin
        canvas.applyTransform(newImage: newImg) { CGPoint(x: $0.x - pc.minX, y: $0.y - pc.minY) }
        hideCropConfirm()
        relayout(canvasFrame: NSRect(x: oldOrigin.x + pc.minX * scale,
                                     y: oldOrigin.y + pc.minY * scale,
                                     width: pc.width * scale, height: pc.height * scale))
        selectTool(.pencil)
    }

    private func cancelCrop() {
        canvas.pendingCrop = nil
        canvas.needsDisplay = true
        hideCropConfirm()
    }

    /// Move the canvas + ring to a new frame and rebuild the tool clusters
    /// around it (after the image changed size). Selection highlights restored.
    private func relayout(canvasFrame: NSRect) {
        guard let content = window.contentView else { return }
        let pad = currentBackground.isNone ? 0 : Background.padding(maxDim: max(canvasFrame.width, canvasFrame.height))
        var fr = canvasFrame
        fr.origin.x = min(max(8 + pad, fr.origin.x), max(8 + pad, content.bounds.width - fr.width - 8 - pad))
        fr.origin.y = min(max(8 + pad, fr.origin.y), max(8 + pad, content.bounds.height - fr.height - 8 - pad))
        // Keep the canvas origin on the device-pixel grid — a fractional origin resamples
        // the whole canvas and softens it on 1× external displays (the padding clamp above
        // can otherwise reintroduce a sub-pixel offset).
        fr.origin.x.round()
        fr.origin.y.round()
        canvas.frame = fr
        ring.frame = fr.insetBy(dx: -1, dy: -1)
        applyBackgroundPreview()

        clusterViews.forEach { $0.removeFromSuperview() }
        clusterViews = []
        toolButtons = [:]; swatchButtons = []; bgButtons = []; plusButton = nil
        let prevTool = canvas.tool
        clusterViews = buildClusters(around: fr, in: content)
        animateIn(clusterViews)

        selectTool(prevTool)
        for (i, b) in swatchButtons.enumerated() { b.selectedState = (i == currentSwatch) }
        plusButton?.selectedState = (currentSwatch == nil)
        placeResizeHandle(in: content)
    }

    /// The center point of an edge's knob for a given canvas frame.
    private func resizeHandleCenter(_ edge: ResizeHandle.Edge, in f: NSRect) -> CGPoint {
        switch edge {
        case .topLeft:     return CGPoint(x: f.minX, y: f.maxY)
        case .top:         return CGPoint(x: f.midX, y: f.maxY)
        case .topRight:    return CGPoint(x: f.maxX, y: f.maxY)
        case .right:       return CGPoint(x: f.maxX, y: f.midY)
        case .bottomRight: return CGPoint(x: f.maxX, y: f.minY)
        case .bottom:      return CGPoint(x: f.midX, y: f.minY)
        case .bottomLeft:  return CGPoint(x: f.minX, y: f.minY)
        case .left:        return CGPoint(x: f.minX, y: f.midY)
        }
    }

    /// Put (or move) the eight resize knobs around the canvas — corners resize both
    /// axes, edge midpoints a single axis.
    private func placeResizeHandle(in content: NSView) {
        let s: CGFloat = 18
        if resizeHandles.isEmpty {
            for edge in ResizeHandle.Edge.allCases {
                let h = ResizeHandle(edge: edge)
                h.onBegin = { [weak self] in self?.resizeBegan(edge) }
                h.onDrag = { [weak self] d in self?.resizeDragged(d) }
                h.onEnd = { [weak self] in self?.resizeEnded() }
                resizeHandles.append(h)
            }
        }
        for h in resizeHandles {
            let c = resizeHandleCenter(h.edge, in: canvas.frame)
            h.frame = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            content.addSubview(h)
        }
    }

    private func repositionResizeHandles(around f: NSRect) {
        let s: CGFloat = 18
        for h in resizeHandles {
            let c = resizeHandleCenter(h.edge, in: f)
            h.setFrameOrigin(NSPoint(x: c.x - s / 2, y: c.y - s / 2))
        }
    }

    private func resizeBegan(_ edge: ResizeHandle.Edge) {
        guard let content = window.contentView else { return }
        activeResizeEdge = edge
        resizeBaseFrame = canvas.frame
        let p = NSView(frame: canvas.frame)
        p.wantsLayer = true
        p.layer?.borderColor = Theme.lavender.cgColor
        p.layer?.borderWidth = 1.5
        p.layer?.backgroundColor = NSColor.clear.cgColor
        // Insert the preview *below* the handles — re-adding the handles here would cancel
        // the in-progress drag tracking on the grabbed handle (its mouseDragged then never
        // fires, so the crop never registers).
        content.addSubview(p, positioned: .below, relativeTo: resizeHandles.first)
        resizePreview = p
    }

    /// Move the grabbed edge(s) by the drag delta, holding the opposite edge(s) fixed.
    /// Clamped to the display bounds so the region can be trimmed inward *or* grown outward
    /// (up to the screen edge); growth re-grabs the display in `resizeEnded`.
    private func resizeDragged(_ d: CGSize) {
        guard let p = resizePreview, let content = window.contentView,
              resizeBaseFrame.width > 0, resizeBaseFrame.height > 0 else { return }
        let b = resizeBaseFrame, edge = activeResizeEdge, minSide: CGFloat = 40
        let limit = content.bounds
        var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
        switch edge {
        case .topLeft, .left, .bottomLeft:    minX = min(max(b.minX + d.width, limit.minX), maxX - minSide)
        case .topRight, .right, .bottomRight: maxX = max(min(b.maxX + d.width, limit.maxX), minX + minSide)
        default: break
        }
        switch edge {
        case .topLeft, .top, .topRight:          maxY = max(min(b.maxY + d.height, limit.maxY), minY + minSide)
        case .bottomLeft, .bottom, .bottomRight: minY = min(max(b.minY + d.height, limit.minY), maxY - minSide)
        default: break
        }
        p.frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        repositionResizeHandles(around: p.frame)
    }

    /// Commit the new region by re-grabbing that rectangle from the display (excluding this
    /// editor window so it sees the real screen behind) — so the region can be enlarged to
    /// show more, not just cropped. A drag that didn't move the region is a no-op.
    private func resizeEnded() {
        guard let p = resizePreview, resizeBaseFrame.width > 0, resizeBaseFrame.height > 0 else { return }
        let b = resizeBaseFrame, ds = canvas.displayScale, pf = p.frame
        p.removeFromSuperview(); resizePreview = nil
        // Unchanged region → nothing to do.
        if abs(pf.minX - b.minX) < 1, abs(pf.minY - b.minY) < 1,
           abs(pf.width - b.width) < 1, abs(pf.height - b.height) < 1 { relayout(canvasFrame: b); return }
        guard pf.width >= 20, pf.height >= 20, let displayID = captureScreen.displayID, !reGrabbing else {
            relayout(canvasFrame: b); return
        }
        // Preview frame (content coords) → display-local sourceRect (top-left origin).
        let source = CGRect(x: pf.minX, y: captureScreen.frame.height - pf.maxY,
                            width: pf.width, height: pf.height)
        // Annotation shift (image pixels): the new image origin (region bottom-left) moved.
        let dxPix = (b.minX - pf.minX) / ds, dyPix = (b.minY - pf.minY) / ds
        let exclude = [CGWindowID(window.windowNumber)]
        reGrabbing = true
        Task {
            let result = await ScreenshotController.recaptureRegion(displayID: displayID, sourceRect: source, excluding: exclude)
            await MainActor.run {
                self.reGrabbing = false
                guard let result else { self.relayout(canvasFrame: b); self.flashMessage("Couldn't adjust the region"); return }
                let newImage = ScreenshotController.nsImage(from: result.cg)
                self.canvas.applyTransform(newImage: newImage) { CGPoint(x: $0.x + dxPix, y: $0.y + dyPix) }
                self.relayout(canvasFrame: NSRect(x: pf.minX.rounded(), y: pf.minY.rounded(),
                                                  width: pf.width.rounded(), height: pf.height.rounded()))
            }
        }
    }

    private func showCropConfirm() {
        guard let pc = canvas.pendingCrop, let content = window.contentView else { return }
        hideCropConfirm()
        let scale = canvas.displayScale, f = canvas.frame
        let cr = NSRect(x: f.minX + pc.minX * scale, y: f.minY + pc.minY * scale,
                        width: pc.width * scale, height: pc.height * scale)
        let r: CGFloat = 16
        let sz = ToolButton.size(radius: r)
        let gap: CGFloat = 6
        let totalW = sz.width * 2 + gap
        let x = min(max(8, cr.midX - totalW / 2), content.bounds.width - totalW - 8)
        var y = cr.maxY + gap
        if y + sz.height > content.bounds.height - 8 { y = cr.minY - gap - sz.height }
        y = max(8, y)

        let ok = ToolButton(style: .tool("checkmark"), radius: r, target: self, action: #selector(applyCropPressed))
        ok.tip = "Apply crop  (↵)"; wireHover(ok)
        let cancel = ToolButton(style: .tool("xmark"), radius: r, target: self, action: #selector(cancelCropPressed))
        cancel.tip = "Cancel crop"; wireHover(cancel)
        content.addSubview(ok); content.addSubview(cancel)
        ok.frame = NSRect(x: x, y: y, width: sz.width, height: sz.height)
        cancel.frame = NSRect(x: x + sz.width + gap, y: y, width: sz.width, height: sz.height)
        cropButtons = [ok, cancel]
    }

    private func hideCropConfirm() {
        cropButtons.forEach { $0.removeFromSuperview() }
        cropButtons = []
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        EditorWindowController.open.removeAll { $0 === self }
    }
}

