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
///
/// Every card moves on its own — the gathered layout only *looks* like one slab, and a
/// single grab hauling all five cards along read as a bug.
private final class DraggablePanel: NSView {
    /// Fires on every drag move — lets a caller know the panel was manually
    /// repositioned (e.g. so auto-positioning logic stops fighting the user).
    var onDrag: (() -> Void)?

    private var grabbed = false
    private var grabOffset = CGPoint.zero

    override func mouseDown(with event: NSEvent) {
        guard let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        grabbed = true
        grabOffset = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard grabbed, let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        setFrameOrigin(NSPoint(x: min(max(0, p.x - grabOffset.x), sv.bounds.width - frame.width),
                               y: min(max(0, p.y - grabOffset.y), sv.bounds.height - frame.height)))
        onDrag?()
    }

    /// Open hand while hovering, closed while actually dragging — the convention
    /// `PinnedWindow` and `VideoRecordBar` already use for a borderless HUD.
    override func mouseUp(with event: NSEvent) {
        grabbed = false
        NSCursor.openHand.set()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The header above each tool cluster: a grip glyph, the group's eyebrow label and
/// the hairline under it. The grip is the only *standing* cue that the card can be
/// moved — an open-hand cursor is invisible until the pointer is already over the
/// card, so nothing on screen ever said "grab me". It sits quiet at rest and
/// brightens under the pointer. The row draws its own text instead of hosting an
/// `NSTextField`: a control consumes the mouse-down, which is why dragging by the
/// caption never worked at all.
private final class ClusterHeader: NSView {
    /// 17 pt of cap height plus the 6 pt gap down to the hairline, so the label,
    /// the grip and the rule are one grab target.
    static let height: CGFloat = 23
    private static let capH: CGFloat = 17

    var onEnter: ((ClusterHeader) -> Void)?
    var onExit: (() -> Void)?
    /// Fires the moment the header is pressed, i.e. when a drag begins.
    var onPress: (() -> Void)?

    /// Six dots in two columns — the grabber every platform uses, so it carries its
    /// meaning without a legend and still fits inside the eyebrow's cap height.
    private let dot: CGFloat = 2, dotStep: CGFloat = 3.5, gripGap: CGFloat = 7
    private var gripSize: NSSize { NSSize(width: dot + dotStep, height: dot + dotStep * 2) }

    private let text: NSAttributedString
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    /// Width the grip and label actually need, so `makeCluster` sizes the card around
    /// a long localized group name instead of clipping it. The grip eats into the
    /// breathing room a centered label already had rather than adding to it —
    /// otherwise German's "HINTERGRUND" pushed the Background card 2 pt wider than
    /// the cards beside it.
    var contentWidth: CGFloat { gripSize.width + gripGap + ceil(text.size().width) }

    init(_ title: String) {
        let shadow = NSShadow()
        shadow.shadowColor = Theme.textShadow
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        text = NSAttributedString(string: title.uppercased(), attributes: [
            .foregroundColor: Theme.eyebrow,
            .font: Theme.font(11, .medium),
            .kern: 1.2,
            .shadow: shadow,
        ])
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onEnter?(self) }
    override func mouseExited(with event: NSEvent) { hovering = false; onExit?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    /// A press starts a drag, and the tip is positioned against where the card *was* —
    /// leaving it up would park a stale label next to the moving card, since the
    /// pointer never exits the header it is dragging by. `super` still forwards the
    /// press up to the card so the drag itself happens.
    override func mouseDown(with event: NSEvent) {
        onPress?()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ts = text.size()
        let grip = gripSize
        let midY = bounds.height - Self.capH / 2
        var x = ((bounds.width - (grip.width + gripGap + ceil(ts.width))) / 2).rounded()

        // Muted at rest so it never competes with the label it sits beside; full ink
        // under the pointer, the same brightening every tool tile does on hover.
        ctx.setFillColor((hovering ? Theme.ink : Theme.textMuted).cgColor)
        for col in 0..<2 {
            for row in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: x + CGFloat(col) * dotStep,
                                           y: midY + grip.height / 2 - dot - CGFloat(row) * dotStep,
                                           width: dot, height: dot))
            }
        }
        x += grip.width + gripGap
        text.draw(at: NSPoint(x: x, y: (midY - ts.height / 2).rounded()))

        Theme.divider.setFill()
        NSRect(x: (bounds.width * 0.14).rounded(), y: 0,
               width: (bounds.width * 0.72).rounded(), height: 1).fill()
    }
}

