// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox

extension Shortcut {
    /// A human-readable glyph string, e.g. `⌃⇧X`.
    var displayString: String { Shortcut.modifierGlyphs(modifiers) + Shortcut.keyName(keyCode) }

    /// `⌃⌥⇧⌘` glyphs for a Carbon modifier mask, in the conventional order.
    static func modifierGlyphs(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & UInt32(controlKey) != 0 { s += "⌃" }
        if carbon & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbon & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbon & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Convert AppKit modifier flags (from an event) to a Carbon mask.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    /// A short label for a virtual key code (letters, digits, and the common
    /// specials people pick for capture shortcuts).
    static func keyName(_ code: UInt32) -> String {
        if let s = specials[Int(code)] { return s }
        // Letters / digits via the current keyboard layout, upper-cased.
        if let ch = layoutCharacter(code) { return ch.uppercased() }
        return "Key \(code)"
    }

    private static let specials: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    ]

    /// Translate a key code to its base character using the active layout.
    private static func layoutCharacter(_ code: UInt32) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// A brand-styled control that records a global hotkey: click to arm, then press
/// the desired combination. Shows the current shortcut as glyphs; lavender border
/// while recording. Esc cancels. On capture it persists to `Settings` and calls
/// `onChange` so the app can re-register its hotkeys.
final class HotKeyField: NSView {
    private let action: ShortcutAction
    private let onChange: () -> Void
    private let glyphLabel = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var recording = false { didSet { needsDisplay = true; refreshDisplay() } }

    init(action: ShortcutAction, onChange: @escaping () -> Void) {
        self.action = action
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        wantsLayer = true

        glyphLabel.font = Theme.font(12, .semibold)
        glyphLabel.textColor = Theme.textPrimary
        glyphLabel.alignment = .left
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BrandControl.textInset),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        refreshDisplay()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshDisplay() {
        if recording {
            glyphLabel.stringValue = "Type shortcut…"
            glyphLabel.textColor = Theme.lavender
        } else {
            glyphLabel.stringValue = Settings.shared.shortcut(action).displayString
            glyphLabel.textColor = Theme.textPrimary
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall)
        Theme.surfaceRaised.setFill()
        path.fill()
        (recording ? Theme.lavender : Theme.border).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        recording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self, self.recording else { return ev }
            if ev.type == .flagsChanged {
                let g = Shortcut.modifierGlyphs(Shortcut.carbonModifiers(ev.modifierFlags))
                self.glyphLabel.stringValue = g.isEmpty ? "Type shortcut…" : g + "…"
                return nil
            }
            if ev.keyCode == UInt16(kVK_Escape) { self.cancelRecording(); return nil }
            let mods = Shortcut.carbonModifiers(ev.modifierFlags)
            guard mods != 0 else { return nil }   // require at least one modifier
            Settings.shared.setShortcut(Shortcut(keyCode: UInt32(ev.keyCode), modifiers: mods), for: self.action)
            self.stopRecording()
            self.onChange()
            return nil
        }
    }

    private func cancelRecording() { stopRecording() }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}
