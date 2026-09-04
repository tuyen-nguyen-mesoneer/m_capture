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
  click) → the annotation editor opens over the dimmed screen, the capture centred in it. Selecting on a
  frozen frame is what makes tooltips, hover menus and popovers capturable at all: the
  overlay has to activate the app to get its keyboard, and activating dismisses them.
- **Record** (⌃⇧R): drag a region → record it in-process via ScreenCaptureKit
  (`SCStream`), encoding HEVC video + AAC audio into an `.mp4` at 30 or 60 fps, with an
  optional start countdown and mouse-click ripples captured into the video. The hotkey
  toggles (press again to stop & save), ⌃⇧X stops and only ever stops, and ⌥+hotkey
  discards (with confirm). Every stop the user can trigger funnels through
  `stopRecording`, which **asks first** by default (Settings → Video) and **pauses the
  take while it asks** — the alert is on screen, so without the pause it would be the last
  thing in the video. The floating control bar (live timer, size estimate, quality badge,
  pause/stop, minimize) starts
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
  derived ⌥ variant discards; a separate Stop binding (⌃⇧X) no-ops unless something is
  recording, so it can never start one by mistake.
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
  *only* when pinned windows would be closed by it. `--update-debug` forgets the stamps and
  checks now. Requires the repo's releases to be readable by the user.
