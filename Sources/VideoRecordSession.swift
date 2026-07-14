// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import ScreenCaptureKit

/// HEVC screen-recording engine. Sets up a `SCStream` to capture a fixed display
/// region, feeds `CMSampleBuffer` data into an `AVAssetWriter` configured for
/// HEVC (H.265) video and AAC audio, and writes an `.mp4` to the caller-supplied URL.
///
/// Thread model: all `AVAssetWriter` mutations are serialised onto `writeQueue`.
/// The `SCStreamOutput` callback arrives on SCStream's internal queue; it always
/// marshals to `writeQueue` before touching the writer. Mic buffers likewise
/// funnel to `writeQueue` via `AVCaptureAudioDataOutput`'s delegate queue.
@available(macOS 14, *)
final class VideoRecordSession: NSObject, @unchecked Sendable {

    // MARK: - Target

    /// What the session captures. A display region uses a display filter with a
    /// `sourceRect`; a window uses a `desktopIndependentWindow` filter that tracks the
    /// window (and excludes anything occluding it) with no `sourceRect`.
    enum Target {
        case region(rect: CGRect, screen: NSScreen)
        case window(CGWindowID)
    }

    // MARK: - Initialiser

    /// - Parameters:
    ///   - target: The display region or window to capture.
    ///   - quality: HEVC bitrate preset.
    ///   - audioSource: Which audio streams to mix into the output file.
    ///   - outputURL: Destination `.mp4` file path; the file must not already exist.
    ///   - excludedWindowIDs: Window IDs to suppress from the capture (typically
    ///     the recording bar). Only applies to region/display capture — a window
    ///     filter already captures nothing but the target window. Defaults to empty.
    init(target: Target,
         quality: VideoQuality,
         audioSource: VideoAudioSource,
         outputURL: URL,
         excludedWindowIDs: [CGWindowID] = []) {
        self.target = target
        self.quality = quality
        self.audioSource = audioSource
        self.outputURL = outputURL
        self.excludedWindowIDs = excludedWindowIDs
    }

    /// Invoked on the main thread if the capture stream stops on its own — permission
    /// revoked mid-recording, the captured display unplugged, etc. Lets the controller
    /// tear down the HUD and tell the user, instead of the bar ticking on forever
    /// against a dead stream. Fired at most once.
    var onUnexpectedStop: ((String) -> Void)?
    private var didReportUnexpectedStop = false
    private var isStopping = false

    // MARK: - Public interface

    /// Configures SCStream and AVAssetWriter, then begins capture.
    /// Throws if Screen Recording permission is denied or writer setup fails.
    func start() async throws {
        let content = try await SCShareableContent.current

        // Build the content filter and capture dimensions from the target. Both paths
        // size the output by `SCContentFilter.pointPixelScale` — ScreenCaptureKit's own
        // pixels-per-point — so the grab is 1:1 native with no up/down-scaling on any
        // display (plain 2×, fractional-HiDPI, and 1× externals alike). This is
        // authoritative, unlike deriving the ratio from `CGDisplayMode`, whose point
        // dimensions are ambiguous on some external monitors.
        let filter: SCContentFilter
        let capturePoints: CGSize   // capture size in points (before the pixel scale)

        switch target {
        case let .region(region, screen):
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordError.noMatchingDisplay
            }
            let excluded = content.windows.filter { excludedWindowIDs.contains(CGWindowID($0.windowID)) }
            filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            capturePoints = region.size
        case let .window(windowID):
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordError.noMatchingWindow
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            capturePoints = scWindow.frame.size
        }

        // SCStreamConfiguration — 30 fps, YUV pixels (required by HEVC).
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // A display filter captures the whole display, so the region is carved out with
        // `sourceRect` (display-local, top-left origin — the SCK convention). A window
        // filter already captures nothing but the window, so no sourceRect is set.
        if case let .region(region, screen) = target {
            cfg.sourceRect = CGRect(
                x: region.minX - screen.frame.minX,
                y: screen.frame.maxY - region.maxY,
                width: region.width,
                height: region.height
            )
        }
        let pixelWidth  = Int(capturePoints.width  * scale)
        let pixelHeight = Int(capturePoints.height * scale)
        cfg.width  = pixelWidth
        cfg.height = pixelHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // HEVC encoder requires YUV input — BGRA is not directly encodable.
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.capturesAudio = audioSource.capturesSystemAudio
        cfg.showsCursor = Settings.shared.captureCursor

