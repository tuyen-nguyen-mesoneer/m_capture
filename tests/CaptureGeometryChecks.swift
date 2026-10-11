import Foundation

/// The overlay's bottom-left view rect must land on the same pixels in ScreenCaptureKit's
/// top-left space; a wrong flip captures the mirror-image strip of the display.
final class CaptureGeometryChecks: CheckSuite {
    private let displayHeight: CGFloat = 900

    @objc func checkTopRegionFlipsToTopLeftOrigin() {
        let r = CaptureGeometry.sourceRect(viewRect: CGRect(x: 10, y: 800, width: 100, height: 50),
                                           displayHeight: displayHeight)
        expect(r == CGRect(x: 10, y: 50, width: 100, height: 50), "top region → y=50, got \(r)")
    }

    @objc func checkBottomRegionFlipsToBottomOfSource() {
        let r = CaptureGeometry.sourceRect(viewRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                                           displayHeight: displayHeight)
        expect(r == CGRect(x: 0, y: 780, width: 200, height: 120), "bottom region → y=780, got \(r)")
    }

    @objc func checkFullHeightRegionStaysAtZero() {
        let r = CaptureGeometry.sourceRect(viewRect: CGRect(x: 300, y: 0, width: 400, height: 900),
                                           displayHeight: displayHeight)
        expect(r == CGRect(x: 300, y: 0, width: 400, height: 900), "full-height region → y=0, got \(r)")
    }
}
