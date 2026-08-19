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
shows both a Dock icon and the menu-bar **m.** icon (activation policy `.regular`);
the menu-bar item stays the primary entry point, the Dock icon is a fallback for
when the menu bar is hidden — Settings → General can hide it (`.accessory`).
No automated tests; smoke-test by hand.

Prerequisites, the faster dev loop, the testing checklist, and PR rules live in
**[`CONTRIBUTING.md`](CONTRIBUTING.md)**.

## How it works

- **Screenshot** (⌃⇧S): every display is frozen the instant the hotkey fires → the
  selection overlay dims those stills → drag a region (or **Space** → whole-screen mode →
  click) → an in-place annotation editor opens over the dimmed screen. Selecting on a
  frozen frame is what makes tooltips, hover menus and popovers capturable at all: the
  overlay has to activate the app to get its keyboard, and activating dismisses them.
- **Record** (⌃⇧R): drag a region → record it in-process via ScreenCaptureKit
  (`SCStream`), encoding HEVC video + AAC audio into an `.mp4` at 30 or 60 fps, with an
  optional start countdown and mouse-click ripples captured into the video. The hotkey
  toggles (press again to stop & save); ⌥+hotkey discards (with confirm). The floating
  control bar (live timer, size estimate, quality badge, pause/stop, minimize) starts
  minimized to the menu bar by default; **Esc**/**Return** work only while it's visible.
  While recording, the menu-bar icon shows a red dot + live timer, and the status menu
  offers Stop / Stop-as-GIF / Stop-&-Trim / Discard / Pause-Resume / Show-bar. Finishing
  opens the History panel. Quitting mid-record still finalizes a playable file; a
  disconnected display auto-stops and saves the partial take. Quality, frame rate,
  countdown, click ripples, bar default and audio source (default none) live in
  Settings → Video.
- **Simulate recording** (Settings → Video, `./build.sh --run --simulate`, or the
  "Simulate Instead" button on the permission alert): runs the entire
  record flow with no capture — no `SCStream`, no `AVAssetWriter`, no file. A
  `SimulatedRecordingClock` stands in for the session so the bar, timer, pause and
  menu-bar indicator behave normally, and the HUD switches to amber **SIM** so it can't be
  read as a live capture. It intentionally **bypasses the Screen Recording permission
  guard** — being usable while the grant is pending (a managed Mac awaiting admin approval)
  is the whole point — so don't "fix" that guard back. `isSimulatedRecording` (i.e.
  `simClock != nil`, not the setting) is the authoritative mid-recording mode flag, so
  toggling the setting mid-recording can't strand a half-switched teardown.
- **History**: a brand panel over the save folder's newest captures (thumbnail cards;
  copy / pin / trim / reveal / trash); opens from the menu and after every save. Only
  one app panel (Settings / History / Trim) is open at a time (`AppPanels.closeAll`).
- **Localization**: the whole UI ships in English / German / Vietnamese (`L10n.swift`),
  following the system language or the Settings → General override.
- Hotkeys are rebindable defaults (**Settings → Shortcuts**). Captures save to the
  configured folder (default Desktop) and copy to the clipboard; format, location
  and auto-copy live in Settings.

## Source map (`Sources/`)

- `main.swift` — entry point; applies the activation policy via
  `AppDelegate.applyDockVisibility()` (`.regular` = Dock icon + menu-bar item,
  `.accessory` = menu-bar only, per Settings → General → Hide the Dock icon).
- `AppDelegate.swift` — status item, menu, global hotkeys, capture actions. The menu is
  a short action list (Screenshot / Record Video / History / Library /
  Settings / Check for Updates / Quit); the meta items (Usage Guide, Report a Bug,
  version + license) live in Settings → About instead. Shows the one-time first-run
  welcome (`showWelcome`), the in-menu recording controls (Stop / Stop-as-GIF /
  Stop-&-Trim / Discard / Pause), and the menu-bar recording indicator
  (`updateRecordingIndicator`); opening the menu closes any app panel; Quit/Force-Quit
  finalize an active recording first. The record hotkey toggles (stop & save); a
  derived ⌥ variant discards.
- `Updater.swift` — checks GitHub Releases (`releases.atom`, newest-first) for a newer
  build; drives the manual "Check for Updates" item and the silent daily check. The
  schedule lives in **wall-clock stamps** (`updater.lastSuccessfulCheck` /
  `updater.lastAttempt`), never in a timer's progress: `checkIfDue(_:)` is the single
  gate, and six triggers re-read it — launch, a 15-min heartbeat, wake from sleep, app
  activation, reopen, and the network coming back (`NWPathMonitor`). A `Trigger` says how
  much of the gate each may skip (24 h scheduled / 1 h user-present / no floor on a
  network return). **Nothing installs without consent**: a check *offers* the release with
  what changed, and only an explicit Install downloads and swaps; the relaunch is a
  second, declinable question. The offer lists **every version the user hasn't got**, each
  under its own number — not just the newest — since someone who skipped three releases is
  being asked to take all three (`changeLog(_:)` over the feed entries newer than
  `effectiveCurrentVersion`; lines parsed out of each entry's `<content>` — GitHub's `<li>`
  of PR titles, minus the "by @x in #y" trailer — capped at `maxNoteLines`). Whatever the user still owes is one value,
  `pendingAction` (`.install` / `.relaunch`), driving the menu-bar badge, the menu item
  and which prompt shows — so those three can't disagree. "Later" snoozes that exact
  version for 24 h (a newer one always gets through). `relaunchFromMenu()` confirms first
  *only* when pinned windows would be closed by it. `./build.sh --run --update-demo`
  (`Updater.runDemo()`) walks the real prompts against real release notes, installing
  nothing: it drives the shipping path, with demo guards only in `install` / `snooze` /
  `relaunch`, so the screens can't drift from what ships. Its state is two in-memory
  statics — never `UserDefaults` — so quitting is the whole cleanup. `--update-debug` forgets the stamps and
  checks now. Requires the repo's releases to be readable by the user.
- `BrandMenu.swift` — custom mesoneer-styled menu (NSMenu isn't themeable); used for
  the status-item menu and the pin window's right-click.
- `BrandAlert.swift` — mesoneer-styled alert (the brand counterpart to `NSAlert`) in
  the native layout: icon badge left, left-aligned text, buttons bottom-right with the
  primary always rightmost (enforced regardless of call-site order). Width comes from the
  **widest single line**, not the whole message measured as one run — capped at `maxWidth`
  (380 by default, `wideMessageWidth` = 520 for the updater's change log). Pass
  `attributedMessage:` for a body that needs more than one style; `message:` still drives
  measurement, so pass the same characters. Such a body is drawn by `AlertBody`, not an
  `NSTextField`: a field re-derives what it shows from `stringValue` plus its *own* font
  and colour on a window state change, so styling survived until the first click and then
  flattened. Same trap in `BrandToast`: size a label from `sizeThatFits`, never
  `intrinsicContentSize` — the latter is 3-4 pt short and clips the last glyph. `runModal()` for
  user-initiated confirms; `present(completion:)` (non-modal, self-retaining) for
  anything fired from a background context — nested `runModal` from callbacks can
  wedge the run loop. Panel level sits above the capture overlays.
- `BrandToast.swift` — brief auto-fading toast pill (copied / trashed confirmations).
- `BrandCursor.swift` — mesoneer-styled pointer cursors built from SF Symbols (brand-
  purple glyph + soft white halo, no background chip); shared by the capture overlay's
  camera/video cursors and the editor's per-tool cursors.
- `Theme.swift` — brand palette + fonts; the single styling source.
- `Logo.swift` — the "m." logo / menu-bar glyph, drawn in code; `menuBarImage(badged:)`
  composes the update badge into the same template image so it still tints with the menu bar.
- `ScreenshotController.swift` — selection-overlay windows; grabs the rect
  *in-process* via ScreenCaptureKit (`SCScreenshotManager`, macOS 14+);
  `deliver(_:)` routes the result per `CaptureBehavior` (editor / save / clipboard).
  Multi-monitor coordinate math lives in `finish`. Gated on
  `ScreenRecordingPermission` so a denied grant guides the user instead of
  silently producing nothing. `begin()` freezes every display first (one
  `SCScreenshotManager` grab each, before `NSApp.activate`), then `presentOverlays`
  puts the overlay up over those stills; `finish` just crops the still (`crop(_:to:scale:)`)
  — no second grab. A display whose freeze failed falls back to the old live grab.
  `warmUp()` keeps a background `SCShareableContent` snapshot ready (launch, display
  change, after each capture) since that enumeration now sits on the hotkey's critical
  path. Window mode deliberately stays on the live grab (unoccluded pixels).
- `Permissions.swift` — `ScreenRecordingPermission`: `CGPreflightScreenCaptureAccess`
  check, `prime()` (fire the grant prompt during onboarding), + the brand guidance alert
  / System Settings deep link when Screen Recording is off.
- `SelectionOverlay.swift` — the drag-to-select overlay, dimming either a frozen still
  of the display (screenshots, via the `frozen:` backdrop) or the live desktop (the
  record flow and the freeze-failed fallback); **Space** cycles
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
  selection overlay (region / window / screen), prefetches `SCShareableContent` while
  the user drags (so the session — and its timer — starts promptly), runs the optional
  `RecordCountdownWindow`, then drives `VideoRecordSession`, the `VideoRecordBar`
  (created positioned but minimized by default), `ClickVisualizer`, and a 4 Hz update
  tick; requests mic permission first when the audio source needs it. Stop routes by
  `StopDestination` (movie / gif via `VideoToGIF` / trim via `TrimWindowController`)
  and opens History when done. Exposes menu-bar controls (stop variants / discard /
  pause / show-bar), `onRecordingUIUpdate` and `onGIFExportUpdate`;
  `finalizeForTermination()` pump-runs the main run loop so quit/force-quit finish the
  file. `handleUnexpectedStop` also fires when the recorded display disconnects.
  Every exit path (stop / discard / unexpected / start failure / termination) funnels
  through one `teardownRecordingUI()` so none can strand an overlay window. Simulate mode
  short-circuits before the session is built and holds a `SimulatedRecordingClock` instead.
- `VideoRecordSession.swift` — records a `Target` (display region or a single window)
  via ScreenCaptureKit (`SCStream`), encoding HEVC video + AAC audio into an `.mp4`
  with `AVAssetWriter` (PTS-normalized on a serial `writeQueue`) at the configured
  frame rate. Consumes the controller's `SCShareableContent` prefetch; `recordedDisplayID`
  lets the controller detect the display vanishing. `onUnexpectedStop` fires if the
  stream dies on its own.
- `VideoRecordBar.swift` — the floating recording HUD (live timer, size estimate, quality
  badge, pause/stop, and a minimize-to-menu-bar button); its `windowNumber` is excluded
  from the `SCStream` capture. All controls accept first-mouse so a single click works
  while another app is frontmost.
- `VideoToGIF.swift` — streams a finished `.mp4` into a looping animated GIF
  (AVAssetImageGenerator → ImageIO, 10 fps, 960 px cap, one frame in memory at a time);
  drives "Stop & Save as GIF".
- `TrimWindow.swift` — lossless post-recording trim panel: `AVPlayerLayer` preview,
  custom in/out `TrimSlider`, passthrough `AVAssetExportSession` over the original file;
  opened by "Stop & Trim…" and History's Trim action.
- `ClickVisualizer.swift` — expanding ripple windows at mouse clicks while recording
  (global `NSEvent` monitor; deliberately *not* excluded from the stream).
- `HistoryWindow.swift` — the History panel: newest captures from the save folder as
  thumbnail cards (adaptive grid, video play badges) with Copy / Pin / Trim / Reveal /
  Trash actions; rebuilt from the folder on every open.
- `EditorWindow.swift` — the in-place annotation editor: tool tiles in five groups
  (Markup, Shapes, Style, Actions, Background) as scattered cards or one draggable
  panel. Style holds the color palette, custom-color picker, and a cycling stroke-width
  tile. Actions owns the Select tool (move/resize/delete a placed mark; **V**),
  crop, rotate-right, flip, undo/redo, Pin (⌘P), Before/After GIF, Copy (⌘C), Save
  (⌘S), Save As (⇧⌘S), Cancel. Owns tooltips, selection state, the pickers, and the
  live background preview (`BackgroundView`).
- `CanvasView.swift` — the annotation canvas: `Tool` enum, undo/redo, Gaussian blur,
  crop/rotate/flip transforms (`applyTransform` shifts annotations when the region
  changes), and live edit state. (The whole-canvas resize is now a display re-grab in
  `EditorWindow`, not a pixel resample.) Shapes get an eight-handle box resize
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
  launch-at-login (live via `SMAppService`), Dock-icon visibility, `simulateRecording`
  (+ the `--simulate-recording` launch override, which pins it on and disables the
  checkbox). `fileURL()` + `encode(_:)` are the
  single source for where/how captures are saved; `fileURL()` uniquifies the name and
  `resolvedSaveDirectory()` falls back to the Desktop when the configured folder is
  gone/unwritable.
- `SettingsWindow.swift` — the dark Settings panel (`SettingsWindowController.shared`):
  an icon sidebar (macOS System Settings shape) with General / Shortcuts / Capture /
  Output / Video / Live Drawing / About sections, per-row info-dot tips, and a fixed
  window size measured once against the tallest section. ("Live Drawing" is the
  draw-*while-recording* section — named for the one property that separates it from the
  editor's annotation tools, and the only wording short enough for the sidebar in German.)
  About is a centered identity card (logo, name + version on one line, MIT/© mesoneer
  line, Usage Guide + Report a Bug buttons, and the updater's "Last checked" as a quiet
  footer) — the app's only about surface; there is no separate About panel.
  `--settings-demo` opens it at launch. Sections are built **once** and cached, so
  anything live (the "Last checked" stamp) must be filled in `refresh()`, not at build
  time. Checkbox labels must fit `Layout.rowWidth` minus `controlX` — ~248 pt at
  `Theme.font(12)` — **in all three languages**, or they wrap; measure before wording.
- `ShortcutRecorder.swift` — click-to-record shortcut field + `Shortcut` glyph helpers.
- `BrandPopUpButton.swift` — brand `NSPopUpButton` + `BrandControl` shared inset
  geometry aligning the Settings form controls.
- `HotKey.swift` — global hotkey registration via Carbon.
- `L10n.swift` — code-level localization (no `.strings` files): `L(_:)` looks the
  English string up in the German or Vietnamese dictionary per the Settings language
  (or the system language); English keys pass through. Resolved once per launch —
  language changes prompt a relaunch.
- `PanelChrome.swift` — borderless square-cornered panel for Settings / History / Trim
  + `AppPanels.closeAll(except:)`, the one-panel-at-a-time policy (macOS
  rounds `.titled` corners) with its own close button, Esc / ⌘W, and a draggable background.
- `tools/makeicon.swift` — generates the app `.icns` at build time.
- `tools/shots.swift` — dev-only; regenerates the menu/about/settings screenshots in
  `docs/assets/` (see CONTRIBUTING.md). Its editor preview (from `tools/sample.png`) renders
  to a scratch temp dir, never a committed asset. Not part of the app build.
- `tools/import-cert.sh` — dev-only; imports the shared `certs/m_capture-release.p12`
  signing identity into the login keychain so rebuilds keep the Screen Recording grant.

## Gotchas

- **Screen Recording permission is required, and the grant resets on rebuild.**
  `build.sh` ad-hoc signs (`codesign -s -`), so a rebuild can read as a new identity
  and reset the grant — re-approve under *System Settings → Privacy & Security →
  Screen Recording* and relaunch if capture silently produces nothing. A self-signed
  shared `m_capture-release` cert — committed as `certs/m_capture-release.p12` and imported
  with `./tools/import-cert.sh` — gives a stable identity, so the grant persists across
  rebuilds *and* matches the shipped release. See CONTRIBUTING.md.
- **Never schedule with a bare repeating `Timer`.** Run-loop timers don't fire while the
  Mac sleeps and their interval counts *awake* time, so the updater's old 24 h timer meant
  "every few days" on any laptop that gets closed — a release could sit unnoticed for a
  week with the app running the whole time. Anything periodic stamps a `Date` in
  `UserDefaults` and re-reads it from several triggers (`Updater.checkIfDue`); the timer
  is only a heartbeat. Stamps in the *future* (clock correction, restored backup) must
  count as overdue, or the gate stays shut until the clock catches up.
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
- **Capture latency / overlay.** The screenshot path pays its ScreenCaptureKit cost
  *up front* (the freeze in `begin()`), so mouse-up only crops — no grab, no
  wait-for-the-overlay-to-clear delay, nothing of ours that could bake into the shot.
  That trades latency onto the hotkey instead, which is why `warmUp()` keeps the
  shareable-content snapshot warm. The live fallback in `finish` keeps the old shape: a
  short `asyncAfter` for the overlay to clear, then an async `Task` for the grab.
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
  so the window still hit-tests the click. Don't restore a fully-clear cutout. Over a
  frozen backdrop the still itself is redrawn there instead, so the window is opaque
  throughout and the hazard doesn't arise — but the live path (recording) still needs it.

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
- **Every user-facing string goes through `L(...)`** (`L10n.swift`); the English string
  is the key. Adding or rewording a string means updating the call site AND both the
  German and Vietnamese dictionaries in lockstep (their key sets must stay identical).
  Keep the tone formal and concise; preserve `%@` templates and trailing shortcut
  suffixes like "  (P)" verbatim. Names used as persistence keys (e.g. `Background.name`)
  stay English — localize only at display sites.
- Editor coordinates stay in full-resolution image space (see `CanvasView`).
- **Comments explain *why*, not *what*** — put a single `///` doc comment on the
  method or type; don't annotate the body line by line with inline `//` notes.
- **Release notes (`docs/index.html`) are exactly 2 lines** — each `rel.N.note` string,
  in both the `en` and `de` i18n dicts, must stay short enough to wrap to 2 lines at
  the `.note` column width: roughly 80-160 characters. Write one clause, comma, and a
  second clause ("X, and Y."), not a longer list. Every new release adds a `rel.N.date`
  / `rel.N.note` pair to *both* language dicts plus the matching `<div class="release">`
  block (newest first) — don't add the HTML without the i18n keys (or vice versa).
- **Feature cards (`docs/index.html`) are exactly 3 lines** — each `feat.N.p` string,
  in both the `en` and `de` i18n dicts *and* the inline HTML default (which mirrors
  `en`), must wrap to 3 lines at the `.card p` column width (345 px at 15 px):
  **100-134 characters** (browser-measured; ≥139 wraps to 4 lines). A new card needs
  the `<div class="card">` block plus `feat.N.h`/`feat.N.p` in both language dicts.