/// One of the four strips of screen outside the selection, measured in whole tool
/// cards. A gutter beside the capture runs its cards vertically, a strip above or below
/// runs them in a horizontal row — so a run is always shaped like the space it lives in.
private enum Side { case left, right, top, bottom }
private struct Gap {
    let capacity: Int
    var taken = 0
    var hasRoom: Bool { taken < capacity }
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
    enum Edge: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        /// Corners resize both axes; the four midpoints stretch one. A canvas too small for
        /// all eight keeps only these.
        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
            default: return false
            }
        }
    }
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
        let radius = Theme.radiusSmall
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
    /// The display the capture came from — its geometry sizes the opening scale and bounds a
    /// hand zoom.
    private let captureScreen: NSScreen
    private var toolButtons: [Tool: ToolButton] = [:]
    private var swatchButtons: [ToolButton] = []
    /// Stroke-width presets, exposed via ONE cycling tile (Thin → Medium → Thick) so the
    /// Style cluster stays a clean 3×4 like every other cluster. The tile's bar previews
    /// the current width. `widthDisplay` is the on-tile bar thickness for each preset.
    private let widths: [CGFloat] = [3, 6, 11]
    private let widthDisplay: [CGFloat] = [2, 4, 7]
    private let widthLabels = [L("Thin"), L("Medium"), L("Thick")]
    private weak var widthButton: ToolButton?
    private var currentWidth = 1   // 6 pt — matches the editor's default stroke
    private weak var plusButton: ToolButton?
    private weak var counterFormatButton: ToolButton?
    private weak var emojiButton: ToolButton?
    private var colorPicker: ColorPickerPanel?
    private var textBgColorPicker: ColorPickerPanel?

    // MARK: Text format bar — a small inline toolbar shown while the Text tool is
    // active: a font-size dropdown, a Bold toggle, alignment tiles, and a dropdown +
    // swatch for the text box's own background (not the text itself).
    private var textFormatBar: NSView?
    private weak var textSizePopup: BrandPopUpButton?
    private weak var textBoldButton: ToolButton?
    private var alignButtons: [NSTextAlignment: ToolButton] = [:]
    private weak var textBgPopup: BrandPopUpButton?
    private weak var textBgColorSwatch: ToolButton?
    /// Once the user drags the bar, auto-positioning backs off until a *different*
    /// text box becomes current (tracked via `lastTextFocusToken`).
    private var textFormatBarUserMoved = false
    private var lastTextFocusToken: ObjectIdentifier?
    private let textFontSizes: [CGFloat] = [12, 14, 18, 24, 32, 48, 64]
    private let textBackgrounds: [TextBackground] = [.none, .filled, .outlined]
    private let textBackgroundNames = [L("No background"), L("Filled box"), L("Outlined box")]
    private var emojiPicker: EmojiPickerPanel?
    private var formatPicker: CounterFormatPicker?

    private var clusterViews: [NSView] = []
    private var ring: NSView!
    private var cropButtons: [NSView] = []
    /// Tool panels temporarily slid aside so the crop bar has room, with their original
    /// origins — restored in `hideCropConfirm` when the crop ends.
    private var displacedPanels: [(view: NSView, origin: NSPoint)] = []
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
        let inset = EditorWindowController.onScreenScale(selection: selectionRect, screen: screen,
                                                        captureScale: captureScale)
        let scale = (captureScale > 0 ? 1 / captureScale : 1) * inset
        canvas = CanvasView(image: image, displayScale: scale)
        captureScreen = screen
        window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // `.screenSaver`, not `.normal`: the editor is a full-screen surface over a frozen
        // capture, so anything the window server puts above it *clips the tools*. At
        // `.normal` the Dock (level 20) and the menu bar (24) cut the bottom and top rows
        // of tool cards off, and any other app's window could come up over the whole
        // editor. The rest of the app is built on this level — the pickers and toast sit at
        // `.screenSaver + 1` and `BrandAlert` at `+2` precisely to clear the editor — so
        // lowering it also silently put those *below* what they were written to cover.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true

        let dim = NSView(frame: content.bounds)
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        content.addSubview(dim)

        // The capture is centred on the display for editing, not left where it was shot.
        // Centred, the four margins are symmetric — two equal gutters and two equal strips —
        // which is what lets the cards scatter around it from any capture shape, and for one
        // large enough to need scaling the middle is the *only* place that leaves a gutter on
        // both sides. Its size comes from the canvas, which sized itself from the image and
        // `displayScale`, so the ring and the gap measurements line up with the pixels
        // actually on screen. From here on the resize handles are a free zoom, so the canvas
        // frame is only ever `image.size * canvas.displayScale`.
        let local = NSRect(x: ((screen.frame.width - canvas.frame.width) / 2).rounded(),
                           y: ((screen.frame.height - canvas.frame.height) / 2).rounded(),
                           width: canvas.frame.width, height: canvas.frame.height)
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
            if t == .text { self.showTextFormatBar() } else { self.hideTextFormatBar() }
        }
        canvas.onChange = { [weak self] in
            guard let self, self.canvas.tool == .text else { return }
            self.syncTextFormatBar(); self.positionTextFormatBar()
        }
        // Fires on every new/edited/selected text mark (including the moment a fresh
        // box is started) so the bar jumps straight to whichever box is now current.
        canvas.onTextStyleChange = { [weak self] in
            guard let self, self.canvas.tool == .text else { return }
            self.syncTextFormatBar(); self.positionTextFormatBar()
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
        selectTool(.arrow)
        selectSwatch(0)
        canvas.style.lineWidth = 6

        EditorWindowController.open.append(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        window.delegate = self
    }

    // MARK: Card geometry — shared by the gap model and `insetScale`, which has to predict
    // what the gap model will decide before a single card exists.

    /// Gap between a cluster card and the capture.
    private static let cardGap: CGFloat = 16
    /// Margin every card keeps from the screen edge.
    private static let cardMargin: CGFloat = 8
    /// How far `buildClusters` shrinks the capture before measuring around it.
    private static let capturePad: CGFloat = 8
    /// Slack so `insetScale`'s arithmetic lands clear of the gap model's own comparisons
    /// rather than exactly on them.
    private static let cardSlack: CGFloat = 8
    /// Long edge a capture should reach to be comfortable to annotate. Below it the capture
    /// is magnified (see `magnification`).
    private static let comfortableEdge: CGFloat = 320
    /// Long edge below which a capture is too small to work on at all — the point where
    /// replicating pixels to enlarge it beats leaving it sharp but untouchable. Between this
    /// and `comfortableEdge` a capture is only enlarged as far as its own pixel density
    /// allows for free (see `magnification`).
    private static let workableEdge: CGFloat = 120
    /// Ceiling on that magnification — past this a capture is more pixel blocks than picture.
    /// Only the *opening* scale is capped; the resize handles zoom without limit.
    private static let maxMagnification: CGFloat = 4
    /// How close a dragged scale must come to a whole number to be committed as exactly that.
    /// Kept small — the stretch is meant to be free, and this only absorbs drift a hand cannot
    /// avoid (see `snapScale`).
    private static let scaleSnap: CGFloat = 0.04
    /// Floor on either edge of a hand-dragged canvas, so a knob can't collapse it to nothing.
    private static let minCanvasEdge: CGFloat = 40
    /// Ceiling on either edge of a hand-dragged canvas, in screens.
    private static let maxCanvasScreens: CGFloat = 8

    /// Horizontal room a card column needs beside the capture: its own width, plus the gap
    /// and margin `measureGaps` adds, plus slack. Both `insetScale` and the resize clamp
    /// reserve exactly this, so a capture can neither open nor be dragged into a size that
    /// leaves the cards nowhere to go.
    private static var gutterInset: CGFloat { cardFootprint.width + cardGap + cardMargin + cardSlack }

    /// The footprint of one cluster card. All five clusters are a 4×3 grid of `radius: 14`
    /// tiles, so `makeCluster` + `cardFit` give them the same size — and `insetScale` needs
    /// it before any card is built. Mirrors those two methods' geometry; if it ever drifts
    /// from them the scale just comes out wrong by a few points and a card gathers over the
    /// capture, which is where this layout started.
    private static var cardFootprint: NSSize {
        let side = ToolButton.size(radius: 14).width, gap: CGFloat = 4, pad: CGFloat = 5
        let grid = NSSize(width: 3 * (side + gap) + side, height: 2 * (side + gap) + side)
        return NSSize(width: grid.width + pad * 2, height: 17 + 22 + grid.height + pad * 2)
    }

    /// How much to shrink the capture on screen so the tool cards have somewhere outside it
    /// to sit — 1, meaning pixel-exact and left where it was shot, whenever they already do.
    ///
    /// A capture big enough to leave `measureGaps` nothing loses the scattered layout
    /// entirely: no strip outside the image can hold a card, so all five gather *on top of*
    /// the image — over the very pixels being annotated. That starts well before a
    /// whole-display capture (around 85% of the screen's width), and at the whole-display
    /// end the editor is on top of that pixel-identical to the desktop it froze, with only
    /// those cards to say anything happened. Shrinking until a card column clears both sides
    /// fixes both: the dim becomes a frame, and the cards scatter around it the way they do
    /// for a small capture. It applies to any capture mode, because it is measured from the
    /// rect rather than read off the mode that produced it.
    ///
    /// The test is the gap model's own, so nothing is scaled that didn't need it: if any one
    /// side can take a card, the layout works and the capture stays pixel-exact. That matters
    /// because an inexact scale costs a full-canvas resample on every redraw (see `init`'s
    /// note) — a capture that would otherwise be annotated *under* its own toolbars pays it,
    /// nothing else does.
    /// The capture's on-screen scale: shrunk when the cards can't fit around it, magnified
    /// when it is too small to work on, and 1 — pixel-exact — for everything in between.
    /// Shrinking wins if both apply, since a capture that big is not also small.
    private static func onScreenScale(selection: CGRect, screen: NSScreen,
                                      captureScale: CGFloat) -> CGFloat {
        let shrunk = insetScale(selection: selection, screen: screen)
        return shrunk < 1 ? shrunk
            : magnification(selection: selection, screen: screen, captureScale: captureScale)
    }

    /// Whole-number magnification for a capture too small to annotate comfortably.
    ///
    /// A 40×30 region centred in a dimmed 1440×900 screen is a postage stamp — there is
    /// nothing to aim a mark at, and below roughly 36 pt of canvas the eight 18 pt resize
    /// knobs overlap each other, so it can't even be resized.
    ///
    /// **Enlarging is only affordable up to the capture's own pixel density.** The canvas
    /// shows `1 / displayScale` captured pixels per point of screen, and `displayScale` is
    /// `magnification / captureScale` — so holding the magnification at or under
    /// `captureScale` keeps that at one captured pixel per point or better, the same density
    /// as ordinary 1× screen content. Past it the picture is coarser than the screen's own
    /// point grid: each captured pixel is spread over a block of points, which adds no detail
    /// and reads as soft whether the block is smoothed or left hard-edged.
    ///
    /// That threshold is what made this display-dependent, and it is worth spelling out
    /// because the symptom looks like a capture bug and isn't. `captureScale` *is* the
    /// display's density, so a 1× external panel has no headroom at all while a Retina one
    /// has 2×. A 265 pt capture was enlarged 2× on both, but that left the Retina canvas at
    /// one captured pixel per point (~113 per inch) and the 1× external at half that (~46
    /// per inch) — the same nominal zoom, two and a half times the perceived blur. `fits`
    /// allowed it on the external precisely because that screen is *bigger* in points.
    ///
    /// So only a capture under `workableEdge` — genuinely too small to aim a mark at — pays
    /// for replication, up to `maxMagnification`; anything larger is enlarged only as far as
    /// its own density gives away for nothing. Both are further capped by half the display,
    /// which keeps every margin at a quarter of the screen or more, well past what a card
    /// needs, so a magnified capture can never push the cards back on top of itself.
    private static func magnification(selection: CGRect, screen: NSScreen,
                                      captureScale: CGFloat) -> CGFloat {
        let f = screen.frame
        let long = max(selection.width, selection.height)
        guard long > 0, long < comfortableEdge, selection.width > 0, selection.height > 0
        else { return 1 }
        let wanted = (comfortableEdge / long).rounded(.up)
        let fits = min(f.width / 2 / selection.width, f.height / 2 / selection.height).rounded(.down)
        let free = max(1, captureScale)
        let ceiling = long < workableEdge ? maxMagnification : free
        return max(1, min(wanted, fits, ceiling))
    }

    private static func insetScale(selection: CGRect, screen: NSScreen) -> CGFloat {
        let f = screen.frame, card = cardFootprint, need = cardGap + cardMargin
        // `measureGaps`' own tests, against the geometry the capture will actually have: it is
        // centred, so both gutters are one width and both strips one depth, and four tests
        // collapse to two. One side with room is enough — a lone strip seats 10 cards and a
        // lone gutter 5 — so the gather only happens when every side comes up short.
        let side = (f.width - selection.width) / 2, strip = (f.height - selection.height) / 2
        let hasRoom = strip + capturePad - need >= card.height
            || (selection.height - capturePad * 2 >= card.height * 0.7
                && side + capturePad - need >= card.width)
        guard !hasRoom else { return 1 }

        // Leave a card's gutter on each side. Width drives it: the two side gutters are the
        // pair that can seat all five cards between them, and any capture that got here is
        // too wide for them. The top and bottom strips fall out proportionally and the gap
        // model uses them when they're deep enough.
        let room = f.width - gutterInset * 2
        let scale = room / selection.width
        // Past this the capture is being sacrificed rather than framed (a display this narrow
        // has no room for the scattered layout at any scale), so leave it pixel-exact and let
        // the cards gather as they did before.
        guard room > 0, scale >= 0.6 else { return 1 }
        return min(1, scale)
    }

    private func buildClusters(around sel: NSRect, in content: NSView) -> [NSView] {
        let bgPad = currentBackground.isNone ? 0 : Background.padding(maxDim: max(sel.width, sel.height))
        let sel = sel.insetBy(dx: Self.capturePad - bgPad, dy: Self.capturePad - bgPad)
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
        overlayBtn.tip = L("Overlay image — paste (⌘V), drop a file, or click to choose")
        wireHover(overlayBtn); toolButtons[.overlay] = overlayBtn

        let counterBtn = ToolButton(style: .counterGlyph, target: self, action: #selector(counterPressed))
        counterBtn.tip = L("Counter — place numbered badges (click again to change format)  (C)")
        wireHover(counterBtn); toolButtons[.counter] = counterBtn; counterFormatButton = counterBtn
        let emojiBtn = ToolButton(style: .text(canvas.currentEmoji), target: self, action: #selector(emojiPressed))
        emojiBtn.tip = L("Emoji — stamp an emoji (click to choose)"); wireHover(emojiBtn)
        emojiButton = emojiBtn; toolButtons[.emoji] = emojiBtn

        let draw = makeCluster(L("Markup"), [
            toolButton(.pencil, "pencil", L("Pencil — freehand draw  (P)")),
            toolButton(.marker, "highlighter", L("Highlighter — translucent highlight  (H)")),
            toolButton(.eraser, "eraser", L("Eraser — click a mark to remove it  (E)")),
            toolButton(.text, .text("T"), L("Text — click and type a label  (T)")),
            toolButton(.blur, .mosaic, L("Blur — obscure sensitive content  (B)")),
            toolButton(.spotlight, .spotlightGlyph, L("Spotlight — dim everything around an area  (S)")),
            counterBtn,
            emojiBtn,
            toolButton(.zoom, "plus.magnifyingglass", L("Zoom — magnify a region into a callout  (Z)")),
            toolButton(.ruler, "ruler", L("Ruler — drag to measure  (hold ⇧ to snap horizontal/vertical)")),
            overlayBtn,
            actionButton("text.viewfinder", L("Copy text / QR (OCR) — drag over text or a QR code  (⌘T)"), key: "t", mods: [.command], #selector(copyTextPressed))], perRow: 4)
        let shapes = makeCluster(L("Shape"), [
            toolButton(.arrow, "arrow.up.right", L("Arrow — point to an area  (A)")),
            toolButton(.line, "line.diagonal", L("Line  (L)")),
            toolButton(.rect, "rectangle", L("Rectangle  (R)")),
            toolButton(.ellipse, "circle", L("Ellipse  (O)")),
            toolButton(.roundedRect, .roundedSquare, L("Rounded rectangle  (U)")),
            toolButton(.triangle, "triangle", L("Triangle  (G)")),
            toolButton(.diamond, "diamond", L("Diamond  (D)")),
            toolButton(.star, "star", L("Star  (Y)")),
            toolButton(.checkmark, "checkmark", L("Checkmark  (K)")),
            toolButton(.pentagon, "pentagon", L("Pentagon  (5)")),
            toolButton(.hexagon, "hexagon", L("Hexagon  (6)")),
            toolButton(.octagon, "octagon", L("Octagon  (8)"))], perRow: 4)

        let colorR: CGFloat = 14
        let eyedropper = ToolButton(style: .tool("eyedropper"), radius: colorR,
                                   target: self, action: #selector(toolPressed(_:)))
        eyedropper.tip = L("Eyedropper — pick a color from the image  (I)"); wireHover(eyedropper)
        toolButtons[.eyedropper] = eyedropper
        var colorTiles: [ToolButton] = [eyedropper]
        for (i, entry) in palette.enumerated() {
            let b = ToolButton(style: .swatch(entry.0), radius: colorR, target: self, action: #selector(swatchPressed(_:)))
            b.tag = i; b.tip = String(format: L("%@ color"), L(entry.1)); wireHover(b)
            swatchButtons.append(b); colorTiles.append(b)
        }
        let plus = ToolButton(style: .plusGlyph, radius: colorR, target: self, action: #selector(customColorPressed))
        plus.tip = L("Custom color — pick any hue"); wireHover(plus)
        plusButton = plus
        colorTiles.append(plus)
        // One cycling stroke-width tile completes a tidy 3×4 grid (9 swatches +
        // eyedropper + custom + width), matching every other cluster's footprint.
        let widthTile = ToolButton(style: .lineWeight(widthDisplay[currentWidth]), radius: colorR,
                                   target: self, action: #selector(widthPressed))
        widthTile.tip = String(format: L("Stroke width: %@ — click to cycle"), widthLabels[currentWidth])
        widthTile.activeLineWeightIndex = currentWidth
        wireHover(widthTile); widthButton = widthTile; colorTiles.append(widthTile)
        let color = makeCluster(L("Style"), colorTiles, perRow: 4, radius: colorR)

        let actions = makeCluster(L("Action"), [
            // A pointer glyph read as a second Arrow tool — the four-way move symbol
            // says "reposition an existing mark" without competing with it.
            toolButton(.select, "arrow.up.and.down.and.arrow.left.and.right", L("Move — drag an object to reposition, drag its corner to resize, ⌫ to delete  (V)")),
            toolButton(.crop, "crop", L("Crop — drag a region, then ↵ or ✓")),
            actionButton("rotate.right", L("Rotate right 90°"), key: "", mods: [], #selector(rotateRightPressed)),
            actionButton("arrow.left.and.right.righttriangle.left.righttriangle.right", L("Flip horizontal"), key: "", mods: [], #selector(flipHorizontalPressed)),
            actionButton("arrow.uturn.backward", L("Undo  (⌘Z)"), key: "z", mods: [.command], #selector(undoPressed)),
            actionButton("arrow.uturn.forward", L("Redo  (⇧⌘Z)"), key: "z", mods: [.command, .shift], #selector(redoPressed)),
            actionButton("pin", L("Pin to screen — keep on top  (⌘P)"), key: "p", mods: [.command], #selector(pinPressed)),
            actionButton("photo.stack", L("Before/After GIF — animate overlays on/off"), key: "", mods: [], #selector(beforeAfterPressed)),
            actionButton("doc.on.doc", L("Copy & close  (⌘C)"), key: "c", mods: [.command], #selector(copyPressed)),
            actionButton("square.and.arrow.down", L("Save & close  (⌘S)"), key: "s", mods: [.command], #selector(savePressed)),
            actionButton("square.and.arrow.down.on.square", L("Save As… — choose location  (⇧⌘S)"), key: "s", mods: [.command, .shift], #selector(saveAsPressed)),
            actionButton("xmark", L("Cancel  (Esc)"), key: "\u{1b}", mods: [], #selector(closePressed))], perRow: 4)

        let bgR: CGFloat = 14
        var bgTiles: [ToolButton] = []
        for (i, style) in Background.presets.enumerated() {
            let tileStyle: ToolButton.Style = style.isNone ? .noneGlyph : .swatch(style.swatch)
            let b = ToolButton(style: tileStyle, radius: bgR, target: self, action: #selector(backgroundPressed(_:)))
            b.tag = i
            b.tip = style.isNone ? L("None") : L(style.name)
            b.selectedState = (style.name == currentBackground.name)
            wireHover(b); bgButtons.append(b); bgTiles.append(b)
        }
        let bgPlus = ToolButton(style: .plusGlyph, radius: bgR, target: self, action: #selector(backgroundCustomPressed))
        bgPlus.tip = L("Custom color")
        bgPlus.selectedState = currentBackground.isSolid
        wireHover(bgPlus); bgPlusButton = bgPlus; bgTiles.append(bgPlus)
        let background = makeCluster(L("Background"), bgTiles, perRow: 4, radius: bgR)

        let cs = content.bounds.size
        let g = Self.cardGap, m = Self.cardMargin
        let cards = [draw, shapes, color, background, actions].map(cardFit)
        let cardSize = NSSize(width: cards.map { $0.frame.width }.max() ?? 0,
                              height: cards.map { $0.frame.height }.max() ?? 0)

        // Where each cluster would rather live, best first. Markup hugs the left and Shape
        // the right — that is the scattered look — while the three wide tile rows prefer
        // the horizontal strips, which is the shape they lay out in.
        let preference: [[Side]] = [
            [.left,   .right,  .bottom, .top],   // Markup
            [.right,  .left,   .bottom, .top],   // Shape
            [.top,    .bottom, .right,  .left],  // Style
            [.top,    .bottom, .left,   .right], // Background
            [.bottom, .top,    .right,  .left],  // Action
        ]
        var gaps = measureGaps(sel: sel, cs: cs, card: cardSize, g: g, m: m)
        let band = gutterBand(sel: sel, cs: cs, card: cardSize, g: g, m: m,
                              top: gaps[.top] != nil, bottom: gaps[.bottom] != nil)
        var runs: [Side: [NSView]] = [:]
        var leftover: [NSView] = []
        for (card, prefs) in zip(cards, preference) {
            if let side = prefs.first(where: { gaps[$0]?.hasRoom == true }) {
                gaps[side]?.taken += 1
                runs[side, default: []].append(card)
            } else {
                leftover.append(card)
            }
        }
        if let v = runs[.left]   { stackVertically(v, onLeft: true,  sel: sel, gap: g, cs: cs, band: band, content) }
        if let v = runs[.right]  { stackVertically(v, onLeft: false, sel: sel, gap: g, cs: cs, band: band, content) }
        if let v = runs[.top]    { rowOutside(v, above: true,  sel: sel, gap: g, cs: cs, content) }
        if let v = runs[.bottom] { rowOutside(v, above: false, sel: sel, gap: g, cs: cs, content) }
        if !leftover.isEmpty {
            let (offsets, size) = gatherOffsets(leftover, rows: rowSplit(leftover.count))
            let origin = overCaptureOrigin(size, sel: sel, cs: cs)
            for (v, off) in zip(leftover, offsets) {
                v.setFrameOrigin(NSPoint(x: origin.x + off.x, y: origin.y + off.y))
                content.addSubview(v)
            }
        }
        return cards
    }

    /// Center the cluster in its card on both axes (uniform panel cards leave
    /// extra space around smaller clusters; this keeps them centered).
    private func placeInner(_ inner: NSView, in size: NSSize) {
        inner.setFrameOrigin(NSPoint(x: (size.width - inner.frame.width) / 2,
                                     y: (size.height - inner.frame.height) / 2))
    }

    /// A draggable, free-floating cluster card. It has to stay legible over any backdrop — a
    /// bright capture or a near-black desktop — so it gets the status-item menu's own surface,
    /// a hairline edge and a soft drop shadow, via `Theme.styleFloatingCard`: the app's floating
    /// chrome and the menu it opens from are one material.
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
        Theme.styleFloatingCard(c, cornerRadius: radius)
        placeInner(inner, in: size)
        c.addSubview(inner)
        return c
    }

    /// Measure the four strips of screen around the selection, in whole tool cards. Each
    /// cluster then takes the best gap that still has room, and only what nothing can hold
    /// gets gathered. The old test was all-or-nothing — one short gutter and *all five*
    /// clusters went into a single block dumped over the image — so a capture anywhere
    /// near a screen edge lost the scattered layout entirely.
    private func measureGaps(sel: NSRect, cs: CGSize, card: NSSize,
                             g: CGFloat, m: CGFloat) -> [Side: Gap] {
        /// Cards of `extent` that fit in `span`: n·extent + (n−1)·g ≤ span.
        func fit(_ span: CGFloat, _ extent: CGFloat) -> Int {
            Int(max(0, (span + g) / (extent + g)))
        }
        var out: [Side: Gap] = [:]
        let row = fit(cs.width - 2 * m, card.width)
        if cs.height - sel.maxY - g - m >= card.height { out[.top] = Gap(capacity: row) }
        if sel.minY - g - m >= card.height { out[.bottom] = Gap(capacity: row) }

        // A gutter only reads as *flanking* the capture if the capture is tall enough to
        // flank; below that, a tower of cards beside a sliver of image looks wrong.
        guard sel.height >= card.height * 0.7 else { return out }
        // Whatever the horizontal strips will take is not the gutters' to use. Capping the
        // run to the capture's own height instead — and only when *both* strips were in play
        // — left the one-strip case free to reach into that strip's band: a small capture in
        // a screen corner got a run that `stackVertically` then had to push inside the screen
        // edge, straight through the row above it. A band too shallow for a single card now
        // yields no gutter at all, rather than the forced one (`max(1, …)`) that could put a
        // card taller than the capture beside it.
        let band = gutterBand(sel: sel, cs: cs, card: card, g: g, m: m,
                              top: out[.top] != nil, bottom: out[.bottom] != nil)
        let run = fit(band.hi - band.lo, card.height)
        guard run > 0 else { return out }
        if sel.minX - g - m >= card.width { out[.left] = Gap(capacity: run) }
        if cs.width - sel.maxX - g - m >= card.width { out[.right] = Gap(capacity: run) }
        return out
    }

    /// The vertical band a gutter run may occupy: the screen, less whatever the horizontal
    /// strips will take. `rowOutside` puts a strip hard against the capture, clamped to the
    /// screen edge — so these bounds are exactly that row's own edges, which is what keeps a
    /// column and a row from ever sharing a band. Both `measureGaps` (for capacity) and
    /// `stackVertically` (for placement) read it, so the two cannot disagree.
    private func gutterBand(sel: NSRect, cs: CGSize, card: NSSize, g: CGFloat, m: CGFloat,
                            top: Bool, bottom: Bool) -> (lo: CGFloat, hi: CGFloat) {
        (lo: bottom ? max(m, sel.minY - g - card.height) + card.height : m,
         hi: top ? min(cs.height - m - card.height, sel.maxY + g) : cs.height - m)
    }

    /// Rows for a gathered block of `n` cards: one flat row up to three, then the squarest
    /// split. A block only gathers when it has to sit over the capture, so it should cover
    /// as little of the image as its card count allows.
    private func rowSplit(_ n: Int) -> [Int] { n <= 3 ? [n] : [n / 2, n - n / 2] }

    /// Each card's offset inside a gathered block, plus the block's size. The block is an
    /// arrangement, not a container — the caller positions the cards themselves, so every
    /// one stays a free-standing, independently draggable view.
    private func gatherOffsets(_ cards: [NSView], rows: [Int]) -> (offsets: [NSPoint], size: NSSize) {
        let pad: CGFloat = 7, hgap: CGFloat = 6, vgap: CGFloat = 6
        var grid: [[NSView]] = [], i = 0
        for n in rows where i < cards.count {
            grid.append(Array(cards[i..<min(i + n, cards.count)])); i += n
        }
        let rowW = grid.map { row in
            row.reduce(0) { $0 + $1.frame.width } + hgap * CGFloat(row.count - 1)
        }
        let rowH = grid.map { row in row.map { $0.frame.height }.max() ?? 0 }
        let w = (rowW.max() ?? 0) + pad * 2
        let h = rowH.reduce(0, +) + vgap * CGFloat(grid.count - 1) + pad * 2

        var offsets: [NSPoint] = []
        var yTop = pad
        for (r, row) in grid.enumerated() {
            var x = (w - rowW[r]) / 2
            for v in row {
                offsets.append(NSPoint(x: x, y: h - yTop - rowH[r] + (rowH[r] - v.frame.height) / 2))
                x += v.frame.width + hgap
            }
            yTop += rowH[r] + vgap
        }
        return (offsets, NSSize(width: w, height: h))
    }

    /// Where a gathered block goes when no gap outside the selection can take it: bottom-
    /// centre *of the capture*, hugging the image's lower edge. Dead centre — the old
    /// behaviour for a whole-screen selection — covered exactly the part of the image you
    /// want to see, and the bottom edge is where every annotation tool puts its toolbar.
    /// Sitting inside the selection also means it cannot collide with cards already placed
    /// in the gaps outside it.
    private func overCaptureOrigin(_ size: NSSize, sel: NSRect, cs: CGSize) -> NSPoint {
        let m: CGFloat = 8, inset: CGFloat = 16
        return NSPoint(x: min(max(m, sel.midX - size.width / 2), max(m, cs.width - size.width - m)),
                       y: min(max(m, sel.minY + inset), max(m, cs.height - size.height - m)))
    }

    /// Stack clusters in a column beside the selection, centered vertically,
    /// keeping the whole column out of the selection rectangle when possible.
    private func stackVertically(_ views: [NSView], onLeft: Bool, sel: NSRect,
                                 gap: CGFloat, cs: CGSize, band: (lo: CGFloat, hi: CGFloat),
                                 _ content: NSView) {
        let m = Self.cardMargin
        let maxW = views.map { $0.frame.width }.max() ?? 0
        let totalH = views.reduce(0) { $0 + $1.frame.height } + gap * CGFloat(views.count - 1)
        var topY = sel.midY + totalH / 2
        // Clamped into `band`, not the whole screen: pushing a run inside the screen edge is
        // exactly what used to walk it into a row's band. `measureGaps` sized the run against
        // this same band, so it always fits.
        topY = min(topY, band.hi)
        if topY - totalH < band.lo { topY = band.lo + totalH }
        let x = onLeft ? max(m, sel.minX - gap - maxW)
                       : min(cs.width - m - maxW, sel.maxX + gap)
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
        let m = Self.cardMargin
        let totalW = views.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(views.count - 1)
        let maxH = views.map { $0.frame.height }.max() ?? 0
        var x = min(max(m, sel.midX - totalW / 2), cs.width - totalW - m)
        // `gutterBand` mirrors these two edges exactly — change one, change the other.
        let y = above ? min(cs.height - m - maxH, sel.maxY + gap)
                      : max(m, sel.minY - gap - maxH)
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

        let header = ClusterHeader(name)
        header.onEnter = { [weak self] h in self?.showTip(L("Drag to move this panel"), over: h) }
        header.onExit = { [weak self] in self?.hideTip() }
        header.onPress = { [weak self] in self?.hideTip() }
        let contentW = max(gridW, header.contentWidth + 6)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: totalH))
        container.wantsLayer = true

        header.frame = NSRect(x: 0, y: totalH - ClusterHeader.height,
                              width: contentW, height: ClusterHeader.height)
        container.addSubview(header)

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

    private func showTip(_ button: ToolButton) { showTip(button.tip, over: button) }

    /// Tips sit above their source; a card pinned near the top of the screen has no
    /// room there, so flip below rather than draw the tip off-screen.
    private func showTip(_ tip: String?, over view: NSView) {
        guard let tip, let content = window.contentView else { return }
        tipText.stringValue = tip
        tipText.sizeToFit()
        let ts = tipText.frame.size
        let padX: CGFloat = 9, padY: CGFloat = 5
        let w = ts.width + padX * 2, h = ts.height + padY * 2
        let bf = content.convert(view.bounds, from: view)
        var x = bf.midX - w / 2
        x = max(6, min(x, content.bounds.width - w - 6))
        let above = bf.maxY + 6
        let y = above + h <= content.bounds.height - 6 ? above : bf.minY - 6 - h
        content.addSubview(tipBox, positioned: .above, relativeTo: nil)
        tipBox.frame = NSRect(x: x, y: max(6, y), width: w, height: h)
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
        widthButton?.tip = String(format: L("Stroke width: %@ — click to cycle"), widthLabels[currentWidth])
        widthButton?.activeLineWeightIndex = currentWidth
    }

    @objc private func counterPressed() {
        if canvas.tool == .counter { formatPressed() }
        else { selectTool(.counter) }
    }
    @objc private func formatPressed() {
        // Pressing the counter tile again while the popover is already open should
        // close it, not stack a second, unreachable one on top.
        if let existing = formatPicker, existing.isShowing { existing.close(); return }
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
        writeCapture(rep, to: Settings.shared.fileURL(), fellBack: fellBack) { [weak self] in
            self?.close()
            // Land in History with the fresh capture on top, matching the
            // recording flow — not silently back on the desktop.
            HistoryWindowController.shared.show()
        }
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
                        BrandAlert(title: L("Saved to the Desktop"),
                                   message: L("The save folder was unavailable; the file was saved to the Desktop. Update it in Settings → Output."),
                                   titles: [L("OK")], primary: 0, cancel: 0,
                                   icon: "folder.badge.questionmark").present()
                    }
                    onSuccess()
                } else {
                    // The write never happened, so let the name go — a retry should land on
                    // it rather than on a `-1` suffix.
                    Settings.shared.releaseClaim(url)
                    BrandAlert(title: L("Unable to save the capture"),
                               message: L("Saving failed. The capture remains open — try Save As."),
                               titles: [L("OK")], primary: 0, cancel: 0,
                               icon: "exclamationmark.triangle").present()
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
        panel.nameFieldStringValue = Settings.shared.suggestedFileName()
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
            self.writeCapture(rep, to: url) {
                self.close()
                HistoryWindowController.shared.show()
            }
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
        box.layer?.cornerRadius = Theme.radiusSmall
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
        panel.nameFieldStringValue = Settings.shared.suggestedFileName(ext: "gif")
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
        let vx = overlay.rect.midX * canvas.scaleX + canvas.frame.minX
        let vy = overlay.rect.maxY * canvas.scaleY + canvas.frame.minY
        var x = vx - card.frame.width / 2, y = vy + 12
        x = min(max(8, x), content.bounds.width - card.frame.width - 8)
        y = min(max(8, y), content.bounds.height - card.frame.height - 8)
        card.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func buildOpacityCard() -> NSView {
        let w: CGFloat = 200, h: CGFloat = 56
        let card = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        Theme.styleFloatingCard(card)
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
        let choice = BrandAlert(title: L("Discard capture?"),
                                message: L("The screenshot and all edits will be permanently deleted."),
                                titles: [L("Keep Editing"), L("Discard")],
                                primary: 0, cancel: 0,
                                icon: "trash.fill", destructive: [1]).runModal()
        if choice == 1 { close() }
    }
    private func close() {
        colorPicker?.close(); bgColorPicker?.close(); textBgColorPicker?.close()
        window.close()
    }

    @objc private func rotateRightPressed() { rotate(left: false) }

    private func rotate(left: Bool) {
        guard let newImg = canvas.rotatedImage(left: left) else { return }
        let W = canvas.image.size.width, H = canvas.image.size.height
        let remap: (CGPoint) -> CGPoint = left
            ? { CGPoint(x: H - $0.y, y: $0.x) }
            : { CGPoint(x: $0.y, y: W - $0.x) }
        let sx = canvas.scaleX, sy = canvas.scaleY
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        cancelCrop()
        // A quarter turn turns the stretch with it: the axes swap, so the scales do too, and
        // the box the user dragged comes back on its side rather than snapping square.
        canvas.scaleX = sy; canvas.scaleY = sx
        canvas.applyTransform(newImage: newImg, remap: remap)
        let newSize = NSSize(width: newImg.size.width * sy, height: newImg.size.height * sx)
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
        let sx = canvas.scaleX, sy = canvas.scaleY
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        cancelCrop()
        canvas.applyTransform(newImage: newImg, remap: remap)
        let newSize = NSSize(width: newImg.size.width * sx, height: newImg.size.height * sy)
        relayout(canvasFrame: NSRect(x: center.x - newSize.width / 2,
                                     y: center.y - newSize.height / 2,
                                     width: newSize.width, height: newSize.height))
    }

    @objc private func applyCropPressed()  { applyCrop() }
    @objc private func cancelCropPressed() { cancelCrop() }

    private func applyCrop() {
        guard let pc = canvas.pendingCrop, pc.width >= 5, pc.height >= 5,
              let newImg = canvas.croppedImage(rect: pc) else { cancelCrop(); return }
        let sx = canvas.scaleX, sy = canvas.scaleY
        let oldOrigin = canvas.frame.origin
        canvas.applyTransform(newImage: newImg) { CGPoint(x: $0.x - pc.minX, y: $0.y - pc.minY) }
        hideCropConfirm()
        relayout(canvasFrame: NSRect(x: oldOrigin.x + pc.minX * sx,
                                     y: oldOrigin.y + pc.minY * sy,
                                     width: pc.width * sx, height: pc.height * sy))
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
        // A frame bigger than the screen can't be clamped inside it — centre the overflow
        // rather than pinning it into one corner, which is what the old `max(8 + pad, …)`
        // floor did. Reachable now that the resize handles zoom without a limit.
        let m = 8 + pad
        let fitsX = content.bounds.width - fr.width - m >= m
        let fitsY = content.bounds.height - fr.height - m >= m
        fr.origin.x = fitsX ? min(max(m, fr.origin.x), content.bounds.width - fr.width - m)
                            : (content.bounds.width - fr.width) / 2
        fr.origin.y = fitsY ? min(max(m, fr.origin.y), content.bounds.height - fr.height - m)
                            : (content.bounds.height - fr.height) / 2
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

    /// Put (or move) the eight resize knobs around the canvas. Each drags only the edge(s) it
    /// sits on, holding the opposite one fixed — corners both axes, midpoints one (see
    /// `resizeDragged`).
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
        // A canvas narrower than two knobs can't seat all eight without them piling up: on a
        // 30 pt edge, a corner and the midpoint beside it are 15 pt apart with 18 pt targets,
        // so which one a click lands on is whichever happens to be in front — the capture
        // reads as un-resizable. Magnification (`magnification`) keeps most small captures
        // clear of this; below it, corners only, which resize both axes anyway.
        let crowded = min(canvas.frame.width, canvas.frame.height) < s * 2
        for h in resizeHandles {
            guard !crowded || h.edge.isCorner else { h.removeFromSuperview(); continue }
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

    /// Drag the grabbed edge(s), holding the opposite edge(s) fixed — each knob moves only
    /// what it is attached to, so the picture stretches freely.
    ///
    /// Deliberately **not** aspect locked and **not** anchored on the centre: locking the
    /// aspect made an edge knob change the height too, and centre-anchoring made it move the
    /// opposite edge as well, so no knob felt like it belonged to the side it sat on. The
    /// picture is a screenshot, so a non-uniform stretch does distort it — that is the cost of
    /// the freedom, and the Rotate / Flip / Crop actions are the ones that stay rigid.
    ///
    /// Bounded only by `minCanvasEdge` and `maxCanvasScreens`, per side, so a drag can neither
    /// collapse an edge to nothing nor run away past anything drawable. There is no clamp to
    /// the screen: the pixels were fixed at capture time, so this is a zoom, not a re-grab, and
    /// a zoom has no natural stop.
    private func resizeDragged(_ d: CGSize) {
        guard let p = resizePreview, resizeBaseFrame.width > 0, resizeBaseFrame.height > 0
        else { return }
        let b = resizeBaseFrame, edge = activeResizeEdge
        let lo = Self.minCanvasEdge
        let hi = max(captureScreen.frame.width, captureScreen.frame.height) * Self.maxCanvasScreens
        var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
        switch edge {
        case .topLeft, .left, .bottomLeft:
            minX = min(max(b.maxX - hi, b.minX + d.width), maxX - lo)
        case .topRight, .right, .bottomRight:
            maxX = max(min(b.minX + hi, b.maxX + d.width), minX + lo)
        case .top, .bottom: break
        }
        switch edge {
        case .topLeft, .top, .topRight:
            maxY = max(min(b.minY + hi, b.maxY + d.height), minY + lo)
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(max(b.maxY - hi, b.minY + d.height), maxY - lo)
        case .left, .right: break
        }
        p.frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        repositionResizeHandles(around: p.frame)
    }

    /// Commit the stretch: the two scales and a relayout, nothing more. The image is untouched
    /// and annotations live in image space, so there is nothing to fetch and nothing async —
    /// the old re-grab needed a ScreenCaptureKit round trip and could fail.
    private func resizeEnded() {
        guard let p = resizePreview, resizeBaseFrame.width > 0, resizeBaseFrame.height > 0
        else { return }
        let b = resizeBaseFrame, pf = p.frame
        p.removeFromSuperview(); resizePreview = nil
        let imgW = canvas.image.size.width, imgH = canvas.image.size.height
        // A drag that didn't change anything, or an image with no size, is a no-op.
        guard imgW > 0, imgH > 0, abs(pf.width - b.width) >= 1 || abs(pf.height - b.height) >= 1
        else { relayout(canvasFrame: b); return }
        canvas.endTextEditing()
        cancelCrop()
        // Quantise what the hand dragged before committing it. `relayout` already rounds the
        // canvas *origin* onto the device-pixel grid because a fractional one resamples the
        // whole canvas; the size needs the same treatment and never got it, so every stretch
        // softened the very picture the user enlarged to look at.
        let backing = max(1, window.backingScaleFactor)
        canvas.scaleX = Self.snapScale(pf.width / imgW, imageEdge: imgW, backing: backing)
        canvas.scaleY = Self.snapScale(pf.height / imgH, imageEdge: imgH, backing: backing)
        // Size the frame from the committed scales, so the canvas stays exactly
        // `image.size × (scaleX, scaleY)` and the image can't land a fraction off its own view.
        var committed = pf
        committed.size = CGSize(width: imgW * canvas.scaleX, height: imgH * canvas.scaleY)
        relayout(canvasFrame: committed)
    }

    /// Quantise a dragged scale so the stretched canvas lands on whole device pixels.
    ///
    /// A drag arrives in fractional points — a trackpad reports sub-pixel deltas — so a stretch
    /// that looks like exactly 2× commits as 1.9987×. Both axes are then fractional, the image's
    /// edges fall between device pixels, and CoreGraphics resamples the entire canvas on every
    /// redraw. That is pure loss: the user dragged the picture *bigger* to see it better and got
    /// a softer one, worst on a 1× display where there is no spare density to hide it.
    ///
    /// Near a whole step the scale snaps to it, which also lets `CanvasView.draw` take its
    /// nearest-neighbour path so an integer zoom of a screenshot keeps its glyph edges hard.
    /// Anywhere else the scale is kept but nudged onto the pixel grid — the sharpest an
    /// arbitrary ratio can be — leaving the free stretch free.
    private static func snapScale(_ s: CGFloat, imageEdge: CGFloat, backing: CGFloat) -> CGFloat {
        guard s > 0, imageEdge > 0, backing > 0 else { return s }
        let whole = s.rounded()
        if whole >= 1, abs(s - whole) <= scaleSnap { return whole }
        let px = (imageEdge * s * backing).rounded()
        guard px >= 1 else { return s }
        return px / (imageEdge * backing)
    }

    private func showCropConfirm() {
        guard let pc = canvas.pendingCrop, let content = window.contentView else { return }
        hideCropConfirm()
        let sx = canvas.scaleX, sy = canvas.scaleY, f = canvas.frame
        let cr = NSRect(x: f.minX + pc.minX * sx, y: f.minY + pc.minY * sy,
                        width: pc.width * sx, height: pc.height * sy)

        // Slide any tool panel out of the crop region first: on a whole-screen capture
        // (Screen mode) the panel is centered right over the image, so a centered crop
        // would otherwise cover it — and the crop bar with it.
        moveClustersClear(of: cr, in: content)

        let r: CGFloat = 16
        let sz = ToolButton.size(radius: r)
        let gap: CGFloat = 6, pad: CGFloat = 5
        let totalW = sz.width * 2 + gap
        let barW = totalW + pad * 2, barH = sz.height + pad * 2
        let x = min(max(8, cr.midX - barW / 2), content.bounds.width - barW - 8)

        // Place the bar just outside the crop rect (top, then bottom), then tucked inside
        // if neither outside edge is on-screen — taking the first spot that clears the
        // (now-relocated) panels.
        let candidateYs = [cr.maxY + gap, cr.minY - gap - barH, cr.maxY - gap - barH, cr.minY + gap]
        let fits: (CGFloat) -> Bool = { candY in
            guard candY >= 8, candY + barH <= content.bounds.height - 8 else { return false }
            let bar = NSRect(x: x, y: candY, width: barW, height: barH)
            return !self.clusterViews.contains { $0.frame.intersects(bar) }
        }
        let y = candidateYs.first(where: fits)
            ?? max(8, min(cr.maxY + gap, content.bounds.height - 8 - barH))

        // A bordered brand bar behind the buttons, so the ✓/✗ read clearly against any
        // image instead of floating as bare glyphs on the dim backdrop.
        let bar = NSView(frame: NSRect(x: x, y: y, width: barW, height: barH))
        bar.wantsLayer = true
        if let layer = bar.layer {
            layer.cornerRadius = Theme.radiusSmall
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: -5)
        }
        // Lavender edge rather than the usual hairline: this bar is a confirm, and the edge is
        // what says so.
        Theme.styleFloatingCard(bar, stroke: Theme.lavender.withAlphaComponent(0.9))
        content.addSubview(bar)

        let ok = ToolButton(style: .tool("checkmark"), radius: r, target: self, action: #selector(applyCropPressed))
        ok.tip = "Apply crop  (↵)"; wireHover(ok)
        let cancel = ToolButton(style: .tool("xmark"), radius: r, target: self, action: #selector(cancelCropPressed))
        cancel.tip = "Cancel crop"; wireHover(cancel)
        bar.addSubview(ok); bar.addSubview(cancel)
        ok.frame = NSRect(x: pad, y: pad, width: sz.width, height: sz.height)
        cancel.frame = NSRect(x: pad + sz.width + gap, y: pad, width: sz.width, height: sz.height)
        cropButtons = [bar]
    }

    /// Slide each tool panel that overlaps `cr` to the nearest screen corner that clears
    /// it, remembering the original origin so `hideCropConfirm` can put it back.
    private func moveClustersClear(of cr: CGRect, in content: NSView) {
        let m: CGFloat = 16
        for p in clusterViews where p.frame.intersects(cr) {
            let w = p.frame.width, h = p.frame.height
            let corners = [
                NSPoint(x: m, y: content.bounds.height - h - m),                    // top-left
                NSPoint(x: content.bounds.width - w - m, y: content.bounds.height - h - m), // top-right
                NSPoint(x: m, y: m),                                                // bottom-left
                NSPoint(x: content.bounds.width - w - m, y: m),                     // bottom-right
            ]
            guard let spot = corners.first(where: { !NSRect(origin: $0, size: p.frame.size).intersects(cr) }) else { continue }
            displacedPanels.append((p, p.frame.origin))
            p.animator().setFrameOrigin(spot)
        }
    }

    private func hideCropConfirm() {
        cropButtons.forEach { $0.removeFromSuperview() }
        cropButtons = []
        displacedPanels.forEach { $0.view.animator().setFrameOrigin($0.origin) }
        displacedPanels = []
    }

    // MARK: - Text format bar

    private func showTextFormatBar() {
        guard let content = window.contentView else { return }
        if textFormatBar == nil {
            let bar = buildTextFormatBar()
            content.addSubview(bar)
            textFormatBar = bar
        }
        textFormatBar?.isHidden = false
        syncTextFormatBar()
        positionTextFormatBar()
    }

    private func hideTextFormatBar() {
        textFormatBar?.isHidden = true
    }

    /// A floating brand bar (same chrome as the crop-confirm bar): a font-size dropdown,
    /// a Bold toggle, three alignment tiles, and — clearly separate from the text
    /// itself — a dropdown + swatch for the text **box's** own background.
    private func buildTextFormatBar() -> NSView {
        let r: CGFloat = 13
        let btn = ToolButton.size(radius: r)
        let pad: CGFloat = 6, gap: CGFloat = 4, groupGap: CGFloat = 12
        let popupH: CGFloat = 24

        func tile(_ style: ToolButton.Style, _ tip: String, _ action: Selector) -> ToolButton {
            let b = ToolButton(style: style, radius: r, target: self, action: action)
            b.tip = tip; wireHover(b)
            return b
        }
        /// Sizes the popup to fit its widest title (plus the chevron/inset) so no
        /// item — in the button or its dropdown list — is ever clipped.
        func popup(titles: [String], action: Selector) -> BrandPopUpButton {
            let font = Theme.font(12)
            let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 40
            let width = ceil(widest) + BrandControl.textInset + 26
            let p = BrandPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: popupH), pullsDown: false)
            titles.forEach { p.addItem(withTitle: $0) }
            p.target = self; p.action = action
            p.showsCheckmark = false   // the button's own title already shows the current value
            return p
        }

        let sizePopup = popup(titles: textFontSizes.map { "\(Int($0))pt" },
                              action: #selector(textSizePopupChanged(_:)))
        textSizePopup = sizePopup

        let bold = tile(.text("B"), "Bold", #selector(textBoldPressed))
        textBoldButton = bold

        let alignL = tile(.tool("text.alignleft"), "Align left", #selector(textAlignLeftPressed))
        let alignC = tile(.tool("text.aligncenter"), "Align center", #selector(textAlignCenterPressed))
        let alignR = tile(.tool("text.alignright"), "Align right", #selector(textAlignRightPressed))
        alignButtons = [.left: alignL, .center: alignC, .right: alignR]

        let bgPopup = popup(titles: textBackgroundNames, action: #selector(textBgPopupChanged(_:)))
        textBgPopup = bgPopup

        let swatch = ToolButton(style: .swatch(canvas.textBackgroundColor), radius: r,
                                target: self, action: #selector(textBgColorPressed))
        swatch.tip = "Text box background color — click to choose"; wireHover(swatch)
        textBgColorSwatch = swatch

        let views: [NSView] = [sizePopup, bold, alignL, alignC, alignR, bgPopup, swatch]
        let gapsBefore: [CGFloat] = [0, groupGap, groupGap, gap, gap, groupGap, gap]

        let rowH = max(popupH, btn.height)
        var x = pad
        for (i, v) in views.enumerated() {
            x += gapsBefore[i]
            let isPopup = v is BrandPopUpButton
            let h = isPopup ? popupH : btn.height
            let w = isPopup ? v.frame.width : btn.width
            v.frame = NSRect(x: x, y: pad + (rowH - h) / 2, width: w, height: h)
            x += w
        }
        let barSize = NSSize(width: x + pad, height: rowH + pad * 2)

        let inner = NSView(frame: NSRect(origin: .zero, size: barSize))
        views.forEach { inner.addSubview($0) }
        // `cardFit` gives the same brand chrome as every other tool cluster, wrapped
        // in a `DraggablePanel` — the bar can be grabbed and moved anywhere, same as
        // the tool clusters, while its own tiles/dropdowns still get their clicks.
        let bar = cardFit(inner)
        (bar as? DraggablePanel)?.onDrag = { [weak self] in self?.textFormatBarUserMoved = true }
        return bar
    }

    /// Reflects the canvas's current text style on the bar's controls — called after
    /// every change so they never drift from what the mark actually looks like.
    private func syncTextFormatBar() {
        let s = canvas.currentTextStyle
        if let idx = textFontSizes.enumerated().min(by: { abs($0.element - s.size) < abs($1.element - s.size) })?.offset {
            textSizePopup?.selectItem(at: idx)
        }
        textBoldButton?.selectedState = s.bold
        for (a, b) in alignButtons { b.selectedState = (a == s.alignment) }
        if let idx = textBackgrounds.firstIndex(of: s.background) { textBgPopup?.selectItem(at: idx) }
        textBgColorSwatch?.setStyle(.swatch(canvas.textBackgroundColor))
    }

    /// Places the bar just above (else below) the active text box, or the selection
    /// center when nothing is focused yet — mirroring the crop-confirm bar's placement.
    /// Backs off once the user has dragged the bar, until a *different* text box
    /// becomes current (a new one started, or another mark selected).
    private func positionTextFormatBar() {
        guard let bar = textFormatBar, let content = window.contentView else { return }
        let token = canvas.textFocusToken
        if token != lastTextFocusToken { lastTextFocusToken = token; textFormatBarUserMoved = false }
        guard !textFormatBarUserMoved else { return }
        let sx = canvas.scaleX, sy = canvas.scaleY, f = canvas.frame
        let target = canvas.textFocusRect ?? CGRect(origin: .zero, size: canvas.image.size)
        let r = NSRect(x: f.minX + target.minX * sx, y: f.minY + target.minY * sy,
                       width: target.width * sx, height: target.height * sy)
        let barW = bar.frame.width, barH = bar.frame.height
        let gap: CGFloat = 10
        let x = min(max(8, r.midX - barW / 2), content.bounds.width - barW - 8)
        let candidateYs = [r.maxY + gap, r.minY - gap - barH]
        let y = candidateYs.first(where: { $0 >= 8 && $0 + barH <= content.bounds.height - 8 })
            ?? max(8, min(r.maxY + gap, content.bounds.height - 8 - barH))
        bar.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func textSizePopupChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < textFontSizes.count else { return }
        canvas.setTextFontSize(textFontSizes[idx])
        positionTextFormatBar()
    }

    @objc private func textBoldPressed() {
        canvas.setTextBold(!canvas.currentTextStyle.bold)
        syncTextFormatBar()
    }

    @objc private func textAlignLeftPressed() { setTextAlign(.left) }
    @objc private func textAlignCenterPressed() { setTextAlign(.center) }
    @objc private func textAlignRightPressed() { setTextAlign(.right) }
    private func setTextAlign(_ a: NSTextAlignment) {
        canvas.setTextAlignment(a)
        syncTextFormatBar()
    }

    @objc private func textBgPopupChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < textBackgrounds.count else { return }
        canvas.setTextBackground(textBackgrounds[idx])
        positionTextFormatBar()
    }

    /// Custom color for the text **box's** background — picking one while the
    /// background is off promotes it to Filled so the choice is immediately visible.
    @objc private func textBgColorPressed() {
        if textBgColorPicker == nil {
            textBgColorPicker = ColorPickerPanel(
                onPick: { [weak self] c in
                    guard let self else { return }
                    canvas.setTextBackgroundColor(c)
                    if canvas.currentTextStyle.background == .none { canvas.setTextBackground(.filled) }
                    syncTextFormatBar()
                },
                onClose: { [weak self] in
                    self?.window.makeKeyAndOrderFront(nil)
                    self?.window.makeFirstResponder(self?.canvas)
                })
        }
        guard let picker = textBgColorPicker, let swatch = textBgColorSwatch else { return }
        picker.show(near: swatch, initial: canvas.textBackgroundColor)
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        EditorWindowController.open.removeAll { $0 === self }
    }
}

