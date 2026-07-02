// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Pure, UI-free animated-GIF writer (ImageIO — a system framework, no deps).
/// Used by the editor's before/after export: two frames, looping forever.
enum AnimatedGIF {
    /// Write `frames` as a looping GIF, each shown for `frameDuration` seconds.
    /// Returns `false` if the destination couldn't be created or finalized.
    static func write(frames: [CGImage], frameDuration: Double, to url: URL) -> Bool {
        guard !frames.isEmpty else { return false }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return false }

        let fileProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFUnclampedDelayTime as String: frameDuration,
                             kCGImagePropertyGIFDelayTime as String: frameDuration]]
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProps as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }
}

