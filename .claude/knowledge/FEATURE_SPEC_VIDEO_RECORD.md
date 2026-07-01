# Feature Spec: Smart Video Recorder

> **Status:** Planned — tasks not yet started  
> **Replaces:** `AppDelegate.record()` → native ⇧⌘5 toolbar  
> **Hotkey:** ⌃⇧R (same key, new behavior)  
> **macOS minimum:** 14.0 (SCStream audio capture; graceful no-op on 13)

---

## 1. Goal

Replace the dumb "open ⇧⌘5" shortcut with a fully in-app recorder that:
- Lets the user pick **region or full screen** at record time.
- Encodes in **HEVC (H.265)** — same perceived quality as H.264 at roughly half the bitrate.
- Respects per-user **audio source** and **quality** preferences from Settings.
- Shows a **live recording HUD** (timer, file-size estimate, pause, stop).
- Saves an `.mp4` file to the configured save folder and plays the system capture sound.

---

## 2. UX Flow

```
User presses ⌃⇧R
  │
  └─► SelectionOverlay appears (all screens)
        ├─ Drag a region  →  region confirmed
        └─ Press Space    →  toggle to full-screen mode
              (accent border around entire display, no dim)
              └─ Press Space again  →  back to region-drag mode
              └─ Click or ↵        →  full screen confirmed

  Selection confirmed
  │
  └─► Overlays dismissed
      VideoRecordSession starts
        (SCStream → HEVC frames → AVAssetWriter → .mp4)
      VideoRecordBar appears (bottom-center)
        ├─ Timer: 00:00:00
        ├─ Size: ~0 KB  (updates every second)
        ├─ [⏸ Pause]  [⏹ Stop]
        └─ Quality badge: H  M  L

  User clicks Stop (or presses Esc)
  │
  └─► Session finalised (AVAssetWriter.finishWriting)
      .mp4 saved to Settings.shared.saveDirectory
      System capture sound played
      Finder reveal (optional — same as post-screenshot behavior)
```

---

## 3. Codec & Quality Presets

**Codec:** `AVVideoCodecType.hevc` (H.265), container `.mp4`  
**Hardware:** VideoToolbox hardware encoder on Apple Silicon and Intel Macs with T2.

| Preset | Video bitrate (1080p) | Video bitrate (4K) | Expected savings vs H.264 |
|--------|-----------------------|--------------------|---------------------------|
| **High**   | 8 Mbps  | 20 Mbps | ~50 % smaller              |
| **Medium** | 4 Mbps  | 10 Mbps | ~50 % smaller              |
| **Low**    | 2 Mbps  | 5 Mbps  | ~50 % smaller              |

Frame rate: **30 fps** (fixed; matches native macOS screen recording default).  
Color space: Display P3 if display supports it; sRGB fallback.  
Pixel format: `kCVPixelFormatType_32BGRA` (SCKit default → VideoToolbox).

---

## 4. Audio Sources

| Setting | Behavior |
|---------|----------|
| `none` | No audio track |
| `system` | SCStream `capturesAudio = true` → system audio mixed into .mp4 |
| `mic` | `AVCaptureDevice.default(.builtInMicrophone)` via separate AVCaptureSession; mixed at write time |
| `both` | System audio (SCStream) + mic (AVCapture) mixed into a single stereo audio track |

Audio codec: **AAC**, 128 kbps stereo (negligible contribution to file size).

---

## 5. New Files

| File | Type | Role |
|------|------|------|
| `VideoRecordSession.swift` | class (final, @unchecked Sendable) | Core engine: SCStream + AVAssetWriter |
| `VideoRecordBar.swift` | class (final) | Floating HUD window |
| `VideoRecordController.swift` | class (final) — singleton | Orchestrator |

---

## 6. Modified Files

| File | Change |
|------|--------|
| `Settings.swift` | Add `VideoQuality` enum, `VideoAudioSource` enum, `videoQuality`/`videoAudioSource` computed properties |
| `SettingsWindow.swift` | Add "Video" section with quality + audio-source pickers |
| `SelectionOverlay.swift` | Add `allowsFullScreenMode: Bool` flag; add full-screen mode to `SelectionView` |
| `AppDelegate.swift` | Replace `record()` body; update menu label |
| `KNOWLEDGE_GRAPH.md` | Add new types, flow, extension points |

---

## 7. Architecture Diagram

