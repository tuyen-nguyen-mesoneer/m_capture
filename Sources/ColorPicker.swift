// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A compact, brand-styled custom-color picker: a saturation/brightness square,
/// a hue strip and a live preview. Far simpler than the full `NSColorPanel`, and
/// — crucially — it opens *above* the screen-saver-level editor so it's actually
/// usable (the system panel was hidden behind the overlay).
final class ColorPickerPanel: NSObject {
    private var window: KeyablePickerWindow?
    private let onPick: (NSColor) -> Void
    private let onClose: () -> Void

    private var hue: CGFloat = 0
    private var sat: CGFloat = 1
    private var bri: CGFloat = 1

    private var square: SVSquareView!
    private var hueStrip: HueStripView!
    private var preview: NSView!

    init(onPick: @escaping (NSColor) -> Void, onClose: @escaping () -> Void) {
        self.onPick = onPick
        self.onClose = onClose
    }

    func show(near button: NSView, initial: NSColor) {
        if window != nil { close(); return }

        let c = initial.usingColorSpace(.deviceRGB) ?? .red
        hue = c.hueComponent; sat = c.saturationComponent; bri = c.brightnessComponent

        let pad: CGFloat = 14, w: CGFloat = 208
        let sqH: CGFloat = 150, stripH: CGFloat = 20, gap: CGFloat = 12, previewH: CGFloat = 28
        let panelW = w + pad * 2
        let panelH = pad + previewH + gap + stripH + gap + sqH + pad + 22 // +22 caption

        let container = KeyView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        container.onEsc = { [weak self] in self?.close() }
        Theme.stylePanel(container, cornerRadius: 14)

        let cap = NSTextField(labelWithString: "")
        Theme.styleEyebrow(cap, "Custom color")
        cap.alignment = .left
        cap.frame = NSRect(x: pad, y: panelH - 22, width: w, height: 14)
        container.addSubview(cap)

        square = SVSquareView(frame: NSRect(x: pad, y: pad + previewH + gap + stripH + gap,
                                            width: w, height: sqH))
        square.onChange = { [weak self] s, b in self?.sat = s; self?.bri = b; self?.emit() }
        container.addSubview(square)

        hueStrip = HueStripView(frame: NSRect(x: pad, y: pad + previewH + gap, width: w, height: stripH))
        hueStrip.onChange = { [weak self] h in self?.hue = h; self?.square.hue = h; self?.emit() }
        container.addSubview(hueStrip)

        preview = NSView(frame: NSRect(x: pad, y: pad, width: previewH, height: previewH))
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        container.addSubview(preview)

        let hint = NSTextField(labelWithString: "Drag to pick · click away to close")
        hint.font = Theme.font(10, .medium); hint.textColor = Theme.textMuted
        hint.alignment = .right
        hint.frame = NSRect(x: pad + previewH + 8, y: pad + 6, width: w - previewH - 8, height: 14)
        container.addSubview(hint)

        square.hue = hue
        square.set(sat: sat, bri: bri)
        hueStrip.set(hue: hue)
        refreshPreview()

        let win = KeyablePickerWindow(contentRect: container.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
        Theme.styleOverlayWindow(win)
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.contentView = container

        // Position above the button, kept on screen.
        if let scr = button.window?.screen ?? NSScreen.main,
           let bw = button.window {
            let onScreen = bw.convertToScreen(button.convert(button.bounds, to: nil))
            var x = onScreen.midX - panelW / 2
            var y = onScreen.maxY + 10
            let vf = scr.visibleFrame
            x = min(max(vf.minX + 8, x), vf.maxX - panelW - 8)
            if y + panelH > vf.maxY - 8 { y = onScreen.minY - panelH - 10 }
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(container)   // so Esc closes the picker
        window = win

        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: win)
    }

    @objc private func resigned() { close() }

    func close() {
        guard let win = window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: win)
        win.orderOut(nil)
        window = nil
        onClose()
    }

    private func currentColor() -> NSColor {
        NSColor(deviceHue: hue, saturation: sat, brightness: bri, alpha: 1)
    }
    private func refreshPreview() { preview?.layer?.backgroundColor = currentColor().cgColor }
    private func emit() { refreshPreview(); onPick(currentColor()) }
}

/// Borderless window that can still take key focus (so it receives clicks).
final class KeyablePickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Picker container that closes on Esc (mouse stays handled by the subviews).
private final class KeyView: NSView {
    var onEsc: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEsc?() } else { super.keyDown(with: e) }
    }
}

/// Saturation (x) × brightness (y) gradient for the active hue, with a ring cursor.
private final class SVSquareView: NSView {
    var onChange: ((CGFloat, CGFloat) -> Void)?
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    private var sat: CGFloat = 1, bri: CGFloat = 1

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    func set(sat: CGFloat, bri: CGFloat) { self.sat = sat; self.bri = bri; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.addClip()

        ctx.setFillColor(NSColor(deviceHue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
        ctx.fill(bounds)
        let cs = CGColorSpaceCreateDeviceRGB()
        // White → clear, left to right (saturation).
        if let g = CGGradient(colorsSpace: cs, colors: [NSColor.white.cgColor,
                NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: 0),
                                   end: CGPoint(x: bounds.maxX, y: 0), options: [])
        }
        // Black → clear, bottom to top (brightness).
        if let g = CGGradient(colorsSpace: cs, colors: [NSColor.black.cgColor,
                NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.minY),
                                   end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }
        let p = CGPoint(x: bounds.minX + sat * bounds.width, y: bounds.minY + bri * bounds.height)
        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
        ring.lineWidth = 2
        NSColor.white.setStroke(); ring.stroke()
        NSColor(white: 0, alpha: 0.5).setStroke()
        NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).stroke()
    }

    override func mouseDown(with e: NSEvent) { track(e) }
    override func mouseDragged(with e: NSEvent) { track(e) }
    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        sat = min(max(0, p.x / bounds.width), 1)
        bri = min(max(0, p.y / bounds.height), 1)
        needsDisplay = true
        onChange?(sat, bri)
    }
}

/// Horizontal rainbow hue selector with a cursor.
private final class HueStripView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var hue: CGFloat = 0

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    func set(hue: CGFloat) { self.hue = hue; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
            NSColor(deviceHue: CGFloat($0), saturation: 1, brightness: 1, alpha: 1).cgColor
        }
        let locs: [CGFloat] = stops.enumerated().map { CGFloat($0.offset) / CGFloat(stops.count - 1) }
        if let g = CGGradient(colorsSpace: cs, colors: stops as CFArray, locations: locs) {
            ctx.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: 0),
                                   end: CGPoint(x: bounds.maxX, y: 0), options: [])
        }
        let x = bounds.minX + hue * bounds.width
        let cursor = NSBezierPath(roundedRect: NSRect(x: x - 3, y: -1, width: 6, height: bounds.height + 2),
                                  xRadius: 3, yRadius: 3)
        cursor.lineWidth = 2
        NSColor.white.setStroke(); cursor.stroke()
    }

    override func mouseDown(with e: NSEvent) { track(e) }
    override func mouseDragged(with e: NSEvent) { track(e) }
    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hue = min(max(0, p.x / bounds.width), 1)
        needsDisplay = true
        onChange?(hue)
    }
}
