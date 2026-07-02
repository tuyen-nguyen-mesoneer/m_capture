# FIP-7: AppDelegate — Wire ⌃⇧R to VideoRecordController

## Context

This is the smallest task in the feature: replacing the single line in `AppDelegate.record()` that opens the native ⇧⌘5 toolbar with a call to `VideoRecordController.shared.begin()`, and updating the menu label to reflect the new behaviour.

Everything this task touches already exists. The risk here is almost entirely regression — breaking hotkey registration, the menu, or shortcut rebinding.

**How to verify:** ⌃⇧R must open the new region-selection overlay. ⇧⌘5 must NOT open. The menu item must read "Record Video" with the ⌃⇧R glyph. Rebinding the shortcut in Settings must still work.

---

## What to Build

### `AppDelegate.record()` body replacement

**Before:**
```swift
func record() {
    // opens the native macOS screenshot toolbar
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", "com.apple.screenshot.launcher"]
    try? p.run()
}
```

**After:**
```swift
func record() {
    guard #available(macOS 14, *) else {
        // Fallback for macOS 13: open native toolbar
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "com.apple.screenshot.launcher"]
        try? p.run()
        return
    }
    VideoRecordController.shared.begin()
}
```

### Menu label update in `buildMenu()`

Find the menu entry for `ShortcutAction.record` and update its title from `"Record"` (or `"Record Screen"`) to `"Record Video"`.

### No other changes

- `ShortcutAction.record` remains unchanged — no new enum case.
- `reloadHotKeys()` is unchanged — `HotKey` for `.record` continues to point to `record()`.
- `SettingsWindow` Shortcuts section is unchanged.

---

## Implementation Direction

1. Open `Sources/AppDelegate.swift`.
2. Replace the body of `record()` with the `#available` guard above.
3. Search `buildMenu()` for the `.record` entry; update its title string to `"Record Video"`.
4. Add `import` for `VideoRecordController` if needed (same file = no import; separate file = no import needed in Swift within the same module).
5. `./build.sh` — zero errors.
6. `open build/m_capture.app` — verify the menu.

---

## Acceptance Criteria

### CPU
- No regression in idle CPU. `reloadHotKeys()` is unchanged; Carbon event registration path is identical.
- `top` before/after: delta < 0.1%.

### Memory
- `leaks $(pgrep m_capture)` after app launch with new code — 0 leaks.
- `reloadHotKeys()` correctly deallocates old `HotKey` instances before creating new ones (existing behaviour — confirm not broken).

### UX / Correctness
- ⌃⇧R opens the new `SelectionOverlay` (not the ⇧⌘5 toolbar) on macOS 14+.
- On macOS 13: ⌃⇧R opens ⇧⌘5 toolbar (graceful fallback).
- Menu item label reads `"Record Video"` with the ⌃⇧R key glyph.
- Rebinding ⌃⇧R in Settings → Shortcuts still works; the new binding triggers `VideoRecordController.shared.begin()`.
- ⌃⇧X (screenshot) is completely unaffected.
- `./build.sh` compiles clean.

---

## Known Risks

- **`#available` guard placement:** The guard must be inside `record()`, not at the call site in the hotkey handler. If placed at the call site, it would need to be added in `reloadHotKeys()` as well, which is unnecessary complexity.
- **Menu label search:** `buildMenu()` constructs `MenuEntry` values. Find the exact string literal for the record entry — it may be `"Record"`, `"Record Screen"`, or similar. Update only that string; do not change the icon or shortcut glyph logic.
- **Module access:** `VideoRecordController` is in the same Swift module (all `Sources/*.swift` compiled together). No import needed. If the type is marked `@available(macOS 14, *)`, the call site inside the `#available` guard satisfies the compiler.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Edit | `Sources/AppDelegate.swift` | Replace `record()` body; update menu label string in `buildMenu()` |

No new files. No other files touched.

---

## Out of Scope

- New `ShortcutAction` cases
- Changes to Settings, SettingsWindow, or HotKey
- Any UI additions to AppDelegate
- macOS 13 feature parity (fallback to native toolbar is sufficient)
