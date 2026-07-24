// m_capture — README screenshot generator (dev tool, not shipped).
// Renders the REAL UI (editor, menu, selection overlay) to PNGs by reusing the
// app's own source. Uses cacheDisplay → no Screen Recording permission needed
// and never captures the real desktop.
//
// Build & run (from repo root):
//   swiftc -O -o /tmp/shots tools/shots.swift $(ls Sources/*.swift | grep -v main.swift) \
//       -framework AppKit -framework Carbon
//   /tmp/shots assets
import AppKit

// MARK: - Capture helpers

/// Render a view (or sub-rect of it) to a bitmap using its layer/draw code.
func render(_ view: NSView, _ rect: NSRect) -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    view.display()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
        fatalError("no rep")
    }
    view.cacheDisplay(in: rect, to: rep)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(path)  (\(rep.pixelsWide)×\(rep.pixelsHigh)px)")
}

func pump(_ secs: Double) {
    let app = NSApplication.shared
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                 inMode: .default, dequeue: true) {
            app.sendEvent(e)
        }
    }
}

// MARK: - Sample "screenshot" content

/// A believable captured "hero" — the mesoneer.io marketing banner — to annotate.
/// A dark gradient card with an eyebrow, a two-line headline, body copy and two
/// CTAs; the editor wraps it in the lavender Background frame, so the result
/// reads like a real screenshot dropped into the editor.
func makeSampleImage(size: NSSize) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    let W = size.width, H = size.height

    // Dark card gradient: a soft top-left glow into a deep bottom-right.
    NSGradient(colors: [Theme.rgb(0x26, 0x1C, 0x46), Theme.rgb(0x14, 0x0F, 0x29)])?
        .draw(in: NSRect(origin: .zero, size: size), angle: -55)

    // Centered text, measured so each line sits dead-center horizontally.
    func ctext(_ s: String, _ topY: CGFloat, _ sz: CGFloat, _ col: NSColor,
               _ weight: NSFont.Weight = .regular, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: sz, weight: weight),
            .foregroundColor: col, .kern: kern,
        ]
        let str = s as NSString
        let tw = str.size(withAttributes: attrs).width
        str.draw(at: NSPoint(x: (W - tw) / 2, y: H - topY - sz), withAttributes: attrs)
    }

    ctext("SOFTWARE COMPANY FOR TRUSTED DIGITAL SOLUTIONS", 58, 13, Theme.lavender, .semibold, kern: 1.5)
    ctext("Empower Digital Trust", 100, 44, .white, .bold)
    ctext("to Simplify Life", 154, 44, .white, .bold)
    ctext("Digital trust is essential. As a software company, we deliver software solutions and expertise that strengthen",
          238, 15.5, Theme.rgb(0xC6, 0xBE, 0xDA))
    ctext("customer relationships end to end.", 265, 15.5, Theme.rgb(0xC6, 0xBE, 0xDA))

    // Two CTAs, centered: a solid white primary and an outlined secondary.
    let bW: CGFloat = 168, bH: CGFloat = 44, gap: CGFloat = 18
    let bx = (W - (bW * 2 + gap)) / 2, by = H - 392
    func button(_ label: String, _ x: CGFloat, fill: NSColor, text col: NSColor, border: NSColor? = nil) {
        let r = NSRect(x: x, y: by, width: bW, height: bH)
        fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        if let border {
            border.setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9); p.lineWidth = 1; p.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: col]
        let str = (label + "   ›") as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }
    button("Get in touch", bx, fill: .white, text: Theme.rgb(0x1A, 0x14, 0x2E))
    button("Learn more", bx + bW + gap, fill: Theme.rgb(0x2A, 0x20, 0x4C), text: .white, border: Theme.rgb(0x4A, 0x3D, 0x70))

    // Decorative accent bar at the left, fading to the right (mirrors the hero).
    NSGradient(colors: [Theme.lavender, Theme.lavender.withAlphaComponent(0)])?
        .draw(in: NSRect(x: 40, y: by + 18, width: 160, height: 9), angle: 0)

    img.unlockFocus()
    return img
}

/// The captured "screenshot" to annotate: a real sample image loaded from
/// `tools/sample.png` (run shots from the repo root). Falls back to the drawn
/// banner if the file is missing. The size is forced to the file's pixel
/// dimensions so DPI metadata can't silently shrink it.
func loadSampleImage() -> NSImage {
    let path = "tools/sample.png"
    if let img = NSImage(contentsOfFile: path), let rep = img.representations.first, rep.pixelsWide > 0 {
        img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        return img
    }
    print("  ⚠️ \(path) missing — using the drawn placeholder")
    return makeSampleImage(size: NSSize(width: 1080, height: 450))
}

// MARK: - Main

