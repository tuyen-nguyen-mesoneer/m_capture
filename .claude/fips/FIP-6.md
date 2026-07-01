# FIP-6: SelectionOverlay — Full-Screen Capture Mode

## Context

The current `SelectionView` supports two modes toggled by the Space key: region-drag and window-capture. Video recording needs a third: **full-screen mode**, where the user does not drag — instead the entire display is highlighted with an accent border and a single click (or ↵) confirms the selection.

This task extends `SelectionOverlay.swift` minimally and conservatively. The two existing modes (region-drag for screenshots, window-capture for screenshot) must be completely unaffected. The new flag `allowsFullScreenMode` is `false` by default, so no existing caller is impacted unless they opt in.

**How to verify:** Temporarily pass `allowsFullScreenMode: true` to `OverlayWindow` from `ScreenshotController.begin()` (revert after), press Space, confirm the full-screen border appears and the dim is replaced by a clear border. Click → confirm the returned rect equals the full screen frame. Revert the test change.

---

## What to Build

### `OverlayWindow` addition
```swift
init(screen: NSScreen, allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = false)
```
Pass `allowsFullScreenMode` down to `SelectionView`.

### `SelectionView` additions

**New mode in the private `CaptureMode` enum:**
```swift
private enum CaptureMode {
    case region
    case window       // existing
    case fullScreen   // new
}
```

**New property:**
```swift
var allowsFullScreenMode: Bool = false
```

**Space key cycle (keyDown, keyCode 49):**
- Current: `region ↔ window` (when `allowsWindowMode`)
- New cycle when `allowsFullScreenMode`:
  - `region → fullScreen → region` (if `!allowsWindowMode`, i.e. video recording)
  - `region → window → fullScreen → region` (if both flags true — unlikely but safe)

**Full-screen mode rendering (in `draw(_:)`):**
- Remove the dim gradient.
- Draw a 3pt accent-coloured (`Theme.accent`) rounded-rect border around the entire `bounds`.
- Show a centred label: `"Full Screen — click or ↵ to record"` in `Theme.labelFont`.

**Mode hint label (overlay for region mode too):**
- Bottom-centre: `"Drag to select  ·  Space: full screen"` when `allowsFullScreenMode && captureMode == .region`
- Replaces (or appends to) existing crosshair/size readout area — keep it subtle, small font.

**mouseUp in full-screen mode:**
```swift
case .fullScreen:
    onComplete?(screen.frame)   // returns the full display CGRect
```

**keyDown ↵ (keyCode 36) in full-screen mode:**
```swift
case .fullScreen:
    onComplete?(screen.frame)
```

---

## Implementation Direction

1. Open `Sources/SelectionOverlay.swift`.
2. Add `allowsFullScreenMode: Bool` parameter to `OverlayWindow.init` and `SelectionView.allowsWindowMode` equivalent.
3. Extend the private `CaptureMode` enum with `.fullScreen`.
4. Update `keyDown` Space handling: compute next mode based on which flags are enabled.
5. Update `draw(_:)`: add a `case .fullScreen:` branch that skips the dim and draws the border.
6. Update `mouseUp`: add `case .fullScreen:` that calls `onComplete?(captureScreen.frame)`.
7. Update `keyDown` ↵: same.
8. Add the bottom hint label (a sublabel `NSTextField` added lazily as a subview).
9. `./build.sh` — zero errors.

---

## Acceptance Criteria

### CPU
- Overlay in full-screen mode: CPU delta vs region mode < 1%. No extra render loop; drawing is event-driven (`needsDisplay = true`).

### Memory
- Overlay shown in full-screen mode → Esc cancel → `leaks $(pgrep m_capture)` — 0 leaks. No extra views retained.

### UX / Correctness
- Space key in video recording overlay (`allowsWindowMode: false, allowsFullScreenMode: true`) cycles `region → fullScreen → region`.
- In full-screen mode: dim is gone, accent border appears, hint label reads `"Full Screen — click or ↵ to record"`.
- Click or ↵ in full-screen mode: `onComplete` called with a rect equal to `screen.frame`.
- Esc cancels from full-screen mode (existing `onCancel` path unchanged).
- **Regression — screenshot flow (`allowsWindowMode: true, allowsFullScreenMode: false`):** Space still cycles `region ↔ window` exactly as before. No hint label shown. No behaviour change.
- **Regression — scroll capture (`allowsWindowMode: false, allowsFullScreenMode: false`):** Space has no effect (existing behaviour). No hint label. No behaviour change.
- `./build.sh` compiles clean.

---

## Known Risks

- **`screen.frame` coordinate space:** The overlay's `screen` property is set at init time (`captureScreen`). In full-screen mode, `onComplete?(captureScreen.frame)` returns the NSScreen frame in AppKit coordinates (bottom-left origin, global). The caller (`VideoRecordController`) must convert to display-local top-left for SCStream's `sourceRect`. Document this in a code comment.
- **Mode hint label overlap:** If the existing loupe or coordinate-readout UI is drawn in the same region as the new hint label, they will overlap. Place the hint at the very bottom of the overlay (last 24pt strip) and ensure it is only drawn when `allowsFullScreenMode` is true.
- **Three-mode Space cycle:** If both `allowsWindowMode` and `allowsFullScreenMode` are true, a three-state cycle is possible. This is not a current use case, but the code must not crash if both flags are set. Define the cycle order explicitly in a comment.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Edit | `Sources/SelectionOverlay.swift` | Add `allowsFullScreenMode` flag; extend `CaptureMode` enum; update Space key handler, `draw()`, `mouseUp`, `keyDown ↵`; add hint label |

No new files. No other files touched.

---

## Out of Scope

- Window-capture mode changes (untouched)
- Loupe / magnifier changes
- Any recording logic
- `VideoRecordController` calling this (Task 5 already accounts for it)
- Changes to `ScreenshotController` or `ScrollCaptureController` callers
