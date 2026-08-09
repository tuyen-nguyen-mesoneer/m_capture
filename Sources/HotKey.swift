// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox

/// Minimal global hotkey registration via Carbon RegisterEventHotKey.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let handler: () -> Void
    private let id: UInt32

    private static var counter: UInt32 = 0
    private static var registry: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false

    private let keyCode: UInt32
    private let modifiers: UInt32
    private static var suspended = false

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.keyCode = keyCode
        self.modifiers = modifiers
        HotKey.counter += 1
        self.id = HotKey.counter
        HotKey.installHandlerIfNeeded()

        HotKey.registry[id] = self
        if !HotKey.suspended { register() }
    }

    private func register() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D435054), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    /// Release every registered combination while a shortcut is being recorded in
    /// Settings. Merely ignoring the handler isn't enough: a live Carbon hotkey
    /// swallows the key event system-wide, so an already-bound combination would never
    /// reach the recorder's monitor — it would look like the keypress did nothing.
    static func suspendAll() {
        guard !suspended else { return }
        suspended = true
        for hk in registry.values {
            if let r = hk.ref { UnregisterEventHotKey(r); hk.ref = nil }
        }
    }

    /// Re-register everything released by `suspendAll`.
    static func resumeAll() {
        guard suspended else { return }
        suspended = false
        for hk in registry.values where hk.ref == nil { hk.register() }
    }

    /// Register from a stored `Shortcut`.
    convenience init(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, handler: handler)
    }

    /// Unregister so the combination is freed when this object is released
    /// (lets the app rebind hotkeys by dropping the old `HotKey` instances).
    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        if handlerInstalled { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let hk = HotKey.registry[hkID.id], !HotKey.suspended {
                DispatchQueue.main.async { hk.handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

