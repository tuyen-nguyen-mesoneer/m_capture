// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreImage

enum Tool {
    case pencil, marker, line, arrow, rect, ellipse
    case triangle, diamond, star, roundedRect, checkmark, pentagon, hexagon, octagon
    case text, blur, counter, spotlight, eyedropper, eraser, crop, ocr, zoom, emoji
    case overlay, ruler
}

/// Displays the captured image (scaled to fit) and the annotations on top.
/// Annotation coordinates are kept in full-resolution image space.
final class CanvasView: NSView, NSTextFieldDelegate {
    private(set) var image: NSImage
    let displayScale: CGFloat

    var tool: Tool = .pencil {
        didSet {
            if tool != .arrow { editingArrow = nil }
            if tool != .zoom { editingZoom = nil }
            if tool != .overlay, editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
            if tool != .ruler { measureAxis = .none; measureAnchor = nil }
            needsDisplay = true
        }
    }
    var style = DrawStyle(color: Theme.accent, lineWidth: 3)
    var onChange: (() -> Void)?
    var onColorPicked: ((NSColor) -> Void)?
    var onShortcut: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // Crop: a pending region (image space) drawn but not yet applied. The
    // controller shows a confirm control and performs the actual crop/relayout.
    var pendingCrop: CGRect?
    private var cropStart: CGPoint?
    var onCropBegin: (() -> Void)?    // a new crop drag started — hide any confirm UI
    var onCropReady: (() -> Void)?    // a usable crop region was drawn — show confirm UI
    var onCropConfirm: (() -> Void)?  // ↵ pressed with a pending crop — apply it

    // OCR: drag a region; on release its pixels are recognized (editor stays open).
    private var ocrStart: CGPoint?
    private var ocrRect: CGRect?
    var onOCR: ((CGImage) -> Void)?

    // Zoom callout: drag a source region; on release an enlarged bubble is placed.
    // The fresh callout stays selected so its bubble can be moved/resized.
    private var zoomStart: CGPoint?
    private var zoomRect: CGRect?
    private var editingZoom: ZoomAnnotation?
    private enum ZoomDrag { case none, move, resize }
    private var zoomDrag: ZoomDrag = .none
    private var zoomDragOffset: CGPoint = .zero

    // Bendable arrow: the just-drawn arrow stays selected with a draggable apex
    // handle so it can be curved; cleared when the tool changes (see `tool`).
    private var editingArrow: CurvedArrowAnnotation?
    private var draggingArrowHandle = false

    // Overlay image: the selected overlay (move whole / resize bottom-right knob),
    // mirroring the zoom-callout editing model. `onOverlaySelected` lets the editor
    // show/hide the opacity slider for the current selection.
    private var editingOverlay: ImageOverlayAnnotation?
    private enum OverlayDrag { case none, move, resize }
    private var overlayDrag: OverlayDrag = .none
    private var overlayDragOffset: CGPoint = .zero
    var onOverlaySelected: ((ImageOverlayAnnotation?) -> Void)?
    var onPaste: (() -> Void)?

    // Ruler / measure: an arrow key locks an axis and anchors at the cursor; moving
    // extends an axis-aligned dimension line; a click imprints it. `lastMousePoint`
    // (image space) is the live cursor, tracked on every mouse move.
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

    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var live: Annotation?
    private var counter = 0
    var counterFormat: CounterFormat = .number {
        didSet { if counterFormat != oldValue { counter = 0 } }   // restart the sequence
    }
    var currentEmoji = Logo.stampToken

    // Inline text editing state.
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textImageFont: CGFloat = 18

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

