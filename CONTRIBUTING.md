# m_capture — contributing

## Prerequisites

- macOS **14.0** (Sonoma) or later
- **Xcode Command Line Tools** (`xcode-select --install`) — full Xcode not needed

## Build & run

```sh
./build.sh                 # → build/m_capture.app + m_capture.dmg (repo root)
open build/m_capture.app   # menu-bar app — look for the "m." icon
```

`build.sh` compiles `Sources/*.swift` with `swiftc`, assembles the bundle, draws the icon, signs, and packages the
DMG. No Xcode/SPM project.

- **Faster development loop**
  - `./build.sh --run` — rebuild, quit, and relaunch in place (skips the DMG).
  - **Keep the Screen Recording grant across rebuilds:** ad-hoc signing resets the
    grant every build. Create a self-signed **Code Signing** cert named **`m_capture-dev`** in
    Keychain Access (*Self Signed Root*); `./build.sh --run` then signs with it. It's local and
    per-developer, separate from the shared release identity (see *Releasing*).
  - `./build.sh && open build/m_capture.app --args --settings-demo` — opens the
    Settings panel at launch to iterate on it.

## Releasing

CI does the work: push a version tag and a signed `m_capture.dmg` is published to a GitHub
Release (`.github/workflows/release.yml`). Every release is signed with one shared identity,
**`m_capture-release`**, so users keep their Screen Recording grant across updates — the grant
is tied to the signing cert, and a different cert forces everyone to re-grant.

### One-time setup (admin, once)

1. **Create the cert** — Keychain Access → *Certificate Assistant → Create a Certificate* → a
   **Code Signing** cert (*Self Signed Root*) named exactly **`m_capture-release`**.
2. **Export it** — right-click the cert → *Export* → `m_capture-release.p12`, and set a password.
3. **Add two GitHub secrets** — repo → **Settings → Secrets and variables → Actions → New
   repository secret**:
   - `RELEASE_CERT_P12_BASE64` — run `base64 -i m_capture-release.p12 | pbcopy`, then paste.
   - `RELEASE_CERT_PASSWORD` — the password from step 2.
4. **Pin it** — set `RELEASE_CERT_SHA` in `build.sh` to the cert's SHA-1 (from
   `security find-identity -p codesigning`), so a build signed by any other cert fails.

### Cut a release (anyone)

1. Bump `VERSION` in `build.sh` and commit.
2. Tag (no `v` prefix, equal to `VERSION`) and push:
   `git tag 1.2.0 && git push origin 1.2.0`.

CI checks the tag matches `VERSION`, signs the DMG, and publishes the release. Users' apps
download it, swap in place, and run the new version on next launch (a silent daily check, plus
**Check for Updates**). The repo's releases (and issues, for **Report a Bug**) must be readable
by every user — keep the repo public or org-accessible.

## Conventions

- **No external dependencies** — system frameworks only.
- **All styling via `Theme.swift`** — no hardcoded colors or fonts.
- **Icons drawn in code** (SF Symbols or CoreGraphics) — no image assets.
- **Editor coordinates stay in full-resolution image space** so exports stay sharp.
- **Comments explain *why*, not *what*** — prefer one `///` doc comment over
  scattered inline notes.
- Write original code; match the surrounding Swift.

## Testing

No automated suite — smoke-test by hand after a build. Cover what your change
touches, plus a baseline pass:

- **Hotkeys** `⌃⇧X` / `⌃⇧R` (and any you rebound) fire.
- **Capture** — a region drag shows the overlay + size label; **Space** cycles Region → Window → Screen (window mode hover-highlights the window under the pointer and captures it when the mouse is released over it), for both `⌃⇧X` and `⌃⇧R`.
- **Editor** — tools draw correctly; undo/redo, crop, rotate, flip and corner-drag resize work; the **Select** tool (`V`) moves / resizes / deletes a placed mark.
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

1. Branch off `trunk`.
2. Run `./build.sh` — confirm it builds and launches.
3. Smoke-test the areas you touched.
4. Update docs (`README.md` / `CLAUDE.md`) and screenshots when behavior, tools, or shortcuts change.
5. Open a focused PR with imperative commits and a clear what / why / how-tested.
