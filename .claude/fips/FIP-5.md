# FIP-5: VideoRecordController — Singleton Orchestrator

## Context

`VideoRecordController` is the singleton that coordinates every other piece: it shows the selection overlay, creates a `VideoRecordSession` with the right parameters, shows the `VideoRecordBar`, drives the 1 Hz update tick, handles pause/resume, and finally saves the output file.

It follows the exact same singleton + lifecycle pattern as `ScreenshotController`. AppDelegate will call `VideoRecordController.shared.begin()` (Task 7); this task makes that call meaningful.

This is also where microphone permission is requested, since the controller is the first point where `VideoAudioSource` is resolved against the actual system state.

**How to verify:** Wire `VideoRecordController.shared.begin()` to a temporary menu item, exercise the full flow: overlay → select region → bar appears → timer counts → pause → resume → stop → `.mp4` saved to Desktop.

---

## What to Build

**`VideoRecordController`** — `final class`, singleton (`static let shared`)

### Public Interface
```swift
static let shared: VideoRecordController
func begin()          // called by AppDelegate; no-op if already recording
```

### Internal State
```swift
private var session: VideoRecordSession?
private var bar: VideoRecordBar?
private var updateTimer: DispatchSourceTimer?
private var overlays: [OverlayWindow] = []
```

### Full Lifecycle

**Phase 1 — Selection**
1. `begin()`: if `session != nil`, return (prevent concurrent recordings).
2. If `audioSource` includes `.mic`, call `AVCaptureDevice.requestAccess(for: .audio)` — if denied, show an `NSAlert` explaining why mic audio won't be captured, then continue with `audioSource = .system`.
3. Create one `OverlayWindow(screen:, allowsWindowMode: false, allowsFullScreenMode: true)` per screen (Task 6 adds `allowsFullScreenMode`).
4. Set `onComplete` and `onCancel` callbacks; show all overlays.

**Phase 2 — Recording**
5. On `onComplete(region: CGRect, screen: NSScreen)`:
   - Dismiss all overlays.
   - Create `bar = VideoRecordBar()`.
   - Call `bar.show(near: screen)`.
   - Determine output URL: `Settings.shared.fileURL()` with `.mp4` extension (override the format).
   - Create `session = VideoRecordSession(region:, screen:, quality: Settings.shared.videoQuality, audioSource: effectiveAudioSource, outputURL:)`.
   - Exclude `bar.windowNumber` from SCContentFilter by passing it into the session (add an `excludedWindowIDs: [Int]` parameter to `VideoRecordSession.init`).
   - `Task { try await session.start() }`.
   - Start `updateTimer` (1 Hz `DispatchSourceTimer`) → calls `bar.update(elapsed:fileSize:isPaused:)`.
   - Set `bar.onStop = { [weak self] in self?.stopRecording() }`.
   - Set `bar.onPauseResume = { [weak self] in self?.togglePause() }`.

**Phase 3 — Stop**
6. `stopRecording()`:
   - Invalidate `updateTimer`.
   - `bar.close()`.
   - `Task { await session.stop() }` → on completion:
     - Play capture sound (`NSSound(named: "Grab")?.play()`).
     - `NSWorkspace.shared.activateFileViewerSelecting([outputURL])` (reveal in Finder).
     - `session = nil; bar = nil`.

**Phase 4 — Pause / Resume**
7. `togglePause()`: call `session.pause()` or `session.resume()` based on current state.

---

## Implementation Direction

1. Create `Sources/VideoRecordController.swift`.
2. Mark the class `@available(macOS 14, *)`.
3. For mic permission: wrap in `AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { … } }`.
4. The `updateTimer` is a `DispatchSourceTimer` set to fire on `DispatchQueue.main` every 1 second — do not use `Timer.scheduledTimer` (it requires a runloop; DispatchSourceTimer is more reliable).
5. `fileURL()` in `Settings` produces timestamped paths. Add a small extension or override to force `.mp4` suffix regardless of `Settings.shared.format`.
6. If `begin()` is called while a recording is in progress, ignore it silently (or flash the bar to acknowledge).
7. `./build.sh` — zero errors.

---

## Acceptance Criteria

### CPU
- End-to-end flow (overlay → record 10s → stop): peak CPU < 20% Apple Silicon / < 30% Intel.
- After stop and session release: CPU < 1% within 5 seconds.
- `updateTimer` at 1 Hz: CPU contribution < 0.1%.

### Memory
- Three consecutive full recording cycles (begin → 10s → stop): no cumulative RSS growth.
- After each cycle: `leaks $(pgrep m_capture)` — 0 leaks.
- `session` and `bar` are `nil` after stop; their objects must deallocate (confirmed by adding a `deinit` print during development, removed before commit).

### UX / Correctness
- Overlay appears within 200ms of `begin()`.
- Bar appears within 500ms of region confirmed.
- Timer counts correctly; pausing freezes the elapsed display.
- Stop → `.mp4` appears in Finder within 3 seconds for a 10-second clip.
- Capture sound plays on stop.
- Mic permission denied → alert shown → recording continues with system audio only.
- Pressing ⌃⇧R while recording is in progress: no crash, no second overlay (silently ignored).
- Cancel on overlay (Esc): no session created, no bar shown, no file written.
- `./build.sh` compiles clean.

---

## Known Risks

- **`@available(macOS 14, *)` bridging:** `AppDelegate` must guard any call to `VideoRecordController.shared` with `#available(macOS 14, *)`. If the app runs on macOS 13, `begin()` must be a no-op or show an alert.
- **Mic permission is async:** `requestAccess(for:)` returns on an arbitrary thread. Always bounce back to `DispatchQueue.main` before creating UI or starting the session.
- **Output URL extension:** `Settings.shared.fileURL()` uses the current `ImageFormat` to determine the extension. For video, this must always be `.mp4` regardless of the image format setting. Do not modify `fileURL()` globally — compute a separate video URL locally.
- **Bar window excluded after session start:** The bar must be shown and its `windowNumber` captured before `session.start()` is called. If the order is reversed, the bar will appear in the recording.
- **`DispatchSourceTimer` retain:** Cancel and nil the timer in `stopRecording()` to avoid a dangling timer firing after the session is gone.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Create | `Sources/VideoRecordController.swift` | New file — full implementation |

No other files modified in this task. `AppDelegate` wiring is Task 7.

---

## Out of Scope

- `SelectionOverlay` full-screen mode implementation (Task 6 — but this controller will use it)
- AppDelegate hotkey + menu wiring (Task 7)
- Any changes to screenshot capture flows
- Custom save-path UI for video files (uses the same Settings save directory as screenshots)
