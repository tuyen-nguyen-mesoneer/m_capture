# m_capture — contributing

## Prerequisites

- macOS **13.0** (Ventura) or later
- **Xcode Command Line Tools** (`xcode-select --install`) — full Xcode not needed

## Build & run

```sh
./build.sh                 # → build/m_capture.app + m_capture.dmg (repo root)
open build/m_capture.app   # menu-bar app — look for the "m." icon
```

`build.sh` compiles `Sources/*.swift` with `swiftc`, assembles the bundle
(`io.mesoneer.mcapture`, `LSUIElement`), draws the icon, signs, and packages the
DMG. No Xcode/SPM project.

**Faster development loop**

- `./build.sh --run` — rebuild, quit, and relaunch in place (skips the DMG).
- **Preserving the Screen Recording grant:** ad-hoc signing changes the app's
  identity on each build and resets the grant. Create a self-signed **Code Signing**
  certificate named **`m_capture-dev`** in Keychain Access (Certificate Assistant →
  Create a Certificate, Identity Type *Self Signed Root*); `build.sh` then signs with
  it, so the grant persists.
- `./build.sh && open build/m_capture.app --args --settings-demo` — opens the
  Settings panel at launch to iterate on it.

## Releasing

1. Bump `VERSION` in `build.sh` (semver, e.g. `1.1.0`).
2. Build with the **`m_capture-dev`** cert present (see *Faster dev loop* above) — a
   stable signing identity means users keep their Screen Recording grant across
   updates instead of re-granting after every release.
3. `./build.sh` → `m_capture.dmg` in the repo root.
4. Create a **GitHub Release** tagged `v<VERSION>` and attach the DMG. The app's
   **Check for Updates** reads `releases` (newest-first), so the tag must match `VERSION` and
   the repo's releases (and issues, for **Report a Bug**) must be readable by every
   user — i.e. the repo is public or org-accessible to all employees.

> The build is **not notarized** (no Apple Developer ID), so first launch needs the
> *System Settings → Privacy & Security → Open Anyway* step. See the README's Install
> section — link users there.

## Where things live

Full source map in **[`CLAUDE.md`](CLAUDE.md)**. Quick index:

- **Menu item / hotkey** → `AppDelegate.swift` (+ `HotKey.swift` for Carbon).
- **Selection overlay** → `ScreenshotController.swift` / `SelectionOverlay.swift`.
- **New annotation tool** → `Tool` case + drawing in `Annotations.swift`, input in
  `CanvasView.swift`, tile + shortcut in `EditorWindow.swift`.
- **Background** → `Background.swift`; **setting/preference** → `Settings.swift` +
  `SettingsWindow.swift`.
- **Colors, fonts, spacing** → `Theme.swift`.

## Conventions

- **No external dependencies** — system frameworks only.
- **All styling via `Theme.swift`** — no hardcoded colors or fonts.
- **Icons drawn in code** (SF Symbols or CoreGraphics) — no image assets.
- **Editor coordinates stay in full-resolution image space** so exports stay sharp.
- **Comments explain *why*, not *what*** — prefer one `///` doc comment over
  scattered inline notes.
- Write original code; match the surrounding Swift.

> ⚠️ Before touching capture code: all capture shells out to
> `/usr/sbin/screencapture` (no in-process pixel grab), and multi-monitor
> coordinate math lives in `ScreenshotController.finish`. See
> **[`CLAUDE.md` → Gotchas](CLAUDE.md)** for the rest.

## Testing

No automated suite — smoke-test by hand after a build. Cover what your change
touches, plus a baseline pass:

- **Hotkeys** `⌃⇧X` / `⌃⇧R` (and any you rebound) fire.
- **Capture** — a region drag shows the overlay + size label; **Space** grabs the whole screen.
- **Editor** — tools draw correctly; undo/redo, crop, rotate, flip and corner-drag resize work.
- **Output** — `⌘C` copy, `⌘S` save, `⇧⌘S` Save As, `Esc` cancel; plus Pin (`⌘P`), OCR, the Before/After GIF, and backgrounds.
- **Settings** persist across relaunch; check **multi-monitor** geometry if you touched capture.

If the UI changed, regenerate the README screenshots:

```sh
swiftc -O -o build/shots tools/shots.swift $(ls Sources/*.swift | grep -v main.swift) \
  -framework AppKit -framework Carbon && ./build/shots docs/assets
```

## Landing site (`docs/`)

The GitHub Pages site is static. Preview it locally with:

```sh
./serve.sh           # → http://localhost:8000  (pass a port to override)
```

Serve from `docs/` (the script does) so relative asset/font paths resolve —
opening `index.html` via `file://` won't load them. Reload the browser after
edits; add `?lang=en` / `?lang=de` to force a locale. Brand tokens (colors,
type, spacing) live in [`docs/styleguide.md`](docs/styleguide.md).

## Reporting issues

[Open an issue](https://github.com/tuyen-nguyen-mesoneer/m_capture/issues/new) with
your macOS version, steps to reproduce, and expected vs. actual result (the app's
**Report a Bug** menu item pre-fills the version details for you). For capture bugs,
note whether **Screen Recording** is granted and whether the file/clipboard came out
empty — that usually points at the signing/grant reset above.

## Pull requests

1. Branch off `main`.
2. Run `./build.sh` — confirm it builds and launches.
3. Smoke-test the areas you touched.
4. Update docs (`README.md` / `CLAUDE.md`) and screenshots when behavior, tools, or shortcuts change.
5. Open a focused PR with imperative commits and a clear what / why / how-tested.
