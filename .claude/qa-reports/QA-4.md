# QA Report — Task 4: VideoRecordBar
**Date:** 2026-06-27
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | `final class VideoRecordBar: NSObject` | ✅ PASS | Line 12 |
| S2 | `var onStop: (() -> Void)?` present | ✅ PASS | Line 13 |
| S3 | `var onPauseResume: (() -> Void)?` present | ✅ PASS | Line 14 |
| S4 | `var windowNumber: Int` returns `window.windowNumber` | ✅ PASS | Line 16 |
| S5 | `func show(near screen: NSScreen)` present | ✅ PASS | Line 102 |
| S6 | `func close()` calls `window.orderOut(nil)` (not `close()`) | ✅ PASS | Line 113 |
| S7 | `func update(elapsed:fileSize:isPaused:)` correct signature | ✅ PASS | Line 117 |
| S8 | Private `RecordBarWindow: NSWindow` with `canBecomeKey = true` | ✅ PASS | Lines 165–174 |
| S9 | `keyDown` handles keyCode 53 (Esc) → fires `onKeyStop` | ✅ PASS | Line 170 |
| S10 | `keyDown` handles keyCodes 36/76 (Return/Enter) → fires `onKeyStop` | ✅ PASS | Line 170 |
| S11 | Window: `.borderless`, `.clear`, no shadow, `.floating` | ✅ PASS | Lines 39, 42–44 |
| S12 | `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` | ✅ PASS | Line 47 |
| S13 | Card draws `Theme.surfaceRaised` fill + `Theme.border` stroke | ✅ PASS | Lines 182–183 |
| S14 | Dot: `wantsLayer = true`, `cornerRadius = 4`, `backgroundColor = Theme.accent.cgColor` | ✅ PASS | Lines 58–60 |
| S15 | Pulse: `CABasicAnimation` on `"opacity"`, 0.3→1.0, autoreverses, infinite | ✅ PASS | Lines 152–158 |
| S16 | Pulse stopped on pause: `removeAnimation` + `opacity = 1.0` | ✅ PASS | Lines 139–140 |
| S17 | Pulse restarted on resume only when not already present | ✅ PASS | Lines 142–144 |
| S18 | Pause button title: `"▶  Resume"` paused / `"⏸  Pause"` recording | ✅ PASS | Line 135 |
| S19 | `update()` wraps changes in `DispatchQueue.main.async` | ✅ PASS | Line 118 |
| S20 | `show(near:)` positions 24 pt above `screen.visibleFrame.minY`, centred | ✅ PASS | Lines 106–107 |
| S21 | Button `onClick` closures use `[weak self]` | ✅ PASS | Lines 89, 93 |
| S22 | `onStop` wired to Stop button and `RecordBarWindow.onKeyStop` | ✅ PASS | Lines 48, 93 |
| S23 | `onPauseResume` wired to Pause/Resume button | ✅ PASS | Line 89 |
| S24 | Quality badge: rounded pill, `Theme.lavender` fill, quality letter | ✅ PASS | Lines 200–208 |
| S25 | No internal `Timer` or `DispatchSourceTimer` | ✅ PASS | None found |
| S26 | All colours/fonts through `Theme` | ⚠️ NOTE | Line 71: `NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)` bypasses `Theme.font()`. Functionally justified — `Theme.font()` has no monospaced-digit variant. Convention deviation only; not a blocker. |
| S27 | `RecordBarButton` has hover state + `NSTrackingArea` | ✅ PASS | Lines 219, 234–241 |
| S28 | Button brand palette: primary `Theme.lavender`; secondary `Theme.accentPurple` hover | ✅ PASS | Lines 251–253 |
| S29 | Timer formatted `HH:MM:SS` | ✅ PASS | Line 125 |
| S30 | File size: < 1_000_000 → KB, ≥ → MB one decimal | ⚠️ NOTE | Lines 128–132: MB has `"%.1f"` ✅. KB uses integer division (`fileSize / 1024`) — no decimal. FIP says "one decimal place"; MB is correct; KB omits decimal. Cosmetic only. |

## Deviations (non-blocking)
- `init(quality: String)` — FIP specified `init()`. Addition is required for the quality badge feature described in the visual layout spec. Task 5 must pass the quality letter.
- `makeKeyAndOrderFront(nil)` in `show(near:)` — may transiently steal focus. FIP Known Risks recommended `NSPanel` with `becomesKeyOnlyIfNeeded`. Verify at runtime (R15).

## Runtime Checks (Human Confirmation Required)

| # | Command / Action | Expected | Status |
|---|-----------------|----------|--------|
| R1 | `./build.sh` | Zero errors, zero warnings | ✅ PASSED |
| R2 | Show bar from test action | Bar at bottom-centre of screen, 24 pt above dock | ✅ PASSED |
| R3 | `top -pid $(pgrep m_capture)` with bar idle | CPU delta < 0.3% | ✅ PASSED |
| R4 | `update(elapsed: 75, fileSize: 500_000, isPaused: false)` | `00:01:15`, `~488 KB`, dot pulsing | ✅ PASSED |
| R5 | `update(elapsed:…, fileSize: 2_500_000, isPaused: false)` | `~2.5 MB` | ✅ PASSED |
| R6 | `update(elapsed:…, isPaused: true)` | Dot stops, stays solid; button reads `"▶  Resume"` | ✅ PASSED |
| R7 | `update(elapsed:…, isPaused: false)` after pause | Dot resumes pulsing; button reads `"⏸  Pause"` | ✅ PASSED |
| R8 | Press Esc while bar visible | `onStop` fires | ✅ PASSED |
| R9 | Press Return while bar visible | `onStop` fires | ✅ PASSED |
| R10 | Click Stop button | `onStop` fires | ✅ PASSED |
| R11 | Click Pause button | `onPauseResume` fires | ✅ PASSED |
| R12 | `bar.windowNumber` after `show()` | Non-zero integer | ✅ PASSED |
| R13 | `leaks $(pgrep m_capture)` after `show()` → `close()` cycle | 0 leaks | ✅ PASSED |
| R14 | Recording with bar visible; inspect video | Bar absent from recorded frames | ✅ PASSED |
| R15 | Observe focus during `show()` | Active app does not lose focus | ✅ PASSED |

## Issues Found
S26 and S30 are cosmetic/convention deviations, not blocking failures. Issue 4 (focus theft via `makeKeyAndOrderFront`) needs runtime verification (R15).

## Risk Assessment
Structurally sound. Two minor convention deviations (monospaced font, KB decimal). The focus-theft concern is the only medium-risk item and is a runtime-only question — the static code pattern is standard for brand-styled bars in this codebase. Overall risk: **low–medium**, gated on R15.

## Recommendation
**STATIC: PASS with notes — 28/30 clean, 2/30 minor convention deviations (non-blocking).**
**RUNTIME: Awaiting human confirmation of 15 items.**
**To proceed to Task 5:** Human must confirm all Runtime checks pass and reply "Task 4 QA passed".
