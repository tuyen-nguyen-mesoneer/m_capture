# m_capture

> A macOS menu-bar utility for screenshots and screen recording — capture a region,
> annotate it in place, and copy or save the result. Built in **Swift + AppKit** with
> **zero external dependencies**; all processing happens locally on your machine.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![language](https://img.shields.io/badge/Swift-5-orange)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![license](https://img.shields.io/badge/license-MIT-green)

Press a hotkey and drag to select a region; an **in-place annotation editor** opens
immediately, where you can highlight, blur, and add arrows or numbered steps before
copying the result to the clipboard or saving it to disk. The app runs in the menu
bar, with no Dock icon.

<p align="center">
  <img src="docs/assets/editor.png" alt="The in-place annotation editor — a captured image surrounded by grouped tool clusters" width="760">
  <br>
  <em>Capture a region, then annotate it in place — highlight, arrow, blur, numbered steps, and more.</em>
</p>

## Features

A complete screenshot workflow — capture, annotate, and share — that runs entirely
on-device, with no subscriptions, cloud services, or accounts.

**📸 Capture**
- **Global hotkeys** — `⌃⇧S` for a screenshot, `⌃⇧R` to record, `⌃⇧Q` for Quick Screen; all fully rebindable.
- **Region, window, or full screen** — drag to select a region, or press **Space** to grab a whole window (hover to wash it in a tint, release the mouse over it to capture) or the entire screen in a single click. Fully multi-monitor aware — every mode works on any connected display.
- **Quick Screen** (`⌃⇧Q`) — grabs the screen under your cursor the instant you press the hotkey, with no selection overlay in between — for a hover state, tooltip, or menu that would vanish once you start dragging a selection.
- **Self-timer** — a 3, 5, or 10-second delay with a menu-bar countdown, plus an optional mouse cursor and shutter sound.
- **Recording** — record a region, a single window, or the whole screen in-app to an MP4 (HEVC), with a floating, draggable bar (live timer, size, quality, pause/stop); optionally mixes in system and/or microphone audio. **Esc discards** the take; **Return** saves it.
- **Menu-bar recording controls** — the menu-bar icon turns into a **red dot with a live timer** while recording (grey when paused), so it's clear even at a glance. **Minimize** the floating bar and drive Pause / Resume / Stop straight from the **m.** menu.
- **Configurable after-capture action** — open the editor, save directly to disk, or copy to the clipboard.
- **Never lose a capture** — quitting mid-recording still finalizes a playable file; if a save folder is missing the capture falls back to the Desktop (and tells you); same-second captures never overwrite.
- **First-run welcome** — a one-time welcome points out the menu-bar icon and hotkeys and, with your consent, grants Screen Recording. **Launch at login** is a toggle in Settings.

**✏️ Annotate & edit** — an in-place editor in which every tool is a single keystroke, with full undo and redo.
- **Draw** — pencil, highlighter, and eraser.
- **Shapes** — arrows (with bendable curves), lines, rectangles, ellipses, triangles, diamonds, stars, polygons (pentagon, hexagon, octagon), rounded rectangles, and checkmarks.
- **Text & counters** — inline text labels, auto-incrementing badges (numbers, letters, or Roman numerals), and emoji stamps.
- **Focus & redaction** — **blur** to obscure sensitive information, **spotlight** to dim the surroundings, and **zoom** callouts to magnify detail.
- **Measure & compose** — an on-screen **ruler**, image overlays, and an **eyedropper** for color matching.
- **Style** — a preset color palette with a custom hue/brightness picker, plus a stroke-width control (thin / medium / thick).
- **Select & edit** — every placed mark stays editable: with the **Select** tool (`V`) — or right after you draw it — drag it to reposition, resize shapes from **any of eight handles** (four corners plus four edges, so you can stretch one side), reshape arrows and lines by their **endpoints or bend handle**, or press **⌫** to delete.
- **Transform** — crop, rotate, flip, and aspect-locked resize, all baked into the export.

**🚀 Share**
- **Copy text / QR (OCR)** — extract text or decode a QR code from any capture, on-device via Apple Vision.
- **Pin to screen** — keep a capture floating above other windows, across Spaces.
- **Share-ready backgrounds** — padding, rounded corners, and a soft shadow over 10 solid or gradient presets, or a custom color.
- **Before/After GIF** — export a looping GIF that toggles the annotations on and off.
- **Flexible output** — copy to the clipboard, save as PNG, JPEG, HEIC, or TIFF to a configurable folder, or use **Save As…** to choose a location.

📖 Full reference: **[`USAGE.md`](USAGE.md)**.

## Install

1. Download the latest **`m_capture.dmg`** from [**Releases**](https://github.com/tuyen-nguyen-mesoneer/m_capture/releases) and open it.
2. **Drag m_capture into your home Applications folder** (`~/Applications`). Because the
   app isn't notarized, macOS would block it on first launch — open **Terminal** and clear
   the download quarantine:

   ```sh
   cd ~/Applications && xattr -dr com.apple.quarantine m_capture.app
   ```
3. **Double-click m_capture** to launch it — the menu-bar **m.** icon appears, and you can
   eject the disk image.
4. Grant **Screen Recording** permission when prompted (see [Permissions](#permissions)).

To build it yourself instead, see [Build from source](#build-from-source).

## Updates & feedback

**m_capture** checks GitHub Releases for newer builds — silently once a day, and on
demand via **Check for Updates** in the menu. A newer version downloads and installs
itself in place; it runs the next time you launch (**Check for Updates** offers to
relaunch right away). Living in `~/Applications` means updates apply without admin
prompts and your Screen Recording permission carries over.

To report an issue, use **Report a Bug** in the menu — it opens a
[pre-filled GitHub issue](https://github.com/tuyen-nguyen-mesoneer/m_capture/issues/new)
with your app and macOS versions already attached, so reports arrive with the
essential details in place.

## Permissions

**m_capture** requires **Screen Recording** permission, as it captures the screen
in-process via **ScreenCaptureKit**. The first-run welcome can grant it up front;
otherwise macOS prompts on your first capture. Grant it under **System Settings →
Privacy & Security → Screen Recording**, then relaunch the app (a capture attempted
without the grant shows guidance instead of failing silently). **A blank capture is
almost always caused by a missing grant.** Recording the microphone additionally asks
for **Microphone** permission; declining just drops the mic track. Global hotkeys use
Carbon and require no additional permission.

## Build from source

`./build.sh` builds the app into `build/m_capture.app` and writes `m_capture.dmg`
to the repository root; it requires only the Xcode Command Line Tools. See
**[`CONTRIBUTING.md`](CONTRIBUTING.md)** for prerequisites, the faster development
loop, and the source map.

## License

**MIT License** — © 2026 [mesoneer AG](https://www.mesoneer.io/?r=0). See **[`LICENSE`](LICENSE)** for the full text.

<p align="center">
  <img src="docs/assets/about.png" alt="The m_capture About panel — the m. logo, app name, version, and an MIT License · © 2026 mesoneer AG footer" height="220">
</p>
