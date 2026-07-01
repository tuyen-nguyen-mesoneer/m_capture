# QA Report — Task 3: VideoRecordSession
**Date:** 2026-06-27
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | `@available(macOS 14, *)` on class | ✅ PASS | `VideoRecordSession.swift:15` |
| S2 | `@unchecked Sendable` on class | ✅ PASS | `VideoRecordSession.swift:16` |
| S3 | `SCStreamOutput` conformance in extension | ✅ PASS | `VideoRecordSession.swift:290` |
| S4 | `SCStreamDelegate` conformance in extension | ✅ PASS | `VideoRecordSession.swift:314` |
| S5 | `AVCaptureAudioDataOutputSampleBufferDelegate` conformance in extension | ✅ PASS | `VideoRecordSession.swift:331` |
| S6 | SCStream callback dispatches to `writeQueue` before touching writer state | ✅ PASS | `VideoRecordSession.swift:296` — `writeQueue.async { [self] in … }` |
| S7 | Mic delegate dispatches to `writeQueue` before touching writer state | ✅ PASS | `VideoRecordSession.swift:337` |
| S8 | `append()` guards `assetWriter.status == .writing` | ✅ PASS | `VideoRecordSession.swift:263` |
| S9 | `append()` guards `!isPaused` | ✅ PASS | `VideoRecordSession.swift:264` |
| S10 | `append()` guards `input.isReadyForMoreMediaData` | ✅ PASS | `VideoRecordSession.swift:264` |
| S11 | `CMSampleBufferCreateCopyWithNewTiming` used to offset PTS on resume | ✅ PASS | `VideoRecordSession.swift:370` |
| S12 | `pausedDuration` accumulated correctly in `resume()` | ✅ PASS | `VideoRecordSession.swift:157–159` |
| S13 | `lastPTS` updated on each append | ✅ PASS | `VideoRecordSession.swift:268, 274` |
| S14 | `elapsedSeconds` excludes paused wall time | ✅ PASS | `VideoRecordSession.swift:188–193` |
| S15 | `estimatedFileSize` uses `FileManager.attributesOfItem` (no background timer) | ✅ PASS | `VideoRecordSession.swift:198` |
| S16 | HEVC codec: `AVVideoCodecType.hevc` used | ✅ PASS | `VideoRecordSession.swift:83` |
| S17 | `AVVideoAverageBitRateKey: quality.bitrate(for: regionSize)` | ✅ PASS | `VideoRecordSession.swift:87` |
| S18 | `AVVideoExpectedSourceFrameRateKey: 30` present | ✅ PASS | `VideoRecordSession.swift:88` |
| S19 | `AVVideoMaxKeyFrameIntervalKey: 60` present | ✅ PASS | `VideoRecordSession.swift:89` |
| S20 | Audio: `kAudioFormatMPEG4AAC`, 44100 Hz, 2 ch, 128_000 bps | ✅ PASS | `VideoRecordSession.swift:100–103` |
| S21 | `expectsMediaDataInRealTime = true` on both inputs | ✅ PASS | `VideoRecordSession.swift:93, 106` |
| S22 | Single `audioInput` shared by system and mic | ✅ PASS | `VideoRecordSession.swift:97–109` |
| S23 | `audioSource != .none` guard before creating audio input | ✅ PASS | `VideoRecordSession.swift:98` |
| S24 | `audioSource.capturesSystemAudio` used for `capturesAudio` config | ✅ PASS | `VideoRecordSession.swift:74` |
| S25 | `audioSource.capturesMic` used to gate `startMicCapture()` | ✅ PASS | `VideoRecordSession.swift:122` |
| S26 | `excludedWindowIDs: [CGWindowID] = []` default parameter present | ✅ PASS | `VideoRecordSession.swift:35` |
| S27 | `SCContentFilter(display:excludingWindows:)` used (not deprecated variant) | ✅ PASS | `VideoRecordSession.swift:55` |
| S28 | `startSession(atSourceTime: .zero)` used | ✅ PASS | `VideoRecordSession.swift:115` |
| S29 | File type `.mp4` (`AVFileType.mp4`) | ✅ PASS | `VideoRecordSession.swift:78` |
| S30 | `markAsFinished()` called on both inputs before `finishWriting` in `stop()` | ✅ PASS | `VideoRecordSession.swift:180–181` |
| S31 | `withCheckedContinuation` wraps `finishWriting` in `stop()` | ✅ PASS | `VideoRecordSession.swift:174` |
| S32 | `stream.stopCapture()` called before `finishWriting` in `stop()` | ✅ PASS | `VideoRecordSession.swift:167–169` |
| S33 | `SCStreamDelegate.stream(_:didStopWithError:)` handles unexpected stop | ✅ PASS | `VideoRecordSession.swift:315–325` |
| S34 | `sourceRect` set on `SCStreamConfiguration` | ✅ PASS | `VideoRecordSession.swift:62–67` |
| S35 | Pixel dimensions use `screen.backingScaleFactor` | ✅ PASS | `VideoRecordSession.swift:59, 68–69` |