    // ⌘V pastes an image as an overlay; handled here (it's not a toolbar button).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Skip while a text annotation is being typed so ⌘V pastes into the field.
        if textField == nil,
           event.modifierFlags.intersection([.command, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            onPaste?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Drag-and-drop (drop an image file onto the canvas → overlay)

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
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: ["public.image"]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u) {
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

    /// Set the opacity (0–1) of the currently selected overlay (slider drives this).
    func setSelectedOverlayOpacity(_ value: CGFloat) {
        guard let eo = editingOverlay else { return }
        eo.opacity = max(0, min(1, value))
        needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        // Controls layered over the canvas (crop ✓/✕, the opacity slider, the text
        // field) sit inside our tracking area; let them own their cursor instead of
        // forcing the crosshair over the top of them.
        if let hit = window?.contentView?.hitTest(event.locationInWindow), hit !== self {
            return
        }
        lastMousePoint = imagePoint(event)
        if tool == .ruler, measureAxis != .none { needsDisplay = true }
        // Grab cursor when the zoom bubble is movable under the pointer.
        if tool == .zoom, let ez = editingZoom {
            let p = imagePoint(event), hr = 12 / displayScale
            let knob = CGPoint(x: ez.dest.maxX, y: ez.dest.minY)
            if hypot(knob.x - p.x, knob.y - p.y) < hr || ez.dest.contains(p) {
                NSCursor.openHand.set(); return
            }
        }
        if tool == .overlay, let eo = editingOverlay {
            let p = imagePoint(event), hr = 12 / displayScale
            let knob = CGPoint(x: eo.rect.maxX, y: eo.rect.minY)
            if hypot(knob.x - p.x, knob.y - p.y) < hr || eo.rect.contains(p) {
                NSCursor.openHand.set(); return
            }
        }
        NSCursor.crosshair.set()
    }

    // Plain letter keys switch tools (modifier combos like ⌘C are handled by the
    // toolbar buttons; while typing text the field is first responder, so these
    // never fire mid-typing).
    override func keyDown(with event: NSEvent) {
        if tool == .ruler {
            switch event.keyCode {
            case 126, 125:   // ↑ / ↓ → measure vertically, anchored at the cursor
                measureAxis = .vertical; measureAnchor = lastMousePoint; needsDisplay = true; return
            case 123, 124:   // ← / → → measure horizontally
                measureAxis = .horizontal; measureAnchor = lastMousePoint; needsDisplay = true; return
            case 53 where measureAxis != .none:   // Esc cancels the in-progress measurement
                measureAxis = .none; measureAnchor = nil; needsDisplay = true; return
            default: break
            }
        }
        if event.keyCode == 53 { onCancel?(); return } // Esc cancels the capture
        if pendingCrop != nil, event.keyCode == 36 || event.keyCode == 76 { // ↵ / ⌤ applies a crop
            onCropConfirm?(); return
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

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText() // finish any in-progress text first
        let p = imagePoint(event)
        switch tool {
        case .pencil:  let a = PencilAnnotation(style: style); a.add(p); live = a
        case .marker:  let a = MarkerAnnotation(style: style); a.add(p); live = a
        case .line:    live = LineAnnotation(start: p, style: style)
        case .arrow:
            // Grab the apex handle of the selected arrow to bend it; otherwise
            // start a new (straight) arrow.
            if let ea = editingArrow, hypot(ea.apex.x - p.x, ea.apex.y - p.y) < 11 / displayScale {
                draggingArrowHandle = true
            } else {
                editingArrow = nil
                live = CurvedArrowAnnotation(start: p, style: style)
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
            let r = max(9, style.lineWidth * 2.5)
            live = CounterAnnotation(center: p, label: counterFormat.label(counter + 1),
                                     color: style.color, radius: r)
        case .text:
            beginTextEditing(viewPoint: convert(event.locationInWindow, from: nil))
        case .eyedropper:
            if let c = sample(p) { style.color = c; onColorPicked?(c) }
        case .eraser:
            if let idx = annotations.lastIndex(where: { $0.hit(p) }) {
                annotations.remove(at: idx); redoStack.removeAll(); onChange?()
            }
        case .crop:
            cropStart = p
            pendingCrop = CGRect(origin: p, size: .zero)
            onCropBegin?()  // hide any stale confirm UI while a fresh region is drawn
        case .ocr:
            ocrStart = p
            ocrRect = CGRect(origin: p, size: .zero)
        case .zoom:
            if let ez = editingZoom {
                let hr = 12 / displayScale
                let knob = CGPoint(x: ez.dest.maxX, y: ez.dest.minY)   // bottom-right corner
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
            live = EmojiAnnotation(center: p, emoji: currentEmoji, size: 36)
        case .overlay:
            let hr = 12 / displayScale
            if let eo = editingOverlay,
               hypot(eo.rect.maxX - p.x, eo.rect.minY - p.y) < hr {   // bottom-right knob
                overlayDrag = .resize; NSCursor.closedHand.push()
            } else if let eo = editingOverlay, eo.rect.contains(p) {
                overlayDrag = .move
                overlayDragOffset = CGPoint(x: p.x - eo.rect.minX, y: p.y - eo.rect.minY)
                NSCursor.closedHand.push()
            } else {
                // Click elsewhere selects the topmost overlay under the point, else deselects.
                let hit = annotations.reversed().first { ($0 as? ImageOverlayAnnotation)?.rect.contains(p) ?? false }
                editingOverlay = hit as? ImageOverlayAnnotation
                onOverlaySelected?(editingOverlay)
            }
        case .ruler:
            // Imprint the live measurement (if any), then re-anchor here for chaining.
            if measureAxis != .none, let a = measureAnchor {
                let end = measureEnd(at: p, from: a)
                if hypot(end.x - a.x, end.y - a.y) >= 2 {
                    annotations.append(MeasureAnnotation(start: a, end: end, pixelsPerPoint: pixelsPerPoint, style: style))
                    redoStack.removeAll(); onChange?()
                }
                measureAnchor = p
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if tool == .ruler {   // ruler uses move + click, not drag; just track the cursor
            lastMousePoint = p
            if measureAxis != .none { needsDisplay = true }
            return
        }
        if draggingArrowHandle, let ea = editingArrow {
            ea.bend(through: p); needsDisplay = true; return
        }
        if zoomDrag == .move, let ez = editingZoom {
            ez.dest.origin = CGPoint(x: p.x - zoomDragOffset.x, y: p.y - zoomDragOffset.y)
            needsDisplay = true; return
        }
        if zoomDrag == .resize, let ez = editingZoom {
            let anchorX = ez.dest.minX, top = ez.dest.maxY     // keep top-left fixed
            let newW = max(24 / displayScale, p.x - anchorX)
            let newH = newW * (ez.source.height / max(1, ez.source.width))   // lock to source aspect
            ez.dest = CGRect(x: anchorX, y: top - newH, width: newW, height: newH)
            needsDisplay = true; return
        }
        if overlayDrag == .move, let eo = editingOverlay {
            eo.rect.origin = CGPoint(x: p.x - overlayDragOffset.x, y: p.y - overlayDragOffset.y)
            needsDisplay = true; return
        }
        if overlayDrag == .resize, let eo = editingOverlay {
            let anchorX = eo.rect.minX, top = eo.rect.maxY     // keep top-left fixed
            let newW = max(24 / displayScale, p.x - anchorX)
            let newH = newW * eo.aspect                        // aspect-locked
            eo.rect = CGRect(x: anchorX, y: top - newH, width: newW, height: newH)
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
        else if let a = live as? CurvedArrowAnnotation { a.end = p; a.straighten() }
        else if let a = live as? TwoPointAnnotation { a.end = p }
        else if let a = live as? CounterAnnotation { a.center = p }
        else if let a = live as? EmojiAnnotation {       // drag out from the drop point to size it
            a.size = max(24, hypot(p.x - a.center.x, p.y - a.center.y) * 1.8)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingArrowHandle {
            draggingArrowHandle = false; onChange?(); needsDisplay = true; return
        }
        if zoomDrag != .none {
            zoomDrag = .none; NSCursor.pop(); onChange?(); needsDisplay = true; return
        }
        if overlayDrag != .none {
            overlayDrag = .none; NSCursor.pop()
            onOverlaySelected?(editingOverlay)   // reposition the opacity slider after a move/resize
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
                pendingCrop = nil; onCropBegin?()  // too small — discard, keep confirm hidden
            }
            needsDisplay = true
            return
        }
        if tool == .ocr {
            ocrStart = nil
            if let r = ocrRect, r.width >= 5, r.height >= 5, let cg = croppedCGImage(rect: r) {
                onOCR?(cg)   // recognize off the editor; the editor stays open
            }
            ocrRect = nil
            needsDisplay = true
            return
        }
        if let b = live as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
        if let a = live {
            annotations.append(a)
            if a is CounterAnnotation { counter += 1 }
            // Keep a fresh arrow selected so its apex handle can bend it.
            if let ca = a as? CurvedArrowAnnotation { editingArrow = ca }
            redoStack.removeAll()
            live = nil
            onChange?()
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
        if dx + dw > W { dx = src.minX - gap - dw }          // not enough room right → go left
        dx = max(0, min(W - dw, dx))                          // clamp into image
        let dy = max(0, min(H - dh, src.midY - dh / 2))
        return CGRect(x: dx, y: dy, width: dw, height: dh)
    }

    // MARK: Text editing

    private func beginTextEditing(viewPoint: CGPoint) {
        let screenFont = max(14, style.lineWidth * 6) * displayScale
        let h = screenFont + 8
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - h, width: 260, height: h))
        field.font = .systemFont(ofSize: screenFont, weight: .semibold)
        field.textColor = style.color
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Text…"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)

        textField = field
        textOrigin = CGPoint(x: viewPoint.x / displayScale, y: (viewPoint.y - h) / displayScale + 4)
        textImageFont = screenFont / displayScale
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField else { return }
        let text = field.stringValue
        let color = field.textColor ?? style.color
        textField = nil
        field.removeFromSuperview()
        if !text.isEmpty {
            annotations.append(TextAnnotation(text: text, origin: textOrigin,
                                              fontSize: textImageFont, color: color))
            redoStack.removeAll(); onChange?()
            needsDisplay = true
        }
        window?.makeFirstResponder(self) // restore so tool shortcuts work again
    }

    // MARK: Sampling / redaction

    private func sample(_ p: CGPoint) -> NSColor? {
        guard let bmp = bitmap else { return nil }
        let x = Int(p.x), y = Int(image.size.height - p.y) // flip to top-left origin
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
                        y: (image.size.height - rect.maxY) * sy,   // flip Y for CGImage
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

    // MARK: Edit

    func undo() { clearSelections(); if let a = annotations.popLast() { redoStack.append(a); onChange?(); needsDisplay = true } }
    func redo() { clearSelections(); if let a = redoStack.popLast() { annotations.append(a); onChange?(); needsDisplay = true } }

    private func clearSelections() {
        editingArrow = nil; editingZoom = nil
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
    }

    // MARK: Render

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: displayScale, y: displayScale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for a in annotations { a.draw(in: ctx) }
        live?.draw(in: ctx)
        if let pc = pendingCrop { drawCropOverlay(pc, in: ctx) }
        if let o = ocrRect { drawCropOverlay(o, in: ctx) }   // same dim+outline for the OCR region
        if let z = zoomRect {                                 // live zoom source while dragging
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(z)
        }
        if tool == .arrow, let ea = editingArrow {            // draggable apex handle
            let r = 6 / displayScale, c = ea.apex
            let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: box)
            ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: box)
        }
        if tool == .zoom, let ez = editingZoom {              // move (whole bubble) + resize knob
            let r = 6 / displayScale
            let knob = CGRect(x: ez.dest.maxX - r, y: ez.dest.minY - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
        }
        if tool == .overlay, let eo = editingOverlay {        // selection outline + resize knob
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(eo.rect)
            let r = 6 / displayScale
            let knob = CGRect(x: eo.rect.maxX - r, y: eo.rect.minY - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
        }
        if tool == .ruler, measureAxis != .none, let a = measureAnchor {   // live dimension line
            MeasureAnnotation(start: a, end: measureEnd(at: lastMousePoint, from: a),
                              pixelsPerPoint: pixelsPerPoint, style: style).draw(in: ctx)
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

    // MARK: Transforms (rotate / crop)

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
        let all = annotations + redoStack
        for a in all { a.remap(remap) }
        for a in all {
            if let s = a as? SpotlightAnnotation { s.fullSize = image.size }
            if let b = a as? BlurAnnotation { b.patch = gaussianBlur(b.rect) } // patch was tied to old pixels
            if let z = a as? ZoomAnnotation { z.patch = croppedCGImage(rect: z.source) }
        }
        live = nil
        editingArrow = nil
        editingZoom = nil
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
        // (x,y) -> (H - y, x) for left/CCW, (y, W - x) for right/CW.
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
        // (x,y) -> (W - x, y) horizontally, (x, H - y) vertically.
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
        rep.size = NSSize(width: rect.width, height: rect.height)  // keep point size → displayScale stays constant
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }

    /// Resample the whole capture to `scale`× its current size. Bakes the
    /// current annotations into the new base image (they're no longer separately
    /// editable, like crop/rotate produce a fresh image). The caller relays out.
    func bakeResample(scale: CGFloat) {
        guard scale > 0, abs(scale - 1) > 0.001, let flat = flatten() else { return }
        let newW = max(1, Int((CGFloat(flat.pixelsWide) * scale).rounded()))
        let newH = max(1, Int((CGFloat(flat.pixelsHigh) * scale).rounded()))
        let newPointSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: newW, pixelsHigh: newH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = newPointSize
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        gctx.cgContext.interpolationQuality = .high
        flat.draw(in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: newPointSize); img.addRepresentation(rep)
        image = img
        annotations.removeAll(); redoStack.removeAll(); live = nil; editingArrow = nil; editingZoom = nil
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
        measureAxis = .none; measureAnchor = nil
        rebuildBitmap()
        frame = NSRect(origin: frame.origin,
                       size: NSSize(width: newPointSize.width * displayScale,
                                    height: newPointSize.height * displayScale))
        needsDisplay = true
        onChange?()
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

    /// Render the capture + annotations to a bitmap. `includingOverlays: false`
    /// skips overlay images — used for the "before" frame of the GIF export.
    func flatten(includingOverlays: Bool = true) -> NSBitmapImageRep? {
        commitText()
        let w = Int(image.size.width.rounded()), h = Int(image.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        for a in annotations {
            if !includingOverlays, a is ImageOverlayAnnotation { continue }
            a.draw(in: gctx.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
