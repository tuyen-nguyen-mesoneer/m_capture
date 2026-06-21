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
    var innerRect: CGRect = .zero      // image area, in this view's coordinates
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

/// A draggable knob at the capture's bottom-right corner. Dragging it resizes
/// the picture (aspect-locked); the controller previews and commits the resample.
private final class ResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?   // horizontal drag delta (screen points) since begin
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(Theme.accentPurple.cgColor); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: r)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5)
        for off in [CGFloat(5), 9] {
            ctx.move(to: CGPoint(x: bounds.maxX - off, y: bounds.minY + 5))
            ctx.addLine(to: CGPoint(x: bounds.maxX - 5, y: bounds.minY + off))
        }
        ctx.strokePath()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with e: NSEvent) {
        startX = NSEvent.mouseLocation.x
        NSCursor.closedHand.push()
        onBegin?()
    }
    override func mouseDragged(with e: NSEvent) { onDrag?(NSEvent.mouseLocation.x - startX) }
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

    private let window: KeyableWindow
    private let canvas: CanvasView
    private var toolButtons: [Tool: ToolButton] = [:]
    private var swatchButtons: [ToolButton] = []
    private weak var plusButton: ToolButton?
    private weak var counterFormatButton: ToolButton?
    private weak var emojiButton: ToolButton?
    private var colorPicker: ColorPickerPanel?
    private var emojiPicker: EmojiPickerPanel?
    private var formatPicker: CounterFormatPicker?

    // Re-laid-out on rotate/crop, so they're tracked for teardown + restore.
    private var clusterViews: [NSView] = []
    private var ring: NSView!
    private var cropButtons: [NSView] = []
    private var currentSwatch: Int? = 0     // nil = custom color

    // Share-ready background frame (from Settings, None by default); previewed behind the canvas.
    private var currentBackground: Background = Settings.shared.defaultBackground
    private var bgButtons: [ToolButton] = []

    // Corner resize (resample) handle + live preview.
    private var resizeHandle: ResizeHandle?
    private var resizePreview: NSView?
    private var resizeBaseFrame: NSRect = .zero
    private weak var bgPlusButton: ToolButton?
    private var bgColorPicker: ColorPickerPanel?
    private var bgView: BackgroundView?

    // Opacity slider for the selected overlay image (floats above the overlay).
    private var opacityCard: NSView?
    private weak var opacitySlider: NSSlider?

    // Ten popular annotation colors: a full spectrum plus black & white.
    private let palette: [(NSColor, String)] = [
        (Theme.rgb(0xE5, 0x3E, 0x3E), "Red"),
        (Theme.rgb(0xF9, 0x73, 0x16), "Orange"),
        (Theme.rgb(0xFA, 0xCC, 0x15), "Yellow"),
        (Theme.rgb(0x22, 0xC5, 0x5E), "Green"),
        (Theme.rgb(0x14, 0xB8, 0xA6), "Teal"),
        (Theme.rgb(0x3B, 0x82, 0xF6), "Blue"),
        (Theme.rgb(0xA8, 0x55, 0xF7), "Purple"),
        (Theme.rgb(0xEC, 0x48, 0x99), "Pink"),
        (.white, "White"),
        (.black, "Black"),
    ]

    init(image: NSImage, selectionRect: CGRect, screen: NSScreen) {
        let scale = image.size.width > 0 ? selectionRect.width / image.size.width : 1
        canvas = CanvasView(image: image, displayScale: scale)
        window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
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
        canvas.onCancel = { [weak self] in self?.close() }
        canvas.onCropBegin = { [weak self] in self?.hideCropConfirm() }
        canvas.onCropReady = { [weak self] in self?.showCropConfirm() }
        canvas.onCropConfirm = { [weak self] in self?.applyCrop() }
        canvas.onOCR = { [weak self] cg in self?.recognizeAndCopy(cg) }
        canvas.onOverlaySelected = { [weak self] a in self?.showOpacity(for: a) }
        canvas.onPaste = { [weak self] in self?.pasteOverlay() }
        selectTool(.pencil)
        selectSwatch(0)
        canvas.style.lineWidth = 4   // stroke width is fixed at medium; no size control

        EditorWindowController.open.append(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        window.delegate = self
    }

    // MARK: Clusters

    private func buildClusters(around sel: NSRect, in content: NSView) -> [NSView] {
        // Lay the tools out around the framed graphic (image + background pad) with
        // a uniform 8px margin off the frame, with or without a background. The
        // scatter gap below is 16, so offsetting the reference by (8 - bgPad) lands
        // the cards 8px from the frame (16 - 8 with no background; bgPad + 8 with one).
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

        // Overlay-image tile: opens a file picker; paste (⌘V) / drop a file also
        // insert overlays. Tracked in `toolButtons` so it highlights when selected.
        let overlayBtn = ToolButton(style: .tool("photo"), target: self, action: #selector(overlayPressed))
        overlayBtn.tip = "Overlay image — paste (⌘V), drop a file, or click to choose"
        wireHover(overlayBtn); toolButtons[.overlay] = overlayBtn

        // Text tiles fold into the Markup group below. The counter and emoji
        // tiles need bespoke wiring, so build them up front.
        // One counter icon: click to place numbered badges, click again (while
        // active) to open the format popover (numbers / letters / roman).
        let counterBtn = ToolButton(style: .counterGlyph, target: self, action: #selector(counterPressed))
        counterBtn.tip = "Counter — place numbered badges (click again to change format)  (C)"
        wireHover(counterBtn); toolButtons[.counter] = counterBtn; counterFormatButton = counterBtn
        let emojiBtn = ToolButton(style: .text(canvas.currentEmoji), target: self, action: #selector(emojiPressed))
        emojiBtn.tip = "Emoji — stamp an emoji (click to choose)"; wireHover(emojiBtn)
        emojiButton = emojiBtn; toolButtons[.emoji] = emojiBtn

        // MARKUP — ordered common→niche: everyday strokes + text (row 1), redaction
        // + stamps (row 2), then the advanced/utility tools (row 3).
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
        // SHAPES — workhorse first: strokes (arrow, line) then enclosures (row 1),
        // shape fills (row 2), decorative polygons (row 3).
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

        // COLOR — eyedropper, swatches and the custom-color picker. Stroke width
        // is fixed at medium (set once in init); there is no size control.
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
        let color = makeCluster("Color", colorTiles, perRow: 4, radius: colorR)

        // ACTIONS — ordered by row: transform (row 1), history + non-closing
        // outputs (row 2), then the four ways to finish (row 3, exits last).
        let actions = makeCluster("Action", [
            toolButton(.crop, "crop", "Crop — drag a region, then ↵ or ✓"),
            actionButton("rotate.left", "Rotate left 90°", key: "", mods: [], #selector(rotateLeftPressed)),
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

        // BACKGROUND — a share-ready frame (None + presets + a custom color).
        // Same tile size as the Color cluster.
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

        // Scatter around the image only if it's big enough to host the clusters
        // without overlap; otherwise gather them into one floating panel.
        let cp: CGFloat = 9  // card padding (each side)
        // Markup (left) now carries the text tools, so it stands alone in the left
        // column; Shapes takes the right column the Text card used to occupy.
        let leftW = draw.frame.width + 2 * cp
        let leftH = draw.frame.height + 2 * cp
        let rightW = shapes.frame.width + 2 * cp
        let rightH = shapes.frame.height + 2 * cp
        let rowH = [color.frame.height, background.frame.height, actions.frame.height].max()! + 2 * cp
        // Use both vertical strips: when the top *and* bottom each have room, the
        // appearance pair (Color, Background) goes above and Actions below, so the
        // selection is framed on all four sides. If only one side fits, all three
        // stack there; if neither, we fall back to the gathered group.
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
    /// brand-gradient fill, a crisp light edge, and a soft drop shadow to lift
    /// it off the backdrop (the old translucent-white fill vanished on dark UIs).
    private func cardFit(_ inner: NSView) -> NSView {
        let pad: CGFloat = 8, radius: CGFloat = 12
        let size = NSSize(width: inner.frame.width + pad * 2, height: inner.frame.height + pad * 2)
        let c = DraggablePanel(frame: NSRect(origin: .zero, size: size))
        c.wantsLayer = true
        guard let layer = c.layer else { return c }
        layer.cornerRadius = radius
        layer.masksToBounds = false           // let the shadow render
        layer.borderWidth = 1
        layer.borderColor = Theme.cardStroke.cgColor
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
        let radius: CGFloat = 12
        layer.cornerRadius = radius
        layer.masksToBounds = false           // let the shadow render
        layer.borderWidth = 1
        layer.borderColor = Theme.cardStroke.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: -5)
        Theme.applyPanelGradient(to: c, cornerRadius: radius)
        // Top-align the cluster (centered horizontally) so every card's caption
        // sits at the same height regardless of how many tool rows it has.
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
        let pad: CGFloat = 10, hgap: CGFloat = 8, vgap: CGFloat = 8
        // Every card uses the same size: the largest cluster + uniform padding.
        let innerPad: CGFloat = 7
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

        // Transparent container — draggable as one unit, but no background slab.
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
        let g: CGFloat = 16, m: CGFloat = 8   // gap from selection, margin from screen edge
        let w = p.frame.width, h = p.frame.height
        let cx = min(max(m, sel.midX - w / 2), cs.width - w - m)   // h-centered on sel, clamped
        let cy = min(max(m, sel.midY - h / 2), cs.height - h - m)  // v-centered on sel, clamped

        // Each candidate: an origin + the leftover space on that side (slack).
        let candidates: [(CGPoint, CGFloat)] = [
            (CGPoint(x: cx, y: sel.minY - g - h),   sel.minY - g - h - m),               // below
            (CGPoint(x: cx, y: sel.maxY + g),       cs.height - (sel.maxY + g + h) - m),  // above
            (CGPoint(x: sel.minX - g - w, y: cy),   sel.minX - g - w - m),               // left
            (CGPoint(x: sel.maxX + g, y: cy),       cs.width - (sel.maxX + g + w) - m),   // right
        ]
        // Pick the side that fits with the most slack; if none fits, the roomiest.
        let best = candidates.max { $0.1 < $1.1 }!.0
        let fx = min(max(m, best.x), cs.width - w - m)
        let fy = min(max(m, best.y), cs.height - h - m)
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
        let side = ToolButton.size(radius: r).width          // square tile
        let hgap: CGFloat = 4, vgap: CGFloat = 4
        let stepX = side + hgap, rowVStep = side + vgap
        let rows = Int(ceil(Double(buttons.count) / Double(perRow)))

        let capH: CGFloat = 17, capToGrid: CGFloat = 22  // caption + divider + gap before icons
        let gridW = CGFloat(perRow - 1) * stepX + side
        let gridH = CGFloat(rows - 1) * rowVStep + side
        let totalH = capH + capToGrid + gridH

        // Group name. Widen the whole cluster if the caption is longer than the
        // tile grid (e.g. "Background" under small swatches) so it never truncates.
        let cap = groupLabel(name)
        cap.alignment = .center
        let contentW = max(gridW, ceil(cap.intrinsicContentSize.width) + 10)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: totalH))
        container.wantsLayer = true

        cap.frame = NSRect(x: 0, y: totalH - capH, width: contentW, height: capH)
        container.addSubview(cap)

        // Thin divider bar under the name to set it apart from the tools.
        let divider = NSView(frame: NSRect(x: contentW * 0.14, y: totalH - capH - 6,
                                           width: contentW * 0.72, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        container.addSubview(divider)

        // Square-tile grid. Each row is centered within the content width, so a
        // partial last row (e.g. Markup's tools) stays centered.
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
        Theme.styleEyebrow(l, title)   // brand eyebrow: UPPERCASE lavender, tracked
        // styleEyebrow sets attributedStringValue (no paragraph style), which makes
        // the field ignore `.alignment` and render left-aligned. Bake a centered
        // paragraph style into the attributed string so the caption sits centered.
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let s = NSMutableAttributedString(attributedString: l.attributedStringValue)
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        l.attributedStringValue = s
        l.alignment = .center
        // Slight shadow so it reads over the image too.
        let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.6)
        sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -1)
        l.shadow = sh
        return l
    }

    private func wireHover(_ b: ToolButton) {
        b.onEnter = { [weak self] btn in self?.showTip(btn) }
        b.onExit = { [weak self] in self?.hideTip() }
    }

    // MARK: Tooltip

    private lazy var tipText: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.font(11, .medium); l.textColor = Theme.ink
        return l
    }()
    private lazy var tipBox: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.surfaceBase.cgColor
        v.layer?.cornerRadius = 5
        v.layer?.borderWidth = 1
        v.layer?.borderColor = Theme.border.cgColor
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

    // MARK: Actions

    @objc private func toolPressed(_ sender: ToolButton) {
        if let t = toolButtons.first(where: { $0.value === sender })?.key { selectTool(t) }
    }
    private func selectTool(_ t: Tool) {
        if t != .crop, canvas.pendingCrop != nil {   // leaving crop discards an unconfirmed region
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
        currentSwatch = index
        for (i, b) in swatchButtons.enumerated() { b.selectedState = (i == index) }
        plusButton?.selectedState = false
    }
    private func deselectSwatches() { swatchButtons.forEach { $0.selectedState = false } }

    @objc private func counterPressed() {
        if canvas.tool == .counter { formatPressed() }
        else { selectTool(.counter) }
    }
    @objc private func formatPressed() {
        // Fresh each open so the current format is highlighted.
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
        // Anchor to the Text card (the counter button's enclosing card) so the
        // popover sits just above that card, aligned to it.
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
        // A custom brand-styled picker, opened ABOVE the editor (the system
        // NSColorPanel is hidden behind the screen-saver-level overlay).
        if colorPicker == nil {
            colorPicker = ColorPickerPanel(
                onPick: { [weak self] c in
                    self?.canvas.style.color = c
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
        "z": .zoom,
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
        let url = Settings.shared.fileURL()
        // Encode + write off the main thread so a large capture doesn't stall the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Settings.shared.encode(rep) else { return }
            try? data.write(to: url)
        }
        close()
    }
    /// Save with a chooser: pick the location/name via an NSSavePanel (shown as a
    /// sheet so it surfaces above the screen-saver-level editor), in the configured
    /// image format. Closes on save, stays open on cancel.
    @objc private func saveAsPressed() {
        guard let rep = exportRep() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Settings.shared.format.utType]
        panel.nameFieldStringValue = Settings.shared.fileURL().lastPathComponent
        panel.directoryURL = Settings.shared.saveDirectory
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
            DispatchQueue.global(qos: .userInitiated).async {
                if let data = Settings.shared.encode(rep) { try? data.write(to: url) }
            }
            self.close()
        }
    }
    @objc private func copyTextPressed() {
        // Enter OCR mode: drag over text or a QR code to recognize + copy it; editor stays open.
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
        // Place the pin where the capture sits on screen (expanded to include the
        // background frame, if any), then close the editor so the pin takes over.
        var viewRect = canvas.convert(canvas.bounds, to: nil)
        if !currentBackground.isNone {
            let pad = Background.padding(maxDim: max(canvas.frame.width, canvas.frame.height))
            viewRect = viewRect.insetBy(dx: -pad, dy: -pad)
        }
        _ = PinnedWindowController(rep: rep, screenRect: window.convertToScreen(viewRect))
        close()
    }

    // MARK: Overlay image

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
        // A sheet renders above the screen-saver-level editor window (a free-
        // floating NSOpenPanel gets stuck behind it); runs async, doesn't block.
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
        guard let cg = CanvasView.cgImage(from: .general) else {
            flashMessage("No image on the clipboard"); return
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
        // A sheet so the Save dialog renders above the screen-saver-level editor.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = Settings.shared.fileURL(ext: "gif").lastPathComponent
        panel.directoryURL = Settings.shared.saveDirectory
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
        selectTool(.overlay)   // keep the Markup tile highlighted (paste/drop bypass it)
        let card = opacityCard ?? buildOpacityCard()
        opacityCard = card
        opacitySlider?.doubleValue = Double(overlay.opacity)
        if card.superview == nil { content.addSubview(card) }
        // Center above the overlay's top edge, clamped inside the window.
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
        card.layer?.cornerRadius = Theme.radiusMedium
        card.layer?.borderColor = Theme.border.cgColor
        card.layer?.borderWidth = 1
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

    // MARK: Background frame

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
                        // Just a new fill color — update the live preview cheaply,
                        // no need to re-flow the tool clusters.
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
    @objc private func closePressed() { close() }
    private func close() { colorPicker?.close(); bgColorPicker?.close(); window.close() }

    // MARK: Transforms (rotate / crop)

    @objc private func rotateLeftPressed() { rotate(left: true) }
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
        // Keep the whole framed graphic (image + background padding) on-screen.
        let pad = currentBackground.isNone ? 0 : Background.padding(maxDim: max(canvasFrame.width, canvasFrame.height))
        var fr = canvasFrame
        fr.origin.x = min(max(8 + pad, fr.origin.x), max(8 + pad, content.bounds.width - fr.width - 8 - pad))
        fr.origin.y = min(max(8 + pad, fr.origin.y), max(8 + pad, content.bounds.height - fr.height - 8 - pad))
        canvas.frame = fr
        ring.frame = fr.insetBy(dx: -1, dy: -1)
        applyBackgroundPreview()

        clusterViews.forEach { $0.removeFromSuperview() }
        clusterViews = []
        toolButtons = [:]; swatchButtons = []; bgButtons = []; plusButton = nil
        let prevTool = canvas.tool
        // buildClusters expands around the background pad itself, so pass the bare frame.
        clusterViews = buildClusters(around: fr, in: content)
        animateIn(clusterViews)

        selectTool(prevTool)
        for (i, b) in swatchButtons.enumerated() { b.selectedState = (i == currentSwatch) }
        plusButton?.selectedState = (currentSwatch == nil)
        // Background selection is restored inline by buildClusters (by preset
        // name + the custom + button), so nothing more to do here.
        placeResizeHandle(in: content)
    }

    // MARK: Corner resize

    /// Put (or move) the resize knob at the canvas's bottom-right corner.
    private func placeResizeHandle(in content: NSView) {
        let s: CGFloat = 20
        let h: ResizeHandle
        if let existing = resizeHandle { h = existing } else {
            h = ResizeHandle(frame: .zero)
            h.onBegin = { [weak self] in self?.resizeBegan() }
            h.onDrag = { [weak self] dx in self?.resizeDragged(dx) }
            h.onEnd = { [weak self] in self?.resizeEnded() }
            resizeHandle = h
        }
        h.frame = NSRect(x: canvas.frame.maxX - s / 2, y: canvas.frame.minY - s / 2, width: s, height: s)
        content.addSubview(h)   // keep on top
    }

    private func resizeBegan() {
        guard let content = window.contentView else { return }
        resizeBaseFrame = canvas.frame
        let p = NSView(frame: canvas.frame)
        p.wantsLayer = true
        p.layer?.borderColor = Theme.lavender.cgColor
        p.layer?.borderWidth = 1.5
        p.layer?.backgroundColor = NSColor.clear.cgColor
        content.addSubview(p, positioned: .below, relativeTo: resizeHandle)
        resizePreview = p
    }

    private func resizeDragged(_ dx: CGFloat) {
        guard let p = resizePreview, let content = window.contentView, resizeBaseFrame.height > 0 else { return }
        let aspect = resizeBaseFrame.width / resizeBaseFrame.height
        let newW = min(max(40, resizeBaseFrame.width + dx), content.bounds.width - 16)
        let newH = newW / aspect
        p.frame = NSRect(x: resizeBaseFrame.minX, y: resizeBaseFrame.maxY - newH, width: newW, height: newH)
        let s = resizeHandle?.frame.size ?? NSSize(width: 20, height: 20)
        resizeHandle?.setFrameOrigin(NSPoint(x: p.frame.maxX - s.width / 2, y: p.frame.minY - s.height / 2))
    }

    private func resizeEnded() {
        guard let p = resizePreview, resizeBaseFrame.width > 0 else { return }
        let scale = p.frame.width / resizeBaseFrame.width
        p.removeFromSuperview(); resizePreview = nil
        let newFrame = NSRect(x: resizeBaseFrame.minX, y: resizeBaseFrame.maxY - resizeBaseFrame.height * scale,
                              width: resizeBaseFrame.width * scale, height: resizeBaseFrame.height * scale)
        canvas.bakeResample(scale: scale)
        relayout(canvasFrame: newFrame)
    }

    // MARK: Crop confirm control

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
        EditorWindowController.open.removeAll { $0 === self }
    }
}