```
AppDelegate.record()
  │
  └─► VideoRecordController.shared.begin()
        │
        ├─► OverlayWindow × N  (allowsWindowMode: false, allowsFullScreenMode: true)
        │     └─► SelectionView  [user picks region or full screen]
        │
        └─► VideoRecordSession.init(region: CGRect, screen: NSScreen, quality: VideoQuality, audio: VideoAudioSource)
              │
              ├─► SCStream (SCContentFilter, SCStreamConfiguration)
              │     └─► SCStreamOutput (self) ← CMSampleBuffer (video frames + system audio)
              │
              ├─► AVCaptureSession (mic only, if audioSource ∋ .mic)
              │     └─► AVCaptureAudioDataOutput ← mic PCM buffers
              │
              └─► AVAssetWriter (url: .mp4)
                    ├─► AVAssetWriterInput (video, HEVC, H.265)
                    └─► AVAssetWriterInput (audio, AAC, if audioSource ≠ .none)

              session exposes:
                start()
                pause() / resume()
                stop(completion: (URL) -> Void)
                var elapsedSeconds: TimeInterval
                var estimatedFileSize: Int64   (bytes written so far)
        │
        └─► VideoRecordBar (floating window)
              ├─ timer (DispatchSourceTimer, 1 Hz)
              ├─ size label (reads session.estimatedFileSize)
              ├─ onStop  → VideoRecordController.stopRecording()
              └─ onPause → VideoRecordController.togglePause()
```

---

## 8. Settings Keys (UserDefaults)

| Key string | Type | Default |
|------------|------|---------|
| `"videoQuality"` | String (rawValue) | `"high"` |
| `"videoAudioSource"` | String (rawValue) | `"system"` |

---

## 9. Permissions Required

| Permission | Already granted? | Notes |
|------------|-----------------|-------|
| Screen Recording | Yes (existing) | SCStream reuses the same grant |
| Microphone | No | Required only if audioSource ∋ .mic; request via `AVCaptureDevice.requestAccess` |

`Info.plist` must add `NSMicrophoneUsageDescription` (add to `build.sh` plist generation).

---

## 10. Quality Gate Framework

Every task must pass **all three gates** before the next task begins.

### CPU
Measured with `top -pid $(pgrep m_capture) -l <N> -s 1 -stats pid,cpu,mem`.

| Phase | Threshold |
|-------|-----------|
| Idle (app running, no recording) | < 1% CPU delta vs pre-feature baseline |
| Active recording — Apple Silicon | < 15% sustained (hardware HEVC encoder) |
| Active recording — Intel | < 25% sustained |
| Post-stop recovery | Returns to idle baseline within 5 seconds |

### Memory
Measured with `top` (RSS before/after) and `leaks $(pgrep m_capture)`.

| Criterion | Threshold |
|-----------|-----------|
| Leaks per task | 0 new leaks (`leaks` output clean) |
| Memory after recording stops | Within 5 MB of pre-recording baseline |
| Cumulative growth over 3 cycles | 0 net growth (no session object leaks) |

### User Experience
Latency and correctness criteria measured by hand or stopwatch.

| Criterion | Threshold |
|-----------|-----------|
| Overlay appears after hotkey | < 200 ms |
| Bar appears after selection | < 500 ms |
| Timer drift over 30 s | ± 1 s max |
| Stop → file saved | < 3 s for clips up to 60 s |
| HEVC codec confirmed | `mdls -name kMDItemCodecs <file>` returns `HEVC` |
| 30 s 1080p Medium quality | < 15 MB |
| No regression | Screenshot (⌃⇧X) and scrolling (⌃⇧S) still work after each task |

---

## 11. Task Execution Order

Tasks are **sequential** — each builds on the previous. **No task starts until its predecessor's quality gate passes.**

| # | Task | Files touched | Blocked by |
|---|------|---------------|-----------|
| 1 | Add `VideoQuality`, `VideoAudioSource` enums + Settings keys | `Settings.swift` | — |
| 2 | SettingsWindow "Video" section | `SettingsWindow.swift` | Task 1 QA ✓ |
| 3 | `VideoRecordSession` — SCStream + HEVC writer | `VideoRecordSession.swift` (new) | Task 1 QA ✓ |
| 4 | `VideoRecordBar` — floating HUD | `VideoRecordBar.swift` (new) | Task 3 QA ✓ |
| 5 | `VideoRecordController` — singleton orchestrator | `VideoRecordController.swift` (new) | Tasks 3+4 QA ✓ |
| 6 | `SelectionOverlay` full-screen mode | `SelectionOverlay.swift` | Task 5 QA ✓ |
| 7 | `AppDelegate` wiring | `AppDelegate.swift` | Tasks 5+6 QA ✓ |
| 8 | Full integration verify + `KNOWLEDGE_GRAPH.md` update | all | Task 7 QA ✓ |

---

## 12. Definition of Done

- `./build.sh` compiles clean (zero errors, zero warnings added).
- ⌃⇧R opens region-select overlay, not ⇧⌘5.
- Space toggles to full-screen mode with an accent border; Space again returns to region-drag.
- Recording starts, bar appears, timer counts up.
- Pause/resume works (timer pauses; file keeps current data).
- Stop → `.mp4` appears in save directory, plays capture sound.
- File is valid HEVC: `mdls -name kMDItemCodecs <file>` returns `HEVC`.
- File size for a 30-second 1080p clip at Medium quality is under 15 MB.
- All audio source settings produce expected output (none = no audio track; system/mic/both = audio present).
- `NSMicrophoneUsageDescription` in Info.plist; mic permission prompt shown on first mic-source use.
- `KNOWLEDGE_GRAPH.md` updated with all new types, flows, and extension points.
