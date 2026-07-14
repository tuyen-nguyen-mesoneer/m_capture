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

- **Screenshot** (⌃⇧S): a dim selection overlay → drag a region (or **Space** →
  whole-screen mode → click) → an in-place annotation editor opens over the dimmed screen.
- **Record** (⌃⇧R): drag a region → record it in-process via ScreenCaptureKit
  (`SCStream`), encoding HEVC video + AAC audio into an `.mp4`, with a floating control
  bar (live timer, size estimate, quality badge, pause/stop, minimize). **Esc** discards
  (with confirm), **Return** saves. While recording, the menu-bar icon shows a red dot +
  live timer, and the status menu offers Stop / Pause-Resume / Show-bar so it's driveable
  from the menu bar. Quitting mid-record still finalizes a playable file. Quality and
  audio source (system / mic / both) live in Settings → Video.
- **Quick Screen** (⌃⇧Q): captures the screen under the mouse instantly — no overlay,
  no delay — for a hover state or tooltip that a drag-to-select would lose.
- Hotkeys are rebindable defaults (**Settings → Shortcuts**). Captures save to the
  configured folder (default Desktop) and copy to the clipboard; format, location
  and auto-copy live in Settings.

## Source map (`Sources/`)

- `main.swift` — entry point; configures the menu-bar agent.
- `AppDelegate.swift` — status item, menu, global hotkeys, capture actions, and the
  Quick-Screen / Usage-Guide / Check-for-Updates / Report-a-Bug menu items. Shows the
  one-time first-run welcome (`showWelcome`), the in-menu recording controls, and the
  menu-bar recording indicator (`updateRecordingIndicator`); Quit/Force-Quit finalize an
  active recording first.
- `Updater.swift` — checks GitHub Releases (`releases`, newest-first) for a newer build;
  drives the manual "Check for Updates" item and a silent once-a-day launch check.
  Requires the repo's releases to be readable by the user.
