# FIP-3: VideoRecordSession — SCStream + HEVC Encoding Engine

## Context

This is the most technically complex task. `VideoRecordSession` is the core recording engine: it sets up a `SCStream` to capture screen frames (and optionally system audio), feeds `CMSampleBuffer` data into an `AVAssetWriter` configured with the HEVC (H.265) codec, and writes an `.mp4` file to disk.

All other tasks — the bar, the controller, the wiring — are coordination layers on top of this engine. If this is wrong, everything downstream is wrong. The quality gate here is therefore the strictest.

**Scope of this task:** The session object only. No UI, no orchestration. It must be exercisable standalone (instantiate → start → wait 10s → stop → inspect the file).

**How to verify:** Instantiate a `VideoRecordSession` from a test harness or from a temporary AppDelegate call, record 10 seconds, stop, then: `mdls -name kMDItemCodecs <file>` must return `HEVC`, file must be playable in QuickTime, size must be under 10 MB for 1080p High quality.

---

## What to Build

**`VideoRecordSession`** — `final class`, `@unchecked Sendable`, marked `@available(macOS 14, *)`

### Initialiser
```swift
init(region: CGRect,           // display-local rect (top-left origin, points)
     screen: NSScreen,
     quality: VideoQuality,
     audioSource: VideoAudioSource,
     outputURL: URL)            // caller supplies the .mp4 path
```

### Public Interface
```swift
func start() async throws       // sets up SCStream + AVAssetWriter, begins capture
func pause()                    // suspends frame writes; file size stops growing
func resume()                   // resumes frame writes
func stop() async               // finalises AVAssetWriter, stops SCStream
var elapsedSeconds: TimeInterval { get }   // wall-clock time since start, paused-time excluded
var estimatedFileSize: Int64 { get }       // bytes written so far (approximate)
```

### Internal Architecture
- **Video path:** SCStream → `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` (called on SCStream's internal queue) → serial write queue → `AVAssetWriterInput.append(_:)` (HEVC)
- **System audio path (if audioSource ∋ system):** SCStream audio sample buffers → same serial write queue → `AVAssetWriterInput.append(_:)` (AAC)
- **Mic path (if audioSource ∋ mic):** `AVCaptureSession` with `AVCaptureAudioDataOutput` → its delegate queue → serial write queue → merge into audio AVAssetWriterInput
- **Pause implementation:** set a `isPaused` flag; in the write closure, drop sample buffers when paused and adjust presentation timestamps on resume to avoid gaps
- **Thread safety:** all AVAssetWriter mutations on a single private serial `DispatchQueue("io.mesoneer.mcapture.videowrite")`

### HEVC Configuration
```swift
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: pixelWidth,
    AVVideoHeightKey: pixelHeight,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: quality.bitrate(for: regionSize),
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 60,   // keyframe every 2s at 30fps
    ]
]
```

### Audio Configuration (AAC, 128 kbps stereo)
```swift
let audioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 44100,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
]
```

### SCContentFilter
Exclude the `VideoRecordBar` window and any overlay windows from the capture by window ID. Use `SCContentFilter(display:excludingWindows:)`.

---

## Implementation Direction

1. Create `Sources/VideoRecordSession.swift`.
2. Add `import ScreenCaptureKit`, `import AVFoundation`, `import AppKit`.
3. Implement `start()` as `async throws`:
   - `SCShareableContent.current` (await) → build filter excluding own windows
   - Configure `SCStreamConfiguration` (30 fps, `kCVPixelFormatType_32BGRA`, `capturesAudio: audioSource != .none`)
   - Set up `AVAssetWriter` at `outputURL`
   - Add video and (if needed) audio `AVAssetWriterInput` with `expectsMediaDataInRealTime = true`
   - `assetWriter.startWriting()` then `assetWriter.startSession(atSourceTime: .zero)`
   - `SCStream(filter:configuration:delegate:self).startCapture()` (await)
4. Implement `SCStreamOutput` conformance in an extension.
5. In the sample buffer handler: guard `!isPaused`, guard `assetWriterInput.isReadyForMoreMediaData`, then `assetWriterInput.append(buffer)`.
6. `pause()`: set `isPaused = true`. `resume()`: record the time gap and set `isPaused = false`.
7. `stop()` as `async`: `stream.stopCapture()` (await), then `assetWriter.finishWriting()` (await).
8. `./build.sh` — zero errors.

---

## Acceptance Criteria

### CPU
- 10-second 1080p recording: `top -pid $(pgrep m_capture) -l 10 -s 1 -stats pid,cpu,mem` — sustained CPU < 15% Apple Silicon / < 25% Intel.
- After `stop()`: CPU returns to < 1% within 5 seconds.

### Memory
- Memory growth during recording is bounded. Peak RSS during a 30-second recording must not exceed baseline + 50 MB.
- After `stop()` and session release: RSS returns within 5 MB of pre-recording baseline.
- `leaks $(pgrep m_capture)` after session deinits: 0 leaks from session objects.

### UX / Correctness
- `mdls -name kMDItemCodecs <output.mp4>` → `HEVC`
- File opens and plays correctly in QuickTime Player.
- 10-second 1080p High quality clip: < 10 MB.
- 10-second 1080p Medium quality clip: < 6 MB.
- `elapsedSeconds` does not advance during pause.
- `estimatedFileSize` returns a value > 0 after 2 seconds of recording.
- File is not corrupted if `stop()` is called within 1 second of `start()`.
- `leaks` clean.

---

## Known Risks

- **`SCStreamOutput` called on arbitrary thread:** Never touch AVAssetWriter directly from the SCStream callback thread. Always marshal to the serial write queue.
- **Presentation timestamp gaps on resume:** If paused buffers are dropped without adjusting `presentationTimeStamp`, the output file will have a time jump that confuses QuickTime. Maintain a running `pausedDuration` offset and apply it to PTS on resume.
- **AVAssetWriter state machine:** `append()` must not be called before `startSession(atSourceTime:)` or after `finishWriting()`. Guard with `assetWriter.status == .writing`.
- **SCContentFilter exclusion:** If the bar window is not excluded, it will appear in the recording. Get the window ID via `NSWindow.windowNumber` and pass it to `SCContentFilter(display:excludingWindows:)`.
- **Mic + system audio mixing:** Two independent buffer streams with different clocks must be interleaved on the same `AVAssetWriterInput`. Use a single audio input and funnel both sources to it; never append from two queues simultaneously.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Create | `Sources/VideoRecordSession.swift` | New file — full implementation |

No other files touched in this task.

---

## Out of Scope

- `VideoRecordBar` UI (Task 4)
- `VideoRecordController` orchestration (Task 5)
- `SelectionOverlay` full-screen mode (Task 6)
- AppDelegate wiring (Task 7)
- Microphone permission request UI (Task 5 — session may assume permission already granted)
