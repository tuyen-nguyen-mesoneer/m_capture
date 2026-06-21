// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

let app = NSApplication.shared
// Menu-bar agent: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
