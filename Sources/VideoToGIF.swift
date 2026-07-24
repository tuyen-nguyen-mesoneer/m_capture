// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a finished recording (`.mp4`) into a looping animated GIF — the format
/// bug reports and chat tools actually want. AVFoundation + ImageIO only, no deps.
///
/// Frames stream from the decoder straight into the GIF destination one at a time,
/// so a long recording never holds more than a single frame in memory. 10 fps and a
/// 960 px cap are the sweet spot GIF tools converge on: enough motion to read as
/// video, small enough that the file stays shareable.
enum VideoToGIF {
    static let fps: Double = 10
    static let maxDimension: CGFloat = 960

    static func convert(mp4 url: URL, to gifURL: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return false }

        let frameCount = max(1, Int(duration * fps))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Half a frame of tolerance: exact-time seeks force a full decode per frame,
        // an order of magnitude slower, for accuracy a 10 fps GIF can't show anyway.
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // The destination is declared with `frameCount` up front and refuses to
        // finalize short — so a frame the decoder fails on repeats its neighbour
        // instead of being dropped (invisible at 10 fps, keeps the count exact).
        guard let dest = CGImageDestinationCreateWithURL(
            gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
            [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let delay = 1.0 / fps
        let frameProps = [kCGImagePropertyGIFDictionary as String:
            [kCGImagePropertyGIFUnclampedDelayTime as String: delay,
             kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary

        var lastGood: CGImage?
        var leadingGaps = 0
        for await result in generator.images(for: times) {
            if let cg = try? result.image {
                // Backfill any frames that failed before the first success.
                while leadingGaps > 0 { CGImageDestinationAddImage(dest, cg, frameProps); leadingGaps -= 1 }
                CGImageDestinationAddImage(dest, cg, frameProps)
                lastGood = cg
            } else if let cg = lastGood {
                CGImageDestinationAddImage(dest, cg, frameProps)
            } else {
                leadingGaps += 1
            }
        }
        guard lastGood != nil else { return false }
        return CGImageDestinationFinalize(dest)
    }
}
