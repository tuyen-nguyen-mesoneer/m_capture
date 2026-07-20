# m_capture — usage & reference

A complete reference to the menu, the capture flow, the annotation tools, keyboard
shortcuts, settings, and troubleshooting. For installation and build instructions,
see the [README](README.md).

- [The menu](#the-menu)
- [Taking a screenshot](#taking-a-screenshot)
- [Recording](#recording)
- [The annotation editor](#the-annotation-editor)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)

---

## The menu

Click the **m.** menu-bar icon to open the menu — its header shows the current
version on a badge. If the menu bar is hidden (notch, menu-bar hider), click the
**m.** icon in the **Dock** to drop the same menu instead. **Screenshot** and
**Record** also have global hotkeys (`⌃⇧S` / `⌃⇧R`) that fire directly, without
opening the menu.

<p align="center">
  <img src="docs/assets/menu.png" alt="The m_capture menu-bar dropdown with Screenshot, Record, Library, Settings, About and Quit" height="300">
  <br>
  <em>The branded menu-bar dropdown.</em>
</p>

| Menu item             | Hotkey | What it does                                                                                                                    |
|-----------------------|:------:|---------------------------------------------------------------------------------------------------------------------------------|
| **Screenshot**        | `⌃⇧S`  | Dim the screen; drag a region, or press **Space** to pick a window or the whole screen; open the editor.                        |
| **Record**            | `⌃⇧R`  | Dim the screen; pick a region, a window, or the whole screen; record it in-app to an MP4.                                       |
| **Quick Screen**      | `⌃⇧Q`  | Instantly grab the screen under the pointer — no overlay, no delay.                                                             |
| **Library**           |   —    | Open the save folder in Finder.                                                                                                 |
| **Settings**          |   —    | Shortcuts, capture delay, save location, format, backgrounds, more.                                                             |
| **Usage Guide**       |   —    | Open this reference on GitHub.                                                                                                  |
| **About**             |   —    | Show the About panel (version + license).                                                                                       |
| **Check for Updates** |   —    | Check GitHub Releases for a newer version.                                                                                      |
| **Report a Bug**      |   —    | Open a [pre-filled GitHub issue](https://github.com/tuyen-nguyen-mesoneer/m_capture/issues/new) (app + macOS version attached). |
| **Quit**              |   —    | Quit `m_capture`.                                                                                                               |

While a recording is in progress, the menu also shows **Stop Recording**,
**Pause / Resume Recording**, and — if the floating bar is minimized — **Show
Recording Bar**, so the whole recording can be driven from the menu bar.

---

## Taking a screenshot

1. Press `⌃⇧S`. The screen dims and the cursor becomes a crosshair.
2. **Drag** to select a region. A live cutout shows the area bright with a
   `width × height` label. Press **Space** to cycle modes — the cursor switches to a
   camera glyph for the other two: **Window** — hover over a window to wash it in a
   light purple tint so the target is obvious, then release the mouse over it to
   capture just that window; and **Screen** — the whole display is tinted and a
   single click captures it. Space again returns to region selection. All three
   modes work on every connected display, not just the one you started on.
3. Release — the [editor](#the-annotation-editor) opens with your capture, its
   cursor switching to match whichever tool is active (pencil by default).
4. Annotate, then **Copy** (`⌘C`) or **Save** (`⌘S`). `Esc` cancels.

<p align="center">
  <img src="docs/assets/editor.png" alt="The drag-to-select overlay: the screen dimmed with a bright cutout for the selected region and a size readout" width="640">
  <br>
  <em>Drag to select — the chosen region stays bright while the rest dims.</em>
</p>

Captures save to the Desktop as a PNG by default and copy to the clipboard. The
filename format, location, image format and auto-copy are all configurable in
[Settings](#settings).

---

## Recording

1. Press `⌃⇧R`. The screen dims — the same overlay as a screenshot.
2. Choose what to record: **drag** a region, or press **Space** to cycle to
   **Window** (hover a window to tint it, release the mouse over it to record just
   that window) or **Screen** (the display is tinted; click to record it whole). All
   three work on any connected display.
3. Recording starts with a floating bar showing a live timer, the estimated file
   size, and a quality badge, plus **pause/resume** and **stop** — drag anywhere on
   the bar's background to move it out of the way (the cursor shows an open hand).
4. **Stop** (or **Return**) finalises the `.mp4` (HEVC video, optional AAC audio) into
   your save folder and reveals it in Finder. **Esc discards** the recording after a
   confirmation — the take is deleted, nothing is saved.

**Knowing it's recording, and controlling it from the menu bar:** while recording, the
menu-bar **m.** icon becomes a **red dot with a live timer** (grey "Paused" when
paused). Click the **–** button on the floating bar to **minimize** it to the menu bar;
you can then **Pause / Resume / Stop** — and **Show Recording Bar** — from the menu.

Quality and the audio source (system, microphone, or both) live in
**Settings → Video**. If the microphone is requested but permission is denied, the
recording continues without the mic track. Quitting the app mid-recording still
finalizes a playable file.

---

## The annotation editor

The editor frames your image on a dark backdrop with tools in **clusters**
(Markup, Shapes, Style, Actions, Background). For small or very large selections,
the clusters gather into one draggable panel so they never cover the image.

### Tools

**Markup** — draw, redact, label and stamp.

| Tool           | Key  | Description                                                                            |
|----------------|:----:|----------------------------------------------------------------------------------------|
| Pencil         | `P`  | Freehand thin stroke.                                                                  |
| Highlighter    | `H`  | Thick, translucent marker.                                                             |
| Eraser         | `E`  | Remove the annotation under the click.                                                 |
| Text           | `T`  | Click to place a label and type inline. A floating bar lets you set size, bold, alignment and the box's own background (fill/outline + color) while you type.  |
| Blur           | `B`  | Soften a region (redact sensitive content).                                            |
| Spotlight      | `S`  | Dim everything outside a rectangle.                                                    |
| Counter        | `C`  | Auto-incrementing badge — numbers, letters or Roman. Deleting one renumbers the rest so the sequence stays in order. |
| Emoji          |  —   | Stamp an emoji (click the tile to choose).                                             |
| Zoom           | `Z`  | Magnify a region into a callout bubble.                                                |
| Ruler          |  —   | Drag to measure at any angle (hold `⇧` to snap horizontal/vertical); the placed mark stays live to reshape by its endpoints or move it. |
| Overlay image  |  —   | Add an image — paste (`⌘V`), drop a file, or click to choose (with an opacity slider). |
| Copy text / QR | `⌘T` | OCR — drag over text or a QR code to recognize & copy it.                              |

**Shapes** — drag to draw; all hollow outlines. A just-drawn shape stays live with its
handles showing, so you can resize or move it (or press `⌫` to remove it) without
switching tools.

| Tool              | Key | Tool      | Key |
|-------------------|:---:|-----------|:---:|
| Arrow             | `A` | Star      | `Y` |
| Line              | `L` | Pentagon  | `5` |
| Rectangle         | `R` | Hexagon   | `6` |
| Ellipse           | `O` | Octagon   | `8` |
| Rounded rectangle | `U` | Checkmark | `K` |
| Triangle          | `G` | Diamond   | `D` |

### Transform & actions

- **Select / edit** (`V`) — click any placed mark to select it, then **drag** to reposition or press `⌫` to delete it. **Shapes** resize from **eight handles** — four corners (free) and four edge midpoints (stretch a single side, e.g. widen a triangle). **Arrows and lines** show three handles — both **endpoints** and a **bend** handle at the apex. The **ruler** shows two endpoint handles (no bend, so its distance label always matches what's drawn). Text, emoji, counters, blur, spotlight, overlays and zoom callouts resize from a corner knob; freehand strokes are move-only. Everything can also be edited right after you draw it, without switching to Select.
- **Crop** — drag a region, then `↵` (or **✓**) to apply.
- **Rotate** — 90° right (clockwise).
- **Flip horizontal** — mirror the image left↔right.
- **Adjust the capture region** — drag any of the **eight handles** around the capture (four corners + four edge midpoints) to change what's captured: trim inward to crop, or drag outward to re-grab a **larger** area of the screen. Corners move both axes, edges a single one.
- **Pin to screen** (`⌘P`) — float the capture always-on-top across Spaces. Drag to move, corner-drag to scale, right-click for **Copy / Save / Reset size / Close** (`Esc` / `⌘W` close). Pin several at once.
- **Before/After GIF** — export a two-frame looping GIF that toggles the annotations on and off, useful for highlighting before-and-after differences.
- **Undo / Redo / Copy / Save / Save As / Cancel** — see the shortcut table below.

### Style

- **Palette:** red, orange, yellow, green, blue, purple, pink, white, black, plus
  **+** for a custom color (hue strip + brightness square).
- **Eyedropper** (`I`) — sample a color from the screenshot to match it.
- **Stroke width** — the line-weight tile cycles **Thin → Medium → Thick**; the new
  width applies to marks you draw next and to the currently selected mark.

### Backgrounds

The **Background** cluster wraps your capture in a share-ready frame — padding,
rounded corners and a soft shadow. Pick **None** (default), one of **10 presets**
(White, Light, Dark, Black; Lavender / Sunset / Ocean / Forest / Candy / Midnight
gradients), or **+** for a custom color. It previews live and is baked into Copy,
Save and Pin (OCR always uses the un-framed image).

### Keyboard shortcuts

| Shortcut          | Action                                               |
|-------------------|------------------------------------------------------|
| `⌘Z` / `⇧⌘Z`      | Undo / Redo                                          |
| `⌘C`              | Copy to clipboard & close                            |
| `⌘S`              | Save to your save folder & close                     |
| `⇧⌘S`             | Save As… — choose location & close                   |
| `⌘T`              | Copy text / QR (OCR) — then drag over text or a code |
| `⌘P`              | Pin to screen & close                                |
| `↵`               | Apply a pending crop                                 |
| `⌫` / `⌦`         | Delete the selected mark, or a just-drawn shape/arrow |
| `Esc`             | Cancel & close                                       |
| `P` `H` `V` `T` … | Select a tool — single key (see tables above)        |

> Single-key tool shortcuts are ignored while typing into a text annotation.

---

## Settings

Open **Settings** from the menu. Options are grouped into **General**,
**Shortcuts**, **Capture**, **Output** and **Video**. Info dots (ⓘ) next to the less
obvious rows explain what they do.

<p align="center">
  <img src="docs/assets/settings.png" alt="The dark, brand-styled Settings panel with the General, Shortcuts, Capture and Output groups" height="480">
  <br>
  <em>The Settings panel — General, Shortcuts, Capture and Output groups.</em>
</p>

- **General** — launch at login; capture delay (with menu-bar countdown);
  after-capture behavior (open editor / save to file / copy to clipboard).
- **Shortcuts** — rebind the **Screenshot**, **Record**, **Quick Screen** and
  **Force Quit** hotkeys (click a field, press the new combination).
- **Capture** — include the mouse cursor; play the shutter sound (off by default);
  confirm before discarding an unsaved capture.
- **Output** — save location; filename prefix (default `m_capture_`); image format
  (PNG / JPEG / HEIC / TIFF); background padding and corner radius (Square →
  Large); default editor background; also copy to clipboard when saving.
- **Video** — recording quality and the audio source (system / microphone / both).

Settings persist across launches and apply to the editor's **Save**, the
pinned-window **Save**, and **Library**. Files are named
`<prefix><HH-mm-ss-dd-MM-yyyy>.<ext>`, uniquified with a `-1`, `-2`… suffix if a name
is already taken. If the save folder is missing or not writable, captures fall back to
the Desktop and a notice tells you where they went.

---

## Troubleshooting

`m_capture` needs **Screen Recording** permission (it captures in-process via
ScreenCaptureKit). Grant it under **System Settings → Privacy & Security → Screen
Recording**, then relaunch. Hotkeys use Carbon and need no extra permission.

| Symptom                               | Fix                                                                                                                                                                                                                                                                            |
|---------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Capture is blank / fails              | Grant **Screen Recording**, then relaunch (see above).                                                                                                                                                                                                                         |
| Hotkeys do nothing                    | Another app may own them, or `m_capture` isn't running — relaunch it.                                                                                                                                                                                                          |
| "App can't be opened" on first launch | Not notarized. Install to `~/Applications`, then run `cd ~/Applications && xattr -dr com.apple.quarantine m_capture.app` before opening.                                                                                                                                       |
| No menu-bar icon                      | The menu bar may be hidden (notch / menu-bar hider) — click the **m.** Dock icon to drop the menu; if there's no Dock icon either, the app isn't running, so launch `m_capture.app` again.                                                                                       |
| Can't find a saved screenshot         | Use **Library** to open the save folder.                                                                                                                                                                                                                                       |
