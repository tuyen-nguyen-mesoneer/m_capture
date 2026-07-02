// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

