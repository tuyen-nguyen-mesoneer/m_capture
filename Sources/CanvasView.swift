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
final class CanvasView: NSView, NSTextFieldDelegate {
    private(set) var image: NSImage
    let displayScale: CGFloat

    var tool: Tool = .pencil {
        didSet {
            if tool != .text { commitText(); editingText = nil; textDrag = .none }
            if !((tool == .arrow && editingCurve is CurvedArrowAnnotation) ||
                 (tool == .line && editingCurve is CurvedLineAnnotation)) {
                editingCurve = nil
            }
            if tool != .zoom { editingZoom = nil }
            if tool != .overlay, editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
            if tool != .ruler { measureAxis = .none; measureAnchor = nil }
            if tool != .select { selected = nil; selectDrag = .none }
            needsDisplay = true
        }
    }
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
    private var draggingCurveHandle = false

    private var editingOverlay: ImageOverlayAnnotation?
    private enum OverlayDrag { case none, move, resize }
    private var overlayDrag: OverlayDrag = .none
    private var overlayDragOffset: CGPoint = .zero
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

    private var textField: NSTextField?
    private var textImageFont: CGFloat = 18
    /// While editing an existing mark, the wrap width is locked to its original so
    /// the text keeps wrapping the same way; nil lets a new field grow to fit.
    private var textLockedWidth: CGFloat?
    /// A committed text mark that stays selected under the Text tool, so it can be
    /// moved and resized in place (box + corner knob) without the Select tool.
    private var editingText: TextAnnotation?
    private enum TextDrag { case none, move, resize }
    private var textDrag: TextDrag = .none
    private var textDragOffset: CGPoint = .zero

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
        if textField == nil,
           event.modifierFlags.intersection([.command, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            onPaste?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
            let p = imagePoint(event), hr = 12 / displayScale
            let knob = CGPoint(x: eo.rect.maxX, y: eo.rect.minY)
            if hypot(knob.x - p.x, knob.y - p.y) < hr || eo.rect.contains(p) {
                NSCursor.openHand.set(); return
            }
        }
        if tool == .text, textField == nil, let t = editingText {
            let p = imagePoint(event), hr = 12 / displayScale
            if hypot(t.bounds.maxX - p.x, t.bounds.minY - p.y) < hr {
                NSCursor.openHand.set(); return
            }
            if t.bounds.contains(p) {
                NSCursor.pointingHand.set(); return
            }
        }
        if tool == .select {
            let p = imagePoint(event), hr = 12 / displayScale
            if annotations.contains(where: { $0.resizable && hypot($0.bounds.maxX - p.x, $0.bounds.minY - p.y) < hr }) {
                NSCursor.openHand.set(); return
            }
            (annotations.contains { $0.hit(p) } ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        NSCursor.crosshair.set()
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
        if tool == .text, textField == nil, let t = editingText, event.keyCode == 51 || event.keyCode == 117 {
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
        switch tool {
        case .pencil:  let a = PencilAnnotation(style: style); a.add(p); live = a
        case .marker:  let a = MarkerAnnotation(style: style); a.add(p); live = a
        case .line, .arrow:
            if let ec = editingCurve, hypot(ec.apex.x - p.x, ec.apex.y - p.y) < 11 / displayScale {
                draggingCurveHandle = true
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
            let r = max(9, style.lineWidth * 2.5)
            live = CounterAnnotation(center: p, label: counterFormat.label(counter + 1),
                                     color: style.color, radius: r)
        case .text:
            let hr = 12 / displayScale
            if event.clickCount >= 2, let hit = annotations.reversed()
                .first(where: { ($0 as? TextAnnotation)?.hit(p) ?? false }) as? TextAnnotation {
                beginEditing(hit)
            } else if let t = editingText, hypot(t.bounds.maxX - p.x, t.bounds.minY - p.y) < hr {
                textDrag = .resize
                dragAnchor = CGPoint(x: t.bounds.minX, y: t.bounds.maxY)
                lastDragPoint = p
                NSCursor.closedHand.push()
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
            live = EmojiAnnotation(center: p, emoji: currentEmoji, size: 36)
        case .overlay:
            let hr = 12 / displayScale
            if let eo = editingOverlay,
               hypot(eo.rect.maxX - p.x, eo.rect.minY - p.y) < hr {
                overlayDrag = .resize; NSCursor.closedHand.push()
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
            let hr = 12 / displayScale
            if event.clickCount >= 2, let hit = annotations.reversed()
                .first(where: { ($0 as? TextAnnotation)?.hit(p) ?? false }) as? TextAnnotation {
                beginEditing(hit)
            } else if let corner = annotations.reversed().first(where: {
                $0.resizable && hypot($0.bounds.maxX - p.x, $0.bounds.minY - p.y) < hr
            }) {
                selected = corner
                selectDrag = .resize
                dragAnchor = CGPoint(x: corner.bounds.minX, y: corner.bounds.maxY)
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
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if tool == .ruler {
            lastMousePoint = p
            if measureAxis != .none { needsDisplay = true }
            return
        }
        if draggingCurveHandle, let ec = editingCurve {
            ec.bend(through: p); needsDisplay = true; return
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
            let anchorX = eo.rect.minX, top = eo.rect.maxY
            let newW = max(24 / displayScale, p.x - anchorX)
            let newH = newW * eo.aspect
            eo.rect = CGRect(x: anchorX, y: top - newH, width: newW, height: newH)
            needsDisplay = true; return
        }
        if textDrag == .move, let t = editingText {
            t.origin = CGPoint(x: p.x - textDragOffset.x, y: p.y - textDragOffset.y)
            needsDisplay = true; return
        }
        if textDrag == .resize, let t = editingText {
            let prev = hypot(lastDragPoint.x - dragAnchor.x, lastDragPoint.y - dragAnchor.y)
            let cur = hypot(p.x - dragAnchor.x, p.y - dragAnchor.y)
            if prev > 0.5 {
                let f = cur / prev
                let b = t.bounds
                let minSide = 8 / displayScale
                if f >= 1 || (b.width * f >= minSide && b.height * f >= minSide) {
                    t.scale(by: f, around: dragAnchor)
                    lastDragPoint = p
                }
            }
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
        if draggingCurveHandle {
            draggingCurveHandle = false; onChange?(); needsDisplay = true; return
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
        if let b = live as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
        if let a = live {
            annotations.append(a)
            if a is CounterAnnotation { counter += 1 }
            if let cc = a as? CurvedAnnotation { editingCurve = cc }
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
        if dx + dw > W { dx = src.minX - gap - dw }
        dx = max(0, min(W - dw, dx))
        let dy = max(0, min(H - dh, src.midY - dh / 2))
        return CGRect(x: dx, y: dy, width: dw, height: dh)
    }

    /// A borderless, wrapping, brand-bordered field used to type/edit an annotation.
    private func makeTextField(frame: NSRect, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.font = font
        field.textColor = color
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.placeholderString = "Text…"
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = Theme.lavender.withAlphaComponent(0.9).cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 3
        return field
    }

    private func beginTextEditing(viewPoint: CGPoint) {
        let screenFont = max(14, style.lineWidth * 6) * displayScale
        let h = screenFont + 8
        let field = makeTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - h, width: 120, height: h),
                                  font: .systemFont(ofSize: screenFont, weight: .semibold), color: style.color)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textImageFont = screenFont / displayScale
        textLockedWidth = nil
        fitTextField(field)
    }

    /// Re-open the editor on an existing text mark (double-click) pre-filled with
    /// its wording; the mark is lifted out and re-committed when editing finishes.
    private func beginEditing(_ mark: TextAnnotation) {
        editingText = nil; selected = nil; selectDrag = .none; textDrag = .none
        if let idx = annotations.firstIndex(where: { $0 === mark }) { annotations.remove(at: idx) }
        let scale = displayScale
        let frame = NSRect(x: mark.origin.x * scale, y: mark.origin.y * scale,
                           width: mark.maxWidth * scale, height: mark.boxHeight * scale)
        let field = makeTextField(frame: frame,
                                  font: .systemFont(ofSize: mark.fontSize * scale, weight: .semibold),
                                  color: mark.color)
        field.stringValue = mark.text
        addSubview(field)
        window?.makeFirstResponder(field)
        field.selectText(nil)
        textField = field
        textImageFont = mark.fontSize
        textLockedWidth = mark.maxWidth * scale
        fitTextField(field)
        redoStack.removeAll(); onChange?(); needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = textField { fitTextField(field) }
    }

    /// Size the live text field to its content, capped at the canvas edge, so long
    /// text wraps onto more lines (the field grows downward) instead of clipping.
    private func fitTextField(_ field: NSTextField) {
        let shown = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
        let font = field.font ?? .systemFont(ofSize: 14)
        let cap = max(120, bounds.width - field.frame.minX - 8)
        let width: CGFloat
        if let locked = textLockedWidth {
            width = min(locked, cap)
        } else {
            let natural = ceil(NSAttributedString(string: shown, attributes: [.font: font]).size().width) + 16
            width = min(natural, cap)
        }
        let cellH = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                           height: .greatestFiniteMagnitude)).height ?? field.frame.height
        let height = ceil(max(font.ascender - font.descender, cellH))
        let top = field.frame.maxY
        field.frame = NSRect(x: field.frame.minX, y: top - height, width: width, height: height)
        // Lay the typed text flush to the box edge (no line-fragment padding/inset)
        // so it sits exactly where the committed annotation draws it.
        if let editor = field.currentEditor() as? NSTextView {
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    @discardableResult
    private func commitText() -> Bool {
        guard let field = textField else { return false }
        let text = field.stringValue
        let color = field.textColor ?? style.color
        let f = field.frame
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return false }
        let origin = CGPoint(x: f.minX / displayScale, y: f.minY / displayScale)
        let mark = TextAnnotation(text: text, origin: origin, fontSize: textImageFont,
                                  color: color, maxWidth: f.width / displayScale,
                                  boxHeight: f.height / displayScale)
        annotations.append(mark)
        editingText = mark
        redoStack.removeAll(); onChange?()
        needsDisplay = true
        return true
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

    private func clearSelections() {
        editingCurve = nil; editingZoom = nil; selected = nil; selectDrag = .none
        editingText = nil; textDrag = .none
        if editingOverlay != nil { editingOverlay = nil; onOverlaySelected?(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: displayScale, y: displayScale)
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
            let r = 6 / displayScale, c = ec.apex
            let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: box)
            ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: box)
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
            let r = 6 / displayScale
            let knob = CGRect(x: eo.rect.maxX - r, y: eo.rect.minY - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
        }
        if tool == .text, textField == nil, let t = editingText {
            let b = t.bounds
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(b)
            let r = 6 / displayScale
            let knob = CGRect(x: b.maxX - r, y: b.minY - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
        }
        if tool == .select, let s = selected {
            let b = s.bounds
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale)
            ctx.stroke(b)
            if s.resizable {
                let r = 6 / displayScale
                let knob = CGRect(x: b.maxX - r, y: b.minY - r, width: r * 2, height: r * 2)
                ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor); ctx.fillEllipse(in: knob)
                ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5 / displayScale); ctx.strokeEllipse(in: knob)
            }
        }
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
        let all = annotations + redoStack
        for a in all { a.remap(remap) }
        for a in all {
            if let s = a as? SpotlightAnnotation { s.fullSize = image.size }
            if let b = a as? BlurAnnotation { b.patch = gaussianBlur(b.rect) }
            if let z = a as? ZoomAnnotation { z.patch = croppedCGImage(rect: z.source) }
        }
        live = nil
        editingCurve = nil
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
    private var resampleCumulative: CGFloat = 1

    /// Resample the whole capture to `scale`× its current on-screen size. Bakes the
    /// current annotations into the new base image (they're no longer separately
    /// editable, like crop/rotate produce a fresh image). Across a run of drags the
    /// resample is non-destructive: it always comes from the pristine pre-resize
    /// image (see `resampleSource`), so shrink-then-grow doesn't accumulate blur.
    /// The caller relays out.
    func bakeResample(scale: CGFloat) {
        guard scale > 0, abs(scale - 1) > 0.001 else { return }
        if resampleSource == nil || resampleSourceImage !== image || !annotations.isEmpty {
            guard let flat = flatten() else { return }
            resampleSource = flat
            resampleCumulative = 1
        }
        guard let src = resampleSource else { return }
        let cumulative = resampleCumulative * scale
        let newW = max(1, Int((CGFloat(src.pixelsWide) * cumulative).rounded()))
        let newH = max(1, Int((CGFloat(src.pixelsHigh) * cumulative).rounded()))
        let newPointSize = NSSize(width: src.size.width * cumulative, height: src.size.height * cumulative)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: newW, pixelsHigh: newH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = newPointSize
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        gctx.cgContext.interpolationQuality = .high
        src.draw(in: CGRect(x: 0, y: 0, width: newPointSize.width, height: newPointSize.height))
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: newPointSize); img.addRepresentation(rep)
        image = img
        resampleSourceImage = img
        resampleCumulative = cumulative
        annotations.removeAll(); redoStack.removeAll(); live = nil; editingCurve = nil; editingZoom = nil
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

