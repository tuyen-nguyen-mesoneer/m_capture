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
    var label: String { self == .none ? "None" : "\(rawValue)s" }
}

/// What happens the instant a screenshot is captured: open the annotation
/// editor (the default), save straight to the configured folder, or just put it
/// on the clipboard. Applies to region and window captures.
enum CaptureBehavior: String, CaseIterable {
    case editor, save, copy
    var label: String {
        switch self {
        case .editor: return "Open editor"
        case .save:   return "Save to file"
        case .copy:   return "Copy to clipboard"
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
    case screenshot, record

    var label: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .record:     return "Record"
        }
    }

    var defaultShortcut: Shortcut {
        let cs = UInt32(controlKey | shiftKey)
        switch self {
        case .screenshot: return Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: cs)
        case .record:     return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: cs)
        }
    }

    fileprivate var defaultsKey: String { "shortcut_\(rawValue)" }
}

/// Padding amount for share-ready backgrounds, as a fraction of the longest
/// image dimension. Drives `Background.padding(maxDim:)`, so the editor preview,
/// the baked export, and the Pin window all stay in sync.
enum PaddingSize: String, CaseIterable {
    case small, medium, large
    var scale: CGFloat { self == .small ? 0.03 : self == .medium ? 0.04 : 0.06 }
    var label: String { rawValue.capitalized }
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
    var label: String { self == .none ? "Square" : rawValue.capitalized }
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

    var autoCopyOnSave: Bool {
        get { d.bool(forKey: Key.autoCopy) }
        set { d.set(newValue, forKey: Key.autoCopy) }
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

    /// Seconds to wait before the selection overlay appears (0 = immediate).
    var captureDelay: CaptureDelay {
        get { CaptureDelay(rawValue: d.integer(forKey: Key.delay)) ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.delay) }
    }

    /// Padding amount for share-ready backgrounds (default medium).
    var paddingSize: PaddingSize {
        get { d.string(forKey: Key.padding).flatMap(PaddingSize.init) ?? .medium }
        set { d.set(newValue.rawValue, forKey: Key.padding) }
    }

    /// Corner-rounding amount for share-ready backgrounds (default medium).
    var radiusSize: RadiusSize {
        get { d.string(forKey: Key.radius).flatMap(RadiusSize.init) ?? .medium }
        set { d.set(newValue.rawValue, forKey: Key.radius) }
    }

    /// The background preset selected when the editor opens. Stored by preset
    /// name; custom colors aren't persistable here, so it's always a preset.
    var defaultBackground: Background {
        get { Background.preset(named: d.string(forKey: Key.defaultBG) ?? "") ?? .lavender }
        set { d.set(newValue.name, forKey: Key.defaultBG) }
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

    /// A destination file URL: `<saveDirectory>/<prefix><timestamp>.<ext>`.
    /// `ext` overrides the configured image format (e.g. "gif" for the
    /// before/after animation export).
    func fileURL(date: Date = Date(), ext: String? = nil) -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "HH-mm-ss-dd-MM-yyyy"
        return saveDirectory.appendingPathComponent("\(filenamePrefix)\(fmt.string(from: date)).\(ext ?? format.ext)")
    }

    func encode(_ rep: NSBitmapImageRep) -> Data? { format.encode(rep) }
}
