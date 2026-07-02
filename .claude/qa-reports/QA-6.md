# QA Report — Task 6: SelectionOverlay Full-Screen Mode
**Date:** 2026-06-27
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | `CaptureMode` enum has `.fullScreen` | ✅ PASS | Line 7 |
| S2 | `OverlayWindow.init` has `allowsFullScreenMode: Bool = false` | ✅ PASS | Line 26 |
| S3 | `allowsFullScreenMode` passed to `selectionView` | ✅ PASS | Line 30 |
| S4 | `SelectionView` has `var allowsFullScreenMode: Bool = false` | ✅ PASS | Line 67 |
| S5 | `mouseDown` returns early for `.fullScreen` | ✅ PASS | Line 109 |
| S6 | `mouseDragged` returns early for `.fullScreen` | ✅ PASS | Line 115 |
| S7 | `mouseUp` `.fullScreen` calls `onComplete?(bounds)` | ✅ PASS | Lines 123–125. FIP said `onComplete?(screen.frame)` but `SelectionView` has no screen ref — `bounds` (origin .zero, full-screen size) is correct. Controller adds `screen.frame.origin` → correct on all monitors (verified below). |
| S8 | `mouseUp` `.window` / `.region` cases unchanged | ✅ PASS | Lines 121–129 |
| S9 | Space: `region → window` when `allowsWindowMode` (regression) | ✅ PASS | Line 152 |
| S10 | Space: `region → fullScreen` when `!allowsWindowMode && allowsFullScreenMode` | ✅ PASS | Lines 153–154 |
| S11 | Space: skips `.window` when `!allowsWindowMode` | ✅ PASS | Falls through to `allowsFullScreenMode` check |
| S12 | Space: `fullScreen → region` cycles back | ✅ PASS | Lines 158–159 |
| S13 | Space: no effect when both flags false | ✅ PASS | Line 154: `else { return }` |
| S14 | Return key (36) in `.fullScreen` calls `onComplete?(bounds)` | ✅ PASS | Lines 165–168 |
| S15 | Return key only fires in `.fullScreen` | ✅ PASS | Guarded by `captureMode == .fullScreen` |
| S16 | Esc (53) calls `onCancel()` regardless of mode | ✅ PASS | Line 145 |
| S17 | `draw()`: `.fullScreen` calls `drawFullScreenMode` skips dim + pill | ✅ PASS | Lines 178–180 |
| S18 | `draw()`: non-fullScreen retains original dim + draw + pill | ✅ PASS | Lines 181–186 |
| S19 | `drawFullScreenMode`: no dim; 3pt `Theme.accent` border | ✅ PASS | Lines 257–262 |
| S20 | `drawFullScreenMode`: centred instruction label | ✅ PASS | Lines 265–277 |
| S21 | `drawModePill()`: `.fullScreen` returns early | ✅ PASS | Lines 285–286 |
| S22 | `drawModePill()`: `.region` + `allowsFullScreenMode` → correct hint | ✅ PASS | Line 288 |
| S23 | `drawModePill()`: `.region` + `allowsWindowMode` → original label (regression) | ✅ PASS | Line 290 |
| S24 | No new retained subview | ✅ PASS | Hint drawn in Core Graphics; no `NSTextField` added |

## FLAG Resolution — S7/S14 Coordinate Contract

QA Leader flagged: `onComplete?(bounds)` vs FIP's `onComplete?(screen.frame)`.

**Verified:** `VideoRecordController.onComplete` adds back screen origin:
```swift
let global = CGRect(x: screen.frame.minX + rect.minX,   // + 0 for fullScreen
                    y: screen.frame.minY + rect.minY,   // + 0 for fullScreen
                    width: rect.width, height: rect.height)
```
When `rect = bounds` (origin .zero), `global` correctly equals `screen.frame` for any monitor position. **FLAG resolved — no defect.**

## Runtime Checks (Human Confirmation Required)

| # | Command / Action | Expected | Status |
|---|-----------------|----------|--------|
| R1 | `./build.sh` | Zero errors | ⏳ AWAITING |
| R2 | ⌃⇧R → overlay → Space | Dim gone, 3pt red border around screen, "Full Screen — click or ↵ to record" chip | ⏳ AWAITING |
| R3 | Full-screen mode → click | Recording starts covering full screen | ⏳ AWAITING |
| R4 | Full-screen mode → ↵ | Same as R3 | ⏳ AWAITING |
| R5 | Full-screen mode → Esc | Overlay dismisses, no recording | ⏳ AWAITING |
| R6 | Space again in full-screen | Cycles back to region mode | ⏳ AWAITING |
| R7 | ⌃⇧X → Space | Still cycles region ↔ window (no full-screen) | ⏳ AWAITING |
| R8 | `leaks` after full-screen Esc | 0 leaks | ⏳ AWAITING |
| R9 | `./build.sh` clean | No regressions in screenshot flows | ⏳ AWAITING |

## Issues Found
None. FLAG resolved (see above).

## Risk Assessment
Low. All Space-key transitions correct. Regression paths intact. Coordinate math verified correct for multi-monitor. No new retained objects.

## Recommendation
**STATIC: PASS — 24/24 (FLAG resolved by Leader coordinate verification).**
**RUNTIME: Awaiting human confirmation of 9 items.**
**To proceed to Task 8:** Human must confirm all Runtime checks pass and reply "Task 6 QA passed".
