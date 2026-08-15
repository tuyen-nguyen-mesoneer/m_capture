// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

let app = NSApplication.shared
// Show a Dock icon (alongside the menu-bar item) so the app stays reachable
// even when the menu-bar icon is hidden behind the notch or a menu-bar hider.
// Settings → General can opt out of it (menu-bar-only).
AppDelegate.applyDockVisibility()
let delegate = AppDelegate()
app.delegate = delegate
app.run()