@main
struct Shots {
static func main() {
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()

// Default to a temp dir — the committed docs/assets/*.png are maintained by hand, so
// never clobber them by accident. Pass an explicit output dir to regenerate
// docs images on purpose (e.g. `./build/shots docs/assets`).
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "mcap-shots"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
print("output → \(outDir)")

guard let screen = NSScreen.main else { fatalError("no screen") }
let screenFrame = screen.frame
print("screen \(Int(screenFrame.width))×\(Int(screenFrame.height)) @\(screen.backingScaleFactor)x")

// ---- 1. Annotation editor -------------------------------------------------
// The editor fans its tool tiles out *around* the capture (Markup/Shapes/Color/
// Background/Actions framing it) — the README hero look. That scattered layout
// only kicks in when the capture is small enough to leave room on every side; a
// capture that fills the screen falls back to one crowded panel dumped over the
// image. So we deliberately size the capture smaller than the screen here.
// Pass "gathered" to instead document that single-panel fallback.
// The sample editor render is a working preview, not a committed doc asset — it
// always goes to a scratch temp dir (never `outDir`), so a docs regen
// (`./build/shots docs/assets`) can't drop it into docs/assets/. Input art is
// tools/sample.png; the doc hero editor.png is hand-maintained, not generated here.
let gathered = CommandLine.arguments.contains("gathered")
let sampleOut = gathered ? "editor_gathered.png" : "sample.png"
let sampleDir = NSTemporaryDirectory() + "mcap-sample"
try? FileManager.default.createDirectory(atPath: sampleDir, withIntermediateDirectories: true)
print("editor… (\(gathered ? "gathered" : "scattered"))")
let sample = loadSampleImage()
let sampleSize = sample.size
// Fit the capture on-screen leaving room for the scattered tool clusters on
// every side. A portrait sample is constrained by height as well as width
// (aspect preserved) so the clusters never run off-screen and silently re-gather.
let fit = gathered ? 1
    : min((screenFrame.width  - 300 * 2) / sampleSize.width,
          (screenFrame.height - 190 * 2) / sampleSize.height, 1.4)
let capSize = NSSize(width: (sampleSize.width * fit).rounded(),
                     height: (sampleSize.height * fit).rounded())
// Center the capture on screen with room for scattered tool clusters.
let sel = NSRect(x: screenFrame.minX + (screenFrame.width - capSize.width) / 2,
                 y: screenFrame.minY + (screenFrame.height - capSize.height) / 2,
                 width: capSize.width, height: capSize.height)
_ = EditorWindowController(image: sample, selectionRect: sel, screen: screen)
pump(0.4)

if let win = app.windows.first(where: { w in
        (w.contentView?.subviews.contains { $0 is CanvasView }) ?? false }),
   let content = win.contentView,
   let canvas = content.subviews.compactMap({ $0 as? CanvasView }).first {

    // The sample is shown un-annotated — just the captured image framed by the
    // tool clusters (no markup drawn on the canvas).
    content.display()

    // Crop to the capture + surrounding clusters (skip the full-screen dim view).
    var box = canvas.frame
    for v in content.subviews where v.frame != content.bounds {
        box = box.union(v.frame)
    }
    box = box.insetBy(dx: -56, dy: -56).intersection(content.bounds)
    writePNG(render(content, box), to: "\(sampleDir)/\(sampleOut)")
}

// ---- 2. Menu-bar dropdown -------------------------------------------------
print("menu…")
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = Logo.menuBarImage()
// Mirror AppDelegate.buildMenu() so the shot tracks the real menu — same items,
// same order, shortcuts pulled from Settings (the actions are no-ops; we only
// render it). Keep in sync when the app's menu changes.
let s = Settings.shared
let menu = BrandMenu(entries: [
    .header("m_capture", url: "https://github.com/tuyen-nguyen-mesoneer/m_capture"),
    .separator,
    .item(title: "Screenshot", symbol: "camera.viewfinder", shortcut: s.shortcut(.screenshot).displayString) {},
    .item(title: "Record", symbol: "record.circle", shortcut: s.shortcut(.record).displayString) {},
    .item(title: "Library", symbol: "folder", shortcut: nil) {},
    .item(title: "Settings", symbol: "gearshape", shortcut: nil) {},
    .separator,
    .item(title: "Check for Updates", symbol: "arrow.down.circle", shortcut: nil) {},
    .item(title: "Quit", symbol: "power", shortcut: nil) {},
])
if let button = statusItem.button {
    menu.toggle(from: button)
    pump(0.3)
    if let mwin = app.windows.first(where: { $0.level == NSWindow.Level.popUpMenu }),
       let mview = mwin.contentView {
        writePNG(render(mview, mview.bounds), to: "\(outDir)/menu.png")
    }
}

// ---- 3. Settings panel ----------------------------------------------------
// (The standalone About panel was removed — About is a Settings section now.)
print("settings…")
// Seed deterministic values so the doc shot is independent of the dev's own
// config. Features are shown *enabled* (checkboxes ticked, cursor/sound/copy on)
// so the panel illustrates what's available rather than reading as empty; the
// save path shows ~/Desktop (tilde-abbreviated by SettingsWindow), not a username.
let cfg = Settings.shared
cfg.saveDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop", isDirectory: true)
cfg.filenamePrefix = "m_capture_"
cfg.captureDelay = .none
cfg.captureBehavior = .editor
cfg.format = .png
cfg.paddingSize = .small
cfg.radiusSize = .small
cfg.defaultBackground = .lavender
cfg.autoCopyOnSave = true
cfg.captureCursor = true
cfg.playSound = true
SettingsWindowController.shared.show()
pump(0.3)
if let swin = app.windows.first(where: { $0 is PanelWindow }),
   let sview = swin.contentView {
    swin.makeFirstResponder(nil)   // drop the prefix field's focus ring / text selection
    // "Launch at login" is system-backed (SMAppService), not a UserDefaults flag —
    // tick its checkbox directly for the shot rather than registering a real login item.
    func allButtons(_ v: NSView) -> [NSButton] {
        v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? allButtons($0) }
    }
    if let login = allButtons(sview).first(where: { $0.attributedTitle.string.contains("login") }) {
        login.state = .on
    }
    sview.display()
    pump(0.05)
    writePNG(render(sview, sview.bounds), to: "\(outDir)/settings.png")
}

print("done")
exit(0)
}
}