- `BrandMenu.swift` — custom mesoneer-styled menu (NSMenu isn't themeable); used for
  the status-item menu and the pin window's right-click. A row's shortcut glyphs take the
  title's own colour (white when enabled) rather than `Theme.textMuted`, which had made the
  one part of a row a user is meant to memorize the dimmest thing on it. `toggle(from:)` closes an open
  menu and refuses to reopen within `reopenGuard` (0.25 s), so a second click on the
  menu-bar icon dismisses it — but **only because there is one long-lived instance**.
  The status menu's rows read live state and are rebuilt on every click, so rebuild them
  with `update(entries:)` (via `AppDelegate.setMenu`), never by assigning a new
  `BrandMenu`: a fresh instance resets `window` and `lastClose`, the click monitor closes
  the old menu, and the click then opens a new one — the icon appears unable to dismiss
  its own menu, and each rebuild strands the open window and its monitors.
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
  wedge the run loop. Panel level sits above the capture overlays — floored in `AlertPanel`'s
  own setter, because `runModal` overwrites it (see the window-ladder gotcha).
  **It also picks its own screen**, via `NSWindow.centerOnActiveScreen()` in
  `PanelChrome.swift` — see that helper for why (`center()` resolves to `NSScreen.main`, so a
  discard confirm for a capture on a second display opened on the *first* one, invisible behind
  the work it was asking about) and for the ordering rule it depends on: **call it before
  `makeKeyAndOrderFront`**, while the window being answered for is still key. `HistoryWindow`,
  `SettingsWindow` and `TrimWindow` use the same helper, so every panel and alert now opens on
  the display the user is looking at; nothing moves on a single-display Mac.
- `BrandToast.swift` — brief auto-fading toast pill (copied / trashed confirmations).
- `BrandCursor.swift` — mesoneer-styled pointer cursors, **one style and one builder**
  (`makeOutlined`): a white glyph ringed with a brand-purple keyline. Capture overlay, editor
  tools and the live-drawing overlay all use it, so the pointer never changes character between
  picking a region and marking one up. It won because it is the only style that survives both
  backdrops: the editor used to carry a brand-purple glyph with a soft white halo (`make`, now
  gone), which reads over a bright capture and all but vanishes over the dim around it — dark on
  dark with 2.5 pt of blur to save it. Inverting it covers both extremes with no slab following
  the pointer: the **white body reads on the dim, the keyline reads on bright content** the white
  body would disappear into. The keyline is a ring of offset copies because it must follow the
  *glyph's* silhouette — a stroked rect would outline the box, not the camera. When tinting a
  glyph, do it in its **own transparent image**: `.sourceAtop` over anything already drawn
  composites against those pixels and floods the whole glyph box solid. Only **size** differs by
  role — `modeSize` (19) for a cursor that names a mode, `toolSize` (16) for one that is a tool
  tip and must stay clear of the pixel it is about to touch.
  **"Drag out a region" is one glyph, `plus`**, from the capture overlay's Region mode through
  the editor's Crop to every shape / blur / spotlight drag. Region kept a hand-drawn crosshair
  for a long time (`makeCrosshair`, removed) whose arms left a **gap at the centre** so the
  hotspot sat on nothing drawn — the one thing no SF Symbol offers, and the reason it survived.
  `plus` has ink where its strokes cross, so the exact start pixel now sits *under* the glyph;
  that was traded deliberately for a single pointer across capture and editing. If aiming
  precision ever bites, that gap is what to bring back. Region **must stay crosshair-shaped**
  either way — it is the one shape that reads as "drag out a region", and with no action line in
  the guidance card the cursor is that instruction; a `viewfinder` glyph matched the style but
  said "aim" and lost it.
- `Theme.swift` — brand palette + fonts; the single styling source. **Every colour is a
  named value from the official mesoneer guidelines** (Frontify → Guidelines → Colors,
  mirrored in `docs/styleguide.md`) — a new shade comes off the published Primary /
  Secondary / Accent ramps, never mixed by hand; `#432A84`, `#2A1F50`, `#120D20` and
  `#3A2F5E` were all approximations and are gone. Two gradients, and the split matters:
  `highlightGradient` is the brand's **Gradient 1** verbatim (45°, `#2B2049` 10% →
  `#32245B` 40% → `#422982` 80%), which the guidelines scope to *highlighting* areas.
  (Nothing calls it yet — it is a palette token like `lavenderEase`, not dead code. In
  particular the brand icon does **not** use it: the official asset carries its own older
  Deep-Trust→Night-Indigo ramp, see `Logo.swift`.) `panelGradient` is the app's general
  surface: the same 45° axis
  and hue family at a fraction of the strength, Deep Trust deepening the bottom-left up
  through the two Primary tints. Don't collapse them — Gradient 1 on every panel makes
  Signal Purple the entire app, which is the opposite of the restraint the colour system
  asks for (tried it; Settings became unreadably loud).
  Type is **Open Sans**, the corporate typeface, bundled as the variable roman face
  (`Resources/Fonts/OpenSans-Variable.ttf`, SIL OFL — copied into the bundle by `build.sh`
  and registered via `ATSApplicationFontsPath` *and* explicitly by `Theme`, because
  `tools/shots.swift` draws with `Theme` from outside the bundle). The brand approves
  exactly four styles (Regular, Italic, SemiBold, Bold), so `brandFace(for:)` **snaps** an
  `NSFont.Weight` onto one of the three romans rather than letting descriptor matching
  hand back Light or ExtraBold; italic isn't bundled because nothing here is italic.
  `monoDigitFont` is Open Sans with tabular figures, for anything that counts up in place
  (the recording timer, the trim range). Both fall back to the system font if the face
  fails to register, so a missing font can't stop the app drawing. **One surface across the
  app**: `applyPanelGradient` / `stylePanel` for anything filling a window (Settings, History,
  Trim, alerts, the status-item menu), and `styleFloatingCard` for a small thing floating over a
  capture (the editor's tool cards, its inline bars) — the same `surfaceBase` + `panelGradient`
  the menu uses, plus a 1 pt hairline. Deliberate: the floating chrome and the menu the app
  opens from should be one material. Two ordering details in `styleFloatingCard` that are easy
  to undo by accident — the opaque `backgroundColor` under the gradient is what a caller's drop
  shadow derives its shape from (crisper than compositing one out of sublayers), and a layer
  draws its border *above* its sublayers, which is the only reason the hairline survives the
  gradient. The known trade is that a panel-scaled 45° sweep is compressed on a 126 pt card, so
  a card shows a short diagonal wash rather than the full sweep; the fix, if it ever matters, is
  a gentler `panelGradient`, not a second surface.
- `Logo.swift` — the "m." brand icon / menu-bar glyph, drawn in code. The icon is a
  **circle** — an 18x glyph inside a 34x circle, the proportion the Brand Icon guidelines
  fix — in the two approved variations only: *dark* (Gradient 1 circle, white glyph) for
  light backgrounds, *white* (white circle, Signal Purple glyph) for dark ones. That circle
  is the single documented exception to the square-cornered rule below, and
  `tools/makeicon.swift` draws the app `.icns` from **this same `Logo.image`** — `build.sh`
  compiles it against `Logo.swift` + `Theme.swift` (copying it to `main.swift` first, since
  swiftc only takes top-level code from a file by that name) rather than running it as a
  standalone script, so the icon and the in-app mark are one definition and the logo can't
  drift between them. It only adds the ~7% inset, which both gives the guidelines' clear
  space and keeps an inscribed circle inside macOS's squircle whether or not the system
  masks the icon.
  **The "m." is the official vector, and must stay one.** It used to be typeset — `Theme.font`
  at bold, rasterized and trimmed to its ink bounds — and no choice of substitute face can
  fix that: the wordmark is **PolySans**, which the brand reserves exclusively for the logo
  and which is commercial, so anything else is a different letterform and "never modify the
  logo" is an explicit don't. `markPathData` is therefore the `d` string from Frontify's own
  brand-icon SVG, parsed by a deliberately minimal `parse` (only `M m L l H h V v C c S s
  Z z`, the commands that string uses — extend it for a new asset rather than taking a
  dependency). Still drawn in code, no image asset, but no longer an approximation. The
  circle's gradient and the white variation's glyph colour come off that same asset, which
  is why they are **not** Gradient 1 / Signal Purple as you would guess from the Colors page. `menuBarImage(badged:)`
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
  Region → Window → Screen mode; draws the cutout, size readout, mode banner, and a
  lavender hover tint over the Window/Screen capture target.
  The centred guidance card (`drawModeBanner`) is the only chrome on screen before the
  gesture. Two stacked rows: **every mode in `availableModes` as a segmented control** (each
  segment carrying its own glyph, active one filled), then the muted shortcuts that apply
  right now. Stacked, not one horizontal strip — as a strip it ran ~828 pt, over half a
  1440 pt screen, with everything at the same weight so nothing led.
  **There is deliberately no "Drag to select" line**: the *cursor* carries the gesture —
  crosshair for Region, brand camera (or video, while recording) for Window/Screen over a
  lavender-highlighted target — so a text line was a third way of saying what the segment and
  the pointer already say. That only works while the cursors are honest; `modeCursor` used to
  hand the record flow a bare `.pointingHand` while its own docs promised a video cursor.
  The picker used to name only the current mode and say "Space to cycle", which asks the
  reader to already know there is something to cycle through; naming them as plain words then
  read as a caption *about* the card rather than a control, hence the segments. Building them off
  `availableModes` (not a fixed three) keeps a window/screen-forbidden flow honest: it shows
  a single segment and drops the hint row, rather than advertising a mode Space cannot reach.
  **Shortcuts are parallel phrases and adding one means matching the shape**: every hint is a
  **`%@` template** ("Press %@ to switch") whose key name is drawn as a **keycap** — a faint
  fill in a hairline border — so it reads as a key to press, not as more of the sentence.
  The `%@` is the seam `KeyHint` splits on: splitting the rendered phrase on whitespace would
  not survive translation, since English wraps the key while German *leads* with it
  ("%@ wechselt" → an empty `before`). A new hint must keep exactly one `%@`, and must read
  correctly alone — either hint can appear without the other.
  Pre-drag chrome — the guidance card and the dashed **last-region ghost** — stops drawing
  once `startPoint` is set, because guidance is for *before* the gesture and the size readout
  takes over during it. Both need `clearPreDragChrome()` on mouse-down: `invalidateSelection`
  dirties only the selection rect, so neither the card's (shadow-padded) frame nor
  `previousRect` would ever be repainted, and each sat there as a stale image until a drag
  happened to sweep across it. **Anything else drawn only before the drag has to be added
  there too**, or it will ghost the same way. An `OverlayCoordinator`
  is shared across every display's overlay so mode-cycling and capture work on any
  connected screen, not just the one under the initial cursor. It owns a local event
  monitor as a key-status safety net, and **that monitor must be captured weakly and torn
  down explicitly** (`stopMonitoring()`, called from both controllers' dismiss paths):
  AppKit retains a monitor's handler until `removeMonitor`, so a strong `self` made the
  coordinator and its monitor retain each other — `deinit` never ran and every capture left
  one more monitor intercepting each `keyDown`/`leftMouseDown` for the rest of the launch.
  The weak `views` table kept the strays harmless, which is why it went unnoticed; two live
  coordinators would cycle the mode twice on one Space press. Window mode
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
- `RecordZoomEngine.swift` — live recording zoom: crops each captured frame to a viewport
  and scales it back to the output size via one CoreImage pass into a private 420v
  `CVPixelBufferPool`, hooked at the single adaptor append in `VideoRecordSession`. Owns the
  ease state machine (smoothstep, wall clock — a pause needs no special case since frames stop
  reaching the transform), cursor sampling via `CGEvent` (safe off the main thread) and the
  time-constant follow smoothing with a dead-zone. Built in `start()` because
  `SCContentFilter.pointPixelScale` is the only authoritative pixels-per-point. Viewport
  geometry is forced **even** — 420v chroma is 2×2 subsampled, so an odd crop shifts colour
  against luma. Also holds `ZoomIndicatorWindow` (the excluded-from-capture viewport frame) and
  `--zoom-benchmark`, which times the transform on synthetic frames with no permissions needed.
  Region/whole-screen targets only: a window filter has no fixed display rect to map a cursor into.
- `ClickVisualizer.swift` — expanding ripple windows at mouse clicks while recording
  (global `NSEvent` monitor; deliberately *not* excluded from the stream).
- `RecordDrawOverlay.swift` — freehand drawing over the screen *during* a recording
  (⌃⇧D, the bar's pencil, or the menu): pencil / rectangle / circle / line / arrow, with
  ⇧ constraining, single letters switching tool (rebindable in Settings → Video →
  Drawing), Esc leaving and ⌫ clearing. Strokes reach the video for the same reason
  `ClickVisualizer`'s ripples do — the window is deliberately **not** in the stream's
  exclusion list — and it carries the same `punchHole` hazard: a fully transparent
  non-opaque window leaks every click to the app below, so draw mode paints the region
  at alpha 0.02 to hit-test at all. Region/whole-screen only; a
  `desktopIndependentWindow` filter composites nothing but that window, so the
  controller builds no overlay for a window target. Each mark fades on **its own**
  timer from when *it* finished, so marks vanish oldest-first and a long recording needs
  no clearing gesture; one `pending` work item per mark means scheduling something new
  always supersedes what it replaces. A fade starts from the layer's
  **presentation** opacity, never the model value — `fillMode = .forwards` leaves the
  model at 1, so reading that made Clear flash every mid-fade mark back to full strength
  before taking it down. Leaving draw mode calls
  `ScreenshotController.forcePointerReset()` and hands activation back only on its
  completion: dropping the cursor rect doesn't redraw the pointer (see the cursor-rect
  gotcha), and the reset briefly takes key status, so yielding first would snatch focus
  off the app just handed it.
- `Relocator.swift` — first-launch self-install into `~/Applications`. The DMG ships no
  `/Applications` drop target, so a distributed build launched from anywhere else (a
  mounted DMG, `~/Downloads`, a translocation path, even `/Applications`) copies itself
  there, strips the quarantine and relaunches — which is what lets the updater swap the
  bundle without admin rights. Opt-in via the `MCAutoInstall` Info.plist flag `build.sh`
  sets for DMG builds only, so the dev `--run` loop and the `--…-demo` launches stay in
  `build/`. Launch flags are forwarded by hand because `open` drops the original argv.
- `UpdateInstaller.swift` — the UI-free half of applying an update: download the `.dmg`,
  mount it, `ditto` the app out, verify, and `replaceItemAt` over the running bundle. Safe
  while running — the process keeps executing from its old inode — so the swap takes
  effect on the next launch. `URLSession` sets no quarantine xattr, so the swapped build
  doesn't re-trigger Gatekeeper. The staged bundle must be **both** newer than current
  *and* the exact version that was offered (`expectedVersion`): the caller records that
  string as what is now staged and the relaunch prompt names it, so a mismatched asset
  would have the app claim a version it isn't running.
- `HistoryWindow.swift` — the History panel: newest captures from the save folder as
  thumbnail cards (adaptive grid) with Copy / Pin / Trim / Reveal / Trash actions; rebuilt
  from the folder on every open, and on every filter change. Cards group under **day
  headings** (Today / Yesterday / date), which is what lets a card's caption shrink to a
  bare time — or "5m ago" inside the hour; the filename it dropped survives as the tooltip.
  Recordings carry their **duration** as a pill, the one fact a thumbnail can't show.
  The grid view is the panel's **first responder**: arrows move a selection, Return opens,
  Space is Quick Look (`QLPreviewPanel`, driven from the responder chain), ⌘C copies, ⌫
  trashes. Arrows walk the **visual rows** (`rows: [[Int]]`), not the flat order, so a
  short last row in one day's group can't send Down into the wrong column of the next.
  Unhandled keys must reach `super` or Esc stops closing the panel
  (`PanelWindow.cancelOperation`). Cells are drag sources, so a capture can be dragged into
  another app — which is why they now **consume their mouse-down**, and the panel no longer
  drags by its thumbnails (header and background only). The All / Images / Videos filter
  reuses Settings' `SectionTab`, so the underlined-tab look is defined once.
- `EditorWindow.swift` — the annotation editor: tool tiles in five groups
  (Markup, Shapes, Style, Actions, Background) placed by a **gap model**
  (`measureGaps`): the four strips of screen around the selection are measured in whole
  cards, each cluster takes the best gap that still has room (`preference`), a gutter
  stacks its run (`stackVertically`) while a strip lays it out in a row (`rowOutside`),
  and only clusters that *nothing* can hold get gathered (`gatherOffsets` + `rowSplit`)
  at the capture's bottom edge (`overCaptureOrigin`). This replaced an all-or-nothing
  `canScatter` test that sent **all five** clusters into one block over the image if a
  single gutter came up short — which happened for any capture within ~166 pt of a side
  edge, or under ~107 pt tall, or without ~185 pt clear above *and* below. Across a
  ten-shape matrix that test gathered everything in eight cases; the gap model gathers
  only for a whole-screen selection, where nothing outside the capture exists to use.
  Adding a cluster means adding a `preference` row. Style holds the color palette, custom-color picker, and a cycling stroke-width
  tile. Actions owns the Select tool (move/resize/delete a placed mark; **V**),
  crop, rotate-right, flip, undo/redo, Pin (⌘P), Before/After GIF, Copy (⌘C), Save
  (⌘S), Save As (⇧⌘S), Cancel. Owns tooltips, selection state, the pickers, and the
  live background preview (`BackgroundView`).
  Cards are `Theme.styleFloatingCard` — the status-item menu's surface plus a hairline; see the
  `Theme.swift` entry before changing it.
  Every card carries a `ClusterHeader` — a six-dot grip beside the group's eyebrow
  label, over the hairline — because the open-hand cursor was the *only* cue that the
  cards move, and a cursor is invisible until the pointer is already there. The header
  draws its own text rather than hosting an `NSTextField`: a control eats the
  mouse-down, which is why dragging by the caption never worked at all. It hides its
  own tip on press — the pointer never leaves the header it is dragging by, so the tip
  would otherwise park beside the moving card. The grip sizes into the padding a
  centered label already had (`contentWidth + 6`), not on top of it, so no card widens
  — German's "HINTERGRUND" is the one that has no slack to give; measure before
  rewording a group name.
  **A gathered block is an arrangement, not a container**: free-standing
  `DraggablePanel`s placed at a shared origin, not cards parented to one panel. It only
  *looked* like a slab — the cards have gaps between them — so a grab that hauled them
  all along read as a bug. Every card moves alone, in every layout; there is
  deliberately no move-them-all gesture. One card factory (`cardFit`) serves both the
  gap runs and the gathered block, so nothing has to stay size-matched between them.
  Two placement invariants are worth re-checking after any change here, because nothing
  enforces them at runtime: **no card overlaps another**, and **no card sits over the
  capture unless it is a leftover**. What holds the first one up is `gutterBand`: a gutter run
  is centred on the capture and then clamped, so it must be clamped into *the band the
  horizontal strips leave*, never into the whole screen. Clamping to the screen edge is what
  used to walk a column through the row above it — visible as one card sitting on another for
  a small capture in a screen corner (268 of 13689 simulated capture shapes). `measureGaps`
  sizes the run against that same band and grants no gutter at all when it is too shallow for
  one card, so capacity and placement cannot disagree; `rowOutside`'s two edges are the band's
  definition, so **change one and you must change the other**.
  **The capture is centred on the display, and shrunk if the cards still wouldn't fit
  around it** (`insetScale`, `magnification`). Centring is what makes the layout
  tractable: the four margins become two equal gutters and two equal strips, so `insetScale`
  needs two tests rather than four and the capture's original position drops out of the
  problem entirely. Scaling covers what centring can't — past roughly 78% of the screen's
  width no gutter clears a card, so all five cards would gather *on top of* the image, over
  the very pixels being annotated. `insetScale` runs `measureGaps`' own tests (one side with
  room is enough: a lone strip seats 10 cards, a lone gutter 5) and only scales when every
  side comes up short, to `f.width - 2·gutterInset`. About 10% of capture shapes scale;
  ≈0.78 for whole-screen on a 1440-pt display. Verified by simulating the gap model over
  1764 capture shapes × 9 screen sizes: nothing gathers, no card overlaps the capture or
  another card, nothing lands off-screen. A capture at the other extreme is **magnified**
  instead (`magnification`): centred in a dimmed screen, a 40×30 region is a postage stamp,
  and below ~36 pt of canvas the eight 18 pt resize knobs overlap each other so it can't even
  be resized. Its long edge is brought up to `comfortableEdge` in **whole steps** — integer
  only, so `CanvasView.draw` can lay whole blocks with `interpolationQuality = .none`;
  CoreGraphics bicubic-resamples even an exact 2x otherwise (a black/white edge comes back
  with six grey levels), and a fractional scale is a real resample, which is exactly what
  shrinking has to pay for.
  **How far it may enlarge is capped by the capture's own density, and that is the fix for a
  real "second display is blurry" report.** The canvas shows `1 / displayScale` captured
  pixels per point, and `displayScale` is `magnification / captureScale`, so a magnification
  at or under `captureScale` keeps one captured pixel per point or better; past it the picture
  is coarser than the screen's own point grid and looks soft no matter how it is drawn.
  `captureScale` *is* the display's density, so a Retina panel has 2x of headroom and a 1x
  external has none — and `fits` scales with the screen's *point* size, so the bigger 1x
  panel was granted magnification the smaller Retina one refused. A 265 pt capture opened
  enlarged 2x on both: ~113 captured pixels per inch on the Retina, ~46 on the 1x external.
  Hence `workableEdge` — only a capture genuinely too small to aim a mark at pays for
  replication (up to `maxMagnification`); anything larger gets only what its density gives.
  Halved the 1x display's magnifying shapes from 195 to 25 in a 5184-shape sweep, with the
  Retina path unchanged. Also capped at half the display, which keeps
  every margin at a quarter-screen or more so a magnified capture can't push the cards back
  onto itself. Below that floor `placeResizeHandle` drops to corners only.
  Both fold into `displayScale`, so relayout / crop / rotate / flip follow for free — and it
  stays **1 whenever the cards already fit**, because an inexact scale makes CoreGraphics
  resample the whole canvas on every redraw (see the `init` note; hence
  `interpolationQuality = .high` in `CanvasView.draw`).
  Those two only pick the **opening** scale, and it is the only scale there is. From then on
  **the eight resize knobs change the captured region** (`resizeDragged`, `resizeEnded`): each
  drags only the edge(s) it sits on, holding the opposite one fixed — no aspect lock, no centre
  anchor. Those two were tried and are wrong here: locking the aspect makes an edge knob change
  the height too, and anchoring on the centre makes it move the opposite edge, so no knob feels
  like it belongs to the side it sits on.
  What makes "out" possible is `CaptureSource` — the `CGImage` the canvas is a window onto plus
  `rect`, the part of it currently shown, in **source pixels with a top-left origin**.
  `ScreenshotController.finish` already held the whole-display freeze and threw it away one line
  later; it now hands it to the editor along with the capture's pixel rect inside it, so
  dragging out uncovers screen the selection left behind, from *the same instant* as the shot.
  A window grab, the live fallback and `AppDelegate`'s direct hand-off pass none, and the source
  falls back to the capture itself — one code path either way, differing only in reach.
  Since the scale never moves, a point dragged is a point of screen gained or given up, and the
  committed region is **rounded to whole source pixels** so the crop never resamples. Rotate and
  flip leave the image no longer aligned with the display, so they `rebaseSource()` onto the
  transformed canvas: the knobs keep working, they just crop and un-crop from there. A crop-tool
  crop is still a sub-rect, so it only offsets `rect` and keeps the full reach.
  The region is real, not presentational: `applyTransform` swaps the image and carries the
  annotations, dropping marks the new region no longer contains exactly as the crop tool does.
  This is the **display re-grab**, done right. The old one re-captured a larger rectangle *from
  the screen* on every knob drag — an async ScreenCaptureKit round trip that could fail, and
  that stitched now-pixels around then-pixels. Cropping a still taken at the hotkey has neither
  problem. What it does inherit is the old one's one real flaw: the reach stops at the display's
  edge, and once the capture is centred that edge is invisible, so a shot taken 10 pt from the
  screen's left stops after 10 pt while looking like it has 500 pt of room. If that bites, draw
  the boundary during the drag — don't go back to stretching.
  The **free stretch** that sat here in between is gone with it, along with `snapScale`,
  `scaleSnap` and `maxCanvasScreens`. It let a knob zoom the picture without limit, which is
  genuinely useful for a small capture and is why `magnification` still exists — but it
  distorted the screenshot on a non-uniform drag, and it meant the knobs did something other
  than what dragging a selection edge does everywhere else in the app. If hand zoom is ever
  wanted back it belongs on a modifier (⌥-drag), not on the bare knob.
  `relayout` **centres** a frame too big to fit rather than pinning it into a corner, which now
  matters when a region is grown out to the whole display.
- `CanvasView.swift` — the annotation canvas: `Tool` enum, undo/redo, Gaussian blur,
  crop/rotate/flip transforms (`applyTransform` shifts annotations when the region
  changes), and live edit state. Scale is **two `var`s, `scaleX` / `scaleY`** — a leftover of
  the editor's old free stretch, so they are equal in practice now — and whoever writes them
  owns resizing the view to match. **Coordinate conversions must use both axes**; the scalar
  `displayScale` (`min` of the two) is for *tolerances* only — hit radii, knob sizes, minimum
  drag extents, which are circles in view space and so have no axis. `endTextEditing()` exists
  so the editor can land a live `NSTextView` (positioned in view points) before a scale change
  strands it. Shapes get an eight-handle box resize
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
  a static array. **An animated GIF pins as an animation** (`pinGIF(url:)`, used by
  History): `PinView` keeps the `CGImageSource` and decodes **one frame at a time** on a
  rescheduled one-shot timer — not every frame up front, because a GIF exported from a
  recording is 960 px at 10 fps, so a 30-second take is ~300 frames and hundreds of MB
  for a single window. Only the per-frame delays are read eagerly (cheap, and needed for
  timing); a 0/near-0 delay is floored at 100 ms the way browsers do it, or a pin would
  redraw as fast as the CPU allows. The timer goes on `RunLoop.main` in **`.common`**
  mode: a pin has to keep moving while another app is frontmost and while the user drags
  or resizes it, and a drag runs a modal event loop that `.default` never gets a turn in.
  It is invalidated in `viewWillMove(toWindow:)` — the block captures `self` weakly so a
  stray timer cannot resurrect the view, but the run loop would keep firing it for the
  rest of the launch, once per closed pin.
  Copy and Save on an animated pin hand over the **original GIF bytes**; routing them
  through `image()` / `Settings.encode(rep)` writes a one-frame TIFF/PNG, which is how
  pinning and copying a GIF used to silently flatten it.
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
  launch-at-login (live via `SMAppService`), Dock-icon visibility, `videoConfirmStop`
  (ask before a stop that saves), `simulateRecording`
  (+ the `--simulate-recording` launch override, which pins it on and disables the
  checkbox). `fileURL()` + `encode(_:)` are the
  single source for where/how captures are saved; `fileURL()` uniquifies the name and
  `resolvedSaveDirectory()` falls back to the Desktop when the configured folder is
  gone/unwritable. `fileURL()` also **claims** the name it hands out (`claimedNames`), because
  `fileExists` alone can't separate two captures resolving in the same second: the encode and
  the write happen off the main thread, so the second probes before the first has created
  anything and silently overwrites it. The claim is in-memory, not a placeholder file —
  `AVAssetWriter` refuses a URL that already exists, so touching the recording's `.mp4` would
  break recording. A name that is only being *shown* (a save panel's prefill) must use
  `suggestedFileName()`, which claims nothing.
- `SettingsWindow.swift` — the dark Settings panel (`SettingsWindowController.shared`):
  an icon sidebar (macOS System Settings shape) with General / Shortcuts / Capture /
  Output / Video / About sections, per-row info-dot tips, and a fixed window size
  measured once against the tallest row set — **sub-tab variants included**
  (`rowVariants(_:)`), so no switch can resize the panel.
  Video carries the drawing settings too, behind a `SectionTabBar` (Recording /
  Drawing): each half is a section's worth of rows, and stacking them made every other
  tab as tall as their sum — a scrolling rows area fixed the height but put a scrollbar
  over the controls, so sub-tabs it is. The strip is **underlined tabs on a hairline
  baseline**, not pills: a lone selected pill reads as a toggled button, leaving the
  other label looking like a stray link instead of the tab it is. Adding rows to either half raises every tab's
  height; measure before adding.
  Rows share one rhythm — `Layout.rowHeight` (24) + `rowGap` (10) for *every* row type.
  Sizing rows to their content instead is what made the pitch jump between blocks: the
  form controls are all 24 pt but a checkbox's own height is 16, so checkbox runs read
  tighter than popup runs. A row that needs a different control height changes the
  control, not the row.
  Sections group their rows with `groupHeading(_:firstInSection:)`,
  a quieter small-caps sibling of the section eyebrow: Shortcuts splits into
  Capture / While recording / App; inside Video's Drawing sub-tab, Drawing keys.
  The heading is what carries a row's context, which is what lets a label be one word —
  spelled out, "Zoom While Recording" was clipped in all three languages. Drawing lives
  under Video (it used to be its own "Live Drawing" tab) because it does nothing outside
  a recording.
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

- **The app has a window-level ladder; don't flatten it.** Full-screen capture surfaces
  sit at `.screenSaver` (the editor) or `.screenSaver + 1` (the selection overlay), and
  everything meant to appear *over* the editor is written relative to that: the color /
  emoji / counter pickers and `BrandToast` at `+1`, `BrandAlert` at `+2`. `.normal` is
  wrong for any of them — the Dock (level 20) and the menu bar (24) then draw over the
  editor and **clip its tool cards**, and any other app's window can cover the whole
  thing. The editor was silently dropped to `.normal` once in a commit about something
  else; the "above the screen-saver-level editor" comments left behind are the tell.
  **Setting a level is not the same as keeping one: `NSApp.runModal(for:)` reassigns the
  window's level to `.modalPanel` (8) when the session begins.** Every modal `BrandAlert`
  therefore fell ~1000 levels at the moment it went up, landing behind the `.screenSaver`
  editor while still holding the modal session — an invisible window eating every click, which
  reads as the app freezing with a dialog stuck behind the capture. `AlertPanel` now clamps its
  `level` setter (`minLevel`) so AppKit cannot lower it; don't replace that with a re-assert
  after `runModal`, which races the session start. Verify a level with `kCGWindowLayer` from
  `CGWindowListCopyWindowInfo`, not by reading back `window.level` — the code constant said
  1002 the whole time the window server had it at 8.
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
- **The capture cursor is a cursor *rect*, and the rect must be handed back, not dropped.** `SelectionView`
  claims one over its whole bounds (`resetCursorRects`), because a one-shot `NSCursor.set()`
  races window activation and the plain arrow would survive until the pointer first moved —
  and a `.cursorUpdate` tracking area doesn't help, since a pointer already inside the
  overlay when it appears never *enters* it. Rects are only honoured while the app is
  **active** and `NSApp.activate` is asynchronous, so `claimKeyboard` re-asserts across its
  retries, not just when key status is missing. The flip side: a rect the window server still
  remembers keeps re-asserting after the overlay is gone, which left a camera pointer on
  screen until the next mouse move. **Hand the rect back as the arrow; do not drop it.**
  `relinquishCursor()` latches `cursorReleased` (so a late rect pass can't re-claim the
  capture cursor) and then installs `.arrow` as the rect — immediately, via `addCursorRect`,
  not `invalidateCursorRects`, which only *schedules* a pass a closing window never gets.
  Both controllers call it **before** ordering the overlays out, because only a window still
  under the pointer has a rect to push.
  Discarding the rect instead — what this used to do — leaves the server with no claim, and
  what it then keeps drawing is the last image it composited: the capture cursor. That is
  the bug that put a video-camera glyph in the first ~0.5 s of **every recording**, since
  `SCStream` bakes whatever the server is drawing into the frames.
  The other half was `viewDidMoveToWindow`, which called `modeCursor.set()` unguarded and is
  called *again* on `close()` with `window == nil` — re-installing the capture cursor a
  run-loop turn after the teardown had just handed the pointer back. It now returns early
  once the cursor is released. **Anything on the teardown path that sets a cursor has to be
  guarded the same way.**
  What does *not* work, and cost several wrong fixes: `NSCursor.set()`, `hide`/`unhide`,
  `CGWarpMouseCursorPosition`, `CGDisplayHideCursor`, `NSCursor.setHiddenUntilMouseMoves`,
  and a *fresh* window owning a rect — all change the **claim**, not the drawn image, and the
  server keeps drawing what it last composited until *pointer motion* makes it re-evaluate.
  A rect on a window already under the pointer is the one exception, which is exactly why
  Space cycling the overlay's mode changes the glyph instantly without moving the mouse.
  `SCStream.updateConfiguration` cannot flip `showsCursor` on a live stream either (it
  returns no error and does nothing), so the capture side is no escape hatch.
  Asserting on `NSCursor.current` proves nothing here; it was already the arrow the whole time.
  `ScreenshotController.redrawPointer(on:)` therefore supplies the motion:
  `CGWarpMouseCursorPosition` one point and back on the next tick — two distinct positions so
  it can't be coalesced, net position unchanged, imperceptible. It needs **no** Accessibility
  grant (that gates *synthesizing events* with `CGEvent.post`, not repositioning the pointer;
  a comment here used to claim otherwise). The nudge picks its direction to stay inside the
  current display so it can never walk the pointer onto another screen.
  **And none of it works while a mouse button is held**: the server treats motion during a
  held button as a drag and suppresses cursor re-evaluation entirely. `SelectionView.mouseDown`
  commits **Screen** mode on the *press*, so every reset there ran mid-click and was discarded
  — while Region, which commits on `mouseUp` at the end of a real drag, worked fine and made
  the bug look mode-specific. `forcePointerReset` therefore waits for `NSEvent.pressedMouseButtons
  == 0` (bounded retries) and then defers to a later run-loop turn, so it never runs inside the
  dispatch of the event that triggered it.
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
- **Form controls are a translucent white veil over the panel, not a coloured slab.**
  Popups, text fields and shortcut fields all draw `Theme.controlFill` (white 0.06) inside
  a `Theme.controlStroke` hairline (white 0.16). Both scale with whatever is behind them,
  so the control holds the same *relative* contrast (fill ≈1.18:1, stroke ≈1.95:1) at
  every point of `panelGradient` — no part of the sweep can swallow it — and it matches how
  the rest of `Theme` does neutral surfaces (`hoverFill` 0.10, `divider` 0.18,
  `cardStroke` 0.22). Two approaches were tried and rendered before this one:
  `surfaceRaised` + `border` (what it used to be) became **1.03:1** fill / **1.00:1**
  border once `panelGradient` lifted to Primary 1.1 at the top-right, and the controls
  disappeared; a Deep Trust well ringed in lavender was legible but looked like a debug
  wireframe — near-black boxes punched into a purple panel, and it spent the brand's one
  accent on six rows of chrome. **Lavender is reserved for focus** (an open popup, a
  recording shortcut field), which is where an accent belongs and where it now actually
  reads. Don't put a control's edge back on `border`; that token is for a divider on a
  known backdrop.
  **Disabled state is expressed in colour, never with `alphaValue`.**
  `controlFillDisabled` / `controlStrokeDisabled` / `controlTextDisabled` /
  `controlGlyphDisabled` keep the box present and mute its content. Alpha compounds: the
  popup dimmed itself to 0.4 *and* `updateBackgroundDependentRowsEnabled` dimmed the whole
  row to 0.4, so the Padding and Corner-radius controls rendered at 0.16 — they read as
  missing, not disabled. A disabled control that loses its outline is indistinguishable
  from empty panel.
- **All styling goes through `Theme.swift`** — never hardcode colors or fonts (that
  includes `NSFont.systemFont` and `NSFont.monospacedDigitSystemFont`: the app's typeface
  is Open Sans, so go through `Theme.font` / `Theme.monoDigitFont`), and take
  corner radii from `Theme.radiusSmall` / `radiusMedium` rather than a literal. **Both are
  `0`**: the brand is square-cornered everywhere — panels, chips, badges, pills, banners,
  tool tiles, colour swatches, hover highlights, the sidebar selection, the version badge.
  A literal radius is the bug, not the value; route it through the token so the shape stays
  one decision. Three things are deliberately *not* chrome and keep their curve: the
  `Background` preset's user-configurable image corner, the editor's rounded-rectangle
  annotation tool, and shapes that are circles by function (the recording dot). A fourth
  exception is the **brand icon**, which the official guidelines define as circular — that
  is a brand rule, not a local judgement, so it overrides the square default (`Logo.swift`,
  `tools/makeicon.swift`, and `.logo` in `docs/index.html`). Push buttons
  can't take a radius at all — a native `bezelStyle = .rounded` is rounded by AppKit — so
  Settings' Choose… and the About card's actions are a custom-drawn `BrandPushButton`.
  It is deliberately **not** a `PointerButton` subclass: `PointerButton` also backs the
  panel's `NSButton(checkboxWithTitle:)` checkboxes, and a fill painted in its `draw`
  lands behind the checkbox label as a purple slab. Those checkboxes are the one control
  AppKit still rounds for us.
- **The official brand guidelines are the authority on colour, type and the logo** —
  Frontify → *mesoneer Brand → Guidelines*, mirrored in `docs/styleguide.md` (read the
  mirror; don't re-scrape the site). Measurements from mesoneer.io cover only what the
  guidelines leave open: layout, spacing, hero/nav/footer metrics on the landing page.
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
  **`N` follows display order**, and the dicts are kept in that order too (`1.h`, `1.p`,
  `2.h`, …) — so a new card is the next number and appends at the end of each dict. The
  numbering used to be historical: twelve cards numbered 1-4, 7-9, 13, 14, 16-18, with
  `feat.18.p` sitting before `feat.17.p` in both dicts. Nothing user-visible, but it made
  it easy to add one half of a pair and not notice the other was missing.
