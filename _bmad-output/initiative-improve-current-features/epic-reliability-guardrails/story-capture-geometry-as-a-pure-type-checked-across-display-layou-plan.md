---
title: 'Capture geometry as a pure type, checked across display layouts'
type: 'refactor'
ticket: '2'
created: '2026-10-11'
status: done
baseline_revision: '40d87640a5b8b2fe1de93c1ddf0bc45a8c1a2c44'
route: 'full'
route_source: 'auto'
risk: 'medium'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/epic-reliability-guardrails.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Multi-monitor capture broke four times (#22, #38, #53, #54), but only the display-local Y-flip is checked (1.1). The parts where the display *layout* enters — the global rect, pixel scaling and rounding, and the CoreGraphics↔AppKit global flips — are untested, so a regression there still ships.

**Approach:** Move the rest of the capture mapping into `CaptureGeometry` as pure functions taking explicit inputs (screen origin, scale, image size, primary display height), keep every caller's behaviour identical, and check them against mixed-density, negative-origin and vertically stacked layouts.

## Boundaries & Constraints

**Always:** pixel-identical captures (same arithmetic, same rounding — `.rounded()` half-away-from-zero — same clamping); `WindowList.appKitRect(fromCG:)` / `cgPoint(fromAppKitMouse:)` keep their signatures and delegate, so their six call sites in ScreenshotController, SelectionOverlay and VideoRecordController don't change; pure code stays in `Sources/Core/`, UI-free; checks follow 1.1's harness (`CheckSuite` subclass, `@objc func check…`, `expect`).
**Never:** touch `EditorWindow`/`CanvasView` (story 1.3) or logging (1.4); change `crop`'s callers or the live-grab path's behaviour; edit CLAUDE.md's source map or `Core/` entry (left to 1.5) beyond the two lines this story makes false.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mixed density | Primary 1440×900 @2x at (0,0); external 1920×1080 @1x at (1440,0); region (100,200,300,150) on each | Global rect offset by the screen origin; pixel rect = source rect × that display's scale (2 vs 1) | — |
| Negative origin | External 1920×1080 at (−1920,−180) left of and lower than primary | Global rect keeps negative x/y; CG→AppKit of a window on it lands inside that screen's AppKit frame | — |
| Vertically stacked | External 1920×1080 at (−240,900) above primary (CG y −1080) | CG window (100,−1000,400,300) → AppKit y 1600, inside the external screen; AppKit point ↔ CG point round-trips | — |
| Fractional rounding | Source rect with .5 edges at scale 2 and 1.5 | Rounded exactly as today (`.rounded()`) | — |
| Edge clamp | Source rect overhanging the image's right/bottom edge | Clamped to the image bounds | — |
| Off-image / sub-pixel | Source rect fully outside, or rounding to < 1 px | No crop rect (nil) — caller falls back as today | Returns nil |

</frozen-after-approval>

## Code Map

- `Sources/Core/CaptureGeometry.swift` -- from 1.1: `sourceRect(viewRect:displayHeight:)`. Grow it here.
- `Sources/ScreenshotController.swift:622-624` -- `finish`'s `global` = `screen.frame.origin + viewRect` (feeds `selectionRect` and the `≥ 3 pt` guard). `:451` -- `freeze`'s scale = `CGFloat(cg.width) / bounds.width`. `:522-532` -- `crop(_:to:scale:)`: rounds `sourceRect × scale` per edge with `.rounded()`, intersects with the image rect, rejects null / < 1 px, then `cg.cropping(to:)`. Keep `crop`'s signature and the `cropping` call; move only the rect math.
- `Sources/WindowList.swift:78-93` -- `primaryHeight` (reads `NSScreen.screens`, stays here), `appKitRect(fromCG:)`, `cgPoint(fromAppKitMouse:)`. Callers (unchanged): ScreenshotController 583, 701, 769; SelectionOverlay 455, 498; VideoRecordController 353, 363.
- `tests/CaptureGeometryChecks.swift` -- 1.1's three flip checks; add layout suites as new files (`tests/CaptureLayoutChecks.swift`) per the harness convention.
- `CLAUDE.md` -- Gotchas › "Multi-monitor coordinates" says pixel size is `viewRect × backingScaleFactor` and that `finish` holds the math; the `ScreenshotController.swift` source-map entry says "Multi-monitor coordinate math lives in `finish`". Both false after this story (and the first already was — epic Notes `Source conflict`, deferred item from 1.1's review).
- Sandbox: run swiftc with `CLANG_MODULE_CACHE_PATH="$TMPDIR/swift-mc"`.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/Core/CaptureGeometry.swift` -- add pure `globalRect(viewRect:screenOrigin:)`, `scale(pixelWidth:pointWidth:)`, `pixelRect(sourceRect:scale:imageSize:) -> CGRect?` (rounding + clamp + < 1 px rejection, exactly `crop`'s), `appKitRect(fromCG:primaryHeight:)`, `cgPoint(fromAppKit:primaryHeight:)`; one `///` each on the coordinate space it converts
- [x] `Sources/ScreenshotController.swift` -- `finish`'s `global`, `freeze`'s scale and `crop`'s rect math call `CaptureGeometry`; behaviour identical
- [x] `Sources/WindowList.swift` -- `appKitRect(fromCG:)` and `cgPoint(fromAppKitMouse:)` delegate with `primaryHeight`
- [x] `tests/CaptureLayoutChecks.swift` -- one check per matrix row, plus an AppKit↔CG round-trip
- [x] `CLAUDE.md` -- correct the multi-monitor gotcha (the still's pixels per point, not `backingScaleFactor`; the math lives in `Sources/Core/CaptureGeometry.swift`, called from `finish`) and the one `ScreenshotController.swift` source-map sentence

**Acceptance Criteria:**
- Given the branch, when `./tests/run.sh` runs, then every layout check passes and the run exits 0.
- Given the Y-flip in `CaptureGeometry` inverted, or `pixelRect` ignoring its scale, when `./tests/run.sh` runs, then at least one layout check names the failure and the run exits non-zero.
- Given `./build.sh --run`, when a region is captured on each of two displays and the same region (last-region key) on `trunk`'s build, then each pair is pixel-identical.

## Implementation Notes

- `crop` passes `CGSize(width: cg.width, height: cg.height)` as `imageSize`; the intersection rect is the same `(0,0,w,h)` as before. `WindowList.primaryHeight` is still read once per call, now as the delegate's argument.
- Mutations run: sourceRect flip inverted (4 checks fail, 2 of them layout), CG↔AppKit flip inverted (2 layout checks fail), `pixelRect` forced to scale 1 (4 layout checks fail); each exit 1, file restored byte-identical.
- The round-trip check alone cannot catch a dropped flip (identity is also an involution); the negative-origin and stacked checks are what catch it.

- Orchestrator re-verification (2026-10-11): runner 10/10 exit 0; mutations each exit 1 — Y-flip inverted (4 fail), pixelRect scale ignored (4), CG flip removed (3), globalRect ignoring the screen origin (2, added by the orchestrator); file restored byte-identical; `./build.sh --ci` exit 0 with only pre-existing warnings (HistoryWindow, Settings).

## Plan Change Log

## Review Triage Log

Pass 1 (quick lens, 2026-10-11) — 5 findings: high 0, medium 1, low 2, false 1, plus 1 already-decided deferral.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | Rounding check can't tell `.rounded()` from `.rounded(.up)` | medium | patch | Verified: origin rounding switched to `.rounded(.up)` → still 10/10. The matrix row "Rounded exactly as today" was not actually pinned. Patch adds non-.5 pixel values for origin and size. |
| 2 | `pixelRect` doc (and check name, and the new CLAUDE.md line) say "each edge rounded"; code rounds origin and size separately | low | patch + defer | True — maxX/maxY are never rounded; the suite's own 1.5x message says so. The Swift doc and check name are patched; the CLAUDE.md wording is deferred with #3 (agent-context rule). |
| 3 | CLAUDE.md gotcha: the live grab never goes through `pixelRect` (it sets `config.width/height` with rounding only, no clamp); `pointPixelScale` is also `freeze`'s fallback scale; the call list omits `freeze` | low | defer | Verified at ScreenshotController ~500-504. Fix edits CLAUDE.md → deferred to 1.5's doc sweep. |
| 4 | AC3 two-display comparison has no evidence | false | rejected | Not a code defect: a manual check for the user before merge, listed under Verification. |
| 5 | CLAUDE.md `Core/` entry and CONTRIBUTING's "covers the capture Y-flip" now stale | low | defer | True; the epic's decision already routes source-map and CONTRIBUTING updates for 2–4 to 1.5. |

Patches 1 and 2 applied by the implementer and re-verified by the orchestrator: runner 10/10 exit 0; origin `.rounded(.up)` (which passed before) and size `.rounded(.down)` each now exit 1; `./build.sh --ci` exit 0.

## Verification

**Commands:**
- `./tests/run.sh` -- expected: all checks pass (1.1's 3 + this story's), exit 0
- Mutation: invert the flip, then separately make `pixelRect` use scale 1 -- expected: each run exits 1 naming a layout check; restore
- `./build.sh --ci` -- expected: exit 0 (the app still compiles with the delegating helpers)

**Manual checks (if no CLI):**
- Two-display capture comparison against `trunk` (region at top and bottom of each display, plus Window mode).
