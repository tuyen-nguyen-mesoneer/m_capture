import CoreGraphics

/// Pure capture-geometry math, kept UI-free so `tests/run.sh` compiles and checks it
/// without AppKit. Everything in `Sources/Core/` is built by both `build.sh` and the runner.
/// Inputs that come from the display layout (screen origin, scale, primary height) are
/// passed in explicitly, so the checks can describe any arrangement of monitors.
enum CaptureGeometry {
    /// Maps an overlay selection to the rect ScreenCaptureKit expects for the same pixels.
    ///
    /// The overlay works in AppKit view coordinates — points, origin at the display's
    /// **bottom**-left — while `SCStreamConfiguration.sourceRect` and the frozen still are
    /// addressed from the **top**-left. So Y is flipped within *that display's* height (not
    /// the global desktop's, which on a multi-monitor setup would land on another screen's
    /// rows); X and size carry over unchanged.
    static func sourceRect(viewRect: CGRect, displayHeight: CGFloat) -> CGRect {
        CGRect(x: viewRect.minX,
               y: displayHeight - viewRect.maxY,
               width: viewRect.width, height: viewRect.height)
    }

    /// Lifts an overlay view rect (AppKit points, bottom-left of its own display) into AppKit
    /// **global** space by offsetting it by that display's frame origin — which is negative for
    /// a screen left of or below the primary, and must stay so.
    static func globalRect(viewRect: CGRect, screenOrigin: CGPoint) -> CGRect {
        CGRect(x: screenOrigin.x + viewRect.minX,
               y: screenOrigin.y + viewRect.minY,
               width: viewRect.width, height: viewRect.height)
    }

    /// Pixels per point of a captured still: its pixel width over the display width in points.
    /// This is the still's own density, not `backingScaleFactor` — the two can disagree, and
    /// only this one says where a point lands in *these* pixels.
    static func scale(pixelWidth: Int, pointWidth: CGFloat) -> CGFloat {
        CGFloat(pixelWidth) / pointWidth
    }

    /// Maps a display-local source rect (points, top-left origin) into the pixel rect of a still
    /// of `imageSize` pixels at `scale`. The origin and the size are each rounded to the nearest
    /// pixel (half away from zero) — the far edges are never rounded on their own, so don't round
    /// `maxX`/`maxY` instead, or captures shift by a pixel. The result is clamped to the image so a
    /// selection touching the display edge can't overhang it, and a rect that misses the image or
    /// rounds below one pixel returns `nil`.
    static func pixelRect(sourceRect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        let px = CGRect(x: (sourceRect.minX * scale).rounded(),
                        y: (sourceRect.minY * scale).rounded(),
                        width: (sourceRect.width * scale).rounded(),
                        height: (sourceRect.height * scale).rounded())
        let clamped = px.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// Converts a CoreGraphics global rect (top-left origin at the primary display) to an AppKit
    /// global rect (bottom-left origin) by flipping Y within the **primary** display's height —
    /// the one anchor both global spaces share.
    static func appKitRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts an AppKit global point (bottom-left origin) to a CoreGraphics global point
    /// (top-left origin), flipping Y within the primary display's height.
    static func cgPoint(fromAppKit p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
