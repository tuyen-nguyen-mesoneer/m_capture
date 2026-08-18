// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

/// Output file format for saved captures (clipboard copies stay images regardless).
/// Always encodes at best quality — PNG and TIFF are lossless; JPEG and HEIC use
/// maximum quality (no compression trade-off exposed to the user).
enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic, tiff

    var ext: String { self == .jpeg ? "jpg" : rawValue }
    /// The matching uniform type, for the Save As panel's allowed content type.
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return UTType("public.heic") ?? .image
        case .tiff: return .tiff
        }
    }
    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    func encode(_ rep: NSBitmapImageRep) -> Data? {
        switch self {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .tiff:
            return rep.representation(using: .tiff, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 1.0])
        case .heic:
            guard let cg = rep.cgImage else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        }
    }
}

/// How long to wait (with a menu-bar countdown) before the selection overlay
/// appears — lets you set up menus / hover states first.
enum CaptureDelay: Int, CaseIterable {
    case none = 0, three = 3, five = 5, ten = 10
    var label: String { self == .none ? L("None") : "\(rawValue)s" }
}

/// The UI language: follow the primary system language, or force one of the
/// shipped languages regardless of Language & Region.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case german = "de"
    case vietnamese = "vi"
    /// Native names, the convention for language pickers; only "System" localizes.
    var label: String {
        switch self {
        case .system:     return L("System")
        case .english:    return "English"
        case .german:     return "Deutsch"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

/// What happens the instant a screenshot is captured: open the annotation
/// editor (the default), save straight to the configured folder, or just put it
/// on the clipboard. Applies to region and window captures.
enum CaptureBehavior: String, CaseIterable {
    case editor, save, copy
    var label: String {
        switch self {
        case .editor: return L("Open editor")
        case .save:   return L("Save to file")
        case .copy:   return L("Copy to clipboard")
        }
    }
}

/// A global hotkey: a virtual key code plus a Carbon modifier mask
/// (`controlKey | shiftKey | …`).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// The capture actions that each have a rebindable global hotkey.
enum ShortcutAction: String, CaseIterable {
    case screenshot, record, draw, forceQuit

    var label: String {
        switch self {
        case .screenshot:  return L("Screenshot")
        case .record:      return L("Record")
        case .draw:        return L("Draw on Screen")
        case .forceQuit:   return L("Force Quit")
        }
    }

    var defaultShortcut: Shortcut {
        let cs = UInt32(controlKey | shiftKey)
        switch self {
        case .screenshot:  return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: cs)
        case .record:      return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: cs)
        case .draw:        return Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: cs)
        case .forceQuit:   return Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey | shiftKey))
        }
    }

    fileprivate var defaultsKey: String { "shortcut_\(rawValue)" }
}

/// Padding amount for share-ready backgrounds, as a fraction of the longest
/// image dimension. Drives `Background.padding(maxDim:)`, so the editor preview,
/// the baked export, and the Pin window all stay in sync.
enum PaddingSize: String, CaseIterable {
    case small, medium, large
    var scale: CGFloat { self == .small ? 0.02 : self == .medium ? 0.03 : 0.045 }
    var label: String { L(rawValue.capitalized) }
}

/// Corner-rounding amount for share-ready backgrounds. `.none` = square corners;
/// `.medium` is the original look (multiplier 1.0).
enum RadiusSize: String, CaseIterable {
    case none, small, medium, large
    var scale: CGFloat {
        switch self {
        case .none: return 0
        case .small: return 0.5
        case .medium: return 1.0
        case .large: return 1.75
        }
    }
    var label: String { self == .none ? L("Square") : L(rawValue.capitalized) }
}

/// HEVC recording bitrate preset. `bitrate(for:)` scales the base rate by pixel
/// count relative to 1080p, so small regions record at a proportionally lower rate.
enum VideoQuality: String, CaseIterable {
    case high, medium, low
    var label: String {
        switch self {
        case .high:   return L("High (8 Mbps)")
        case .medium: return L("Medium (4 Mbps)")
        case .low:    return L("Low (2 Mbps)")
        }
    }
    func bitrate(for resolution: CGSize) -> Int {
        let reference: CGFloat = 1920 * 1080
        let pixels = resolution.width * resolution.height
        let scale = max(pixels / reference, 0.01)
        let base: Int
        switch self {
        case .high:   base = 8_000_000
        case .medium: base = 4_000_000
        case .low:    base = 2_000_000
        }
        return max(Int(CGFloat(base) * scale), 500_000)
    }
}