- `BrandMenu.swift` — custom mesoneer-styled menu (NSMenu isn't themeable); used for
  the status-item menu and the pin window's right-click.
- `BrandAlert.swift` — mesoneer-styled modal alert (the brand counterpart to
  `NSAlert`): About-style panel chrome + brand buttons, run modally and returning the
  clicked button index; used by `Updater` for the update / up-to-date / error dialogs.
- `BrandCursor.swift` — mesoneer-styled pointer cursors built from SF Symbols (brand-
  purple glyph + soft white halo, no background chip); shared by the capture overlay's
  camera/video cursors and the editor's per-tool cursors.
- `Theme.swift` — brand palette + fonts; the single styling source.
- `Logo.swift` — the "m." logo / menu-bar glyph, drawn in code.
- `ScreenshotController.swift` — selection-overlay windows; grabs the rect
  *in-process* via ScreenCaptureKit (`SCScreenshotManager`, macOS 14+);
  `deliver(_:)` routes the result per `CaptureBehavior` (editor / save / clipboard).
  Multi-monitor coordinate math lives in `finish`. Gated on
  `ScreenRecordingPermission` so a denied grant guides the user instead of
  silently producing nothing. `captureQuickScreen()` is the Quick Screen path —
  skips the overlay and delay entirely, grabbing the screen under the mouse
  straight away.
- `Permissions.swift` — `ScreenRecordingPermission`: `CGPreflightScreenCaptureAccess`
  check, `prime()` (fire the grant prompt during onboarding), + the brand guidance alert
  / System Settings deep link when Screen Recording is off.
- `SelectionOverlay.swift` — the dim drag-to-select overlay; **Space** cycles
  Region → Window → Screen mode; draws the cutout, size readout, mode hint, and a
  lavender hover tint over the Window/Screen capture target. An `OverlayCoordinator`
  is shared across every display's overlay so mode-cycling and capture work on any
  connected screen, not just the one under the initial cursor. Window mode
  hover-highlights the window under the pointer (via `WindowList`) and captures it on
  mouse-up (release) over it; the completion reports either a rect or a `CGWindowID`.
  Cursors are mesoneer-styled (`BrandCursor`) — camera for screenshots, video for
  recording.
- `WindowList.swift` — synchronous on-screen window enumeration + hit-testing
  (`CGWindowListCopyWindowInfo`) that drives the overlay's window-pick mode, plus the
  CoreGraphics↔AppKit global-coordinate flip helpers shared by the capture controllers.
- `VideoRecordController.swift` — the screen-recording flow (macOS 14+): reuses the
  selection overlay (region / window / screen), then drives `VideoRecordSession`, the
  floating `VideoRecordBar`, and a 1 Hz update tick; requests mic permission first when
  the audio source needs it. Exposes menu-bar controls (stop/pause/minimize) and
  `onRecordingUIUpdate` (drives the menu-bar red-dot/timer indicator);
  `finalizeForTermination()` pump-runs the main run loop so quit/force-quit finish the
  file. `discardRecording()` handles the Esc discard; `handleUnexpectedStop` surfaces a
  mid-record failure.
- `VideoRecordSession.swift` — records a `Target` (display region or a single window)
  via ScreenCaptureKit (`SCStream`),
  encoding HEVC video + AAC audio into an `.mp4` with `AVAssetWriter` (PTS-normalized on
  a serial `writeQueue`). `onUnexpectedStop` fires if the stream dies on its own.
- `VideoRecordBar.swift` — the floating recording HUD (live timer, size estimate, quality
  badge, pause/stop, and a minimize-to-menu-bar button); its `windowNumber` is excluded
  from the `SCStream` capture.
- `EditorWindow.swift` — the in-place annotation editor: tool tiles in five groups
  (Markup, Shapes, Style, Actions, Background) as scattered cards or one draggable
  panel. Style holds the color palette, custom-color picker, and a cycling stroke-width
  tile. Actions owns the Select tool (move/resize/delete a placed mark; **V**),
  crop, rotate-right, flip, undo/redo, Pin (⌘P), Before/After GIF, Copy (⌘C), Save
  (⌘S), Save As (⇧⌘S), Cancel. Owns tooltips, selection state, the pickers, and the
  live background preview (`BackgroundView`).
- `CanvasView.swift` — the annotation canvas: `Tool` enum, undo/redo, Gaussian blur,
  crop/rotate/flip/resample transforms (`bakeResample` bakes annotations on
  corner-drag resize), and live edit state. Shapes get an eight-handle box resize
  (`boxHandle`/`resizeBox`: four corners + four edge midpoints for single-axis stretch);
  arrows/lines get three handles (`curveHandle`: start/end endpoints + bend apex).
  A just-drawn shape (`editingShape`) or curve (`editingCurve`) stays editable under its
  own tool, and ⌫ deletes it. `restrokeSelection` applies a stroke width live. Zoom
  callout; overlay image; ruler; `counterFormat`/`currentEmoji`. Coordinates stay in
  full-res image space so exports stay sharp.
- `Annotations.swift` — annotation model (pencil, marker, line, curved arrow,
  shapes, text, blur, counter, spotlight, emoji, zoom callout, ruler, image
  overlay). Each mark exposes `bounds` / `resizable` / `scale(by:around:)` / `recolor`
  / `restroke` so the Select tool can move, resize, recolor, restyle and delete it
  (path-like marks are move-only). Crop/rotate/flip are transforms, not stored marks.
- `ToolButton.swift` — the rounded tool tile (custom-drawn glyphs / SF Symbols);
  swatches draw a colour chip; `.lineWeight` draws the stroke-width glyph.
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
  single source for where/how captures are saved; `fileURL()` uniquifies the name and
  `resolvedSaveDirectory()` falls back to the Desktop when the configured folder is
  gone/unwritable.
- `SettingsWindow.swift` — the dark Settings panel (`SettingsWindowController.shared`);
  General / Shortcuts / Capture / Output / Video groups, with per-row info-dot tips.
  `--settings-demo` opens it at launch.
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
- **Save is async, but failures aren't silent.** `savePressed` flattens on the main
  thread, then `writeCapture` encodes/writes off a background queue and only closes the
  editor **after** the write succeeds — on failure it keeps the window open and shows a
  brand alert; a save-folder fallback to the Desktop shows a notice too. Files are named
  `<prefix><HH-mm-ss-dd-MM-yyyy>.<ext>` (from Settings, default `m_capture_` / PNG),
  uniquified on collision. ⌘C flattens and writes to the pasteboard.
- Global hotkeys use Carbon `RegisterEventHotKey` (`HotKey.swift`) — no Accessibility
  permission needed.
- **Overlay click-through on transparent holes.** The selection overlay is a
  non-opaque window, and a non-opaque `NSWindow` passes mouse clicks straight
  *through* any fully-transparent (alpha 0) pixels to the app underneath — keyboard
  and `.activeAlways` tracking (hover) still work, so it looks interactive while
  clicks silently hit the app below. Window/Screen modes therefore punch their bright
  "hole" with a hair of opacity (`punchHole`, alpha 0.02) instead of a true `.clear`,
  so the window still hit-tests the click. Don't restore a fully-clear cutout.

## Conventions

- **No external dependencies** — system frameworks only (AppKit / CoreImage / Carbon
  / Vision / ImageIO / ScreenCaptureKit). Write original code; match the surrounding Swift.
- **All styling goes through `Theme.swift`** — never hardcode colors or fonts.
- **Every screen follows the mesoneer brand style** — all user-facing windows,
  dialogs, popovers and menus use the brand panel chrome (`Theme` gradient, square
  corners, a soft drop shadow, and **no border**, plus the `m.` logo and brand-styled
  buttons), matching About/Settings. (The no-border rule is about panel *chrome* —
  functional strokes like the selection ring, input fields, or a selected-item highlight
  are fine.) Never ship a raw system `NSAlert`, a default `NSWindow`, or an unstyled
  control: use `BrandAlert` for alerts and the `PanelWindow` / `Theme` helpers for panels.
- **Icons are drawn in code** (SF Symbols or CoreGraphics) — no image assets.
- Editor coordinates stay in full-resolution image space (see `CanvasView`).
- **Comments explain *why*, not *what*** — put a single `///` doc comment on the
  method or type; don't annotate the body line by line with inline `//` notes.
