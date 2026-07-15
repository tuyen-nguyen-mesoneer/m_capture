// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreImage

enum Tool {
    case pencil, marker, line, arrow, rect, ellipse
    case triangle, diamond, star, roundedRect, checkmark, pentagon, hexagon, octagon
    case text, blur, counter, spotlight, eyedropper, eraser, crop, ocr, zoom, emoji
    case overlay, ruler, select
}

/// Displays the captured image (scaled to fit) and the annotations on top.
/// Annotation coordinates are kept in full-resolution image space.
final class CanvasView: NSView, NSTextViewDelegate {
    private(set) var image: NSImage
    let displayScale: CGFloat

    var tool: Tool = .pencil {
        didSet {
            if tool != .text { commitText(); editingText = nil; textDrag = .none }
            if !((tool == .arrow && editingCurve is CurvedArrowAnnotation) ||
                 (tool == .line && editingCurve is CurvedLineAnnotation)) {
                editingCurve = nil
            }
            if editingShapeTool != tool { editingShape = nil; editingShapeTool = nil }
            if tool != .zoom { editingZoom = nil }
            if tool != .overlay, editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
            if tool != .ruler { measureAxis = .none; measureAnchor = nil }
            if tool != .select { selected = nil; selectDrag = .none }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            if tool != oldValue { onToolChange?(tool) }
        }
    }
    /// Fired when the active tool changes from *inside* the canvas (e.g. auto-selecting
    /// a freshly-stamped emoji into Select) so the editor can sync the toolbar highlight.
    /// Handlers must not set `tool` back, or the didSet recurses.
    var onToolChange: ((Tool) -> Void)?
    var style = DrawStyle(color: Theme.accent, lineWidth: 3)
    var onChange: (() -> Void)?
    var onColorPicked: ((NSColor) -> Void)?
    var onShortcut: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var pendingCrop: CGRect?
    private var cropStart: CGPoint?
    var onCropBegin: (() -> Void)?
    var onCropReady: (() -> Void)?
    var onCropConfirm: (() -> Void)?

    private var ocrStart: CGPoint?
    private var ocrRect: CGRect?
    var onOCR: ((CGImage) -> Void)?

    private var zoomStart: CGPoint?
    private var zoomRect: CGRect?
    private var editingZoom: ZoomAnnotation?
    private enum ZoomDrag { case none, move, resize }
    private var zoomDrag: ZoomDrag = .none
    private var zoomDragOffset: CGPoint = .zero

    private var editingCurve: CurvedAnnotation?
    /// Which of a curved arrow/line's three drag knobs is being reshaped.
    private enum CurveHandle { case start, end, apex }
    private var curveDrag: (curve: CurvedAnnotation, handle: CurveHandle)?

    /// The shape just drawn with a shape tool, kept live so its corner handles show
    /// (and it can be resized/moved) without switching to Select — mirrors `editingCurve`.
    /// `editingShapeTool` records the tool that made it, so re-selecting the same tool
    /// keeps the handles while switching to any other tool clears them.
    private var editingShape: TwoPointAnnotation?
    private var editingShapeTool: Tool?

    /// An eight-way box resize for rectangle-based shapes: four corners (free, both
    /// axes) and four edge midpoints (single axis, e.g. stretch a triangle wider).
    private enum BoxHandle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private var boxDrag: (shape: TwoPointAnnotation, handle: BoxHandle)?

    private var editingOverlay: ImageOverlayAnnotation?
    private enum OverlayDrag { case none, move, resize }
    private var overlayDrag: OverlayDrag = .none
    private var overlayDragOffset: CGPoint = .zero
    /// Which of the eight box knobs the current overlay resize is dragging.
    private var overlayHandle: BoxHandle = .bottomRight
    var onOverlaySelected: ((ImageOverlayAnnotation?) -> Void)?
    var onPaste: (() -> Void)?

    private enum MeasureAxis { case none, vertical, horizontal }
    private var measureAxis: MeasureAxis = .none
    private var measureAnchor: CGPoint?
    private var lastMousePoint: CGPoint = .zero
    /// The capture's Retina factor — device pixels per image point.
    private var pixelsPerPoint: CGFloat {
        guard let b = bitmap, image.size.width > 0 else { return 1 }
        return CGFloat(b.pixelsWide) / image.size.width
    }
    /// The current measurement's far endpoint, locked to the active axis.
    private func measureEnd(at p: CGPoint, from a: CGPoint) -> CGPoint {
        measureAxis == .vertical ? CGPoint(x: a.x, y: p.y) : CGPoint(x: p.x, y: a.y)
    }

    private var selected: Annotation?
    private enum SelectDrag { case none, move, resize }
    private var selectDrag: SelectDrag = .none
    private var dragAnchor: CGPoint = .zero
    private var lastDragPoint: CGPoint = .zero

    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var live: Annotation?
    private var counter = 0
    var counterFormat: CounterFormat = .number {
        didSet { if counterFormat != oldValue { counter = 0 } }
    }
    var currentEmoji = "⭐️"