/// Which audio streams to mix into a video recording.
enum VideoAudioSource: String, CaseIterable {
    case none, system, mic, both
    var label: String {
        switch self {
        case .none:   return L("None")
        case .system: return L("System Audio")
        case .mic:    return L("Microphone")
        case .both:   return L("System + Mic")
        }
    }
    var capturesSystemAudio: Bool { self == .system || self == .both }
    var capturesMic: Bool { self == .mic || self == .both }
}

/// A tool for the on-screen drawing overlay (draw mode while recording). Single letters
/// switch tools *inside* draw mode rather than claiming global hotkeys: the overlay owns
/// the keyboard while it is up, so five more system-wide combinations would buy nothing.
/// The default letters match the annotation editor's, so the two surfaces feel like one app.
enum DrawTool: String, CaseIterable {
    case pencil, rectangle, circle, line, arrow

    var label: String {
        switch self {
        case .pencil:    return L("Pencil")
        case .rectangle: return L("Rectangle")
        case .circle:    return L("Circle")
        case .line:      return L("Line")
        case .arrow:     return L("Arrow")
        }
    }

    var defaultKey: String {
        switch self {
        case .pencil:    return "P"
        case .rectangle: return "R"
        case .circle:    return "C"
        case .line:      return "L"
        case .arrow:     return "A"
        }
    }

    var symbol: String {
        switch self {
        case .pencil:    return "pencil.tip"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .line:      return "line.diagonal"
        case .arrow:     return "arrow.up.right"
        }
    }

    fileprivate var keyDefaultsKey: String { "drawKey_\(rawValue)" }
}

