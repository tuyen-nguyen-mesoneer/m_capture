# SCStream + AVAssetWriter: PTS Normalization for Playable MP4

## Symptom

Recorded `.mp4` file is unplayable in QuickTime Player:
> "The document could not be opened. The file isn't compatible with QuickTime Player."

`mdls -name kMDItemCodecs <file>.mp4` returns `kMDItemCodecs = (null)`.

`ffprobe` shows valid HEVC frames but a broken timeline:
```
start_time=738.558333
duration=747.816689     ← 738 s empty + 9 s real content
```

## Root Cause

SCStream delivers `CMSampleBuffer` frames timestamped with **absolute mach-time** (~seconds since last boot, e.g. 738 s). If these raw PTSs are written directly into the file — or if `AVAssetWriter.startSession(atSourceTime:)` is called with the raw first PTS — AVAssetWriter writes a two-entry edit list:

```
Entry 0: media_time = -1,   duration = 443135   ← 738-second EMPTY segment
Entry 1: media_time =  0,   duration = 5555     ← 9 seconds of real content
```

The movie timeline places content starting at the 12-minute mark. QuickTime cannot play a movie with a 738-second empty preamble.

**Confirmed via ffprobe:**
```sh
ffprobe -v trace <file>.mp4 2>&1 | grep "edit list"
# Processing st: 0, edit list 0 - media_time: -1, duration: 443135
# Processing st: 0, edit list 1 - media_time:  0, duration: 5555
```

## What Does NOT Work

| Attempt | Result |
|---------|--------|
| `startSession(atSourceTime: .zero)` with raw PTSs | Same broken edit list — writer still sees 738 s PTSs |
| `startSession(atSourceTime: firstPTS)` with raw PTSs | Writer inserts 738 s empty segment before mapping media_time=0 |
| `kCVPixelFormatType_32BGRA` pixel format | Separate issue (HEVC encoder rejects BGRA) — unrelated to timing |

## The Fix

Two changes are required together:

### 1. Call `startSession(atSourceTime: .zero)`

```swift
guard writer.startWriting() else { throw ... }
writer.startSession(atSourceTime: .zero)
// Session maps movie-timeline zero to source-media zero.
// All sample buffers are normalised to zero-based time before appending.
```

### 2. Normalize every buffer's PTS before appending

Capture the raw PTS of the first buffer ever received (`sessionStartPTS`) and subtract it from every subsequent buffer. This makes the first frame land at movie time 0:00.

```swift
private var sessionStartPTS    = CMTime.invalid
private var skippedPTSDuration = CMTime.zero    // accumulates pause gaps

private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
    guard let writer = assetWriter, writer.status == .writing else { return }
    guard input.isReadyForMoreMediaData else { return }

    let rawPTS = CMSampleBufferGetPresentationTimeStamp(buffer)

    // Capture origin on first buffer.
    if sessionStartPTS == .invalid { sessionStartPTS = rawPTS }

    guard !isPaused else { return }

    // Handle resume: measure PTS gap that elapsed during pause.
    if pauseStartRawPTS != .invalid {
        let gap = CMTimeSubtract(rawPTS, pauseStartRawPTS)
        if gap.isValid && gap.seconds > 0 {
            skippedPTSDuration = CMTimeAdd(skippedPTSDuration, gap)
        }
        pauseStartRawPTS = .invalid
    }

    // Normalise: subtract session origin + accumulated pause gaps.
    let totalSkip = CMTimeAdd(sessionStartPTS, skippedPTSDuration)
    guard let normalised = buffer.subtractingPresentationTimeStamp(totalSkip) else { return }
    lastRawPTS = rawPTS
    input.append(normalised)
}
```

### 3. PTS subtraction helper — robust `CMSampleTimingInfo` query

When querying timing entry count (`entryCount: 0, arrayToFill: nil`), some CoreMedia versions return `kCMSampleBufferError_ArrayTooSmall` instead of `noErr`. Ignore the return value; only validate the count:

```swift
func subtractingPresentationTimeStamp(_ subtrahend: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    // Do NOT check return value here — some CoreMedia builds return
    // kCMSampleBufferError_ArrayTooSmall for the count-query form.
    CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0,
                                          arrayToFill: nil,
                                          entriesNeededOut: &count)
    guard count > 0 else { return nil }

    var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    guard CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count,
                                                arrayToFill: &timings,
                                                entriesNeededOut: nil) == noErr else { return nil }

    for i in timings.indices {
        timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, subtrahend)
        if timings[i].decodeTimeStamp != .invalid {
            timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, subtrahend)
        }
    }

    var adjusted: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil,
                                         sampleBuffer: self,
                                         sampleTimingEntryCount: count,
                                         sampleTimingArray: &timings,
                                         sampleBufferOut: &adjusted)
    return adjusted
}
```

## Why Normalization Preserves B-Frame Order

HEVC uses B-frames, so DTS ≤ PTS for many frames. Subtracting the same `totalSkip` from both PTS and DTS preserves the per-frame `CTTS = PTS - DTS` offsets unchanged. The decode order and B-frame reorder buffer remain correct; only the absolute timeline origin shifts to zero.

## Verification

After rebuilding:

```sh
open ~/Desktop/m_capture_*.mp4
mdls -name kMDItemCodecs ~/Desktop/m_capture_*.mp4 | tail -1
# kMDItemCodecs = ("HEVC")

ffprobe -v error -show_entries stream=start_time,duration ~/Desktop/m_capture_*.mp4
# start_time=0.000000
# duration=9.258333
```

## Related

- `Sources/VideoRecordSession.swift` — `append(_:to:)`, `subtractingPresentationTimeStamp(_:)`
- HEVC pixel format: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` required (BGRA not encodable by HEVC hardware encoder)
- SCStream `sourceRect` coordinate convention: display-local, top-left origin — different from `screencapture -R` which uses primary-height flip