## Deviations (non-blocking)
- `cfg.showsCursor = Settings.shared.captureCursor` added (FIP silent on this). Consistent with user preferences. Not a defect.
- SCStream callback registered on `writeQueue` via `sampleHandlerQueue: writeQueue`, then re-dispatches `writeQueue.async` internally — one extra hop per frame, harmless, correct.

## Runtime Checks (Human Confirmation Required)

| # | Command / Action | Expected | Status |
|---|-----------------|----------|--------|
| R1 | `./build.sh` from project root | Exit 0, zero errors/warnings | ✅ PASSED |
| R2 | Record 10 s; `mdls -name kMDItemCodecs <output.mp4>` | Output contains `HEVC` | ⏳ AWAITING |
| R3 | Open output `.mp4` in QuickTime Player | Plays back without error | ⏳ AWAITING |
| R4 | 10 s 1080p High quality: check file size | < 10 MB | ⏳ AWAITING |
| R5 | 10 s 1080p Medium quality: check file size | < 6 MB | ⏳ AWAITING |
| R6 | `top -pid $(pgrep m_capture) -l 10 -s 1 -stats pid,cpu,mem` during recording | Sustained CPU < 15% (Apple Silicon) / < 25% (Intel) | ⏳ AWAITING |
| R7 | After `stop()`: same `top` session | Returns to < 1% within 5 s | ⏳ AWAITING |
| R8 | 30 s recording: observe RSS (Activity Monitor or `leaks`) | Peak RSS ≤ baseline + 50 MB | ⏳ AWAITING |
| R9 | After `stop()` + session release: observe RSS | Returns within 5 MB of pre-recording baseline | ⏳ AWAITING |
| R10 | `leaks $(pgrep m_capture)` after session deinit | 0 leaks from session objects | ⏳ AWAITING |
| R11 | Pause during recording; observe `elapsedSeconds` | Does not advance while paused | ⏳ AWAITING |
| R12 | `estimatedFileSize` polled 2 s after `start()` | Returns value > 0 | ⏳ AWAITING |
| R13 | `stop()` within 1 s of `start()` | File not corrupted; QuickTime opens it | ⏳ AWAITING |

## Issues Found
None. All 35 static checks passed.

Two non-blocking observations:
1. **`elapsedSeconds` reads `isPaused`/`pauseWallStart` from the main thread** while those vars are mutated on `writeQueue`. Theoretical data race (scalar reads — worst case is one stale frame in the progress display). Acceptable for a UI timer; not a file-integrity concern.
2. **`pausedDuration` gap**: if no frames arrive during a pause, gap is `.zero` and no offset accumulates. Correct behaviour — no frames dropped means no PTS gap.

## Risk Assessment
Architecturally sound. All thread-safety invariants are enforced: both SCStream and mic callbacks marshal to `writeQueue`; `append()` enforces all guards; `stop()` correctly sequences `stopCapture → markAsFinished × 2 → finishWriting` with a checked continuation. PTS gap compensation uses the correct low-level API (`CMSampleBufferCreateCopyWithNewTiming`). Single shared `audioInput` avoids the two-stream interleaving race. The only residual risk is the cosmetic data race on `elapsedSeconds`, which does not affect file integrity. Overall risk: **low**.

## Recommendation
**STATIC: PASS — 35/35 static checks passed.**
**RUNTIME R1: PASSED** — build clean, zero errors.
**RUNTIME R2–R13: DEFERRED to Task 8** — require full stack (VideoRecordController + AppDelegate wiring) to produce a real recording file.
**RUNTIME: Awaiting human confirmation of 13 items.**
**To proceed to Task 4:** Human must confirm all Runtime checks pass and reply "Task 3 QA passed".
