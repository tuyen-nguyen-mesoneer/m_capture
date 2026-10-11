---
type: epic
title: "Capture-geometry and editor-layout regressions are caught before merge"
parent: initiative-improve-current-features
covers: [CAP-1, CAP-2, CAP-3, CAP-4]
after: []
assignee: ""
risk: high
---

# Capture-geometry and editor-layout regressions are caught before merge

## Description

The platform baseline. The overlay-to-capture geometry and the editor's tool-card placement get
automated checks, every PR is built and checked in CI, and diagnostics go to the unified log. Nothing
user-visible changes; this is what makes epics 2 and 3 safe to build.

## Outcome

The owner merges overlay and editor changes knowing that a geometry or layout regression turns CI
red; CAP-1 to CAP-3's success criteria are the signal.

## Requirements

The spec's CAP-1 to CAP-4 are the requirement source (referenced numbered source; reused ids).

## Done when

1. One local command, Command Line Tools only, runs the geometry and layout checks and passes on `trunk`.
2. Breaking the Y-flip, and making `gutterBand` return `(m, cs.height - m)`, each make that command fail.
3. A PR that fails to compile or fails a check shows a red required check, built without the release signing secrets.
4. `Sources/` has no `print(`; a recording's events appear in `log show --predicate 'subsystem == "io.mesoneer.mcapture"'`.
5. Every entry is merged to `trunk` with "Build and check" green and no user-visible behaviour change; the CONTRIBUTING smoke test passes on two displays. The code ships in epic 2's first release.

## Boundaries

Covers the test runner, the extracted pure geometry and layout types, the PR CI workflow, `build.sh`
(only what PR CI needs), CONTRIBUTING.md's Testing section, and logging. No new user-facing behaviour.
It also owns setup that later epics reuse:

- **The runner picks up any new check file.** Epic 3 adds its detection-rule checks there rather than
  building a second harness.
- **One shared app logger.** Epics 2 and 3 log through it, never `print(`.

## References

- spec — _bmad-output/initiative-improve-current-features/spec-improve-current-features/spec-improve-current-features.md, CAP-1 to CAP-4 and Constraints
- brownfield — same folder, brownfield.md, rows CAP-1 to CAP-4
- conventions — CONTRIBUTING.md, Prerequisites and Testing; CLAUDE.md, Gotchas (multi-monitor coordinates) and the EditorWindow gap-model notes

## Notes

- Tracer bullet: entry 1. It builds the CI mode in `build.sh`, the runner, one extracted function with one check, and the PR workflow, proving that app code, runner and CI connect.
- Sequencing: entries 2, 3 and 4 run in parallel after entry 1. They touch disjoint Sources files (ScreenshotController + WindowList / EditorWindow / VideoRecordSession + RecordZoomEngine), and entry 1's discovery convention means none edits a shared list.
- Decision (2026-10-11): `CLAUDE.md` source-map and CONTRIBUTING edits for entries 2–4 go to entry 5, so parallel branches don't conflict. Entry 1 makes only the edits its own work makes false.
- Decision (2026-10-11): `--zoom-benchmark`'s results table keeps going to stdout through a small output helper. It is command-line output, not diagnostics, so CAP-4's "no `print(`" holds and the documented workflow is unchanged (user approved).
- Decision (2026-10-11): entry 6 cuts the epic's release. It's a hitl step: the user pushes the tag. (Superseded below.)
- Decision (2026-10-11): no release for this epic. Nothing in it is user-visible, and the repo bumps `VERSION` only with user-facing changes (#64, #67, #68 didn't), so the guardrail code ships in epic 2's first release (user agreed after PR #69).
- Dropped: entry 6 (Cut the guardrails release), per the decision above. Nothing waits on it.
- Source conflict: CLAUDE.md, Gotchas › Multi-monitor coordinates — says pixel size is `viewRect × backingScaleFactor` vs the code, which scales by the frozen still's pixels per point (`cg.width / CGDisplayBounds.width`) or `filter.pointPixelScale`. brownfield.md is corrected; entry 2 fixes CLAUDE.md.