/// How long a finished drawing mark stays on screen before it fades away.
enum DrawFade: Int, CaseIterable {
    case two = 2, three = 3, five = 5, ten = 10, never = 0
    var label: String { self == .never ? L("Never — clear manually") : "\(rawValue)s" }
    /// Seconds before the fade begins, or nil to keep the mark until it is cleared.
    var delay: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

/// Stroke thickness for on-screen drawing, in points.
enum DrawStroke: Int, CaseIterable {
    case thin = 2, medium = 4, thick = 7, heavy = 10
    var label: String {
        switch self {
        case .thin:   return L("Thin")
        case .medium: return L("Medium")
        case .thick:  return L("Thick")
        case .heavy:  return L("Heavy")
        }
    }
    var width: CGFloat { CGFloat(rawValue) }
}

/// Persisted output preferences (save location, format, filename prefix,
/// auto-copy). The single source of truth for where and how captures are saved;
/// the editor, the pin window, and the Library menu all read it.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let dir = "saveDirectory", format = "imageFormat"
        static let autoCopy = "autoCopyOnSave"
        static let cursor = "captureCursor", sound = "playSound"
        static let delay = "captureDelay", padding = "paddingSize", defaultBG = "defaultBackground"
        static let radius = "radiusSize"
        static let behavior = "captureBehavior", prefix = "filenamePrefix"
        static let confirmDiscard = "confirmDiscard"
        static let videoQuality = "videoQuality", videoAudioSource = "videoAudioSource"
        static let videoFrameRate = "videoFrameRate", videoShowClicks = "videoShowClicks"
        static let videoCountdown = "videoCountdown", videoBarMinimized = "videoBarMinimized"
        static let simulateRecording = "simulateRecording"
        static let drawColor = "drawColor", drawStroke = "drawStroke"
        static let drawFade = "drawFade", drawTool = "drawTool"
        static let lastRegion = "lastRegion"
        static let appLanguage = "appLanguage"
        static let hideDock = "hideDockIcon"
    }

    private let defaultPrefix = "m_capture_"

    private var defaultDirectory: URL {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory(), isDirectory: true)
    }

    var saveDirectory: URL {
        get { d.string(forKey: Key.dir).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory }
        set { d.set(newValue.path, forKey: Key.dir) }
    }

    var format: ImageFormat {
        get { d.string(forKey: Key.format).flatMap(ImageFormat.init) ?? .png }
        set { d.set(newValue.rawValue, forKey: Key.format) }
    }

    /// Copy to the clipboard when saving straight to a file (default on). Unset
    /// reads as on; once the user toggles it, their choice is respected.
    var autoCopyOnSave: Bool {
        get { d.object(forKey: Key.autoCopy) == nil ? true : d.bool(forKey: Key.autoCopy) }
        set { d.set(newValue, forKey: Key.autoCopy) }
    }

    /// Show the "Discard capture?" confirmation when closing the editor without
    /// saving (default on). Unset reads as on; once the user toggles it, their
    /// choice is respected.
    var confirmDiscard: Bool {
        get { d.object(forKey: Key.confirmDiscard) == nil ? true : d.bool(forKey: Key.confirmDiscard) }
        set { d.set(newValue, forKey: Key.confirmDiscard) }
    }

    /// What to do the moment a region/window capture is taken (default: editor).
    var captureBehavior: CaptureBehavior {
        get { d.string(forKey: Key.behavior).flatMap(CaptureBehavior.init) ?? .editor }
        set { d.set(newValue.rawValue, forKey: Key.behavior) }
    }

    /// Leading text on saved filenames (default `m_capture_`). Sanitized of path
    /// separators; an empty/whitespace value falls back to the default.
    var filenamePrefix: String {
        get {
            let raw = (d.string(forKey: Key.prefix) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = raw.components(separatedBy: CharacterSet(charactersIn: "/:")).joined()
            return clean.isEmpty ? defaultPrefix : clean
        }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.prefix) }
    }

    /// The global hotkey for an action (falls back to its default if unset).
    func shortcut(_ action: ShortcutAction) -> Shortcut {
        let packed = d.integer(forKey: action.defaultsKey)
        guard packed != 0 else { return action.defaultShortcut }
        return Shortcut(keyCode: UInt32(packed & 0xFFFF), modifiers: UInt32((packed >> 16) & 0xFFFF))
    }

    func setShortcut(_ s: Shortcut, for action: ShortcutAction) {
        d.set(Int(s.modifiers) << 16 | Int(s.keyCode), forKey: action.defaultsKey)
    }

    /// The label of whatever already claims `s`, or nil if it's free. Carbon refuses a
    /// second registration of the same combination, so a duplicate would silently leave
    /// one action dead — the recorder rejects the binding up front instead.
    /// Covers the derived ⌥ + record "discard" binding, which is registered too.
    func shortcutConflict(_ s: Shortcut, excluding action: ShortcutAction) -> String? {
        for other in ShortcutAction.allCases where other != action {
            if shortcut(other) == s { return other.label }
        }
        let record = shortcut(.record)
        if record.modifiers & UInt32(optionKey) == 0,
           action != .record,
           s == Shortcut(keyCode: record.keyCode, modifiers: record.modifiers | UInt32(optionKey)) {
            return L("Discard recording")
        }
        // Rebinding Record itself: its own ⌥ variant must not land on another action.
        if action == .record, s.modifiers & UInt32(optionKey) == 0 {
            let derived = Shortcut(keyCode: s.keyCode, modifiers: s.modifiers | UInt32(optionKey))
            for other in ShortcutAction.allCases where other != .record {
                if shortcut(other) == derived { return other.label }
            }
        }
        return nil
    }

    /// Include the mouse pointer in captures (`screencapture -C`).
    var captureCursor: Bool {
        get { d.bool(forKey: Key.cursor) }
        set { d.set(newValue, forKey: Key.cursor) }
    }

    /// Play the shutter sound when capturing (otherwise `screencapture -x`).
    var playSound: Bool {
        get { d.bool(forKey: Key.sound) }
        set { d.set(newValue, forKey: Key.sound) }
    }

    /// The UI language: follow the system, or an explicit in-app override.
    /// Read once at launch by `L10n.table` — changes apply after a relaunch.
    var appLanguage: AppLanguage {
        get { d.string(forKey: Key.appLanguage).flatMap(AppLanguage.init) ?? .system }
        set { d.set(newValue.rawValue, forKey: Key.appLanguage) }
    }

    /// Seconds to wait before the selection overlay appears (0 = immediate).
    var captureDelay: CaptureDelay {
        get { CaptureDelay(rawValue: d.integer(forKey: Key.delay)) ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.delay) }
    }

    /// Padding amount for share-ready backgrounds (default small).
    var paddingSize: PaddingSize {
        get { d.string(forKey: Key.padding).flatMap(PaddingSize.init) ?? .small }
        set { d.set(newValue.rawValue, forKey: Key.padding) }
    }

    /// Corner-rounding amount for share-ready backgrounds (default square).
    var radiusSize: RadiusSize {
        get { d.string(forKey: Key.radius).flatMap(RadiusSize.init) ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.radius) }
    }

    /// HEVC bitrate preset for video recordings (default high).
    var videoQuality: VideoQuality {
        get { d.string(forKey: Key.videoQuality).flatMap(VideoQuality.init) ?? .high }
        set { d.set(newValue.rawValue, forKey: Key.videoQuality) }
    }

    /// Recording frame rate (default 30; 60 for smoother motion at ~2× file size).
    var videoFrameRate: Int {
        get { let v = d.integer(forKey: Key.videoFrameRate); return v == 60 ? 60 : 30 }
        set { d.set(newValue, forKey: Key.videoFrameRate) }
    }

    /// Show a ripple over mouse clicks while recording, so clicks read in the video.
    var videoShowClicks: Bool {
        get { d.bool(forKey: Key.videoShowClicks) }
        set { d.set(newValue, forKey: Key.videoShowClicks) }
    }

    /// Start recordings with the floating bar minimized to the menu bar (default on).
    /// Unset reads as on; once the user toggles it, their choice is respected.
    var videoStartBarMinimized: Bool {
        get { d.object(forKey: Key.videoBarMinimized) == nil ? true : d.bool(forKey: Key.videoBarMinimized) }
        set { d.set(newValue, forKey: Key.videoBarMinimized) }
    }

    /// Colour of marks drawn on screen while recording. Stored as `RRGGBB` rather than an
    /// archived `NSColor`, so the preference stays readable and isn't tied to AppKit's
    /// archive format.
    var drawColor: NSColor {
        get { Self.color(fromHex: d.string(forKey: Key.drawColor) ?? "") ?? Theme.accent }
        set { d.set(Self.hex(newValue), forKey: Key.drawColor) }
    }

    /// Stroke thickness for on-screen drawing (default medium).
    var drawStroke: DrawStroke {
        get { DrawStroke(rawValue: d.integer(forKey: Key.drawStroke)) ?? .medium }
        set { d.set(newValue.rawValue, forKey: Key.drawStroke) }
    }

    /// How long a finished mark lingers before fading (default 3 s). Checked for presence
    /// first: `integer(forKey:)` yields 0 for a missing key, and 0 is the `never` case —
    /// so an unset preference would otherwise read as "keep marks forever".
    var drawFade: DrawFade {
        get {
            guard d.object(forKey: Key.drawFade) != nil else { return .three }
            return DrawFade(rawValue: d.integer(forKey: Key.drawFade)) ?? .three
        }
        set { d.set(newValue.rawValue, forKey: Key.drawFade) }
    }

    /// The tool draw mode opens with — the last one used, remembered across recordings.
    var drawTool: DrawTool {
        get { d.string(forKey: Key.drawTool).flatMap(DrawTool.init) ?? .pencil }
        set { d.set(newValue.rawValue, forKey: Key.drawTool) }
    }

    /// The single letter that selects `tool` while draw mode is active.
    func drawKey(_ tool: DrawTool) -> String {
        let stored = (d.string(forKey: tool.keyDefaultsKey) ?? "").uppercased()
        return stored.count == 1 ? stored : tool.defaultKey
    }

    func setDrawKey(_ key: String, for tool: DrawTool) {
        d.set(key.uppercased(), forKey: tool.keyDefaultsKey)
    }

    /// The name of whatever already claims `key`, or nil if it is free. Two tools sharing a
    /// letter would leave one permanently unreachable, and draw mode reserves ⌫ for Clear
    /// and Esc for leaving — so those can't be taken either.
    func drawKeyConflict(_ key: String, excluding tool: DrawTool) -> String? {
        let k = key.uppercased()
        for other in DrawTool.allCases where other != tool && drawKey(other) == k {
            return other.label
        }
        return nil
    }

    /// `NSColor` ⇄ "RRGGBB", via sRGB so a colour picked in any space round-trips to the
    /// same on-screen result.
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    static func color(fromHex hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Run the recording flow without capturing anything: no `SCStream`, no
    /// `AVAssetWriter`, no file. The selection overlay, countdown, region dim, floating
    /// bar, timer, click ripples and on-screen drawing all behave exactly as in a real
    /// recording — only the capture is absent.
    ///
    /// This exists so the recording tools stay testable on a Mac whose Screen Recording
    /// grant is still pending (an MDM-managed device awaiting admin approval), which
    /// would otherwise block every recording feature behind the permission wall. It is
    /// therefore *not* gated on that permission — see `VideoRecordController.begin()`.
    /// `--simulate-recording` forces it on for one launch.
    var simulateRecording: Bool {
        get { launchSimulateOverride || d.bool(forKey: Key.simulateRecording) }
        set { d.set(newValue, forKey: Key.simulateRecording) }
    }

    /// Whether this process was launched with `--simulate-recording`, which pins
    /// simulate mode on regardless of the stored preference (the Settings checkbox shows
    /// it as locked on). Lets `./build.sh --run` come up in simulate mode without
    /// persisting the flag into the user's defaults.
    let launchSimulateOverride = CommandLine.arguments.contains("--simulate-recording")

    /// Seconds counted down (over the recorded region) after the region is picked,
    /// before the recording starts (0 = start immediately).
    var videoCountdown: CaptureDelay {
        get { CaptureDelay(rawValue: d.integer(forKey: Key.videoCountdown)) ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.videoCountdown) }
    }

    /// The last drag-selected region (screen-local, bottom-left origin) and the
    /// display it was on — lets the overlay re-offer it (Return re-captures it).
    /// Persisted across launches so "same region as yesterday" also works.
    var lastRegion: (rect: CGRect, displayID: CGDirectDisplayID)? {
        get {
            guard let a = d.array(forKey: Key.lastRegion) as? [Double], a.count == 5 else { return nil }
            return (CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), CGDirectDisplayID(a[4]))
        }
        set {
            guard let v = newValue else { d.removeObject(forKey: Key.lastRegion); return }
            d.set([v.rect.minX, v.rect.minY, v.rect.width, v.rect.height, Double(v.displayID)],
                  forKey: Key.lastRegion)
        }
    }

    /// Which audio streams to record alongside the video (default none — opt in to
    /// audio rather than being surprised by a recorded mic/system track).
    var videoAudioSource: VideoAudioSource {
        get { d.string(forKey: Key.videoAudioSource).flatMap(VideoAudioSource.init) ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.videoAudioSource) }
    }

    /// The background preset selected when the editor opens. Stored by preset
    /// name; custom colors aren't persistable here, so it's always a preset.
    var defaultBackground: Background {
        get { Background.preset(named: d.string(forKey: Key.defaultBG) ?? "") ?? .none }
        set { d.set(newValue.name, forKey: Key.defaultBG) }
    }

    /// Run as a menu-bar-only app, with no Dock icon (activation policy `.accessory`).
    /// The Dock icon is the fallback entry point for a menu bar that's hidden behind the
    /// notch or a menu-bar hider, so this is opt-in — see `AppDelegate.applyDockVisibility`.
    var hideDockIcon: Bool {
        get { d.bool(forKey: Key.hideDock) }
        set { d.set(newValue, forKey: Key.hideDock) }
    }

    /// Auto-start the menu-bar app at login. State is read live from
    /// `SMAppService` (the system is the source of truth, not UserDefaults).
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("m_capture: launch-at-login toggle failed: \(error)")
            }
        }
    }

    /// The directory captures are actually written to: the configured folder if it
    /// exists (or can be created) and is writable, otherwise the Desktop. Guards
    /// against a save location that was deleted, unmounted, or made read-only —
    /// which would otherwise make every capture silently vanish.
    /// Whether the configured save folder currently exists and is writable. When false,
    /// `resolvedSaveDirectory()` falls back to the Desktop — callers surface that so the
    /// capture isn't silently redirected without the user knowing.
    var saveDirectoryAvailable: Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: saveDirectory.path, isDirectory: &isDir)
            && isDir.boolValue && fm.isWritableFile(atPath: saveDirectory.path)
    }

    func resolvedSaveDirectory() -> URL {
        let fm = FileManager.default
        let dir = saveDirectory
        var isDir: ObjCBool = false
        // Use the configured folder only if it still exists and is writable — don't
        // silently recreate a folder the user deleted/renamed; fall back to the Desktop.
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
           fm.isWritableFile(atPath: dir.path) { return dir }
        let fallback = defaultDirectory
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// A destination file URL: `<saveDirectory>/<prefix><timestamp>.<ext>`, made
    /// unique with a `-1`, `-2`, … suffix so two captures in the same second never
    /// silently overwrite each other. `ext` overrides the configured image format
    /// (e.g. "gif" for the before/after animation export).
    func fileURL(date: Date = Date(), ext: String? = nil) -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "HH-mm-ss-dd-MM-yyyy"
        let dir = resolvedSaveDirectory(), e = ext ?? format.ext
        let base = "\(filenamePrefix)\(fmt.string(from: date))"
        var url = dir.appendingPathComponent("\(base).\(e)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).\(e)"); n += 1
        }
        return url
    }

    func encode(_ rep: NSBitmapImageRep) -> Data? { format.encode(rep) }
}

