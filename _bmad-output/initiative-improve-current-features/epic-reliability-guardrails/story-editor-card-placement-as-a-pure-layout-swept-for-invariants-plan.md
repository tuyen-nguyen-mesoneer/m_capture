---
title: 'Editor card placement as a pure layout, swept for invariants'
type: 'refactor'
ticket: '3'
created: '2026-10-11'
status: done
baseline_revision: 'c44ea0dfcf4090f051c1e356d4984f07d21759ab'
route: 'full'
route_source: 'auto'
risk: 'high'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/epic-reliability-guardrails.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The editor's tool-card placement (gap model, scaling, centring, gathering) lives in view-bound methods of `EditorWindowController`; its invariants were verified once by an ad hoc simulation and nothing reruns it, so a change can put cards on each other or over the capture unnoticed.

**Approach:** Extract the whole placement computation into a pure `EditorLayout` in `Sources/Core/` that takes sizes and rects (card sizes measured by the controller) and returns card frames; the controller builds views and applies the frames exactly as today. Add a runner sweep over capture shapes × screen sizes asserting the invariants.

## Boundaries & Constraints

**Always:** every card lands where it lands today — same constants (`cardGap` 16, `cardMargin` 8, `capturePad` 8, `cardSlack` 8, `comfortableEdge` 320, `workableEdge` 120, `maxMagnification` 4, `overCaptureOrigin`'s local 8/16, `gatherOffsets`' 7/6/6), same arithmetic, same preference table and assignment order (Markup, Shape, Style, Background, Action), same use of one shared max `cardSize`; `gutterBand` and `rowOutside`'s vertical edges stay one definition; pure code is UI-free and takes card sizes as input; checks use 1.1's harness.
**Never:** change view building, button wiring, `makeCluster`, `cardFit`, `ClusterHeader`, the resize handles, `displacedPanels`, or `relayout`'s call order (clamp → frames → background preview → rebuild → restore selection → handles); fix the known `cardFootprint`-vs-header drift or `insetScale` ignoring `bgPad` (behaviour changes — out of scope); touch capture geometry (1.2) or logging (1.4); edit CLAUDE.md (left to 1.5).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Sweep, trunk geometry | Capture shapes × screen sizes (incl. 1440×900, 1512×982, 1920×1080, 2560×1440, 1280×800), card sizes = footprint and footprint +24 pt wide (long localized header) | Zero card overlaps; no card intersects the canvas unless gathered; every card inside the screen | — |
| Gutter band mutation | `gutterBand` returns `(m, cs.height - m)` | Sweep reports an overlap and exits 1 — the matrix must hit the ~110–118 pt canvas-height band at ≥ 320 pt width (≤ 4 pt steps there, or targeted shapes) | — |
| Whole-screen capture | Selection = screen frame | `insetScale` < 1 scales it; nothing gathers; invariants hold | — |
| Tiny capture | 40×30 pt on a 2x display | Magnified in whole steps (`magnification`), capped by density and half the display; invariants hold | — |
| Narrow screen | `insetScale` would fall below 0.6 → returns 1 | Gathered leftovers may sit over the capture — exempt from "not over the capture" | — |

</frozen-after-approval>

## Code Map