        // AVAssetWriter — mp4 container.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video input: HEVC with bitrate scaled to the capture resolution.
        let regionSize = CGSize(width: capturePoints.width * scale, height: capturePoints.height * scale)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey:  pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey:         AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:       AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey:            AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:          quality.bitrate(for: regionSize),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey:     60,  // keyframe every 2 s at 30 fps
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // Adaptor must be created before adding videoInput to the writer (Apple requirement).
        // It lets us pass CVPixelBuffer + an explicit CMTime PTS directly, avoiding
        // CMSampleBufferCreateCopyWithNewTiming for video frames entirely.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                String(kCVPixelBufferWidthKey):           pixelWidth,
                String(kCVPixelBufferHeightKey):          pixelHeight,
            ]
        )
        writer.add(videoInput)

        // Audio input: AAC 128 kbps stereo, shared by both system and mic sources.
        var audioInput: AVAssetWriterInput?
        if audioSource != .none {
            let audioSettings: [String: Any] = [
                AVFormatIDKey:          kAudioFormatMPEG4AAC,
                AVSampleRateKey:        44100,
                AVNumberOfChannelsKey:  2,
                AVEncoderBitRateKey:    128_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            writer.add(ai)
            audioInput = ai
        }

        guard writer.startWriting() else {
            let err = writer.error ?? RecordError.writerFailed
            print("[VRS] startWriting FAILED: \(err)")
            throw err
        }
        // Session maps movie-timeline zero to source-media zero. All sample buffers
        // are normalised to zero-based time in append() before being handed to the
        // writer, so no empty preamble is inserted in the edit list.
        writer.startSession(atSourceTime: .zero)
        print("[VRS] startWriting OK — startSession(.zero) called — writer.status=\(writer.status.rawValue)")

        self.assetWriter  = writer
        self.videoInput   = videoInput
        self.videoAdaptor = adaptor
        self.audioInput   = audioInput

        // Start mic capture before SCStream so both sources are ready.
        if audioSource.capturesMic { startMicCapture() }

        // SCStream — delegate self to receive sample buffers.
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen,  sampleHandlerQueue: writeQueue)
        if audioSource.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        }
        do {
            try await stream.startCapture()
        } catch {
            // startCapture failed (e.g. Screen Recording permission reset after rebuild).
            // Cancel the writer so the empty output file is deleted rather than left on disk.
            writer.cancelWriting()
            throw error
        }
        self.stream = stream

        // Wall-clock start for `elapsedSeconds`.
        startTime = CACurrentMediaTime()
    }

    /// Suspends frame writes. The output file stops growing; `elapsedSeconds` pauses.
    func pause() {
        writeQueue.async { [self] in
            guard !isPaused else { return }
            isPaused = true
            pauseWallStart  = CACurrentMediaTime()
            // Snapshot the last SCStream PTS so append() can measure the exact PTS
            // gap on the first post-resume frame — same timescale, no CMTime overflow.
            pauseStartRawPTS = lastRawPTS
        }
    }

    /// Resumes frame writes. The PTS gap is measured on the next frame inside
    /// `append()` using SCStream's own clock so both sides of the CMTimeAdd share
    /// the same timescale (no LCM overflow, no wall-clock drift).
    func resume() {
        writeQueue.async { [self] in
            guard isPaused else { return }
            isPaused = false
            pausedWallDuration += CACurrentMediaTime() - pauseWallStart  // UI timer only
            print("[VRS] RESUME — waiting for first post-resume frame to measure PTS gap")
        }
    }

    /// Finalises the AVAssetWriter and stops SCStream. Safe to call immediately
    /// after `start()`. Returns only when the file is fully written.
    func stop() async {
        isStopping = true   // so didStopWithError knows this stop was intentional
        // Stop SCStream first (no more callbacks after this).
        if let stream = stream {
            try? await stream.stopCapture()
        }
        // Stop mic capture session.
        micSession?.stopRunning()

        // Finish writing on the write queue (synchronous hand-off via continuation).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                print("[VRS] stop — appendCount=\(appendCount)  writerStatus=\(assetWriter?.status.rawValue ?? -1)  isFinishing=\(isFinishing)  error=\(String(describing: assetWriter?.error))")
                // isFinishing guards against a race where didStopWithError fires during
                // stopCapture() on some macOS versions and calls markAsFinished() first;
                // calling markAsFinished() twice crashes ("already marked as finished").
                guard let writer = assetWriter, writer.status == .writing, !isFinishing else {
                    cont.resume()
                    return
                }
                isFinishing = true
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting {
                    print("[VRS] finishWriting done — status=\(writer.status.rawValue)  error=\(String(describing: writer.error))")
                    cont.resume()
                }
            }
        }
    }

    /// Wall-clock seconds since `start()`, excluding paused intervals.
    var elapsedSeconds: TimeInterval {
        guard startTime > 0 else { return 0 }
        var paused = pausedWallDuration
        // If currently paused, include the ongoing pause segment.
        if isPaused { paused += CACurrentMediaTime() - pauseWallStart }
        return CACurrentMediaTime() - startTime - paused
    }

    /// Approximate bytes written to disk. Polled on-demand; no background timer.
    var estimatedFileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Private state

    private let target:           Target
    private let quality:          VideoQuality
    private let audioSource:      VideoAudioSource
    private let outputURL:        URL
    private let excludedWindowIDs: [CGWindowID]

    /// All AVAssetWriter mutations are serialised here. SCStream callbacks and the
    /// mic delegate both dispatch to this queue before touching the writer.
    private let writeQueue = DispatchQueue(label: "io.mesoneer.mcapture.videowrite")

    private var stream:       SCStream?
    private var assetWriter:  AVAssetWriter?
    private var videoInput:   AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput:   AVAssetWriterInput?

    // Mic capture objects (non-nil only when audioSource.capturesMic).
    private var micSession:  AVCaptureSession?
    private var micOutput:   AVCaptureAudioDataOutput?

    // Pause / resume state (all accessed on writeQueue).
    private var isPaused           = false
    private var sessionStartPTS    = CMTime.invalid  // raw PTS of first buffer; normalises all PTSs to zero
    private var lastRawPTS         = CMTime.invalid  // raw PTS of last buffer that entered append()
    private var pauseStartRawPTS   = CMTime.invalid  // raw PTS snapshot taken at pause(); measured against
                                                     // the first post-resume rawPTS to get the exact PTS gap
    private var skippedPTSDuration = CMTime.zero     // accumulated pause gaps, in SCStream's timescale
    private var pauseWallStart     = 0.0             // CACurrentMediaTime() at pause — UI timer only
    private var isFinishing        = false           // guards against double markAsFinished / finishWriting

    // Per-track last-appended normalised PTS. Used to drop stale frames that were
    // captured during a pause but whose writeQueue block arrived after resume().
    // Such frames get a normPTS that goes backwards — never let them reach the writer.
    private var lastVideoNormPTS = CMTime.invalid
    private var lastAudioNormPTS = CMTime.invalid

    // Wall-clock timing (read from any thread; written once on start()).
    private var startTime          = 0.0
    private var pausedWallDuration = 0.0

    // MARK: - Helpers

    /// Starts an `AVCaptureSession` for the default microphone and routes its
    /// sample buffers through the write queue into `audioInput`.
    private func startMicCapture() {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        guard let input  = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        let output  = AVCaptureAudioDataOutput()
        // The delegate queue is separate from writeQueue; the delegate body
        // immediately re-dispatches to writeQueue so both audio sources are
        // serialised on the same queue before appending.
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "io.mesoneer.mcapture.mic"))
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        micSession = session
        micOutput  = output
    }

    /// Appends a sample buffer to the given writer input, normalising its PTS to a
    /// zero-based movie timeline. Must be called on `writeQueue`.
    ///
    /// SCStream delivers buffers with absolute mach-time PTSs (~seconds since boot).
    /// Writing these raw into the file creates a massive empty preamble in the edit
    /// list, which QuickTime Player cannot play. We subtract `sessionStartPTS` (first
    /// buffer ever received) from every buffer so the output timeline starts at 0:00.
    /// Pause gaps are also subtracted so paused intervals are invisible to the viewer.
    private var appendCount     = 0   // counts total appended buffers for log throttling
    private var scCallbackCount = 0   // counts SCStream callbacks for log throttling

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard let writer = assetWriter else {
            if appendCount == 0 { print("[VRS] append: assetWriter is nil — dropped") }
            return
        }
        guard writer.status == .writing else { return }
        guard input.isReadyForMoreMediaData else {
            if appendCount < 5 { print("[VRS] append: input NOT ready (backpressure), dropped") }
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(buffer)

        // Capture the origin PTS on the very first buffer.
        let isFirst = sessionStartPTS == .invalid
        if isFirst {
            sessionStartPTS = rawPTS
            // Log pixel format of the first video buffer so we can confirm YUV delivery.
            if let imageBuffer = CMSampleBufferGetImageBuffer(buffer) {
                let fmt = CVPixelBufferGetPixelFormatType(imageBuffer)
                print("[VRS] FIRST VIDEO BUFFER — rawPTS=\(rawPTS.seconds)s  pixelFormat=0x\(String(fmt, radix: 16))")
                // 0x3420 = '420v' = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  ✓
                // 0x42475241 = 'BGRA' = kCVPixelFormatType_32BGRA  ✗ (HEVC can't encode)
            } else {
                // Audio buffer — no image buffer is expected.
                print("[VRS] FIRST AUDIO BUFFER — rawPTS=\(rawPTS.seconds)s")
            }
        }

        guard !isPaused else { return }

        // On the first frame after a resume, measure the exact PTS gap using
        // SCStream's own clock. Both rawPTS and pauseStartRawPTS share the same
        // timescale (1 000 000 000 on Apple Silicon), so CMTimeSubtract is a plain
        // integer subtract with no LCM computation and no precision loss.
        // This replaces the wall-clock approach that used preferredTimescale: 90_000,
        // which caused LCM(1_000_000_000, 90_000) = 9_000_000_000 — overflowing
        // CMTimeScale (Int32 max ≈ 2.1 B) and corrupting every post-resume PTS.
        if pauseStartRawPTS.isValid {
            let gap = CMTimeSubtract(rawPTS, pauseStartRawPTS)
            if gap.isValid && gap.seconds > 0 {
                skippedPTSDuration = CMTimeAdd(skippedPTSDuration, gap)
            }
            pauseStartRawPTS = .invalid
            print("[VRS] PTS gap measured — gap=\(gap.seconds)s  skippedTotal=\(skippedPTSDuration.seconds)s")
        }

        // Compute the normalised PTS directly — no CMSampleBuffer copy needed for video.
        // After the first pause/resume, skippedPTSDuration shares SCStream's timescale,
        // so CMTimeAdd(sessionStartPTS, skippedPTSDuration) is always a same-scale add
        // — no LCM overflow possible.
        let totalSkip = CMTimeAdd(sessionStartPTS, skippedPTSDuration)
        let isVideo   = (input === videoInput)
        let normPTS   = CMTimeSubtract(rawPTS, totalSkip)
        let lastNorm  = isVideo ? lastVideoNormPTS : lastAudioNormPTS

        // Drop any frame whose normalised PTS is invalid or before the session origin.
        // "Invalid" case: CMTimeCompare returns 0 for any invalid operand, so the zero
        // check alone would let a garbage PTS through — guard isValid first.
        // "Pre-session" case: happens when sessionStartPTS was set by the OTHER track's
        // first buffer (e.g. video arrived first; the first audio buffer has a rawPTS
        // slightly earlier). A negative PTS permanently transitions the writer to .failed,
        // leaving the output file without a moov atom and unplayable in QuickTime Player.
        guard normPTS.isValid, CMTimeCompare(normPTS, .zero) >= 0 else {
            print("[VRS] DROP invalid/pre-session \(isVideo ? "video" : "audio") — normPTS=\(normPTS.seconds)s  rawPTS=\(rawPTS.seconds)s  sessionStart=\(sessionStartPTS.seconds)s")
            return
        }

        // Drop frames whose normalised PTS does not strictly advance past the previous one.
        // This catches frames that were captured during a pause but whose writeQueue block
        // arrived after resume() ran (so isPaused was already false). Their normPTS ends up
        // at or behind lastNorm — sending them to the writer causes FigAssetWriter
        // err=-16122 (non-monotonic PTS) and writer failure.
        // Use CMTimeCompare explicitly — avoids any ambiguity in CMTime's Comparable
        // conformance across macOS SDK versions.
        if lastNorm.isValid, CMTimeCompare(normPTS, lastNorm) <= 0 {
            print("[VRS] DROP stale \(isVideo ? "video" : "audio") — normPTS=\(normPTS.seconds)s ≤ lastNorm=\(lastNorm.seconds)s  rawPTS=\(rawPTS.seconds)s")
            return
        }

        // Video: use the pixel-buffer adaptor — pass CVPixelBuffer + explicit normPTS,
        // bypassing CMSampleBufferCreateCopyWithNewTiming for video frames entirely.
        // Drop screen-capture buffers that carry no pixel data (can happen on display
        // sleep or SCStream signal frames) rather than falling through to the audio path.
        // Audio: create a timing-adjusted CMSampleBuffer copy via subtractingPTS.
        let ok: Bool
        if isVideo {
            guard let adaptor = videoAdaptor,
                  let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                return  // No pixel data — drop silently
            }
            ok = adaptor.append(imageBuffer, withPresentationTime: normPTS)
        } else {
            guard let normalised = buffer.subtractingPresentationTimeStamp(totalSkip) else {
                print("[VRS] subtractingPresentationTimeStamp returned nil — buffer dropped")
                return
            }
            ok = input.append(normalised)
        }

        if isFirst {
            print("[VRS] FIRST APPEND — rawPTS=\(rawPTS.seconds)s  totalSkip=\(totalSkip.seconds)s  normPTS=\(normPTS.seconds)s  appended=\(ok)")
            if !ok { print("[VRS]   writer error after first append: \(String(describing: writer.error))") }
        } else if appendCount < 10 || appendCount % 30 == 0 {
            print("[VRS] append #\(appendCount) — normPTS=\(normPTS.seconds)s  appended=\(ok)")
        }
        if !ok {
            print("[VRS] APPEND FAILED #\(appendCount) \(isVideo ? "video" : "audio") — normPTS=\(normPTS.seconds)s  writerStatus=\(writer.status.rawValue)  error=\(String(describing: writer.error))")
        }

        if ok {
            if isVideo { lastVideoNormPTS = normPTS } else { lastAudioNormPTS = normPTS }
        }
        lastRawPTS  = rawPTS
        appendCount += 1
    }

    // MARK: - Errors

    enum RecordError: Error {
        case noMatchingDisplay
        case noMatchingWindow
        case writerFailed
    }
}

