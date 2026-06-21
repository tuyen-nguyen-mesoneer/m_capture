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

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        HotKey.counter += 1
        self.id = HotKey.counter
        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D435054), id: id) // 'MCPT'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        HotKey.registry[id] = self
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
            if let hk = HotKey.registry[hkID.id] {
                DispatchQueue.main.async { hk.handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
