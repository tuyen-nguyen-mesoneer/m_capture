# QA Report — Task 1: Settings Enums + Keys
**Date:** 2026-06-26
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | VideoQuality: String, CaseIterable | ✅ PASS | Line 107: `enum VideoQuality: String, CaseIterable` |
| S2 | VideoQuality cases in order: high → medium → low | ✅ PASS | Line 108: `case high, medium, low` — declaration order matches spec |
| S3 | VideoQuality `label` returns correct display strings | ✅ PASS | Lines 110–116: "High (8 Mbps)", "Medium (4 Mbps)", "Low (2 Mbps)" |
| S4 | `bitrate(for resolution: CGSize) -> Int` present; base values 8M/4M/2M bps | ✅ PASS | Lines 120–131 |
| S5 | `bitrate` guards against zero-size with floor | ✅ PASS | Line 123: scale clamped at 0.01; line 130: floor at 500_000 bps |
| S6 | VideoQuality has no reference to other app types | ✅ PASS | References only CGSize, CGFloat, Int |
| S7 | VideoAudioSource: String, CaseIterable | ✅ PASS | Line 135 |
| S8 | VideoAudioSource cases in order: none → system → mic → both | ✅ PASS | Line 136 |
| S9 | VideoAudioSource `label` returns correct display strings | ✅ PASS | Lines 138–145: "None", "System Audio", "Microphone", "System + Mic" |
| S10 | `capturesSystemAudio` bool helper logically correct | ✅ PASS | Line 148: `self == .system \|\| self == .both` |
| S11 | `capturesMic` bool helper logically correct | ✅ PASS | Line 150: `self == .mic \|\| self == .both` |
| S12 | VideoAudioSource has no reference to other app types | ✅ PASS | No app types referenced |
| S13 | Key struct has `videoQuality = "videoQuality"` | ✅ PASS | Line 166 |
| S14 | Key struct has `videoAudioSource = "videoAudioSource"` | ✅ PASS | Line 166 |
| S15 | `videoQuality` get uses flatMap/init pattern, default `.high` | ✅ PASS | Lines 244–247 — identical to `captureBehavior` pattern |
| S16 | `videoQuality` set uses `d.set(newValue.rawValue, ...)` | ✅ PASS | Line 247 |
| S17 | `videoAudioSource` get uses flatMap/init pattern, default `.system` | ✅ PASS | Lines 250–253 |
| S18 | `videoAudioSource` set uses `d.set(newValue.rawValue, ...)` | ✅ PASS | Line 253 |
| S19 | No circular dependency introduced | ✅ PASS | New enums reference no app types; Background mutual dep pre-existing |
| S20 | Enums placed after PaddingSize, before Settings class | ✅ PASS | VideoQuality:107, VideoAudioSource:135, Settings class:156 |

## Runtime Checks (Human Confirmation Required)

| # | Command | Expected | Status |
|---|---------|----------|--------|
| R1 | `./build.sh` | Exit 0, zero errors, zero new warnings | ⏳ AWAITING |
| R2 | `top -pid $(pgrep m_capture) -l 2 -s 1 -stats pid,cpu,mem` | CPU delta < 0.2% vs baseline | ⏳ AWAITING |
| R3 | `leaks $(pgrep m_capture)` | 0 new leaks | ⏳ AWAITING |
| R4 | `defaults read io.mesoneer.mcapture videoQuality` | `high` (first launch) | ⏳ AWAITING |
| R5 | `defaults read io.mesoneer.mcapture videoAudioSource` | `system` (first launch) | ⏳ AWAITING |
| R6 | Write medium, relaunch, read back | `medium` persists | ⏳ AWAITING |

## Issues Found

None. All 20 static checks pass.

## Risk Assessment

Both enums are self-contained value types with no heap allocations, no app-type references, and no side effects at definition time. The `bitrate(for:)` function uses a conservative double-floor guard. UserDefaults key strings match the FIP spec exactly. The implementation is a minimal, low-risk data-model addition. Runtime confirmation is routine for a change of this scope.

## Recommendation

**STATIC: PASS** — 20/20 static checks passed.
**RUNTIME: Awaiting human confirmation of 6 items.**
**To proceed to Task 2:** Human must confirm all Runtime checks and reply "Task 1 QA passed".