    private var textView: AnnotationTextView?
    private var textImageFont: CGFloat = 18
    /// Current text style for *new* text marks — independent of the stroke width (text
    /// used to borrow its size from it). The format popover drives these; re-editing an
    /// existing mark loads its values here so a commit preserves them.
    var textFontSize: CGFloat = 36
    var textFontName: String?          // nil = system font
    var textBold = false
    var textAlignment: NSTextAlignment = .left
    var textBackground: TextBackground = .none
    /// Chip color behind the text when `textBackground` isn't `.none`; a translucent dark
    /// default reads as a caption highlight behind bright text (kept distinct from the
    /// text color so a filled chip never hides its own text).
    var textBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.55)
    /// Called whenever the text style/selection changes so the editor can refresh the
    /// contextual format popover's controls.
    var onTextStyleChange: (() -> Void)?
    /// While editing an existing mark, the wrap width is locked to its original so
    /// the text keeps wrapping the same way; nil lets a new field grow to fit.
    private var textLockedWidth: CGFloat?
    /// A committed text mark that stays selected under the Text tool, so it can be
    /// moved and resized in place (box + corner knob) without the Select tool.
    private var editingText: TextAnnotation?
    private enum TextDrag { case none, move, resize }
    private var textDrag: TextDrag = .none
    private var textDragOffset: CGPoint = .zero
    /// A text box being resized by one of its eight handles (shared by the Text tool's
    /// in-place box and the Select tool): edge handles reflow width/height, corner handles
    /// scale the font.
    private var textBoxDrag: (mark: TextAnnotation, handle: BoxHandle)?

    private var bitmap: NSBitmapImageRep?
    private func rebuildBitmap() {
        bitmap = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
    }

    init(image: NSImage, displayScale: CGFloat) {
        self.image = image
        self.displayScale = displayScale
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: image.size.width * displayScale,
                                 height: image.size.height * displayScale))
        wantsLayer = true
        rebuildBitmap()
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textView == nil,
           event.modifierFlags.intersection([.command, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            onPaste?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether a text annotation is being edited (a field editor is up). The editor's
    /// paste fallback checks this so ⌘V goes to the text, not a new image overlay.
    var isEditingText: Bool { textView != nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        CanvasView.cgImage(from: sender.draggingPasteboard) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let cg = CanvasView.cgImage(from: sender.draggingPasteboard) else { return false }
        let v = convert(sender.draggingLocation, from: nil)
        return insertOverlay(cg, at: CGPoint(x: v.x / displayScale, y: v.y / displayScale))
    }

    /// Read an image off a pasteboard — either image data (clipboard, dragged
    /// image) or an image file URL (Finder drag). Returns nil if there's no image.
    static func cgImage(from pb: NSPasteboard) -> CGImage? {
        // Prefer an actual image file: Finder copies an image as a file URL *plus* a small
        // icon/thumbnail TIFF, so reading image data first would paste the icon, not the
        // picture. Fall back to raw image data for app-copied images (and dragged images
        // that carry no file URL).
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: ["public.image"]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    /// Insert `cg` as a movable overlay, centered at `center` (image space, or the
    /// image center) and scaled so its larger side is ~⅓ of the capture (never
    /// upscaled past native). Auto-selects it so it can be moved/resized at once.
    @discardableResult
    func insertOverlay(_ cg: CGImage, at center: CGPoint? = nil) -> Bool {
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0 else { return false }
        let target = max(image.size.width, image.size.height) / 3
        let scale = min(1, target / max(iw, ih))
        let w = iw * scale, h = ih * scale
        let c = center ?? CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        r.origin.x = min(max(0, r.origin.x), max(0, image.size.width - w))
        r.origin.y = min(max(0, r.origin.y), max(0, image.size.height - h))
        let a = ImageOverlayAnnotation(image: cg, rect: r)
        annotations.append(a); redoStack.removeAll()
        tool = .overlay
        editingOverlay = a
        onOverlaySelected?(a)
        onChange?(); needsDisplay = true
        return true
    }

    var hasOverlays: Bool { annotations.contains { $0 is ImageOverlayAnnotation } }

    /// Insert clipboard text as a new text mark centered on the canvas, using the current
    /// text style, then leave it selected under the Text tool for immediate move/resize.
    @discardableResult
    func insertTextBox(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        commitText()
        let size = textFontSize
        let font = editorFont(screenSize: size)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping; para.alignment = textAlignment
        let measured = NSAttributedString(string: trimmed, attributes: [.font: font, .paragraphStyle: para])
        let cap = max(60, image.size.width * 0.6)
        let w = min(max(40, ceil(measured.size().width) + 16), cap)
        let textH = ceil(measured.boundingRect(
            with: CGSize(width: w, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let pad = textBackground == .none ? 0 : size * 0.28
        let boxW = w + pad * 2, boxH = textH + pad * 2
        let origin = CGPoint(x: max(0, (image.size.width - boxW) / 2),
                             y: max(0, (image.size.height - boxH) / 2))
        let attr = NSAttributedString(string: trimmed, attributes: [.foregroundColor: style.color])
        let mark = TextAnnotation(attributed: attr, origin: origin, fontSize: size,
                                  maxWidth: boxW, boxHeight: boxH,
                                  fontName: textFontName, bold: textBold,
                                  alignment: textAlignment, background: textBackground,
                                  backgroundColor: textBackgroundColor)
        annotations.append(mark); redoStack.removeAll()
        tool = .text
        editingText = mark
        onChange?(); needsDisplay = true
        onTextStyleChange?()
        return true
    }

    /// Set the opacity (0–1) of the currently selected overlay (slider drives this).
    func setSelectedOverlayOpacity(_ value: CGFloat) {
        guard let eo = editingOverlay else { return }
        eo.opacity = max(0, min(1, value))
        needsDisplay = true
    }
    /// The pointer cursor for the current tool — a mesoneer-styled glyph matching the
    /// active tool (pencil, shapes, text, …) instead of a bare crosshair. `select`
    /// falls back to the arrow (its hover states are handled in `mouseMoved`).
    private var toolCursor: NSCursor {
        guard let name = Self.symbolName(for: tool) else { return .arrow }
        return Self.brandCursor(named: name, tipHotspot: Self.usesTipHotspot(tool))
    }

    /// Tools whose "point" is at the glyph's lower-left tip rather than its centre.
    private static func usesTipHotspot(_ tool: Tool) -> Bool {
        switch tool {
        case .pencil, .marker, .eraser, .eyedropper: return true
        default: return false
        }
    }

    /// The Shapes tool group — a plain click (no drag) with one of these should still
    /// place a visible, default-sized shape rather than a degenerate zero-size one.
    private static func isShapeTool(_ tool: Tool) -> Bool {
        switch tool {
        case .rect, .roundedRect, .ellipse, .triangle, .diamond, .star,
             .checkmark, .pentagon, .hexagon, .octagon: return true
        default: return false
        }
    }

    /// SF Symbol name representing each tool's cursor. The shape family plus line and
    /// arrow share one precise crosshair glyph — a miniature shape/line outline reads as
    /// an indistinguishable purple blob at cursor size and hides the exact drag-start
    /// point, whereas a crosshair marks that point cleanly for dragging the mark out.
    /// `nil` → no glyph (use arrow). Unavailable names fall back to the crosshair.
    private static func symbolName(for tool: Tool) -> String? {
        switch tool {
        case .pencil:      return "pencil"
        case .marker:      return "highlighter"
        // Drag-to-define tools — shapes, line/arrow, and the blur / spotlight region
        // drags — all share the precise crosshair: a filled glyph sits as an opaque
        // blob over the exact start point you're aiming at.
        case .line, .arrow, .rect, .roundedRect, .ellipse, .triangle, .diamond,
             .star, .checkmark, .pentagon, .hexagon, .octagon,
             .blur, .spotlight: return "plus"
        case .text:        return "character.textbox"
        case .counter:     return "number.circle.fill"
        case .eyedropper:  return "eyedropper.full"
        case .eraser:      return "eraser.fill"
        case .crop:        return "crop"
        case .ocr:         return "text.viewfinder"
        case .zoom:        return "plus.magnifyingglass"
        case .emoji:       return "face.smiling.inverse"
        case .overlay:     return "photo.fill"
        case .ruler:       return "ruler.fill"
        case .select:      return nil
        }
    }

    private static var cursorCache: [String: NSCursor] = [:]

    /// A mesoneer-styled tool cursor: the brand-purple glyph with a soft white halo for
    /// contrast — no background chip. Cached per glyph.
    private static func brandCursor(named name: String, tipHotspot: Bool) -> NSCursor {
        let key = "\(name)#\(tipHotspot)"
        if let c = cursorCache[key] { return c }
        guard let cursor = BrandCursor.make(symbol: name, tipHotspot: tipHotspot) else { return .crosshair }
        cursorCache[key] = cursor
        return cursor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: toolCursor) }

    /// Assert the tool cursor whenever the pointer is over the canvas — this also
    /// overrides any capture-overlay cursor (camera/video) that would otherwise linger
    /// into the freshly opened editor for window/screen captures.
    override func cursorUpdate(with event: NSEvent) { toolCursor.set() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { toolCursor.set() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        if let hit = window?.contentView?.hitTest(event.locationInWindow), hit !== self {
            return
        }
        lastMousePoint = imagePoint(event)
        if tool == .ruler, measureAxis != .none { needsDisplay = true }
        if tool == .zoom, let ez = editingZoom {
            let p = imagePoint(event), hr = 12 / displayScale
            let knob = CGPoint(x: ez.dest.maxX, y: ez.dest.minY)
            if hypot(knob.x - p.x, knob.y - p.y) < hr || ez.dest.contains(p) {
                NSCursor.openHand.set(); return
            }
        }
        if tool == .overlay, let eo = editingOverlay {
            let p = imagePoint(event)
            if let h = boxHandle(inRect: eo.rect, at: p) {
                boxCursor(h).set(); return
            }
            if eo.rect.contains(p) { NSCursor.openHand.set(); return }
        }
        if tool == .text, textView == nil, let t = editingText {
            let p = imagePoint(event)
            if let h = boxHandle(inRect: t.bounds, at: p) { boxCursor(h).set(); return }
            if t.bounds.contains(p) { NSCursor.pointingHand.set(); return }
        }
        if tool == .arrow || tool == .line, let ec = editingCurve,
           curveHandle(ec, at: imagePoint(event)) != nil {
            NSCursor.openHand.set(); return
        }
        if Self.isShapeTool(tool), let es = editingShape {
            let p = imagePoint(event)
            if let h = boxHandle(for: es, at: p) { boxCursor(h).set(); return }
            if es.hit(p) { NSCursor.openHand.set(); return }
        }
        if tool == .select {
            let p = imagePoint(event)
            if let c = selected as? CurvedAnnotation, curveHandle(c, at: p) != nil {
                NSCursor.openHand.set(); return
            }
            if let sh = selected as? TwoPointAnnotation, let h = boxHandle(for: sh, at: p) {
                boxCursor(h).set(); return
            }
            if let t = selected as? TextAnnotation, let h = boxHandle(inRect: t.bounds, at: p) {
                boxCursor(h).set(); return
            }
            if let s = selected, resizeAnchor(for: s, at: p) != nil {
                NSCursor.openHand.set(); return
            }
            (annotations.contains { $0.hit(p) } ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        toolCursor.set()
    }

    override func keyDown(with event: NSEvent) {
        if tool == .ruler {
            switch event.keyCode {
            case 126, 125:
                measureAxis = .vertical; measureAnchor = lastMousePoint; needsDisplay = true; return
            case 123, 124:
                measureAxis = .horizontal; measureAnchor = lastMousePoint; needsDisplay = true; return
            case 53 where measureAxis != .none:
                measureAxis = .none; measureAnchor = nil; needsDisplay = true; return
            default: break
            }
        }
        if event.keyCode == 53 { onCancel?(); return }
        if pendingCrop != nil, event.keyCode == 36 || event.keyCode == 76 {
            onCropConfirm?(); return
        }
        if tool == .select, let s = selected, event.keyCode == 51 || event.keyCode == 117 {
            if let idx = annotations.firstIndex(where: { $0 === s }) { annotations.remove(at: idx) }
            selected = nil; selectDrag = .none; redoStack.removeAll(); onChange?(); needsDisplay = true
            return
        }
        // Backspace/Delete also removes a just-drawn shape or arrow/line still showing
        // its handles under its own tool — the instinctive "undo that mark" gesture.
        if event.keyCode == 51 || event.keyCode == 117 {
            let live: Annotation? = Self.isShapeTool(tool) ? editingShape
                : ((tool == .arrow || tool == .line) ? editingCurve : nil)
            if let m = live {
                if let idx = annotations.firstIndex(where: { $0 === m }) { annotations.remove(at: idx) }
                editingShape = nil; editingShapeTool = nil; editingCurve = nil
                curveDrag = nil; boxDrag = nil
                redoStack.removeAll(); onChange?(); needsDisplay = true
                return
            }
        }
        if tool == .text, textView == nil, let t = editingText, event.keyCode == 51 || event.keyCode == 117 {
            if let idx = annotations.firstIndex(where: { $0 === t }) { annotations.remove(at: idx) }
            editingText = nil; textDrag = .none; redoStack.removeAll(); onChange?(); needsDisplay = true
            return
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased(), !c.isEmpty {
            onShortcut?(c)
        } else {
            super.keyDown(with: event)
        }
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / displayScale, y: v.y / displayScale)
    }

    override func mouseDown(with event: NSEvent) {
        let didCommit = commitText()
        let p = imagePoint(event)
        // A shape tool keeps its last shape live: grab a corner to resize it or its
        // body to move it, exactly like the Select tool, without leaving the tool.
        if Self.isShapeTool(tool), let es = editingShape {
            if let h = boxHandle(for: es, at: p) {
                boxDrag = (es, h); lastDragPoint = p
                boxCursor(h).push(); needsDisplay = true; return
            }
            if es.hit(p) {
                selected = es; selectDrag = .move; lastDragPoint = p
                NSCursor.closedHand.push(); needsDisplay = true; return
            }
            editingShape = nil; editingShapeTool = nil   // clicked away → start a fresh shape
        }
        switch tool {
        case .pencil:  let a = PencilAnnotation(style: style); a.add(p); live = a
        case .marker:  let a = MarkerAnnotation(style: style); a.add(p); live = a
        case .line, .arrow:
            if let ec = editingCurve, let h = curveHandle(ec, at: p) {
                curveDrag = (ec, h); NSCursor.closedHand.push()
            } else {
                editingCurve = nil
                live = tool == .arrow ? CurvedArrowAnnotation(start: p, style: style)
                                      : CurvedLineAnnotation(start: p, style: style)
            }
        case .rect:    live = RectAnnotation(start: p, style: style)
        case .ellipse: live = EllipseAnnotation(start: p, style: style)
        case .triangle:    live = TriangleAnnotation(start: p, style: style)
        case .diamond:     live = DiamondAnnotation(start: p, style: style)
        case .star:        live = StarAnnotation(start: p, style: style)
        case .roundedRect: live = RoundedRectAnnotation(start: p, style: style)
        case .checkmark:   live = CheckmarkAnnotation(start: p, style: style)
        case .pentagon:    live = PentagonAnnotation(start: p, style: style)
        case .hexagon:     live = HexagonAnnotation(start: p, style: style)
        case .octagon:     live = OctagonAnnotation(start: p, style: style)
        case .blur:    live = BlurAnnotation(start: p, style: style)
        case .spotlight:
            let a = SpotlightAnnotation(start: p, style: style); a.fullSize = image.size; live = a
        case .counter:
            let r = max(12, style.lineWidth * 3)
            live = CounterAnnotation(center: p, label: counterFormat.label(counter + 1),
                                     color: style.color, radius: r)
        case .text:
            if event.clickCount >= 2, let hit = annotations.reversed()
                .first(where: { ($0 as? TextAnnotation)?.hit(p) ?? false }) as? TextAnnotation {
                beginEditing(hit)
            } else if let t = editingText, let h = boxHandle(inRect: t.bounds, at: p) {
                textBoxDrag = (t, h); lastDragPoint = p; boxCursor(h).push()
            } else if let hit = annotations.reversed()
                .first(where: { ($0 as? TextAnnotation)?.hit(p) ?? false }) as? TextAnnotation {
                editingText = hit
                textDrag = .move
                textDragOffset = CGPoint(x: p.x - hit.origin.x, y: p.y - hit.origin.y)
                NSCursor.closedHand.push()
            } else if didCommit {
                // Clicking away finished typing: keep the box shown for resizing,
                // rather than immediately opening a fresh field.
            } else {
                editingText = nil
                beginTextEditing(viewPoint: convert(event.locationInWindow, from: nil))
            }
        case .eyedropper:
            if let c = sample(p) { style.color = c; onColorPicked?(c) }
        case .eraser:
            if let idx = annotations.lastIndex(where: { $0.hit(p) }) {
                annotations.remove(at: idx); redoStack.removeAll(); onChange?()
            }
        case .crop:
            cropStart = p
            pendingCrop = CGRect(origin: p, size: .zero)
            onCropBegin?()
        case .ocr:
            ocrStart = p
            ocrRect = CGRect(origin: p, size: .zero)
        case .zoom:
            if let ez = editingZoom {
                let hr = 12 / displayScale
                let knob = CGPoint(x: ez.dest.maxX, y: ez.dest.minY)
                if hypot(knob.x - p.x, knob.y - p.y) < hr {
                    zoomDrag = .resize; NSCursor.closedHand.push()
                } else if ez.dest.contains(p) {
                    zoomDrag = .move
                    zoomDragOffset = CGPoint(x: p.x - ez.dest.minX, y: p.y - ez.dest.minY)
                    NSCursor.closedHand.push()
                } else {
                    editingZoom = nil; zoomStart = p; zoomRect = CGRect(origin: p, size: .zero)
                }
            } else {
                zoomStart = p; zoomRect = CGRect(origin: p, size: .zero)
            }
        case .emoji:
            live = EmojiAnnotation(center: p, emoji: currentEmoji, size: 54)
        case .overlay:
            if let eo = editingOverlay, let h = boxHandle(inRect: eo.rect, at: p) {
                overlayDrag = .resize; overlayHandle = h; boxCursor(h).push()
            } else if let eo = editingOverlay, eo.rect.contains(p) {
                overlayDrag = .move
                overlayDragOffset = CGPoint(x: p.x - eo.rect.minX, y: p.y - eo.rect.minY)
                NSCursor.closedHand.push()
            } else {
                let hit = annotations.reversed().first { ($0 as? ImageOverlayAnnotation)?.rect.contains(p) ?? false }
                editingOverlay = hit as? ImageOverlayAnnotation
                onOverlaySelected?(editingOverlay)
            }
        case .select:
            if event.clickCount >= 2, let hit = annotations.reversed()
                .first(where: { ($0 as? TextAnnotation)?.hit(p) ?? false }) as? TextAnnotation {
                beginEditing(hit)
            } else if let c = selected as? CurvedAnnotation, let h = curveHandle(c, at: p) {
                curveDrag = (c, h); NSCursor.closedHand.push()
            } else if let sh = selected as? TwoPointAnnotation, let h = boxHandle(for: sh, at: p) {
                boxDrag = (sh, h); lastDragPoint = p; boxCursor(h).push()
            } else if let t = selected as? TextAnnotation, let h = boxHandle(inRect: t.bounds, at: p) {
                textBoxDrag = (t, h); lastDragPoint = p; boxCursor(h).push()
            } else if let s = selected, let anchor = resizeAnchor(for: s, at: p) {
                selectDrag = .resize
                dragAnchor = anchor
                lastDragPoint = p
                NSCursor.closedHand.push()
            } else if let hit = annotations.reversed().first(where: { $0.hit(p) }) {
                selected = hit
                selectDrag = .move
                lastDragPoint = p
                NSCursor.closedHand.push()
            } else {
                selected = nil
                selectDrag = .none
            }
        case .ruler:
            if measureAxis != .none, let a = measureAnchor {
                let end = measureEnd(at: p, from: a)
                if hypot(end.x - a.x, end.y - a.y) >= 2 {
                    annotations.append(MeasureAnnotation(start: a, end: end, style: style))
                    redoStack.removeAll(); onChange?()
                }
                measureAnchor = p
            }
        }
        needsDisplay = true
        onTextStyleChange?()   // refresh the contextual text popover after any selection change
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if tool == .ruler {
            lastMousePoint = p
            if measureAxis != .none { needsDisplay = true }
            return
        }
        if let cd = curveDrag {
            switch cd.handle {
            case .start: cd.curve.start = p
            case .end:   cd.curve.end = p
            case .apex:  cd.curve.bend(through: p)
            }
            needsDisplay = true; return
        }
        if let bd = boxDrag {
            resizeBox(bd.shape, handle: bd.handle, to: p); needsDisplay = true; return
        }
        if zoomDrag == .move, let ez = editingZoom {
            ez.dest.origin = CGPoint(x: p.x - zoomDragOffset.x, y: p.y - zoomDragOffset.y)
            needsDisplay = true; return
        }
        if zoomDrag == .resize, let ez = editingZoom {
            let anchorX = ez.dest.minX, top = ez.dest.maxY
            let newW = max(24 / displayScale, p.x - anchorX)
            let newH = newW * (ez.source.height / max(1, ez.source.width))
            ez.dest = CGRect(x: anchorX, y: top - newH, width: newW, height: newH)
            needsDisplay = true; return
        }
        if overlayDrag == .move, let eo = editingOverlay {
            eo.rect.origin = CGPoint(x: p.x - overlayDragOffset.x, y: p.y - overlayDragOffset.y)
            needsDisplay = true; return
        }
        if overlayDrag == .resize, let eo = editingOverlay {
            eo.rect = resizeRect(eo.rect, handle: overlayHandle, to: p, min: 24 / displayScale)
            needsDisplay = true; return
        }
        if let td = textBoxDrag {
            resizeTextBox(td.mark, handle: td.handle, to: p)
            needsDisplay = true; return
        }
        if textDrag == .move, let t = editingText {
            t.origin = CGPoint(x: p.x - textDragOffset.x, y: p.y - textDragOffset.y)
            needsDisplay = true; return
        }
        if selectDrag == .move, let s = selected {
            let dx = p.x - lastDragPoint.x, dy = p.y - lastDragPoint.y
            s.remap { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            lastDragPoint = p; needsDisplay = true; return
        }
        if selectDrag == .resize, let s = selected {
            let prev = hypot(lastDragPoint.x - dragAnchor.x, lastDragPoint.y - dragAnchor.y)
            let cur = hypot(p.x - dragAnchor.x, p.y - dragAnchor.y)
            if prev > 0.5 {
                let f = cur / prev
                let b = s.bounds
                let minSide = 8 / displayScale
                if f >= 1 || (b.width * f >= minSide && b.height * f >= minSide) {
                    s.scale(by: f, around: dragAnchor)
                    lastDragPoint = p
                }
            }
            needsDisplay = true; return
        }
        if tool == .zoom, let s = zoomStart {
            zoomRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                              width: abs(s.x - p.x), height: abs(s.y - p.y))
            needsDisplay = true
            return
        }
        if tool == .crop, let s = cropStart {
            pendingCrop = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                                 width: abs(s.x - p.x), height: abs(s.y - p.y))
            needsDisplay = true
            return
        }
        if tool == .ocr, let s = ocrStart {
            ocrRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(s.x - p.x), height: abs(s.y - p.y))
            needsDisplay = true
            return
        }
        if let a = live as? FreehandAnnotation { a.add(p) }
        else if let a = live as? CurvedAnnotation { a.end = p; a.straighten() }
        else if let a = live as? TwoPointAnnotation { a.end = p }
        else if let a = live as? CounterAnnotation { a.center = p }
        else if let a = live as? EmojiAnnotation {
            a.size = max(24, hypot(p.x - a.center.x, p.y - a.center.y) * 1.8)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if curveDrag != nil {
            curveDrag = nil
            NSCursor.pop()   // matches the closedHand push on handle grab
            onChange?(); needsDisplay = true; return
        }
        if let bd = boxDrag {
            if let b = bd.shape as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
            boxDrag = nil
            NSCursor.pop()   // matches the resize-cursor push on knob grab
            onChange?(); needsDisplay = true; return
        }
        if textBoxDrag != nil {
            textBoxDrag = nil; NSCursor.pop(); onChange?(); needsDisplay = true; return
        }
        if textDrag != .none {
            textDrag = .none; NSCursor.pop(); onChange?(); needsDisplay = true; return
        }
        if zoomDrag != .none {
            zoomDrag = .none; NSCursor.pop(); onChange?(); needsDisplay = true; return
        }
        if overlayDrag != .none {
            overlayDrag = .none; NSCursor.pop()
            onOverlaySelected?(editingOverlay)
            onChange?(); needsDisplay = true; return
        }
        if selectDrag != .none {
            if let b = selected as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
            if let z = selected as? ZoomAnnotation { z.patch = croppedCGImage(rect: z.source) }
            selectDrag = .none; NSCursor.pop()
            onChange?(); needsDisplay = true; return
        }
        if tool == .zoom {
            zoomStart = nil
            if let s = zoomRect, s.width >= 8, s.height >= 8 {
                let dest = zoomDestination(for: s)
                let z = ZoomAnnotation(source: s, dest: dest, patch: croppedCGImage(rect: s), style: style)
                annotations.append(z); redoStack.removeAll(); editingZoom = z; onChange?()
            }
            zoomRect = nil; needsDisplay = true; return
        }
        if tool == .crop {
            cropStart = nil
            if let pc = pendingCrop, pc.width >= 5, pc.height >= 5 {
                onCropReady?()
            } else {
                pendingCrop = nil; onCropBegin?()
            }
            needsDisplay = true
            return
        }
        if tool == .ocr {
            ocrStart = nil
            if let r = ocrRect, r.width >= 5, r.height >= 5, let cg = croppedCGImage(rect: r) {
                onOCR?(cg)
            }
            ocrRect = nil
            needsDisplay = true
            return
        }
        if Self.isShapeTool(tool), let a = live as? TwoPointAnnotation {
            let minSide = 6 / displayScale
            if a.rect.width < minSide, a.rect.height < minSide {
                let side = 90 / displayScale, half = side / 2
                let center = a.start
                a.start = CGPoint(x: center.x - half, y: center.y - half)
                a.end = CGPoint(x: center.x + half, y: center.y + half)
            }
        }
        if tool == .line || tool == .arrow, let a = live as? CurvedAnnotation {
            let minSide = 6 / displayScale
            if abs(a.end.x - a.start.x) < minSide, abs(a.end.y - a.start.y) < minSide {
                let side = 70 / displayScale
                a.end = CGPoint(x: a.start.x + side, y: a.start.y + side)
                a.straighten()
            }
        }
        // Spotlight is drag-only: a click (no real dragged area) shouldn't dim the
        // whole shot around a zero-size hole, so discard it below the drag threshold.
        if tool == .spotlight, let a = live as? SpotlightAnnotation {
            let minSide = 8 / displayScale
            if a.rect.width < minSide || a.rect.height < minSide {
                live = nil; needsDisplay = true; return
            }
        }
        if let b = live as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
        if let a = live {
            annotations.append(a)
            if a is CounterAnnotation { counter += 1 }
            if let cc = a as? CurvedAnnotation { editingCurve = cc }
            if Self.isShapeTool(tool), let sh = a as? TwoPointAnnotation {
                editingShape = sh; editingShapeTool = tool
            }
            redoStack.removeAll()
            live = nil
            onChange?()
            // Stamps (emoji / counter) have no in-place edit mode of their own, so drop
            // straight into Select with the new stamp selected — its resize handles show
            // at once and it can be sized/moved without hunting for the Select tool.
            if a is EmojiAnnotation || a is CounterAnnotation {
                tool = .select
                selected = a
            }
        }
        needsDisplay = true
    }

    /// Where the enlarged bubble goes for a zoom callout: ~2.5× the source,
    /// placed beside it (right, else left) and clamped inside the image.
    private func zoomDestination(for src: CGRect) -> CGRect {
        let W = image.size.width, H = image.size.height
        var mag: CGFloat = 2.5
        mag = min(mag, (W * 0.6) / max(1, src.width), (H * 0.6) / max(1, src.height))
        mag = max(1.5, mag)
        let dw = src.width * mag, dh = src.height * mag
        let gap: CGFloat = 24
        var dx = src.maxX + gap
        if dx + dw > W { dx = src.minX - gap - dw }
        dx = max(0, min(W - dw, dx))
        let dy = max(0, min(H - dh, src.midY - dh / 2))
        return CGRect(x: dx, y: dy, width: dw, height: dh)
    }

    /// Snapshot the editor's rich text as characters + per-range foreground colors
    /// (the font is dropped — the annotation re-applies its own uniformly at draw).
    /// Any range with no explicit color falls back to the current draw color.
    private func capturedText(from tv: NSTextView) -> NSAttributedString {
        let src: NSAttributedString = tv.textStorage ?? NSAttributedString(string: tv.string)
        let out = NSMutableAttributedString(string: src.string)
        let full = NSRange(location: 0, length: out.length)
        guard full.length > 0 else { return out }
        out.addAttribute(.foregroundColor, value: style.color, range: full)
        src.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor, NSMaxRange(range) <= out.length {
                out.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return out
    }

    /// A borderless, transparent, brand-bordered text view for typing/editing an
    /// annotation. A real `NSTextView` (not `NSTextField`) so it holds per-range
    /// colors and honors `typingAttributes` — text typed after a color change takes
    /// the new color while earlier text keeps its own.
    private func makeTextView(frame: NSRect, font: NSFont, color: NSColor) -> AnnotationTextView {
        let tv = AnnotationTextView(frame: frame)
        tv.isRichText = true
        // A dark translucent backing while editing: the caret and white placeholder are
        // otherwise invisible over a bright capture. It's just an editing affordance — the
        // committed mark keeps whatever background style the user chose (usually none).
        tv.drawsBackground = true
        tv.backgroundColor = Theme.surfaceBase.withAlphaComponent(0.72)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = NSSize(width: 4, height: 3)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = true
        tv.font = font
        tv.textColor = color
        tv.insertionPointColor = Theme.lavender
        tv.typingAttributes = [.font: font, .foregroundColor: color]
        tv.colorForNewText = { [weak self] in self?.style.color ?? color }
        tv.delegate = self
        tv.wantsLayer = true
        tv.layer?.borderColor = Theme.lavender.cgColor
        tv.layer?.borderWidth = 1.5
        tv.layer?.cornerRadius = 4
        return tv
    }

    /// The editor font at a given on-screen point size, honoring the current family and
    /// bold flag — mirrors `TextAnnotation.font` so the live editor matches the commit.
    private func editorFont(screenSize: CGFloat) -> NSFont {
        resolveTextFont(textFontName, size: screenSize, bold: textBold)
    }

    private func beginTextEditing(viewPoint: CGPoint) {
        let screenFont = textFontSize * displayScale
        let h = screenFont + 8
        let tv = makeTextView(frame: NSRect(x: viewPoint.x, y: viewPoint.y - h, width: 120, height: h),
                              font: editorFont(screenSize: screenFont), color: style.color)
        tv.alignment = textAlignment
        addSubview(tv)
        window?.makeFirstResponder(tv)
        textView = tv
        textImageFont = textFontSize
        textLockedWidth = nil
        fitTextView(tv)
        onTextStyleChange?()
    }

    /// Re-open the editor on an existing text mark (double-click) pre-filled with
    /// its wording; the mark is lifted out and re-committed when editing finishes.
    private func beginEditing(_ mark: TextAnnotation) {
        editingText = nil; selected = nil; selectDrag = .none; textDrag = .none
        if let idx = annotations.firstIndex(where: { $0 === mark }) { annotations.remove(at: idx) }
        // Load the mark's style so the format popover reflects it and a commit preserves it.
        textFontSize = mark.fontSize
        textFontName = mark.fontName; textBold = mark.bold
        textAlignment = mark.alignment; textBackground = mark.background
        textBackgroundColor = mark.backgroundColor
        let scale = displayScale
        let frame = NSRect(x: mark.origin.x * scale, y: mark.origin.y * scale,
                           width: mark.maxWidth * scale, height: mark.boxHeight * scale)
        let screenFont = editorFont(screenSize: mark.fontSize * scale)
        let baseColor = (mark.attributed.length > 0
            ? mark.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : nil) ?? style.color
        let tv = makeTextView(frame: frame, font: screenFont, color: baseColor)
        tv.alignment = mark.alignment
        // Restore the rich text at screen scale, keeping each range's color.
        let rich = NSMutableAttributedString(attributedString: mark.attributed)
        rich.addAttribute(.font, value: screenFont, range: NSRange(location: 0, length: rich.length))
        tv.textStorage?.setAttributedString(rich)
        addSubview(tv)
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        textView = tv
        textImageFont = mark.fontSize
        textLockedWidth = mark.maxWidth * scale
        fitTextView(tv)
        redoStack.removeAll(); onChange?(); needsDisplay = true
        onTextStyleChange?()
    }

    func textDidChange(_ notification: Notification) {
        if let tv = textView { fitTextView(tv) }
    }

    /// Return commits; Shift-Return inserts a line break; Esc commits too (matching
    /// clicking away). Anything else falls through to normal text editing.
    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    /// Size the live editor to its content, capped at the canvas edge, so long text
    /// wraps onto more lines (the box grows downward) instead of clipping. Mirrors
    /// `TextAnnotation`'s own height math so the box matches the committed mark.
    private func fitTextView(_ tv: AnnotationTextView) {
        let shown = tv.string.isEmpty ? tv.placeholder : tv.string
        let font = tv.font ?? .systemFont(ofSize: 14)
        let cap = max(120, bounds.width - tv.frame.minX - 8)
        let width: CGFloat
        if let locked = textLockedWidth {
            width = min(locked, cap)
        } else {
            let natural = ceil(NSAttributedString(string: shown, attributes: [.font: font]).size().width) + 16
            width = min(natural, cap)
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        let measured = NSAttributedString(string: shown, attributes: [.font: font, .paragraphStyle: para])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        // Add the container inset so the caret/text/backing aren't clipped by it.
        let inset = tv.textContainerInset
        let height = ceil(max(font.ascender - font.descender, measured)) + inset.height * 2
        let top = tv.frame.maxY
        tv.frame = NSRect(x: tv.frame.minX, y: top - height, width: width + inset.width * 2, height: height)
    }

    @discardableResult
    private func commitText() -> Bool {
        guard let tv = textView else { return false }
        let attributed = capturedText(from: tv)
        let f = tv.frame
        textView = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !attributed.string.isEmpty else { return false }
        let origin = CGPoint(x: f.minX / displayScale, y: f.minY / displayScale)
        let mark = TextAnnotation(attributed: attributed, origin: origin, fontSize: textImageFont,
                                  maxWidth: f.width / displayScale,
                                  boxHeight: f.height / displayScale,
                                  fontName: textFontName, bold: textBold,
                                  alignment: textAlignment, background: textBackground,
                                  backgroundColor: textBackgroundColor)
        annotations.append(mark)
        editingText = mark
        redoStack.removeAll(); onChange?()
        needsDisplay = true
        return true
    }

    /// The text mark the format controls act on when not actively typing: the just-placed
    /// mark under the Text tool, or a text mark chosen with the Select tool.
    private var targetTextMark: TextAnnotation? { editingText ?? (selected as? TextAnnotation) }

    /// True when a text box is being typed into or a text mark is the current target, so
    /// the editor knows whether to surface the format popover.
    var hasTextFocus: Bool { textView != nil || targetTextMark != nil }

    /// Image-space bounds of the current text target, for positioning the format popover.
    var textFocusRect: CGRect? {
        if let tv = textView {
            return CGRect(x: tv.frame.minX / displayScale, y: tv.frame.minY / displayScale,
                          width: tv.frame.width / displayScale, height: tv.frame.height / displayScale)
        }
        return targetTextMark?.bounds
    }

    /// The current text style, so the format popover can reflect it.
    var currentTextStyle: (size: CGFloat, fontName: String?, bold: Bool,
                           alignment: NSTextAlignment, background: TextBackground) {
        (textFontSize, textFontName, textBold, textAlignment, textBackground)
    }

    // MARK: Text format setters (driven by the contextual popover)

    func setTextFontSize(_ size: CGFloat) { textFontSize = max(6, size); applyFontStyle() }
    func setTextFontName(_ name: String?) { textFontName = name; applyFontStyle() }
    func setTextBold(_ on: Bool) { textBold = on; applyFontStyle() }
    func setTextAlignment(_ a: NSTextAlignment) { textAlignment = a; applyFontStyle() }
    func setTextBackground(_ b: TextBackground) { textBackground = b; applyBackgroundStyle() }
    func setTextBackgroundColor(_ c: NSColor) { textBackgroundColor = c; applyBackgroundStyle() }

    /// Apply font family/size/weight/alignment to the live editor (reflowing it) or, when
    /// not typing, to the target text mark (scaling its box with the size change).
    private func applyFontStyle() {
        if let tv = textView {
            let font = editorFont(screenSize: textFontSize * displayScale)
            tv.font = font
            tv.alignment = textAlignment
            tv.typingAttributes[.font] = font
            if let store = tv.textStorage, store.length > 0 {
                store.addAttribute(.font, value: font, range: NSRange(location: 0, length: store.length))
            }
            textImageFont = textFontSize
            fitTextView(tv)
        } else if let m = targetTextMark {
            let ratio = m.fontSize > 0 ? textFontSize / m.fontSize : 1
            m.fontSize = textFontSize
            m.maxWidth *= ratio; m.boxHeight *= ratio
            m.fontName = textFontName; m.bold = textBold; m.alignment = textAlignment
            onChange?()
        }
        needsDisplay = true
    }

    /// Background chip has no live editor equivalent (the NSTextView stays clear); it
    /// applies to the target mark now and to a live edit on commit.
    private func applyBackgroundStyle() {
        if let m = targetTextMark {
            m.background = textBackground; m.backgroundColor = textBackgroundColor
            onChange?()
        }
        needsDisplay = true
    }

    private func sample(_ p: CGPoint) -> NSColor? {
        guard let bmp = bitmap else { return nil }
        let x = Int(p.x), y = Int(image.size.height - p.y)
        guard x >= 0, y >= 0, x < bmp.pixelsWide, y < bmp.pixelsHigh else { return nil }
        return bmp.colorAt(x: x, y: y)
    }

    private func cropPixels(_ rect: CGRect) -> (crop: CGImage, size: CGSize)? {
        guard rect.width > 1, rect.height > 1,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height
        let pr = CGRect(x: rect.minX * sx,
                        y: (image.size.height - rect.maxY) * sy,
                        width: rect.width * sx,
                        height: rect.height * sy).integral
        guard pr.width >= 1, pr.height >= 1, let crop = cg.cropping(to: pr) else { return nil }
        return (crop, pr.size)
    }

    /// Smooth Gaussian blur — the "Blur" tool. Clamping the edge before
    /// blurring keeps the result opaque to the rect edges (an unclamped blur
    /// fades toward transparent); the radius scales with the region's short side
    /// so small and large selections are obscured to a similar degree.
    private func gaussianBlur(_ rect: CGRect) -> CGImage? {
        guard let (crop, size) = cropPixels(rect) else { return nil }
        let ci = CIImage(cgImage: crop).clampedToExtent()
        let radius = max(8, min(size.width, size.height) / 6)
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: CGRect(origin: .zero, size: size))
    }

    func undo() { clearSelections(); if let a = annotations.popLast() { redoStack.append(a); onChange?(); needsDisplay = true } }
    func redo() { clearSelections(); if let a = redoStack.popLast() { annotations.append(a); onChange?(); needsDisplay = true } }

    /// Restyle the mark the user is currently working with — the Select-tool
    /// selection, or a text mark still active under the Text tool — so choosing a
    /// color repaints a placed mark in place. Like move/resize, this edits the
    /// mark directly rather than pushing an undo step. Also tracks a live text
    /// field mid-edit so the color applies as you type.
    func recolorSelection(_ c: NSColor) {
        // While editing, color only the highlighted characters (⌘A / Ctrl-A selects
        // all first); with nothing selected, set the color for text typed next.
        if let tv = textView {
            let range = tv.selectedRange()
            if range.length > 0 {
                tv.setTextColor(c, range: range)            // just the highlighted characters
            } else {
                tv.typingAttributes[.foregroundColor] = c   // color for text typed next
            }
            needsDisplay = true
            return
        }
        // Not editing: recolor the whole selected mark (Select tool).
        guard let target = selected ?? editingText else { return }
        target.recolor(c)
        onChange?(); needsDisplay = true
    }

    /// Set the stroke width for the next mark drawn, and apply it live to the mark
    /// currently selected (Select tool) or the one still live under its own tool.
    func restrokeSelection(_ width: CGFloat) {
        style.lineWidth = width
        if let target = selected ?? editingShape ?? editingCurve {
            target.restroke(width); onChange?()
        }
        needsDisplay = true
    }

    private func clearSelections() {
        editingCurve = nil; curveDrag = nil; boxDrag = nil; editingShape = nil; editingShapeTool = nil
        editingZoom = nil; selected = nil; selectDrag = .none
        editingText = nil; textDrag = .none
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
    }

    /// Resize a text box by one of its eight handles: edge handles reflow the box on a
    /// single axis (the text re-wraps, font unchanged); corner handles scale the font
    /// (and box) uniformly about the opposite corner — like a real text frame.
    private func resizeTextBox(_ t: TextAnnotation, handle: BoxHandle, to p: CGPoint) {
        let b = t.bounds
        let minW = max(8 / displayScale, t.fontSize)
        let minH = max(8 / displayScale, t.fontSize * 0.6)
        switch handle {
        case .left, .right, .top, .bottom:
            var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
            switch handle {
            case .left:   minX = min(p.x, maxX - minW)
            case .right:  maxX = max(p.x, minX + minW)
            case .bottom: minY = min(p.y, maxY - minH)
            case .top:    maxY = max(p.y, minY + minH)
            default: break
            }
            t.origin = CGPoint(x: minX, y: minY)
            t.resizeBox(width: maxX - minX, height: maxY - minY)
        default:
            // Corner → scale the font about the diagonally opposite corner.
            let anchor: CGPoint
            switch handle {
            case .bottomLeft:  anchor = CGPoint(x: b.maxX, y: b.maxY)
            case .bottomRight: anchor = CGPoint(x: b.minX, y: b.maxY)
            case .topLeft:     anchor = CGPoint(x: b.maxX, y: b.minY)
            default:           anchor = CGPoint(x: b.minX, y: b.minY)   // topRight
            }
            let oldW = abs(b.width)
            guard oldW > 0.5 else { return }
            let f = max(0.05, abs(p.x - anchor.x) / oldW)
            t.scale(by: f, around: anchor)
        }
    }

    /// The curve handle under `p` (whichever knob is nearest within grab range), or
    /// nil. Endpoints and apex share the reshape gesture for arrows and lines.
    private func curveHandle(_ c: CurvedAnnotation, at p: CGPoint) -> CurveHandle? {
        let hr = 12 / displayScale
        let candidates: [(CurveHandle, CGPoint)] = [(.start, c.start), (.end, c.end), (.apex, c.apex)]
        return candidates
            .map { ($0.0, hypot($0.1.x - p.x, $0.1.y - p.y)) }
            .filter { $0.1 < hr }
            .min { $0.1 < $1.1 }?.0
    }

    /// The four corners of a bounding box, each paired with its diagonally opposite
    /// corner (the anchor a resize scales around).
    private func cornerAnchors(_ b: CGRect) -> [(corner: CGPoint, anchor: CGPoint)] {
        [(CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY)),
         (CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.minY)),
         (CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)),
         (CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY))]
    }

    /// The resize anchor (opposite corner) for whichever of a resizable mark's four
    /// corner knobs sits under `p`, or nil. Lets any corner drag the shape's size.
    private func resizeAnchor(for s: Annotation, at p: CGPoint) -> CGPoint? {
        guard s.resizable else { return nil }
        let hr = 12 / displayScale
        return cornerAnchors(s.bounds)
            .map { ($0.anchor, hypot($0.corner.x - p.x, $0.corner.y - p.y)) }
            .filter { $0.1 < hr }
            .min { $0.1 < $1.1 }?.0
    }

    /// The eight box-resize knob positions for a bounding box: four corners and four
    /// edge midpoints.
    private func boxHandlePoints(_ b: CGRect) -> [(handle: BoxHandle, point: CGPoint)] {
        [(.bottomLeft,  CGPoint(x: b.minX, y: b.minY)),
         (.bottom,      CGPoint(x: b.midX, y: b.minY)),
         (.bottomRight, CGPoint(x: b.maxX, y: b.minY)),
         (.right,       CGPoint(x: b.maxX, y: b.midY)),
         (.topRight,    CGPoint(x: b.maxX, y: b.maxY)),
         (.top,         CGPoint(x: b.midX, y: b.maxY)),
         (.topLeft,     CGPoint(x: b.minX, y: b.maxY)),
         (.left,        CGPoint(x: b.minX, y: b.midY))]
    }

    /// Which box-resize knob sits under `p` (nearest within grab range), or nil.
    private func boxHandle(for s: TwoPointAnnotation, at p: CGPoint) -> BoxHandle? {
        boxHandle(inRect: s.bounds, at: p)
    }

    /// Which of `b`'s eight box knobs sits under `p` (nearest within grab range), or nil.
    /// Shared by shapes and the image overlay so both get the same 8-handle affordance.
    private func boxHandle(inRect b: CGRect, at p: CGPoint) -> BoxHandle? {
        let hr = 12 / displayScale
        return boxHandlePoints(b)
            .map { ($0.handle, hypot($0.point.x - p.x, $0.point.y - p.y)) }
            .filter { $0.1 < hr }
            .min { $0.1 < $1.1 }?.0
    }

    /// Resize `b` by dragging box `handle` to `p`: grabbed edge(s) follow the pointer, the
    /// opposite edge(s) stay put, clamped to a `min` size. Aspect is free (edges stretch a
    /// single axis, corners both) — used by the image overlay's 8-handle resize.
    private func resizeRect(_ b: CGRect, handle: BoxHandle, to p: CGPoint, min m: CGFloat) -> CGRect {
        var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft:    minX = Swift.min(p.x, maxX - m)
        case .right, .topRight, .bottomRight: maxX = Swift.max(p.x, minX + m)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY = Swift.min(p.y, maxY - m)
        case .top, .topLeft, .topRight:          maxY = Swift.max(p.y, minY + m)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Resize a rect-based shape by dragging one of its eight knobs to `p`: the grabbed
    /// edge(s) follow the pointer, the opposite edge(s) stay put, clamped to a min size.
    private func resizeBox(_ s: TwoPointAnnotation, handle: BoxHandle, to p: CGPoint) {
        let b = s.bounds, m = 8 / displayScale
        var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft:    minX = min(p.x, maxX - m)
        case .right, .topRight, .bottomRight: maxX = max(p.x, minX + m)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY = min(p.y, maxY - m)
        case .top, .topLeft, .topRight:          maxY = max(p.y, minY + m)
        default: break
        }
        s.start = CGPoint(x: minX, y: minY)
        s.end   = CGPoint(x: maxX, y: maxY)
    }

    /// The resize cursor for a box handle — directional for the edges, a grab hand for
    /// the free corners.
    private func boxCursor(_ h: BoxHandle) -> NSCursor {
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:            return .openHand
        }
    }

    /// Draw a resizable mark's selection outline plus a white knob at each of its four
    /// corners — the shared affordance for the Select tool and a live shape.
    private func drawResizeBox(_ s: Annotation, in ctx: CGContext) {
        let b = s.bounds
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale)
        ctx.stroke(b)
        guard s.resizable else { return }
        // Rect-based shapes and text boxes get all eight knobs (edges reflow / stretch a
        // single axis); other resizable marks scale uniformly, so only four corners show.
        let eightHandles = s is TwoPointAnnotation || s is TextAnnotation
        let pts = eightHandles ? boxHandlePoints(b).map(\.point) : cornerAnchors(b).map(\.corner)
        let r = 6 / displayScale
        for c in pts {
            let knob = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.strokeEllipse(in: knob)
        }
    }

    /// Draw a curve's three reshape knobs (start, end, apex) as white dots ringed in
    /// `tint`, matching the other editor handles.
    private func drawCurveHandles(_ c: CurvedAnnotation, in ctx: CGContext, tint: NSColor) {
        let r = 6 / displayScale
        ctx.setLineWidth(1.5 / displayScale)
        for pt in [c.start, c.end, c.apex] {
            let box = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: box)
            ctx.setStrokeColor(tint.cgColor); ctx.strokeEllipse(in: box)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: displayScale, y: displayScale)
        // Clip to the image so a mark that overhangs the edge (e.g. after the region is
        // trimmed) never paints its cut-off part onto the surrounding backdrop.
        ctx.clip(to: CGRect(origin: .zero, size: image.size))
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for a in annotations { a.draw(in: ctx) }
        live?.draw(in: ctx)
        if let pc = pendingCrop { drawCropOverlay(pc, in: ctx) }
        if let o = ocrRect { drawCropOverlay(o, in: ctx) }
        if let z = zoomRect {
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(z)
        }
        if tool == .arrow || tool == .line, let ec = editingCurve {
            drawCurveHandles(ec, in: ctx, tint: style.color)
        }
        if tool == .zoom, let ez = editingZoom {
            let r = 6 / displayScale
            let knob = CGRect(x: ez.dest.maxX - r, y: ez.dest.minY - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
        }
        if tool == .overlay, let eo = editingOverlay {
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(eo.rect)
            // Eight knobs (four corners + four edge midpoints) — edges stretch a single
            // axis, corners both, matching the shape resize box.
            let r = 6 / displayScale
            for pt in boxHandlePoints(eo.rect).map(\.point) {
                let knob = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
                ctx.setStrokeColor(Theme.lavender.cgColor); ctx.strokeEllipse(in: knob)
            }
        }
        if tool == .text, textView == nil, let t = editingText {
            drawResizeBox(t, in: ctx)   // eight handles: edges reflow, corners scale the font
        }
        if tool == .select, let s = selected {
            if let c = s as? CurvedAnnotation {
                // Curves show their three drag knobs instead of a bounds box — the box
                // around a diagonal arrow is large and reads as a phantom rectangle.
                drawCurveHandles(c, in: ctx, tint: Theme.lavender)
            } else {
                drawResizeBox(s, in: ctx)
            }
        }
        // A shape tool's just-drawn shape shows the same corner handles in place.
        if Self.isShapeTool(tool), let es = editingShape { drawResizeBox(es, in: ctx) }
        if tool == .ruler, measureAxis != .none, let a = measureAnchor {
            MeasureAnnotation(start: a, end: measureEnd(at: lastMousePoint, from: a),
                              style: style).draw(in: ctx)
        }
        ctx.restoreGState()
    }

    /// Dim everything outside the pending crop region and outline it, so the
    /// user can see what "Apply crop" will keep. Drawn in image space.
    private func drawCropOverlay(_ r: CGRect, in ctx: CGContext) {
        let W = image.size.width, H = image.size.height
        ctx.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.fill(CGRect(x: 0, y: r.maxY, width: W, height: H - r.maxY))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: r.minY))
        ctx.fill(CGRect(x: 0, y: r.minY, width: r.minX, height: r.height))
        ctx.fill(CGRect(x: r.maxX, y: r.minY, width: W - r.maxX, height: r.height))
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(1.5 / displayScale)
        ctx.stroke(r.insetBy(dx: 0.75 / displayScale, dy: 0.75 / displayScale))
    }

    /// Swap in a transformed base image and move every annotation through `remap`
    /// so the marks stay aligned and individually editable. The caller resizes /
    /// repositions the view. Scalar sizes (line width, font, radius) are
    /// unaffected because rotate-90 and crop are rigid (no scaling).
    func applyTransform(newImage: NSImage, remap: (CGPoint) -> CGPoint) {
        commitText()
        image = newImage
        rebuildBitmap()
        frame = NSRect(origin: frame.origin,
                       size: NSSize(width: image.size.width * displayScale,
                                    height: image.size.height * displayScale))
        (annotations + redoStack).forEach { $0.remap(remap) }
        // A transform (crop especially) can push a mark entirely off the new image.
        // Drop those so they don't linger invisibly off-canvas or resurface on a later
        // resize — marks still overlapping the image stay and are clipped to the image.
        let frameRect = CGRect(origin: .zero, size: image.size)
        annotations.removeAll { !frameRect.intersects($0.bounds) }
        redoStack.removeAll { !frameRect.intersects($0.bounds) }
        for a in annotations + redoStack {
            if let s = a as? SpotlightAnnotation { s.fullSize = image.size }
            if let b = a as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
            if let z = a as? ZoomAnnotation { z.patch = croppedCGImage(rect: z.source) }
        }
        live = nil
        editingCurve = nil; curveDrag = nil; boxDrag = nil; editingShape = nil; editingShapeTool = nil
        editingZoom = nil
        selected = nil; selectDrag = .none
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
        measureAxis = .none; measureAnchor = nil
        pendingCrop = nil
        needsDisplay = true
        onChange?()
    }

    /// A 90° rotation of the current image (`left` = counter-clockwise). Uses the
    /// same affine map as the annotation remap so image and marks stay aligned.
    func rotatedImage(left: Bool) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pw = cg.width, ph = cg.height
        let newPointSize = NSSize(width: image.size.height, height: image.size.width)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: ph, pixelsHigh: pw,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = newPointSize
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        let W = image.size.width, H = image.size.height
        let m = left ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)
                     : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)
        ctx.concatenate(m)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: newPointSize); img.addRepresentation(rep)
        return img
    }

    /// A mirror of the current image (`horizontal` = left↔right, else top↔bottom).
    /// Same size as the source; the matrix matches the annotation remap below so
    /// marks stay aligned (see `rotatedImage`).
    func flippedImage(horizontal: Bool) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pointSize = image.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = pointSize
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        let W = image.size.width, H = image.size.height
        let m = horizontal ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
                           : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        ctx.concatenate(m)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: pointSize); img.addRepresentation(rep)
        return img
    }

    /// The image cropped to `rect` (image points), preserving pixel resolution.
    func croppedImage(rect: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height
        let pr = CGRect(x: rect.minX * sx, y: (image.size.height - rect.maxY) * sy,
                        width: rect.width * sx, height: rect.height * sy).integral
        guard pr.width >= 1, pr.height >= 1, let crop = cg.cropping(to: pr) else { return nil }
        let rep = NSBitmapImageRep(cgImage: crop)
        rep.size = NSSize(width: rect.width, height: rect.height)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }

    private var resampleSource: NSBitmapImageRep?
    private var resampleSourceImage: NSImage?
    private var resampleCumulative = CGSize(width: 1, height: 1)

    /// Resample the whole capture to `scale`× its current on-screen size. Bakes the
    /// current annotations into the new base image (they're no longer separately
    /// editable, like crop/rotate produce a fresh image). Across a run of drags the
    /// resample is non-destructive: it always comes from the pristine pre-resize
    /// image (see `resampleSource`), so shrink-then-grow doesn't accumulate blur.
    /// The caller relays out.
    func bakeResample(scale: CGFloat) { bakeResample(scaleX: scale, scaleY: scale) }

    /// Resample width and height independently (edge handles stretch a single axis,
    /// corner handles both). A uniform `scaleX == scaleY` preserves aspect as before.
    func bakeResample(scaleX: CGFloat, scaleY: CGFloat) {
        guard scaleX > 0, scaleY > 0, abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 else { return }
        if resampleSource == nil || resampleSourceImage !== image || !annotations.isEmpty {
            guard let flat = flatten() else { return }
            resampleSource = flat
            resampleCumulative = CGSize(width: 1, height: 1)
        }
        guard let src = resampleSource else { return }
        let cumulative = CGSize(width: resampleCumulative.width * scaleX,
                                height: resampleCumulative.height * scaleY)
        // Snap the on-screen size (points × displayScale) to whole device points so the
        // resized canvas lands on the pixel grid. A fractional frame otherwise forces
        // CoreGraphics to resample the whole canvas on every redraw — invisible on a
        // Retina panel, visibly soft on a 1× external display (the capture path dodges
        // the same trap by snapping its selection to `.integral`). Pixels are derived
        // from the snapped point size so the baked image and its frame stay locked.
        let frameW = max(1, (src.size.width * cumulative.width * displayScale).rounded())
        let frameH = max(1, (src.size.height * cumulative.height * displayScale).rounded())
        let newPointSize = NSSize(width: frameW / displayScale, height: frameH / displayScale)
        let newW = max(1, Int((CGFloat(src.pixelsWide) * newPointSize.width / src.size.width).rounded()))
        let newH = max(1, Int((CGFloat(src.pixelsHigh) * newPointSize.height / src.size.height).rounded()))
        guard let finalRep = CanvasView.resampled(src, toPixels: (newW, newH), pointSize: newPointSize)
                ?? CanvasView.redrawn(src, toPixels: (newW, newH), pointSize: newPointSize) else { return }
        let img = NSImage(size: newPointSize); img.addRepresentation(finalRep)
        image = img
        resampleSourceImage = img
        resampleCumulative = cumulative
        annotations.removeAll(); redoStack.removeAll(); live = nil; editingCurve = nil; curveDrag = nil; boxDrag = nil
        editingShape = nil; editingShapeTool = nil; editingZoom = nil
        selected = nil; selectDrag = .none
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
        measureAxis = .none; measureAnchor = nil
        rebuildBitmap()
        frame = NSRect(origin: frame.origin,
                       size: NSSize(width: newPointSize.width * displayScale,
                                    height: newPointSize.height * displayScale))
        needsDisplay = true
        onChange?()
    }

    /// Resample `src` to `px` device pixels. CG's `.high` interpolation (used by the
    /// `redrawn` fallback below) is the best the draw API offers but a soft
    /// downsampler; CILanczosScaleTransform keeps markedly more fine detail on a
    /// shrink — text and UI edges stay legible instead of turning mushy, measured
    /// (≈60% more edge energy at 0.4×) and eyeballed against real screenshots. A
    /// mild luminance sharpen (0.4) finishes an *enlarge* only, where interpolation
    /// softens; a downscale is already crisp and sharpening it amplifies aliasing.
    /// `inputScale`
    /// drives the vertical scale and `inputAspectRatio` the horizontal, so the two
    /// independently-rounded pixel targets are hit exactly. Returns nil if Core
    /// Image is unavailable so the caller can fall back to a plain redraw.
    private static func resampled(_ src: NSBitmapImageRep, toPixels px: (w: Int, h: Int),
                                  pointSize: NSSize) -> NSBitmapImageRep? {
        guard let cg = src.cgImage, px.w >= 1, px.h >= 1, src.pixelsWide > 0, src.pixelsHigh > 0 else { return nil }
        let yScale = CGFloat(px.h) / CGFloat(src.pixelsHigh)
        let xScale = CGFloat(px.w) / CGFloat(src.pixelsWide)
        let ci = CIImage(cgImage: cg)
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        lanczos.setValue(ci, forKey: kCIInputImageKey)
        lanczos.setValue(yScale, forKey: kCIInputScaleKey)
        lanczos.setValue(xScale / yScale, forKey: kCIInputAspectRatioKey)
        guard let scaled = lanczos.outputImage else { return nil }
        // Sharpen only when enlarging: an upscale interpolates invented pixels and
        // softens, so a mild luminance pass restores crispness. A Lanczos downscale is
        // already crisp, so sharpening it there only amplifies downsample aliasing and
        // makes a shrunk-small image look crunchy — skip it.
        var finished = scaled
        if min(xScale, yScale) > 1, let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(scaled, forKey: kCIInputImageKey)
            sharpen.setValue(0.4, forKey: kCIInputSharpnessKey)
            finished = sharpen.outputImage ?? scaled
        }
        let target = CGRect(x: 0, y: 0, width: px.w, height: px.h)
        guard let out = CIContext().createCGImage(finished, from: target) else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = pointSize
        return rep
    }

    /// Plain `.high`-interpolation redraw to `px` pixels — the fallback when Core
    /// Image can't produce the Lanczos resample, so a bake never drops the image.
    private static func redrawn(_ src: NSBitmapImageRep, toPixels px: (w: Int, h: Int),
                                pointSize: NSSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px.w, pixelsHigh: px.h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = pointSize
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        gctx.cgContext.interpolationQuality = .high
        src.draw(in: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The pixels inside `rect` (image points) as a CGImage, for OCR.
    func croppedCGImage(rect: CGRect) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sx = CGFloat(cg.width) / image.size.width, sy = CGFloat(cg.height) / image.size.height
        let pr = CGRect(x: rect.minX * sx, y: (image.size.height - rect.maxY) * sy,
                        width: rect.width * sx, height: rect.height * sy).integral
        guard pr.width >= 1, pr.height >= 1 else { return nil }
        return cg.cropping(to: pr)
    }

    /// Render the capture + annotations to a bitmap at the capture's native pixel
    /// density — not its logical point size. A Retina grab has `pixelsPerPoint` 2,
    /// so a point-sized bitmap would halve the resolution of every export
    /// (Copy/Save/Pin) and collapse a resize to 1×. The rep keeps the point size,
    /// so drawing happens in image-point space and scales up to full pixels (same
    /// trick as `rotatedImage`). `includingOverlays: false` skips overlay images —
    /// used for the "before" frame of the GIF export.
    func flatten(includingOverlays: Bool = true) -> NSBitmapImageRep? {
        commitText()
        let ppp = pixelsPerPoint
        let pw = Int((image.size.width * ppp).rounded()), ph = Int((image.size.height * ppp).rounded())
        guard pw > 0, ph > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        gctx.cgContext.interpolationQuality = .high
        image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        for a in annotations {
            if !includingOverlays, a is ImageOverlayAnnotation { continue }
            a.draw(in: gctx.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

/// The live text-annotation editor. A rich `NSTextView` so one mark can mix colors
/// and text typed after a color change takes the new color. Adds ⌘A / Ctrl-A
/// "select all" (this menu-bar agent has no Edit menu to supply it) and draws a
/// placeholder while empty.
final class AnnotationTextView: NSTextView {
    var placeholder = "Text…"
    /// Color for newly typed text. NSTextView otherwise re-derives the typing color
    /// from the character next to the insertion point, which silently drops a
    /// mid-typing color change — so we force the current color on every insertion.
    var colorForNewText: (() -> NSColor)?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Insert typed text as an attributed run carrying the current color, rather
        // than relying on `typingAttributes` — NSTextView otherwise re-derives the
        // color from the neighboring character, silently dropping a color change.
        let plain = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard let color = colorForNewText?() else {
            super.insertText(string, replacementRange: replacementRange); return
        }
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let font { attrs[.font] = font }
        super.insertText(NSAttributedString(string: plain, attributes: attrs), replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Handle the standard editing shortcuts explicitly: the editor's borderless
        // window has no Edit menu, and the app's ⌘V is otherwise claimed for pasting an
        // image overlay — so paste into the focused field must be wired here.
        if mods == .command, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": pasteAsPlainText(nil); return true   // plain text adopts the current style
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font = self.font else { return }
        placeholder.draw(at: NSPoint(x: 0, y: 0),
                         withAttributes: [.font: font,
                                          .foregroundColor: NSColor.white.withAlphaComponent(0.5)])
    }
}

