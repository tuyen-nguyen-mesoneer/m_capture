# Brownfield notes — where each capability lands

Verified against `trunk` @ `c4203ef` (2026-10-11). Line numbers drift; the symbols are the anchor.

| CAP | Existing code | State today |
|---|---|---|
| CAP-1 | `ScreenshotController.finish` — flips overlay `viewRect` (bottom-left) into SC `sourceRect` (top-left, per-display) via `screen.frame.height - viewRect.maxY`; pixel size = `sourceRect ×` the capture's own scale — the frozen still's pixels per point (`cg.width / CGDisplayBounds.width`), or `filter.pointPixelScale` on the live path; not `backingScaleFactor`. The display layout enters only through the global rect (`screen.frame` origin + `viewRect`) and `WindowList.appKitRect` / `cgPoint` (primary display height). | Math is inline in the controller; untested. `CLAUDE.md`'s multi-monitor gotcha still says `backingScaleFactor`. Multi-monitor fixed in #22, #38, #53, #54. |
| CAP-2 | `EditorWindow` gap model: `measureGaps`, `gutterBand`, `rowOutside`, `insetScale`, `magnification`, `gatherOffsets`. | Invariants were verified once by an ad hoc simulation (1764 shapes × 9 screens); nothing reruns it. `gutterBand` and `rowOutside`'s edges must change together. |
| CAP-3 | `.github/workflows/release.yml` — triggers on version tags and `workflow_dispatch` only. A plain `./build.sh` hard-fails without the `m_capture-release` identity (`RELEASE_CERT_SHA` guard); only `--run` falls back to ad-hoc, and it also quits and relaunches the app. | No PR build, and no build mode a CI runner can use; the macOS 15 SDK break surfaced only at release (#67). |
| CAP-4 | `print(` calls: 20 in `VideoRecordSession`, 6 in `RecordZoomEngine`. Bundle id `io.mesoneer.mcapture`. | Logs go to stdout and are lost for a launched app. |
| CAP-5 | `SelectionView.keyDown` (`SelectionOverlay.swift`) handles Esc (53), Space (49) and `Settings.shared.lastRegionKey`. Region commits on `mouseUp`; Screen commits on press. `OverlayKey` models overlay-owned rebindable keys. Hints are `%@` templates rendered as keycaps (`KeyHint`). | No action keys. |
| CAP-6 | Same `mouseUp` commit path; no `modifierFlags` checks in `SelectionOverlay` / `ScreenshotController`. | — |
| CAP-7 | `CaptureBehavior` (`Settings.swift`): `editor`, `save`, `copy`. Routed in `ScreenshotController.deliver`. History cells are already drag sources. | No thumbnail behaviour. |
| CAP-8 | `EditorWindowController` + `CanvasView` own annotations and undo; `CaptureSource` holds the still and visible rect. | State is discarded on close. |
| CAP-9 | `BlurAnnotation` (`Annotations.swift`) + `CanvasView.gaussianBlur` (`CIGaussianBlur`, edge-clamped). `Tool` enum in `CanvasView`. | Gaussian blur only. |
| CAP-10 | `TextRecognizer.recognize(_:completion:)` (Vision, off-main, returns on main); called only from the editor's `.ocr` tool (`EditorWindow`). | OCR runs on demand, per region; results are not kept. |
| CAP-11 | The editor-free exits: `ScreenshotController.deliver`'s `save` / `copy` cases, plus the new CAP-5/6/7 paths (checked before the thumbnail or pin window appears). `TextRecognizer` is async, so the check must finish before `copyToPasteboard` / `saveToDisk`. | Nothing inspects a capture before it leaves. |

## Leak paths relevant to redaction

- Editor behaviour: nothing is copied or saved before the editor; `autoCopyOnSave` applies on save.
- `save` / `copy` behaviours (`deliver`) write the unredacted capture immediately — and so will CAP-5/6/7.
