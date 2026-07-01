# FIP-4: VideoRecordBar — Floating Recording HUD

## Context

While a recording is in progress, the user needs live feedback: how long they have been recording, how large the file is growing, and the ability to pause or stop without going back to the menu bar. `VideoRecordBar` is the floating window that provides this.

Its design mirrors `ScrollCaptureBar` from `ScrollCaptureController.swift` — a brand-styled dark card with a minimal control set. It must be excluded from the SCStream capture filter so it does not appear in the recorded video.

**How to verify:** Instantiate the bar standalone (e.g., show it from a temporary AppDelegate action), confirm the timer counts, pause/resume toggles the label, Esc triggers `onStop`, and the bar's `windowNumber` can be retrieved for SCContentFilter exclusion.

---

## What to Build

**`VideoRecordBar`** — `final class` (not an NSWindowController subclass; owns a private `NSWindow`)

### Public Interface
```swift
init()
func show(near screen: NSScreen)   // positions bar at bottom-centre of the recording screen
func close()
var windowNumber: Int { get }      // exposed so VideoRecordController can exclude from SCContentFilter

// Callbacks (set before show())
var onStop: (() -> Void)?
var onPauseResume: (() -> Void)?

// Called by VideoRecordController on its 1 Hz timer tick
func update(elapsed: TimeInterval, fileSize: Int64, isPaused: Bool)
```

### Visual Layout (brand-styled dark card)
```
┌─────────────────────────────────────────┐
│  ● REC   00:12:34   ~8.2 MB   [H]       │
│            [⏸ Pause]   [⏹ Stop]         │
└─────────────────────────────────────────┘
```
- Red `●` indicator (pulsing animation while recording, solid while paused)
- Timer label: `HH:MM:SS` format
- File size label: formatted as KB / MB with one decimal place
- Quality badge: `H`, `M`, or `L` in an accent-coloured rounded pill
- Pause/Resume button: toggles label between `"⏸  Pause"` and `"▶  Resume"`
- Stop button: always visible

### Key behaviours
- Window level: `.floating` — stays above app windows but does not steal key focus
- Esc key closes bar (triggers `onStop`)
- Return key triggers `onStop`
- Bar does not accept mouse clicks outside its buttons (click-through background)

---

## Implementation Direction

1. Create `Sources/VideoRecordBar.swift`.
2. Follow `ScrollCaptureBar` in `ScrollCaptureController.swift` as the structural template (private `NSWindow`, `CardView`, `BarButton`).
3. Build the window as `.nonactivatingPanel` (or `.borderless` NSWindow with `canBecomeKey` = true for Esc handling).
4. Use `Theme` constants for all colours and fonts — no hardcoded values.
5. The pulsing red dot: a 1-second `CABasicAnimation` on the dot view's `opacity` (0.3 → 1.0 → 0.3), stopped on pause.
6. `update(elapsed:fileSize:isPaused:)`: update timer label, size label, toggle animation, toggle button label. Called externally on a 1 Hz tick — do NOT start an internal timer.
7. `show(near:)`: position the bar 24 pt above the bottom edge, horizontally centred on the given screen.
8. `./build.sh` — zero errors.

---

## Acceptance Criteria

### CPU
- Bar visible and idle (recording in progress, no interaction): CPU contribution from bar < 0.3%.
- Confirmed by `top` with and without the bar showing — delta must be < 0.3%.
- No internal `Timer` or `DispatchSourceTimer` — the bar is updated externally.

### Memory
- Bar `show()` → `close()` cycle: `leaks $(pgrep m_capture)` — 0 leaks.
- Confirm `CABasicAnimation` and any `NSView` subclasses are released on `close()`.
- No retain cycle between the bar and its callback closures (use `[weak self]` where needed).

### UX / Correctness
- Timer label increments correctly when `update(elapsed:…)` is called with increasing values.
- Paused state: `●` animation stops, button label reads `"▶  Resume"`, timer label frozen (caller's responsibility — bar just displays what it receives).
- Esc and Return both trigger `onStop`.
- Bar does not appear in the SCStream output (verify by inspecting a recording made with the bar visible — bar must not be in the video).
- `windowNumber` is a valid, non-zero integer after `show()`.
- Bar stays on top of all app windows without making itself key.
- `./build.sh` compiles clean.

---

## Known Risks

- **Appearing in recording:** The bar's `windowNumber` must be passed to `SCContentFilter(display:excludingWindows:)` in `VideoRecordSession`. If `show()` is called after `VideoRecordSession.start()`, the bar may not be excluded. `VideoRecordController` (Task 5) must call `bar.show()` first and pass `bar.windowNumber` to the session before starting capture.
- **Key focus theft:** Using a standard `NSWindow` with `canBecomeKey = true` will steal focus from the user's app. Use `NSPanel` with `hidesOnDeactivate = false` and `becomesKeyOnlyIfNeeded = true`, or override `canBecomeKey` to return true only for Esc handling.
- **Retain cycles in closures:** `onStop` and `onPauseResume` are set by the controller. If the bar holds a strong reference to the controller via these closures, and the controller holds a strong reference to the bar, there is a retain cycle. Use `[weak controller]` in the closure.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Create | `Sources/VideoRecordBar.swift` | New file — full implementation |

No other files touched in this task.

---

## Out of Scope

- The 1 Hz update timer (owned by `VideoRecordController`, Task 5)
- SCContentFilter setup (VideoRecordSession, Task 3)
- Any recording logic
- Mic permission UI
