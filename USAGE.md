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

Click the **m.** menu-bar icon to open the menu. **Screenshot** and **Record**
also have global hotkeys (`⌃⇧S` / `⌃⇧R`) that fire directly, without opening the menu.

<p align="center">
  <img src="docs/assets/menu.png" alt="The m_capture menu-bar dropdown with Screenshot, Record, Library, Settings, About and Quit" height="300">
  <br>
  <em>The branded menu-bar dropdown.</em>
</p>

| Menu item             | Hotkey | What it does                                                                                                                    |
|-----------------------|:------:|---------------------------------------------------------------------------------------------------------------------------------|
| **Screenshot**        | `⌃⇧S`  | Dim the screen; drag a region, or press **Space** to pick a window or the whole screen; open the editor.                        |
| **Record**            | `⌃⇧R`  | Dim the screen; pick a region, a window, or the whole screen; record it in-app to an MP4.                                       |
| **Library**           |   —    | Open the save folder in Finder.                                                                                                 |
| **Settings**          |   —    | Shortcuts, capture delay, save location, format, backgrounds, more.                                                             |
| **About**             |   —    | Show the About panel (version + license).                                                                                       |
| **Check for Updates** |   —    | Check GitHub Releases for a newer version.                                                                                      |
| **Report a Bug**      |   —    | Open a [pre-filled GitHub issue](https://github.com/tuyen-nguyen-mesoneer/m_capture/issues/new) (app + macOS version attached). |
| **Quit**              |   —    | Quit `m_capture`.                                                                                                               |

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

1. Press `⌃⇧R`. The screen dims — the same overlay as a screenshot, with a video
   glyph on the cursor in Window/Screen mode so it's clear you're about to record,
   not just capture a still.
2. Choose what to record: **drag** a region, or press **Space** to cycle to
   **Window** (hover a window to tint it, release the mouse over it to record just
   that window) or **Screen** (the display is tinted; click to record it whole). All
   three work on any connected display.
3. Recording starts with a floating bar showing a live timer, the estimated file
   size, and a quality badge, plus **pause/resume** and **stop** — drag anywhere on
   the bar's background to move it out of the way (the cursor shows an open hand).
4. **Stop** finalises the `.mp4` (HEVC video, optional AAC audio) into your save
   folder and reveals it in Finder.

Quality and the audio source (system, microphone, or both) live in
**Settings → Capture**.

---

## The annotation editor

The editor frames your image on a dark backdrop with tools in **clusters**
(Markup, Shapes, Color, Actions, Background). For small or very large selections,
the clusters gather into one draggable panel so they never cover the image.

### Tools

**Markup** — draw, redact, label and stamp.

| Tool           | Key  | Description                                                                            |
|----------------|:----:|----------------------------------------------------------------------------------------|
| Pencil         | `P`  | Freehand thin stroke.                                                                  |
| Highlighter    | `H`  | Thick, translucent marker.                                                             |
| Eraser         | `E`  | Remove the annotation under the click.                                                 |
| Text           | `T`  | Click to place a label and type inline.                                                |
| Blur           | `B`  | Soften a region (redact sensitive content).                                            |
| Spotlight      | `S`  | Dim everything outside a rectangle.                                                    |
| Counter        | `C`  | Auto-incrementing badge — numbers, letters or Roman.                                   |
| Emoji          |  —   | Stamp an emoji (click the tile to choose).                                             |
| Zoom           | `Z`  | Magnify a region into a callout bubble.                                                |
| Ruler          |  —   | Measure: press `↑↓`/`←→`, move to size it, click to imprint.                           |
| Overlay image  |  —   | Add an image — paste (`⌘V`), drop a file, or click to choose (with an opacity slider). |
| Copy text / QR | `⌘T` | OCR — drag over text or a QR code to recognize & copy it.                              |

**Shapes** — drag to draw; all hollow outlines.

| Tool              | Key | Tool      | Key |
|-------------------|:---:|-----------|:---:|
| Arrow             | `A` | Star      | `Y` |
| Line              | `L` | Pentagon  | `5` |
| Rectangle         | `R` | Hexagon   | `6` |
| Ellipse           | `O` | Octagon   | `8` |
| Rounded rectangle | `U` | Checkmark | `K` |
| Triangle          | `G` | Diamond   | `D` |

### Transform & actions

- **Select / move** (`V`) — click any placed mark to select it, then **drag** to reposition, **drag the corner knob** to resize (shapes, text, emoji, counters, blur, spotlight, overlays, zoom callouts), or press `⌫` to delete it. Lines, arrows, freehand strokes and the ruler are move-only. Lets you reposition or remove a mark without undoing and redrawing it.
- **Crop** — drag a region, then `↵` (or **✓**) to apply.
- **Rotate** — 90° right (clockwise).
- **Flip horizontal** — mirror the image left↔right.
- **Resize the capture** — drag the bottom-right knob to resample the whole image (aspect-locked); export comes out at the new size.
- **Pin to screen** (`⌘P`) — float the capture always-on-top across Spaces. Drag to move, corner-drag to scale, right-click for **Copy / Save / Reset size / Close** (`Esc` / `⌘W` close). Pin several at once.
- **Before/After GIF** — export a two-frame looping GIF that toggles the annotations on and off, useful for highlighting before-and-after differences.
- **Undo / Redo / Copy / Save / Save As / Cancel** — see the shortcut table below.

### Colors

- **Palette:** red, orange, yellow, green, teal, blue, purple, pink, white,
  black, plus **+** for a custom color (hue strip + brightness square).
- **Eyedropper** (`I`) — sample a color from the screenshot to match it.

Stroke width is fixed at a medium weight.

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
| `⌫` / `⌦`         | Delete the selected mark (Select tool)               |
| `Esc`             | Cancel & close                                       |
| `P` `H` `V` `T` … | Select a tool — single key (see tables above)        |

> Single-key tool shortcuts are ignored while typing into a text annotation.

---

## Settings

Open **Settings** from the menu. Options are grouped into **General**,
**Shortcuts**, **Capture** and **Output**.

<p align="center">
  <img src="docs/assets/settings.png" alt="The dark, brand-styled Settings panel with the General, Shortcuts, Capture and Output groups" height="480">
  <br>
  <em>The Settings panel — General, Shortcuts, Capture and Output groups.</em>
</p>

- **General** — launch at login; capture delay (with menu-bar countdown);
  after-capture behavior (open editor / save to file / copy to clipboard).
- **Shortcuts** — rebind the **Screenshot** and **Record** hotkeys (click a
  field, press the new combination).
- **Capture** — include the mouse cursor; play the shutter sound (off by default).
- **Output** — save location; filename prefix (default `m_capture_`); image format
  (PNG / JPEG / HEIC / TIFF); background padding and corner radius (Square →
  Large); default editor background; also copy to clipboard when saving.

Settings persist across launches and apply to the editor's **Save**, the
pinned-window **Save**, and **Library**. Files are named
`<prefix><HH-mm-ss-dd-MM-yyyy>.<ext>`.

---

## Troubleshooting

`m_capture` needs **Screen Recording** permission (it uses `screencapture`). Grant it
under **System Settings → Privacy & Security → Screen Recording**, then relaunch.
Hotkeys use Carbon and need no extra permission.

| Symptom                               | Fix                                                                                                                                                                                                                                                                            |
|---------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Capture is blank / fails              | Grant **Screen Recording**, then relaunch (see above).                                                                                                                                                                                                                         |
| Hotkeys do nothing                    | Another app may own them, or `m_capture` isn't running — relaunch it.                                                                                                                                                                                                          |
| "App can't be opened" on first launch | Not notarized. Install to `~/Applications`, then run `cd ~/Applications && xattr -dr com.apple.quarantine m_capture.app` before opening.                                                                                                                                       |
| No menu-bar icon                      | The app isn't running; launch `m_capture.app` again (no Dock icon).                                                                                                                                                                                                            |
| Can't find a saved screenshot         | Use **Library** to open the save folder.                                                                                                                                                                                                                                       |
