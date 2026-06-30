# m_capture — Knowledge Graph

> **For agents and the leader.** Navigate to the section you need; every claim traces back to the Swift source.  
> Scanned: 23 files · Sources/ only (tools/ excluded).  
> Generated: 2026-06-26

---

## Table of Contents

1. [How to Use This Document](#how-to-use-this-document)
2. [File Catalogue](#file-catalogue)
3. [Dependency Matrix](#dependency-matrix)
4. [Framework Map](#framework-map)
5. [Type Catalogue](#type-catalogue)
6. [Controller Hierarchy](#controller-hierarchy)
7. [Singleton & Self-Retaining Registry](#singleton--self-retaining-registry)
8. [Data Flows](#data-flows)
9. [Call Graph](#call-graph)
10. [Async & Callback Boundaries](#async--callback-boundaries)
11. [Extension Points for New Features](#extension-points-for-new-features)
12. [Known Quirks & Gotchas](#known-quirks--gotchas)

---

## How to Use This Document

- **Starting a new feature?** → Read §11 (Extension Points) first, then §8/§9 for the relevant flow.
- **Debugging a crash?** → §9 (Call Graph) + §10 (Async Boundaries) locate where control jumps threads.
- **Adding a type?** → §5 (Type Catalogue) shows what already exists; §3 (Dependency Matrix) shows where to attach it.
- **Agent planning tasks?** → §8 (Data Flows) gives the four canonical end-to-end flows; each step names exact methods.

---

## File Catalogue

All 23 production Swift files in `Sources/`. Sorted by category.

### Entry Point
| File | Types Defined | Role |
|------|---------------|------|
| `main.swift` | — | Sets `AppDelegate` as `NSApp.delegate`; starts the run loop |

### App Orchestration
| File | Types Defined | Role |
|------|---------------|------|
| `AppDelegate.swift` | `AppDelegate` | Status item, menu, global hotkeys, action dispatch |
| `Settings.swift` | `Settings`, `ImageFormat`, `CaptureDelay`, `CaptureBehavior`, `Shortcut`, `ShortcutAction`, `PaddingSize`, `VideoQuality`, `VideoAudioSource` | All persisted preferences (UserDefaults) |
| `HotKey.swift` | `HotKey` | Carbon global hotkey registration/unregistration |

### Capture Layer
| File | Types Defined | Role |
|------|---------------|------|
| `ScreenshotController.swift` | `ScreenshotController` | Region/window screenshot: overlay → subprocess → editor |
| `SelectionOverlay.swift` | `OverlayWindow`, `SelectionView`, `WindowInfo` | Dim selection overlay; region, window-capture, and full-screen modes; loupe. `allowsFullScreenMode` flag opts video recording into the full-screen mode. |
| `VideoRecordSession.swift` | `VideoRecordSession`, `RecordError` | HEVC recording engine: SCStream capture → AVAssetWriter → `.mp4`; pause/resume, PTS normalisation (macOS 14+) |
| `VideoRecordBar.swift` | `VideoRecordBar` | Floating brand-styled HUD: timer, file-size readout, pause/stop buttons, pulse animation |
| `VideoRecordController.swift` | `VideoRecordController` | Singleton orchestrator: selection overlay → mic permission → session lifecycle → 1 Hz UI tick |

### Editor Layer
| File | Types Defined | Role |
|------|---------------|------|
| `EditorWindow.swift` | `EditorWindowController`, `KeyableWindow`†, `DraggablePanel`†, `BackgroundView`†, `ResizeHandle`† | In-place annotation editor; tool clusters; save/copy/pin |
| `CanvasView.swift` | `CanvasView`, `Tool` | Drawing surface; annotation lifecycle; undo/redo; crop/rotate |
| `Annotations.swift` | `Annotation` (protocol), `DrawStyle`, 18 concrete annotation classes, `CounterFormat` | Annotation model — every drawable shape/text/effect |
| `Background.swift` | `Background` | Share-ready background presets; `compose()` bakes final image |
| `TextRecognizer.swift` | `TextRecognizer` | Stateless Vision OCR helper |

### UI Components
| File | Types Defined | Role |
|------|---------------|------|
| `ToolButton.swift` | `ToolButton`, `ToolButton.Style` | Custom-drawn editor tool tile |
| `ColorPicker.swift` | `ColorPickerPanel`, `KeyablePickerWindow`, private views | Brand-styled hue + saturation picker |
| `EmojiPicker.swift` | `EmojiPickerPanel`, private views | Preset emoji grid picker |
| `CounterFormatPicker.swift` | `CounterFormatPicker`, private views | Counter-format selector (Number/Letter/Roman) |
| `PinnedWindow.swift` | `PinnedWindowController`, `PinWindow`†, `PinView`† | Always-on-top floating capture; drag/resize/right-click menu |
| `BrandMenu.swift` | `BrandMenu`, `MenuEntry`, private views | Custom themed NSMenu replacement |
| `BrandPopUpButton.swift` | `BrandPopUpButton`, `BrandControl`, `BrandPopUpList`, private views | Custom themed NSPopUpButton |

### Styling & Branding
| File | Types Defined | Role |
|------|---------------|------|
| `Theme.swift` | `Theme` | Single source of all colors, fonts, gradients |
| `Logo.swift` | `Logo` | "m." glyph renderer (NSImage) |
| `AboutWindow.swift` | `AboutWindowController` | About panel |
| `SettingsWindow.swift` | `SettingsWindowController`, `SectionHeader`†, `BrandTextField`†, `BrandTextFieldCell`† | Dark Settings panel |
| `ShortcutRecorder.swift` | `HotKeyField`, `extension Shortcut` | Click-to-record shortcut field + display-string formatting |

† = private type, internal to that file.

---

## Dependency Matrix

Who depends on whom. Higher = more central.

| Rank | File | Depended on by | Key dependents |
|------|------|---------------|----------------|
| 1 | **Theme.swift** | 17 files | Every UI file |
| 2 | **Settings.swift** | 8 files | AppDelegate, Background, EditorWindow, HotKey, PinnedWindow, ScreenshotController, SettingsWindow, ShortcutRecorder |
| 3 | **Annotations.swift** | 3 files | CanvasView (all types), CounterFormatPicker (CounterFormat), EditorWindow (DrawStyle, CounterFormat) |
| 4 | **Background.swift** | 3 files | EditorWindow, PinnedWindow, SettingsWindow |
| 5 | **ColorPicker.swift** | 3 files | CounterFormatPicker, EditorWindow, EmojiPicker (`KeyablePickerWindow`) |
| 6 | **Logo.swift** | 3 files | AboutWindow, AppDelegate, BrandMenu |
| 7 | **EditorWindow.swift** | 2 files | AppDelegate, ScreenshotController |
| 8 | **BrandMenu.swift** | 2 files | AppDelegate, PinnedWindow |
| 9 | **SelectionOverlay.swift** | 2 files | ScreenshotController, VideoRecordController |
| 10 | **BrandPopUpButton.swift** | 2 files | SettingsWindow, ShortcutRecorder |
| 11 | **VideoRecordController.swift** | AppDelegate | Settings, SelectionOverlay, VideoRecordSession, VideoRecordBar, AVFoundation |
| 12 | **VideoRecordSession.swift** | VideoRecordController | SCStream, AVAssetWriter, AVCaptureSession, Settings |
| 13 | **VideoRecordBar.swift** | VideoRecordController | Theme, BrandMenu |
| 14–23 | All others | 0–1 files | Leaves |

**Circular dependency:** `Settings.swift` ↔ `Background.swift` — Settings decodes `defaultBackground` to a `Background` case; Background reads `Settings.shared.paddingSize` in `compose()`. Both are singletons; no runtime cycle risk, but a refactor must touch both.

**Isolated leaves (safest to test/modify independently):**
- `TextRecognizer.swift` — stateless Vision wrapper, no project-type references.
- `Theme.swift` — no dependencies at all; changing it affects 17 files visually.

---

## Framework Map

| Framework | Used by |
|-----------|---------|
| **AppKit** | All 23 files |
| **Carbon.HIToolbox** | HotKey, Settings, ShortcutRecorder |
| **ScreenCaptureKit** | ScreenshotController, VideoRecordSession |
| **CoreImage** | CanvasView (CIPixellate for blur) |
| **Vision** | TextRecognizer |
| **ImageIO** | Settings (HEIC encoding via CGImageDestination) |
| **ServiceManagement** | Settings (launch-at-login via SMAppService) |
| **AVFoundation** | VideoRecordSession (AVAssetWriter, AVCaptureSession), Settings (VideoQuality bitrate) |

> **Note:** `CGDisplayCreateImage` / `CGWindowListCreateImage` are **removed** in macOS 15 SDK. All in-process pixel capture uses `SCScreenshotManager` (macOS 14+). The loupe in `ScreenshotController` uses this API.

---

## Type Catalogue

### Protocols
| Protocol | File | Conformers |
|----------|------|-----------|
| `Annotation` | Annotations.swift | 18 concrete classes (see below) |
| `NSApplicationDelegate` | (AppKit) | AppDelegate |
| `NSWindowDelegate` | (AppKit) | EditorWindowController, PinnedWindowController |
| `NSTextFieldDelegate` | (AppKit) | CanvasView |

### Enums (namespace / value types)
| Enum | File | Key Members |
|------|------|-------------|
| `Theme` | Theme.swift | Static colors, fonts, gradients — no cases |
| `Logo` | Logo.swift | `image(size:)`, `menuBarImage()` |
| `Background` | Background.swift | `none`, `solid(NSColor)`, 10 presets; `compose(_:)`, `presets` |
| `TextRecognizer` | TextRecognizer.swift | `recognize(_:completion:)` |
| `Tool` | CanvasView.swift | 21 cases: pencil, marker, line, arrow, rect, ellipse, triangle, diamond, star, roundedRect, checkmark, text, blur, counter, spotlight, eyedropper, eraser, crop, ocr, zoom, emoji |
| `CounterFormat` | Annotations.swift | `number`, `letter`, `roman` |
| `ImageFormat` | Settings.swift | `png`, `jpeg`, `heic`, `tiff`; `encode(_ rep:) -> Data?` |
| `CaptureDelay` | Settings.swift | `none(0)`, `three(3)`, `five(5)`, `ten(10)` |
| `CaptureBehavior` | Settings.swift | `editor`, `save`, `copy` |
| `ShortcutAction` | Settings.swift | `screenshot`, `record` |
| `VideoQuality` | Settings.swift | `low`, `medium`, `high`; `bitrate(for: CGSize) -> Int` |
| `VideoAudioSource` | Settings.swift | `none`, `system`, `mic`, `both`; `capturesSystemAudio`, `capturesMic` |
| `PaddingSize` | Settings.swift | `small`, `medium`, `large`; `scale: CGFloat` |
| `BrandControl` | BrandPopUpButton.swift | `textInset: CGFloat = 11` |
| `MenuEntry` | BrandMenu.swift | `header(String)`, `item(…)`, `separator` |
| `DrawStyle` | Annotations.swift | `color: NSColor`, `lineWidth: CGFloat` (struct, value type) |

### Singletons (classes)
| Class | File | Access |
|-------|------|--------|
| `Settings` | Settings.swift | `Settings.shared` |
| `ScreenshotController` | ScreenshotController.swift | `ScreenshotController.shared` |
| `SettingsWindowController` | SettingsWindow.swift | `SettingsWindowController.shared` |
| `AboutWindowController` | AboutWindow.swift | `AboutWindowController.shared` |
| `VideoRecordController` | VideoRecordController.swift | `VideoRecordController.shared` (macOS 14+) |

### Self-Retaining Pools (classes)
| Class | File | Pool |
|-------|------|------|
| `EditorWindowController` | EditorWindow.swift | `static var open: [EditorWindowController]` |
| `PinnedWindowController` | PinnedWindow.swift | `static var pinned: [PinnedWindowController]` |
| `HotKey` | HotKey.swift | `static var registry: [UInt32: HotKey]` |

### Core View/Controller Classes
| Class | File | Superclass | Key Responsibilities |
|-------|------|------------|----------------------|
| `AppDelegate` | AppDelegate.swift | NSObject | App lifecycle, menu, hotkey registration, action dispatch |
| `CanvasView` | CanvasView.swift | NSView | Drawing, annotation CRUD, undo/redo, crop/rotate, OCR trigger |
| `SelectionView` | SelectionOverlay.swift | NSView | Mouse-driven region selection, window-capture mode, loupe |
| `OverlayWindow` | SelectionOverlay.swift | NSWindow | One full-screen borderless window per display |
| `BrandMenu` | BrandMenu.swift | NSObject | Custom themed drop-down (not NSMenu) |
| `HotKey` | HotKey.swift | — | Carbon hotkey wrapper; one per action |

### Annotation Class Hierarchy
```
Annotation (protocol)
├── FreehandAnnotation
│   ├── PencilAnnotation
│   └── MarkerAnnotation
├── TwoPointAnnotation
│   ├── LineAnnotation
│   ├── RectAnnotation
│   ├── EllipseAnnotation
│   ├── TriangleAnnotation
│   ├── DiamondAnnotation
│   ├── StarAnnotation
│   ├── RoundedRectAnnotation
│   ├── CheckmarkAnnotation
│   ├── BlurAnnotation          (stores patch: CGImage?)
│   └── SpotlightAnnotation     (stores fullSize: CGSize)
├── CurvedArrowAnnotation       (quadratic Bézier; draggable apex handle)
├── TextAnnotation
├── CounterAnnotation           (number/letter/roman badge)
├── EmojiAnnotation
└── ZoomAnnotation              (source rect + enlarged bubble + patch)
```

---

## Controller Hierarchy

```
NSApplication
└── AppDelegate  (NSApplicationDelegate)
    │
    ├── owns: BrandMenu              ← the menu-bar drop-down
    └── owns: [HotKey]               ← one per ShortcutAction
    │
    ├── dispatches → ScreenshotController.shared
    │     └── creates (transient): [OverlayWindow] ← one per NSScreen
    │           └── contentView: SelectionView
    │     └── calls → EditorWindowController (self-retained in open[])
    │           ├── owns: CanvasView
    │           ├── owns (transient): ColorPickerPanel
    │           ├── owns (transient): EmojiPickerPanel
    │           ├── owns (transient): CounterFormatPicker
    │           └── creates → PinnedWindowController (self-retained in pinned[])
    │
    ├── dispatches → SettingsWindowController.shared
    │     ├── owns: [HotKeyField]
    │     └── calls back → AppDelegate.reloadHotKeys()
    │
    ├── dispatches → VideoRecordController.shared  [macOS 14+]
    │     └── creates (transient): [OverlayWindow] (allowsWindowMode:false, allowsFullScreenMode:true)
    │     └── creates (transient): VideoRecordBar   ← floating HUD window
    │     └── creates (transient): VideoRecordSession
    │           ├── owns: SCStream         ← SCStreamOutput + SCStreamDelegate
    │           ├── owns: AVAssetWriter    ← confined to writeQueue
    │           └── owns (optional): AVCaptureSession  ← mic audio
    │
    └── dispatches → AboutWindowController.shared
```

---

## Singleton & Self-Retaining Registry

### Singletons
```swift
Settings.shared                    // UserDefaults-backed prefs
ScreenshotController.shared        // screenshot capture session
VideoRecordController.shared       // video recording session (macOS 14+)
SettingsWindowController.shared    // Settings panel
AboutWindowController.shared       // About panel
```

### Self-Retaining Pools
```swift
// Multiple editors can coexist (e.g. screenshot while one is still open)
EditorWindowController.open: [EditorWindowController]
// Adds self on init; removes on windowWillClose

// Multiple pins can coexist
PinnedWindowController.pinned: [PinnedWindowController]
// Same add-on-init / remove-on-close pattern

// Carbon hotkey registry; deinit unregisters
HotKey.registry: [UInt32: HotKey]
```

---

## Data Flows

### Flow 1 — Region / Window Screenshot

```
[User presses ⌃⇧X]
HotKey handler (Carbon thread)
  → DispatchQueue.main.async
    → AppDelegate.takeScreenshot()
      → [delay > 0] countdown(from:) via asyncAfter 1s ticks
      → ScreenshotController.shared.begin()
        → OverlayWindow × N screens (contentView: SelectionView)
        → captureScreenContent()  [async Task: SCShareableContent.current]
          → OverlayWindow.setWindowList([WindowInfo])

[User drags a region]
SelectionView.mouseUp
  → onComplete?(CGRect)  →  ScreenshotController.finish(viewRect:screen:)
    → dismiss()          [remove overlays]
    → asyncAfter +0.04s  [let overlay compositor clear]
      → Process("/usr/sbin/screencapture -R x,y,w,h /tmp/m_XXX.png")
      → terminationHandler (background thread)
        → DispatchQueue.main.async
          → NSImage(contentsOfFile: tmp)   →  NSImage
          → file deleted
          → ScreenshotController.deliver(NSImage, CGRect, NSScreen)
            → [.editor]  EditorWindowController.init(image:selectionRect:screen:)
            → [.save]    saveToDisk()  →  DispatchQueue.global.async { encode + write }
            → [.copy]    NSPasteboard.writeObjects([NSImage])

[User clicks a window (Space toggles to window mode)]
SelectionView.mouseUp → onWindowCapture?(WindowInfo)
  → ScreenshotController.finishWindow(info:screen:)
    → Process("screencapture -l <windowID> /tmp/…")
    → same terminationHandler path → deliver()
```

### Flow 2 — Annotation Lifecycle

```
[EditorWindowController opens]
EditorWindowController.init(image:selectionRect:screen:)
  → reads Settings.shared.defaultBackground → currentBackground: Background
  → CanvasView.init(image: NSImage)
  → buildClusters() → [ToolButton] arranged in cards
  → EditorWindowController.open.append(self)   [self-retain]

[User selects a tool]
ToolButton.action → EditorWindowController.selectTool(Tool)
  → canvas.tool = Tool
  → ToolButton.selectedState update

[User draws]
CanvasView.mouseDown → live = ConcreteAnnotation(start:style:)
CanvasView.mouseDragged → live.update(point)
CanvasView.mouseUp
  → [blur] b.patch = pixelate(rect) via CIPixellate
  → annotations.append(live); live = nil
  → onChange?()  →  EditorWindowController.canvasChanged()
    → needsDisplay

[Undo / Redo]
CanvasView.undo()  → annotations.popLast() → redoStack.append
CanvasView.redo()  → redoStack.popLast() → annotations.append

[Flatten for export]
EditorWindowController.exportRep() → NSBitmapImageRep?
  → canvas.flatten()
      → NSBitmapImageRep (full image resolution)
      → draw image at original size
      → for each annotation: a.draw(in: CGContext)
      → return NSBitmapImageRep
  → currentBackground.compose(inner)
      → bake background frame + shadow + rounded-rect at full res
      → return NSBitmapImageRep (or inner if .none)

[Save ⌘S]
EditorWindowController.savePressed()
  → exportRep()
  → [autoCopyOnSave] NSPasteboard.writeObjects([NSImage])
  → Settings.shared.fileURL()  →  URL
  → DispatchQueue.global.async { Settings.shared.encode(rep) → Data; data.write(to: url) }
  → close()   [immediate; write is async]

[Copy ⌘C]
EditorWindowController.copyPressed()
  → exportRep()
  → NSPasteboard.general.writeObjects([NSImage])
  → close()

[Pin ⌘P]
EditorWindowController.pinPressed()
  → exportRep()
  → PinnedWindowController.init(rep:screenRect:)  →  pinned[]
  → close()

[OCR]
EditorWindowController.copyTextPressed() → canvas.tool = .ocr
[User drags] → CanvasView.onOCR?(CGImage)
  → TextRecognizer.recognize(CGImage) { text in ... }
      [DispatchQueue.global.async → VNRecognizeTextRequest → main.async]
  → NSPasteboard.setString(text)
```

### Flow 3 — Settings Read / Write

```
WRITE (SettingsWindow UI → UserDefaults):

  SettingsWindowController UI control action
    → Settings.shared.<property> = value
      → UserDefaults.standard.set(rawValue, forKey: "key")   [synchronous]

  Special cases:
    launchAtLogin  →  SMAppService.mainApp.register/unregister()   [not UserDefaults]
    chooseLocation →  NSOpenPanel.beginSheetModal (async sheet)
    shortcut rebind (HotKeyField)
      → Settings.shared.setShortcut(_:for:)   [packs Int into UserDefaults]
      → (NSApp.delegate as? AppDelegate)?.reloadHotKeys()

READ (Settings.shared → callers, all synchronous computed properties):

  AppDelegate.takeScreenshot()        → captureDelay
  AppDelegate.buildMenu()             → shortcut(for:) × 2
  AppDelegate.reloadHotKeys()         → shortcut(for:) × 2
  ScreenshotController               → captureCursor, playSound, captureBehavior,
                                        fileURL(), encode(_:)
  EditorWindowController.init        → defaultBackground
  EditorWindowController.savePressed → autoCopyOnSave, fileURL(), encode(_:)
  Background.compose                 → paddingSize.scale
  AppDelegate.openLibrary            → saveDirectory
  SettingsWindowController.refresh() → all properties (UI population)

  NO NotificationCenter — all reads are poll-at-use-time.
```

### Flow 4 — Video Recording (macOS 14+)

```
[User presses ⌃⇧R]
HotKey handler (Carbon thread)
  → DispatchQueue.main.async
    → AppDelegate.record()
      → [macOS < 14] Process("open -b com.apple.screenshot.launcher")  [fallback]
      → [macOS 14+] VideoRecordController.shared.begin()
          → guard session == nil  [re-entrant press ignored]
          → NSApp.activate(ignoringOtherApps: true)
          → OverlayWindow × N screens
                (allowsWindowMode: false, allowsFullScreenMode: true)

[User drags region OR presses Space → full-screen → clicks]
SelectionView.mouseUp → onComplete?(CGRect)   [view-local rect; origin = .zero for full-screen]
  → VideoRecordController.onComplete
      → global = CGRect(screen.origin + rect.origin, rect.size)
      → dismissOverlays()
      → requestMicThenStart(region: global, screen: screen)
          → [audioSource.capturesMic]
              AVCaptureDevice.requestAccess(for: .audio) { granted in
                  main.async {
                      [denied + .both] → effective = .system + NSAlert
                      [denied + .mic]  → effective = .none  + NSAlert
                      → startRecording(region:screen:audioSource:)
                  }
              }
          → [else] startRecording(region:screen:audioSource:)

VideoRecordController.startRecording(region:screen:audioSource:)
  → VideoRecordBar.init(quality:); bar.show(near: screen)   ← shown FIRST so windowNumber exists
  → url = videoURL()                                          [timestamped .mp4 in saveDirectory]
  → VideoRecordSession.init(region:screen:quality:audioSource:outputURL:
                             excludedWindowIDs:[bar.windowNumber])
  → bar.onStop = { stopRecording() }
  → bar.onPauseResume = { togglePause() }
  → Task { try? await session.start() }
  → startTimer()   ← DispatchSourceTimer on .main, fires every 1 s

VideoRecordSession.start() [async throws]
  → SCShareableContent.current (await)
  → SCContentFilter(display:excludingWindows:)   [bar excluded by windowID]
  → SCStreamConfiguration
      pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  [YUV — required by HEVC]
      minimumFrameInterval = 1/30 s
      sourceRect = display-local top-left origin
  → AVAssetWriter(outputURL:fileType:.mp4)
  → AVAssetWriterInput(mediaType:.video)  [HEVC + BT.709 color props]
  → AVAssetWriterInput(mediaType:.audio)  [AAC 128 kbps — if audioSource != .none]
  → writer.startWriting(); writer.startSession(atSourceTime: .zero)
  → [audioSource.capturesMic] startMicCapture() → AVCaptureSession
  → SCStream(filter:configuration:delegate:self)
  → stream.addStreamOutput(self, type:.screen, sampleHandlerQueue: writeQueue)
  → stream.startCapture() (await)

[Per frame — SCStream callback, ~30 Hz]
SCStreamOutput.stream(_:didOutputSampleBuffer:of:)   [SCStream internal queue]
  → writeQueue.async {
      switch type:
        .screen → append(buffer, to: videoInput)
        .audio  → append(buffer, to: audioInput)
    }

VideoRecordSession.append(_:to:)   [on writeQueue]
  → rawPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
  → [first ever buffer] sessionStartPTS = rawPTS
  → [isPaused] return  (buffer discarded; sessionStartPTS captured even while paused)
  → [first post-resume buffer]
      gap = rawPTS - pauseStartRawPTS
      skippedPTSDuration += gap       ← removes pause interval from output timeline
  → totalSkip = sessionStartPTS + skippedPTSDuration
  → normalised = buffer.subtractingPresentationTimeStamp(totalSkip)
      ← CMSampleBufferCreateCopyWithNewTiming; first frame → PTS 0.000 s
  → input.append(normalised)          ← feeds HEVC encoder

[User clicks Pause on bar]
VideoRecordBar.onPauseResume → VideoRecordController.togglePause()
  → session.pause()
    → writeQueue.async { isPaused = true; pauseStartRawPTS = lastRawPTS }
  → bar.update(isPaused: true)   [via 1 Hz timer on next tick]

[User clicks Resume]
VideoRecordController.togglePause()
  → session.resume()
    → writeQueue.async { isPaused = false; pausedWallDuration += wallGap }
    [next buffer in append() computes gap and adds to skippedPTSDuration]

[User clicks Stop on bar  OR  presses Esc/↵ on bar window]
VideoRecordController.stopRecording()
  → updateTimer.cancel(); bar.close()
  → session = nil; bar = nil          ← nils BEFORE await so no dangling refs
  → Task { await session.stop()
      → stream.stopCapture() (await)
      → micSession?.stopRunning()
      → writeQueue.async {
          videoInput.markAsFinished(); audioInput.markAsFinished()
          writer.finishWriting { cont.resume() }   ← continuation blocks Task
        }
    }
  → MainActor.run {
      [playSound] NSSound(named:"Grab")?.play()
      NSWorkspace.shared.activateFileViewerSelecting([url])  ← Finder reveal
    }
```

**Key invariants:**
- Bar is shown BEFORE `VideoRecordSession` is created — its `windowNumber` must exist before `SCContentFilter` is built.
- All `AVAssetWriter` mutations are serialised on `writeQueue` (private serial `DispatchQueue`).
- SCStream delivers raw mach-time PTSs (~seconds since boot). `append()` normalises every buffer to zero-based time by subtracting `sessionStartPTS`. Without this, AVAssetWriter writes a 738-second empty edit-list preamble and QuickTime refuses to play the file. See `.claude/knowledge/scstream-avassetwriter-pts-normalization.md`.
- `startSession(atSourceTime: .zero)` must be called AFTER `startWriting()` and BEFORE any buffer is appended.


---

## Call Graph

### Hotkey → Screenshot
```
RegisterEventHotKey (Carbon, background)
  → DispatchQueue.main.async
    → AppDelegate.takeScreenshot()
      → [delay] countdown(from:) [asyncAfter 1s loop]
      → ScreenshotController.shared.begin()
        → OverlayWindow.init × N; makeKeyAndOrderFront
        → Task @MainActor: SCShareableContent.current (await)
          → OverlayWindow.setWindowList([WindowInfo])
      → [user selects]
        → SelectionView.mouseUp → onComplete?(CGRect)
          → ScreenshotController.finish(viewRect:screen:)
            → dismiss()
            → asyncAfter +0.04s
              → Process("screencapture -R …").run()
              → terminationHandler (background)
                → DispatchQueue.main.async
                  → NSImage(contentsOfFile:)
                  → deliver(NSImage, CGRect, NSScreen)
                    → EditorWindowController.init OR saveToDisk OR pasteboard
```

### CanvasView — Tool Dispatch
```
CanvasView.mouseDown(NSEvent)
  → imagePoint(event) → CGPoint (image-space)
  → switch tool:
      .pencil/.marker  → FreehandAnnotation.init; live = a
      .line            → LineAnnotation.init
      .arrow           → CurvedArrowAnnotation.init OR draggingArrowHandle = true
      .rect/.ellipse/… → ShapeAnnotation.init
      .blur            → BlurAnnotation.init
      .spotlight       → SpotlightAnnotation.init; a.fullSize = image.size
      .counter         → CounterAnnotation.init(center:label:color:radius:)
      .text            → beginTextEditing() → NSTextField in subview
      .eyedropper      → sample(p) → NSBitmapImageRep.colorAt → onColorPicked?(NSColor)
      .eraser          → annotations.remove; onChange?()
      .crop            → cropStart = p; onCropBegin?()
      .ocr             → ocrStart = p
      .zoom            → drag existing OR zoomStart = p
      .emoji           → EmojiAnnotation.init

CanvasView.mouseUp(NSEvent)
  → [crop] onCropReady?() → EditorWindowController.showCropConfirm()
  → [ocr]  onOCR?(CGImage) → TextRecognizer.recognize → NSPasteboard
  → [blur] b.patch = pixelate(b.rect) via CIPixellate
  → [general] annotations.append(live); onChange?()
```

### Editor Export
```
EditorWindowController.exportRep() → NSBitmapImageRep?
  → canvas.commitText()
  → canvas.flatten() → NSBitmapImageRep
      (draw image + all annotations at full pixel resolution)
  → currentBackground.compose(inner) → NSBitmapImageRep

savePressed:
  exportRep() → DispatchQueue.global { encode + data.write(url) }
  close()  [immediate]

copyPressed:
  exportRep() → NSPasteboard.writeObjects([NSImage])
  close()
```

### Settings Shortcut Rebind
```
HotKeyField (click) → recording mode
  → local NSEvent monitor captures keyDown
  → Shortcut(keyCode:modifiers:)
  → Settings.shared.setShortcut(_:for:)  [UserDefaults write]
  → onChange?()
    → (NSApp.delegate as? AppDelegate)?.reloadHotKeys()
      → HotKey array rebuilt with new Shortcut values
        → Carbon.UnregisterEventHotKey (old)
        → Carbon.RegisterEventHotKey  (new)
```

---

## Async & Callback Boundaries

| Location | Mechanism | Thread flow |
|----------|-----------|-------------|
| HotKey carbon handler | `DispatchQueue.main.async` | Carbon thread → main |
| AppDelegate.countdown | `DispatchQueue.main.asyncAfter` | main → main (1s loop) |
| ScreenshotController.finish (overlay clear) | `asyncAfter +0.04s` | main → main |
| `screencapture` subprocess | `Process.terminationHandler` + `main.async` | background → main |
| ScreenshotController.saveToDisk | `DispatchQueue.global.async` | main → global |
| SCShareableContent.current | `Task @MainActor` + `await` | main (async) |
| TextRecognizer.recognize | `DispatchQueue.global.async` + `main.async` | global → main |
| EditorWindowController.savePressed | `DispatchQueue.global.async` | main → global |
| PinnedWindowController.saveToDisk | `DispatchQueue.global.async` | main → global |
| NSOpenPanel.beginSheetModal | async sheet modal | main → user → main |

**Rule of thumb:** All UI mutations are on main. Encoding and Vision are always off-main.

---

## Extension Points for New Features

### Adding a New Capture Action (e.g., "Timed burst", "GIF capture")

1. Add a case to `ShortcutAction` in `Settings.swift` (with `defaultShortcut` and `defaultsKey`).
2. Add a menu entry in `AppDelegate.buildMenu()`.
3. Add a `HotKey` in `AppDelegate.reloadHotKeys()`.
4. Implement the action method on `AppDelegate`.
5. Implement the capture controller (follow `ScreenshotController` pattern: begin/dismiss/deliver).
6. Settings, hotkey rebinding, and the Shortcuts panel all pick it up automatically.

### Adding a New Annotation Tool

1. Add a case to the `Tool` enum in `CanvasView.swift`.
2. Create a concrete `Annotation` class in `Annotations.swift` (implement `draw(in:)`, `hit(_:)`, `remap(_:)`).
3. Handle the new case in `CanvasView.mouseDown`, `mouseDragged`, `mouseUp`.
4. Add a `ToolButton` in `EditorWindowController.buildClusters()`.
5. `flatten()`, undo/redo, crop remap, and the save path all work without changes.

### Adding a New Image Format

1. Add a case to `ImageFormat` in `Settings.swift`.
2. Implement `encode(_ rep: NSBitmapImageRep) -> Data?` for that case.
3. Add a display label.
4. `SettingsWindow`'s format popup and `Settings.encode()` iterate `ImageFormat.allCases` — no other changes.

### Adding a New Background Preset

1. Add a case to the `Background` enum in `Background.swift`.
2. Add it to `presets`, implement `swatch` (NSColor), `fill(_:in:)`, and `name`.
3. The editor's background cluster and the Settings default-background popup both iterate `Background.presets`.

### Post-Save Hook / Share / Upload

- **After every capture (including window mode):** inject in `ScreenshotController.deliver(_:selectionRect:screen:)` — this is the single funnel for all capture paths. You have `NSImage`, `CGRect`, `NSScreen` in scope.
- **After editor save only:** inject after `data.write(to: url)` inside the `DispatchQueue.global.async` block in `EditorWindowController.savePressed()`. You have `Data` and `URL` in scope.

### Adding a New CaptureBehavior

1. Add a case to `CaptureBehavior` in `Settings.swift`.
2. Handle it in `ScreenshotController.deliver(_:selectionRect:screen:)`.
3. The Settings popup iterates `CaptureBehavior.allCases`.

### Adding a New Post-Recording Action (Compress, Upload, Share)

Inject after `NSWorkspace.shared.activateFileViewerSelecting([url])` inside `VideoRecordController.stopRecording()`. You have `url: URL` (the final `.mp4`) in scope. The writer has already called `finishWriting`, so the file is fully flushed. Add a `CaptureBehavior`-style case to `Settings` if the action should be user-configurable.

### Replacing the HEVC Codec (e.g., ProRes, H.264)

1. Change `AVVideoCodecKey: AVVideoCodecType.hevc` to the target codec in `VideoRecordSession.start()`.
2. Update `AVVideoColorPropertiesKey` and `AVVideoCompressionPropertiesKey` to match the new codec's requirements.
3. Update `VideoQuality.bitrate(for:)` for the new bitrate profile.
4. If the new codec requires BGRA input instead of YUV, change `cfg.pixelFormat` in `SCStreamConfiguration` — but do NOT use BGRA with HEVC (hardware encoder rejects it).
5. `.mp4` container is compatible with H.264 and HEVC; ProRes typically uses `.mov` (`fileType: .mov` in `AVAssetWriter.init`).

### Adding a PinnedWindow Context Menu Item

In `PinView.rightMouseDown()`, add a `.item(…)` entry to the `BrandMenu` entries array and implement the corresponding method on `PinnedWindowController`.

---

## Known Quirks & Gotchas


### SCStream PTS Normalisation (video recording)

SCStream delivers `CMSampleBuffer` frames with **absolute mach-time PTSs** (~seconds since last boot, e.g. 738 s). If written raw into an `.mp4`, AVAssetWriter produces an edit list with a 738-second empty preamble and QuickTime refuses to play the file.

**Fix:** call `writer.startSession(atSourceTime: .zero)` and subtract `sessionStartPTS` (first buffer's raw PTS) from every buffer's PTS before calling `input.append(_:)`. Both `CMSampleBufferCreateCopyWithNewTiming` and `AVAssetWriter` handle the resulting slightly-negative DTS from HEVC B-frames correctly.

**`CMSampleBufferGetSampleTimingInfoArray` count-query:** when called with `entryCount: 0, arrayToFill: nil`, some CoreMedia builds return `kCMSampleBufferError_ArrayTooSmall` instead of `noErr`. Do NOT check the return value on the count-query call; only validate `count > 0`.

Full diagnosis and code sample: `.claude/knowledge/scstream-avassetwriter-pts-normalization.md`.

### Coordinate Systems (critical — two different conventions)
- **`screencapture -R` uses primary-screen-height flip:** `y = primaryHeight - frame.maxY`. This lives in `ScreenshotController.finish()`. Do not copy this math elsewhere.
- **SCK `sourceRect` uses display-local top-left origin:** `y = screen.frame.maxY - region.maxY`. This lives in `VideoRecordController / VideoRecordSession`. Completely different from the above.
- **`CanvasView` uses image-space coordinates** (full pixel resolution). The canvas only scales for display. All annotation geometry must be in image space.

### Screen Recording Permission & Code Signing
- Ad-hoc signing (`codesign -s -`) treats each rebuild as a new identity → macOS may reset the Screen Recording grant.
- Workaround: create a `m_capture-dev` cert in Keychain Access; `build.sh` detects and uses it → stable identity → grant persists.
- `./build.sh --run` rebuilds + relaunches in place.

### `CGDisplayCreateImage` is Dead
`CGDisplayCreateImage` / `CGWindowListCreateImage` are hard compile errors in the macOS 15 SDK. All in-process pixel grabs must use `SCScreenshotManager.captureImage` (macOS 14+).

### Circular Dependency: Settings ↔ Background
`Settings.swift` decodes `defaultBackground` into a `Background` case. `Background.swift` reads `Settings.shared.paddingSize` in `compose()`. Refactoring either must touch both files and ensure no init-order issue (both are lazy singletons / static properties, so this is currently safe).

### `EditorWindowController` Is Not an NSWindowController
Despite its name, it subclasses `NSObject`, not `NSWindowController`. It manages its window directly and self-retains via the static `open` array. `windowWillClose` removes it.

### Save Is Asynchronous; Window Closes Immediately
`EditorWindowController.savePressed()` closes the window before the `DispatchQueue.global.async` write completes. The `Data` write can still fail silently after the window is gone. Any error handling must be inside the async block.

### Build Tool: `swiftc` Only, No Xcode / SPM
There is no `.xcodeproj` or `Package.swift`. Everything is compiled by `build.sh` with a direct `swiftc` invocation. All 23 `Sources/*.swift` files are compiled together in one pass. Adding a new file requires no project-file edit — just drop it in `Sources/`.