// MARK: - SCStreamOutput

@available(macOS 14, *)
extension VideoRecordSession: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // This callback arrives on SCStream's internal queue. Marshal everything to
        // writeQueue before touching any writer state.
        let n = scCallbackCount
        scCallbackCount += 1
        if n < 3 { print("[VRS] SCStream callback #\(n) type=\(type.rawValue)") }

        writeQueue.async { [self] in
            switch type {
            case .screen:
                guard let input = videoInput else {
                    if n < 3 { print("[VRS] SCStream #\(n): videoInput is nil") }
                    return
                }
                append(buffer, to: input)
            case .audio:
                guard let input = audioInput else { return }
                append(buffer, to: input)
            default:
                break
            }
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14, *)
extension VideoRecordSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Do NOT finalize the writer here. stop() is always the sole finalizer.
        //
        // On some macOS versions stopCapture() triggers this delegate with a
        // "user stopped" error — even on a clean stop. If we called markAsFinished()
        // here, stop()'s writeQueue block could see isFinishing=true and call
        // cont.resume() while finishWriting is still running in the background,
        // producing an incomplete file that QuickTime cannot open.
        //
        // If the stream stops unexpectedly (permission revoked etc.) without stop()
        // being called, the file will be left unfinalized — acceptable for an error
        // path. The user can still trigger stop() via the recording bar.
        print("[VRS] didStopWithError: \(error) — finalization deferred to stop()")

        // If this wasn't a stop() we initiated, the stream died on us (permission
        // revoked, display unplugged, …). Tell the controller once so it can tear down
        // the HUD and surface the reason, instead of the bar ticking against a dead
        // stream. stop() still owns finalizing whatever was written.
        guard !isStopping, !didReportUnexpectedStop else { return }
        didReportUnexpectedStop = true
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onUnexpectedStop?(reason) }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (mic)

@available(macOS 14, *)
extension VideoRecordSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Mic delegate fires on its own queue; re-dispatch to writeQueue so both
        // audio sources are serialised before they touch the shared audioInput.
        writeQueue.async { [self] in
            guard let input = audioInput else { return }
            append(sampleBuffer, to: input)
        }
    }
}

// MARK: - CMSampleBuffer PTS offset helper

private extension CMSampleBuffer {
    /// Returns a copy of the receiver with its presentation and decode timestamps
    /// reduced by `subtrahend` (used to strip accumulated pause time from PTS).
    /// Returns `nil` if the copy cannot be made.
    func subtractingPresentationTimeStamp(_ subtrahend: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        // Query the number of timing entries. Some CoreMedia implementations return
        // kCMSampleBufferError_ArrayTooSmall here even for the count-query form
        // (entryCount=0, arrayToFill=nil), so we ignore the return value and only
        // verify that count was populated with a positive value.
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
}
