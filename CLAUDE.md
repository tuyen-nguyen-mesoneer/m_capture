# m_capture — project guide

A lightweight **macOS menu-bar tool for screenshots and screen recording**, built
in **Swift + AppKit** — no external dependencies, no Xcode project (compiled with
`swiftc`). Internal tool by [mesoneer AG](https://www.mesoneer.io/?r=0),
MIT-licensed. Targets macOS 14+; bundle id `io.mesoneer.mcapture`.

## Build & run

```sh
./build.sh          # → build/m_capture.app + m_capture.dmg
./build.sh --run    # rebuild + quit-and-relaunch in place (skips the DMG)
```

`build.sh` compiles `Sources/*.swift`, assembles the `.app` (+ `Info.plist`, icon
via `tools/makeicon.swift`), code-signs, and builds the DMG; the version is set
here. It pins the deployment target with `-target …-macos14.0` to match
`LSMinimumSystemVersion` (ScreenCaptureKit's capture API needs macOS 14). The app
runs as a menu-bar agent (`LSUIElement`) — look for the **m.** icon, no Dock icon.
No automated tests; smoke-test by hand.

Prerequisites, the faster dev loop, the testing checklist, and PR rules live in
**[`CONTRIBUTING.md`](CONTRIBUTING.md)**.

## How it works

- **Screenshot** (⌃⇧X): a dim selection overlay → drag a region (or **Space** →
  whole-screen mode → click) → an in-place annotation editor opens over the dimmed screen.
- **Record** (⌃⇧R): hands off to the native macOS capture toolbar (⇧⌘5) via
  `open -b com.apple.screenshot.launcher`; reopens in its last-used mode.
- Hotkeys are rebindable defaults (**Settings → Shortcuts**). Captures save to the
  configured folder (default Desktop) and copy to the clipboard; format, location
  and auto-copy live in Settings.

## Source map (`Sources/`)

- `main.swift` — entry point; configures the menu-bar agent.
- `AppDelegate.swift` — status item, menu, global hotkeys, capture actions, and the
  Check-for-Updates / Report-a-Bug menu items.
- `Updater.swift` — checks GitHub Releases (`releases`, newest-first) for a newer build;
  drives the manual "Check for Updates" item and a silent once-a-day launch check.
  Requires the repo's releases to be readable by the user.
- `BrandMenu.swift` — custom mesoneer-styled menu (NSMenu isn't themeable); used for
  the status-item menu and the pin window's right-click.
- `BrandAlert.swift` — mesoneer-styled modal alert (the brand counterpart to
  `NSAlert`): About-style panel chrome + brand buttons, run modally and returning the
  clicked button index; used by `Updater` for the update / up-to-date / error dialogs.
- `Theme.swift` — brand palette + fonts; the single styling source.
- `Logo.swift` — the "m." logo / menu-bar glyph, drawn in code.
- `ScreenshotController.swift` — selection-overlay windows; grabs the rect
  *in-process* via ScreenCaptureKit (`SCScreenshotManager`, macOS 14+);
  `deliver(_:)` routes the result per `CaptureBehavior` (editor / save / clipboard).
  Multi-monitor coordinate math lives in `finish`. Gated on
  `ScreenRecordingPermission` so a denied grant guides the user instead of
  silently producing nothing.
- `Permissions.swift` — `ScreenRecordingPermission`: `CGPreflightScreenCaptureAccess`
  check + the guidance alert / System Settings deep link when Screen Recording is off.
- `SelectionOverlay.swift` — the dim drag-to-select overlay; **Space** toggles
  Region ↔ Screen mode; draws the cutout, size readout, and mode hint.
- `EditorWindow.swift` — the in-place annotation editor: tool tiles in five groups
  (Markup, Shapes, Color, Actions, Background) as scattered cards or one draggable
  panel. Actions owns the Select tool (move/resize/delete a placed mark; **V**),
  crop, rotate-right, flip, undo/redo, Pin (⌘P), Before/After GIF, Copy (⌘C), Save
  (⌘S), Save As (⇧⌘S), Cancel. Owns tooltips, selection state, the pickers, and the
  live background preview (`BackgroundView`).
- `CanvasView.swift` — the annotation canvas: `Tool` enum, undo/redo, Gaussian blur,
  crop/rotate/flip/resample transforms (`bakeResample` bakes annotations on
  corner-drag resize), and live edit state (the Select tool's move/resize of a
  placed mark — drag reuses `remap`, the corner knob reuses `scale(by:around:)`;
  bendable-arrow apex; zoom callout; overlay image; ruler;
  `counterFormat`/`currentEmoji`). Coordinates stay in full-res image space so
  exports stay sharp.
- `Annotations.swift` — annotation model (pencil, marker, line, curved arrow,
  shapes, text, blur, counter, spotlight, emoji, zoom callout, ruler, image
  overlay). Each mark exposes `bounds` / `resizable` / `scale(by:around:)` so the
  Select tool can move, resize, and delete it (path-like marks are move-only).
  Crop/rotate/flip are transforms, not stored marks.
- `ToolButton.swift` — the rounded tool tile (custom-drawn glyphs / SF Symbols);
  swatches draw a colour chip.
- `ColorPicker.swift` — brand custom-color picker (hue strip + S/B square), shown
  *above* the editor (system `NSColorPanel` is hidden behind the overlay).
- `EmojiPicker.swift` — preset emoji grid; sets the current emoji stamp.
- `CounterFormatPicker.swift` — popover for counter numbering (Numbers / Letters / Roman).
- `PinnedWindow.swift` — Pin to screen: a floating, always-on-top window across
  Spaces; drag / corner-drag to scale / right-click `BrandMenu`. Self-retained via
  a static array.
- `Background.swift` — share-ready backgrounds: the `Background` enum (None + 10
  presets + custom solid) with padding/radius geometry; `compose(_:)` bakes the
  frame (fill + shadow + rounded image) at full res.
- `AnimatedGIF.swift` — UI-free animated-GIF writer (ImageIO); powers the
  Before/After GIF export.
- `TextRecognizer.swift` — Copy text / QR (OCR) via Apple Vision; recognizes
  off-thread, returns on main; driven by the editor's `.ocr` tool.
- `Settings.swift` — persisted output prefs (`Settings.shared` / `UserDefaults`):
  save dir, format (`ImageFormat`), quality, auto-copy, cursor, sound, delay,
  post-capture `CaptureBehavior`, per-action hotkeys, background padding/radius,
  launch-at-login (live via `SMAppService`). `fileURL()` + `encode(_:)` are the
  single source for where/how captures are saved.
- `SettingsWindow.swift` — the dark Settings panel (`SettingsWindowController.shared`);
  General / Shortcuts / Capture / Output groups. `--settings-demo` opens it at launch.
- `ShortcutRecorder.swift` — click-to-record shortcut field + `Shortcut` glyph helpers.
- `BrandPopUpButton.swift` — brand `NSPopUpButton` + `BrandControl` shared inset
  geometry aligning the Settings form controls.
- `HotKey.swift` — global hotkey registration via Carbon.
- `PanelChrome.swift` — borderless square-cornered panel for About / Settings (macOS
  rounds `.titled` corners) with its own close button, Esc / ⌘W, and a draggable background.
- `AboutWindow.swift` — the About panel.
- `tools/makeicon.swift` — generates the app `.icns` at build time.
- `tools/shots.swift` — dev-only; regenerates the menu/about/settings screenshots in
  `docs/assets/` (see CONTRIBUTING.md). Its editor preview (from `tools/sample.png`) renders
  to a scratch temp dir, never a committed asset. Not part of the app build.

## Gotchas

- **Screen Recording permission is required, and the grant resets on rebuild.**
  `build.sh` ad-hoc signs (`codesign -s -`), so a rebuild can read as a new identity
  and reset the grant — re-approve under *System Settings → Privacy & Security →
  Screen Recording* and relaunch if capture silently produces nothing. A self-signed
  `m_capture-dev` cert (see CONTRIBUTING.md) gives a stable identity so the grant persists.
- **Capture is in-process** via ScreenCaptureKit (`SCScreenshotManager.captureImage`,
  macOS 14+) — the app grabs the pixels itself, no subprocess. This replaced the old
  `/usr/sbin/screencapture` subprocess, which stalled for *minutes* on managed Macs
  where endpoint-security software gated each process spawn. `CGDisplayCreateImage` /
  `CGWindowListCreateImage` are *obsoleted* (hard compile error) in the macOS 15 SDK,
  so ScreenCaptureKit is the only supported in-process route — hence the macOS 14 floor.
- **Multi-monitor coordinates.** `finish` maps the overlay's per-screen (bottom-left)
  `viewRect` into ScreenCaptureKit's `sourceRect` (points, top-left origin, relative
  to the display) by flipping Y within *that screen's* height (`screen.frame.height -
  viewRect.maxY`); pixel size is `viewRect × backingScaleFactor`. Change there, carefully.
- **Capture latency / overlay.** A short `asyncAfter` delay in `finish` lets the dim
  overlay clear (a couple of compositor frames) so it isn't in the shot; the actual
  ScreenCaptureKit grab then runs asynchronously off a `Task`, so the UI never stalls.
- **Save is async.** `savePressed` flattens on the main thread, then encodes/writes
  off a background queue (the window closes immediately). Files are named
  `<prefix><HH-mm-ss-dd-MM-yyyy>.<ext>` (from Settings, default `m_capture_` / PNG).
  ⌘C flattens and writes to the pasteboard.
- Global hotkeys use Carbon `RegisterEventHotKey` (`HotKey.swift`) — no Accessibility
  permission needed.

## Conventions

- **No external dependencies** — system frameworks only (AppKit / CoreImage / Carbon
  / Vision / ImageIO / ScreenCaptureKit). Write original code; match the surrounding Swift.
- **All styling goes through `Theme.swift`** — never hardcode colors or fonts.
- **Every screen follows the mesoneer brand style** — all user-facing windows,
  dialogs, popovers and menus use the brand panel chrome (`Theme` gradient + square
  1px border, the `m.` logo, brand-styled buttons), matching About/Settings. Never
  ship a raw system `NSAlert`, a default `NSWindow`, or an unstyled control: use
  `BrandAlert` for alerts and the `PanelWindow` / `Theme` helpers for panels.
- **Icons are drawn in code** (SF Symbols or CoreGraphics) — no image assets.
- Editor coordinates stay in full-resolution image space (see `CanvasView`).
- **Comments explain *why*, not *what*** — prefer one `///` doc comment over
  scattered inline notes.