All in `Sources/EditorWindow.swift` unless noted.
- `init` 398-465 -- `onScreenScale` (400) → `scale = (1/captureScale)*inset` (402) → canvas; centring `local` (445-448); `buildClusters(around: local, in:)` (462). Keep the order.
- Statics to move: `onScreenScale` 580-585, `magnification` 614-625, `insetScale` 627-650 (take `screen.frame` as a `CGRect`; `insetScale` needs the card footprint — pass it in; the controller computes it from `cardFootprint` 553-557 / `ToolButton.size(radius:)` = r×1.85).
- `buildClusters` 652-804 -- keep view building (679-760), `cardFit` (764), button-map writes. Move: `bgPad`/`sel` inset arithmetic (653-654, with `bgPad` passed in — it reads `Settings.shared`), `cardSize` max (765-766), `measureGaps` 840-868, `gutterBand` 875-879, the preference/assignment loop 771-790, `rowSplit` 884, `gatherOffsets` 889-913 (sizes only), `overCaptureOrigin` 921-925, and the position math of `stackVertically` 929-950 / `rowOutside` 954-967. The controller applies the returned frames with `setFrameOrigin` + `addSubview` in the same order.
- `relayout(canvasFrame:)` 1576-1610 -- the clamp/centre/round with `m = 8 + pad` (1578-1594) is pure; move it, keep everything else.
- `Side`/`Gap` 148-153 -- move with the gap model.
- Re-run entry points (all through `relayout`, unchanged): `applyCrop` 1562, `rotate` 1512, `flip` 1531, `resizeEnded` 1734/1745/1756, `backgroundPressed` 1423, `backgroundCustomPressed` 1438.
- `tests/` -- add `tests/EditorLayoutChecks.swift`; reproduce `init`'s pipeline in the check: scale → canvas size (`selection.size × inset`) → centre → inset by `capturePad − bgPad` → place.
- Sandbox: `CLANG_MODULE_CACHE_PATH="$TMPDIR/swift-mc"`.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/Core/EditorLayout.swift` -- the pure layout: scale functions, canvas centring and relayout clamp, `Side`/`Gap`, gap model, preference/assignment, gathering, per-card frame computation; returns card frames (by cluster index) plus which were gathered; constants move with it (controller keeps referencing them through `EditorLayout`)
- [x] `Sources/EditorWindow.swift` -- call `EditorLayout`; keep building, wiring, order and applying frames; delete the moved bodies
- [x] `tests/EditorLayoutChecks.swift` -- the sweep (matrix rows) plus targeted shapes in the gutter band; failure messages name the shape and screen

**Acceptance Criteria:**
- Given the branch, when `./tests/run.sh` runs, then the sweep passes and the run exits 0.
- Given `gutterBand` returning `(m, cs.height - m)`, when `./tests/run.sh` runs, then the sweep names an overlapping shape and exits non-zero.
- Given `./build.sh --run`, when a capture is taken at three sizes (tiny, mid, whole-screen) on `trunk` and on the branch, then the cards land in the same places.

## Implementation Notes

- `EditorLayout` (Sources/Core) holds the constants, `gutterInset(card:)`, `onScreenScale` / `magnification` / `insetScale` (screen as a `CGRect`, card footprint passed in), `centredCanvas` (init's centring), `clampCanvas` (relayout's clamp/centre/round), `Side`/`Gap`, `preference`, and `cardFrames(cards:around:bgPad:in:)`, which does the `capturePad − bgPad` inset and returns `Placement { frames, order, gathered }`. `order` is the add order (left run, right, top, bottom, gathered) so the controller's `addSubview` z-order is unchanged.
- Stays in the controller: `cardFootprint` (needs `ToolButton.size`), `minCanvasEdge` (resize clamp, not layout), `bgPad`/`pad` (read `Settings` via `Background.padding`), all view building, `cardFit`, `relayout`'s call order.
- Equivalence verified out of tree: trunk's original view-based functions (copied verbatim from c44ea0d) vs `EditorLayout` over 521,208 layouts (8 screens incl. a negative-origin frame, 1x/2x, 4 card-size sets, 3 bgPad fractions, plus the relayout clamp on an off-centre probe) — 0 mismatches in scale, centring, frames or add order.
- Pre-existing, not fixed (behaviour change): a canvas thinner than 16 pt (2 × `capturePad`) insets to `CGRect.null`, so every card gets an infinite origin (NSView clamps it to ~1.8e13) and no tool card is visible. Reachable: the overlay accepts ≥ 3 pt selections, and e.g. a 3×200 pt capture on a 1x display is not magnified. The sweep skips these shapes (`isSliver`) and says why.
- The gutter-band mutation does not bite at ≥ 320 pt width as the Intent guessed: the collision needs the top row to reach sideways past the capture, so it hits 1x captures up to ~290 pt wide (and tiny 2x captures magnified into the band). `checkGutterBandShapes` walks heights 104–124 in 1 pt steps × widths 120–1200; the general sweep (24 pt steps) catches it too.

- Orchestrator re-verification (2026-10-11): runner 16/16 exit 0; `gutterBand` → `(m, cs.height - m)` exits 1 failing `checkGutterBandShapes` and `checkSweepAcrossCaptureShapesAndScreens`; file restored byte-identical; `./build.sh --ci` exit 0, only the two pre-existing warnings (HistoryWindow, Settings). Controller diff read in full: `bgPad` still from the un-inset selection, frames applied in `Placement.order` (left, right, top, bottom, leftovers — trunk's add order), `relayout` order unchanged.

## Plan Change Log

## Review Triage Log

Pass 1 (quick lens, 2026-10-11) — 6 findings: high 0, medium 0, low 5, false 1.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | AC3 manual trunk-vs-branch comparison not run; the 521,208-layout equivalence run is out of tree | false | rejected | Not a code defect: a manual check for the user before merge. The orchestrator independently read the controller diff and `cardFrames` against trunk, and the reviewer compared the moved code line by line; the out-of-tree equivalence run is supporting evidence only. |
| 2 | `isSliver` skips layouts silently, against the matrix's "every card inside the screen" | low | patch | Real: for a canvas < 16 pt the inset rect is `.null` and every card goes to an infinite origin — a pre-existing trunk bug. The frozen intent puts behaviour changes out of scope ("every card lands where it lands today"), so exclusion is the intent-consistent reading; the patch makes the skip visible by counting it. The bug itself is deferred as a backlog bug. |
| 3 | The test's `footprint` hand-copies `EditorWindowController.cardFootprint` | low | defer | Real but bounded: the sweep also runs +24 pt and mixed card sets, and `cardFootprint` is itself a hand mirror of `makeCluster`/`cardFit` (pre-existing). Sharing one definition adds API to Core, which goes beyond a patch. |
| 4 | The sweep never exercises `bgPad > 0` | low | patch | Real: `relayout` rebuilds with nonzero `bgPad` whenever a background is set. Patch adds a nonzero padding to the invariant sweeps; the whole-screen scatter check stays at 0 because `insetScale` ignores `bgPad` (known, out of scope per the frozen Never). |
| 5 | Doc comment hardcodes mutation counts | low | patch | Real; goes stale with any matrix change. Direct deletion. |
| 6 | Inline `//` sub-case labels in `checkTinyCaptureMagnifiesInWholeSteps` | low | patch | Real, against CLAUDE.md's comment convention; the `//` comments inside the moved EditorLayout bodies came from trunk unchanged and stay. |

