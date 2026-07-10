// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics

/// A single on-screen window the user can pick to capture.
/// `frame` is in CoreGraphics global coordinates (points, top-left origin) — the
/// convention shared by `CGWindowListCopyWindowInfo` and `SCWindow.frame`.
struct PickableWindow {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String?
    let title: String?
}

/// Interactive window enumeration for the selection overlay's window-pick mode.
///
/// `CGWindowListCopyWindowInfo` is synchronous and cheap, so it can drive per-
/// `mouseMoved` hit-testing — unlike `SCShareableContent`, which is async and only
/// used later to resolve the picked `CGWindowID` into an `SCWindow` for the actual
/// capture. The window IDs are the same across both APIs.
enum WindowList {

    /// On-screen, user-capturable windows in front-to-back z-order.
    ///
    /// Filters to normal application windows (`layer == 0`, which already excludes the
    /// menu bar, Dock, desktop, and our own `screenSaver`-level overlay), drops our own
    /// process, and skips windows too small or too transparent to meaningfully target.
    static func onScreen(excludingPID pid: pid_t) -> [PickableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info -> PickableWindow? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid else { return nil }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.05 else { return nil }
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 40, h >= 40 else { return nil }
            return PickableWindow(
                id: id,
                frame: CGRect(x: x, y: y, width: w, height: h),
                ownerName: info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String
            )
        }
    }

    /// The frontmost pickable window whose frame contains `point` (CG global,
    /// top-left origin). Front-to-back z-order means the first hit is the topmost.
    static func topmost(atCGPoint point: CGPoint, excludingPID pid: pid_t) -> PickableWindow? {
        onScreen(excludingPID: pid).first { $0.frame.contains(point) }
    }

    // MARK: - Coordinate conversion (CoreGraphics ↔ AppKit)

    /// Height of the primary display — the one whose AppKit frame origin is `(0, 0)`,
    /// which anchors both coordinate systems. Used to flip Y between CG (top-left) and
    /// AppKit (bottom-left) global space.
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]).frame.height
    }

    /// Convert a CoreGraphics global rect (top-left origin) to an AppKit global rect
    /// (bottom-left origin) by flipping Y within the primary display's height.
    static func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Convert an AppKit global mouse location (bottom-left origin) to a CoreGraphics
    /// global point (top-left origin) for hit-testing against `PickableWindow.frame`.
    static func cgPoint(fromAppKitMouse p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
