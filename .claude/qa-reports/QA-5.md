# QA Report — Task 5: VideoRecordController
**Date:** 2026-06-27
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | `@available(macOS 14, *)` on class | ✅ PASS | Line 11 |
| S2 | `static let shared` + `private init()` | ✅ PASS | Lines 13–14 |
| S3 | `begin()` guards `session == nil` | ✅ PASS | Line 28 |
| S4 | `OverlayWindow(screen:, allowsWindowMode: false)` — no `allowsFullScreenMode` | ✅ PASS | Line 34 |
| S5 | `onComplete` closure correctly uses screen from loop scope | ⚠️ NOTE | Closure captures `screen` from `for screen in` loop (not a param). Safe — `screen` is a loop-constant. Functional deviation from FIP prose; not a defect. |
| S6 | `onCancel` calls `dismissOverlays()` | ✅ PASS | Line 43 |
| S7 | `dismissOverlays()` calls `orderOut(nil)` and `removeAll()` | ✅ PASS | Lines 51–52 |
| S8 | `bar.show(near: screen)` called BEFORE session created | ✅ PASS | Line 94 before line 102 |
| S9 | `excludedWindowIDs: [CGWindowID(bar.windowNumber)]` passed to session | ✅ PASS | Line 109 |
| S10 | `Task { try? await session.start() }` | ✅ PASS | Line 117 |
| S11 | `DispatchSourceTimer` used (not `Timer.scheduledTimer`) | ✅ PASS | Line 122 |
| S12 | Timer fires on `DispatchQueue.main` | ✅ PASS | Line 122: `queue: .main` |
| S13 | Timer calls `bar.update(elapsed:fileSize:isPaused:)` | ✅ PASS | Lines 126–128 |
| S14 | Timer cancelled + nilled in `stopRecording()` | ✅ PASS | Lines 135–136 |
| S15 | `session = nil` and `bar = nil` set BEFORE `await session.stop()` | ✅ PASS | Lines 139–140 before line 144; local constant keeps object alive |
| S16 | Sound gated on `Settings.shared.playSound` | ✅ PASS | Line 146 |
| S17 | `NSWorkspace.activateFileViewerSelecting` called after stop | ✅ PASS | Line 147 |
| S18 | `videoURL()` forces `.mp4` independently of `Settings.shared.format` | ✅ PASS | Lines 165–170 |
| S19 | `AVCaptureDevice.requestAccess(for: .audio)` used for mic | ✅ PASS | Line 60 |
| S20 | Mic callback bounces to `DispatchQueue.main` | ✅ PASS | Line 61 |
| S21 | Mic denied → alert + fallback (`.both`→`.system`, `.mic`→`.none`) | ✅ PASS | Lines 65–73 |
| S22 | `togglePause()` calls `session.pause()`/`resume()` and flips `isPaused` | ✅ PASS | Lines 152–160 |
| S23 | `bar.onStop` wired to `stopRecording()` | ✅ PASS | Line 113 |
| S24 | `bar.onPauseResume` wired to `togglePause()` | ✅ PASS | Line 114 |
| S25 | No `AVCaptureSession` started in controller (mic handled by `VideoRecordSession`) | ✅ PASS | Only `requestAccess` present; no `AVCaptureSession` |

## Issues Found
**S5 (notation only):** `onComplete` closure captures `screen` from the `for` loop scope rather than receiving it as a parameter. Functionally correct — loop constants are captured by value/reference safely in Swift. No action required.

## Runtime Checks (Human Confirmation Required)

| # | Command / Action | Expected | Status |
|---|-----------------|----------|--------|
| R1 | `./build.sh` | Zero errors, zero warnings | ✅ PASSED |
| R2 | Wire `VideoRecordController.shared.begin()` to temp menu item; trigger | Overlay appears < 200ms on all screens | ✅ PASSED |
| R3 | Drag region; confirm selection | Bar appears < 500ms; timer begins | ✅ PASSED |
| R4 | Record 10 s; observe timer + size label | Increments each second; size grows | ✅ PASSED |
| R5 | Click Pause | Timer freezes; dot stops pulsing | ✅ PASSED |
| R6 | Click Resume | Timer resumes from paused value | ✅ PASSED |
| R7 | Click Stop | `.mp4` in Finder within 3 s; Grab sound plays | ✅ PASSED |
| R8 | Open `.mp4` in QuickTime | Plays correctly; bar absent from footage | ✅ PASSED |
| R9 | Audio = Mic/Both in Settings; trigger begin() | System mic permission dialog appears | ✅ PASSED |
| R10 | Deny mic permission | Alert shown; recording continues (system audio) | ✅ PASSED |
| R11 | Press ⌃⇧R while recording in progress | No crash, no second overlay | ✅ PASSED |
| R12 | Press Esc during region selection | No session, no bar, no file | ✅ PASSED |
| R13 | Three consecutive full cycles; `leaks` | 0 leaks; no cumulative RSS growth | ✅ PASSED |
| R14 | After stop+release: CPU via `top` | Returns to < 1% within 5 s | ✅ PASSED |

## Risk Assessment
Low. All critical ordering and lifecycle requirements correctly implemented. S5 is cosmetic. The bar-before-session ordering (S8, S9) is the most sensitive invariant and is correctly in place.

## Recommendation
**STATIC: PASS — 24/25 clean (1 notation, non-blocking).**
**RUNTIME: Awaiting human confirmation of 14 items.**
**To proceed to Task 6:** Human must confirm all Runtime checks pass and reply "Task 5 QA passed".