Patches 2, 4, 5, 6 applied by the implementer (tests only) and re-verified by the orchestrator: runner 16/16 exit 0; the sweep prints its sliver skip count (6504 of 201168); the `gutterBand` mutation still exits 1; app sources unchanged since the review diff.

## Verification

Results (2026-10-11): `./tests/run.sh` → 16 passed, exit 0; the sweep and gutter-band check run at bgPad 0 and at the large preset ratio 0.045. Mutation → exit 1, `checkGutterBandShapes` (2115 of 137340 layouts) and the sweep (150 of 201168, 6504 sliver layouts skipped) fail, naming e.g. "capture 120×111 pt on 1440×900 @1x, footprint cards: Markup … overlaps Style …"; restored. `./build.sh --ci` → exit 0, warning set identical to trunk's. Manual three-size UI comparison not run (no display access from the agent); covered by the equivalence run above.

**Commands:**
- `./tests/run.sh` -- expected: all checks pass, exit 0
- Mutation: `gutterBand` → `(m, cs.height - m)` -- expected: exit 1 naming a shape; restore
- `./build.sh --ci` -- expected: exit 0, no new warnings

**Manual checks (if no CLI):**
- Three capture sizes, `trunk` vs branch: card positions identical; crop, rotate, flip and a resize-knob drag still re-lay the cards correctly.
