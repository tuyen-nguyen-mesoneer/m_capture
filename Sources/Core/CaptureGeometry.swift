import CoreGraphics

/// Pure capture-geometry math, kept UI-free so `tests/run.sh` compiles and checks it
/// without AppKit. Everything in `Sources/Core/` is built by both `build.sh` and the runner.
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
}
