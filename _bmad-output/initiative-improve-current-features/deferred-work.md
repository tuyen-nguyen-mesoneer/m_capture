- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-test-runner-and-pr-ci-proven-on-the-capture-y-flip-plan.md`
  summary: Correct the claim that `precondition` is compiled out under `-O` in tests/Harness.swift's CheckSuite doc and CLAUDE.md's `tests/` entry — only `assert` is.
  evidence: Swift removes `assert` at -O and `precondition` only at -Ounchecked; deferred because the fix edits CLAUDE.md (agent-context rule). Fits entry 1.5's doc sweep.
- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-test-runner-and-pr-ci-proven-on-the-capture-y-flip-plan.md`
  summary: Point CLAUDE.md's multi-monitor gotcha and the ScreenshotController source-map entry at Sources/Core/CaptureGeometry.swift, where the Y-flip now lives.
  evidence: Both still say the math lives in `finish`; entry 1.2 already owns correcting that gotcha (it also names backingScaleFactor wrongly).
- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-capture-geometry-as-a-pure-type-checked-across-display-layou-plan.md`
  summary: Correct CLAUDE.md's multi-monitor gotcha — origin and size are rounded separately (not "per edge"); clamping/nil happen only in `crop`'s pixelRect, while the live grab sets config.width/height with rounding alone; `pointPixelScale` is also `freeze`'s fallback scale; `freeze` calls `CaptureGeometry.scale`.
  evidence: ScreenshotController ~500-504 (live grab) vs `crop` → `CaptureGeometry.pixelRect`; deferred because the fix edits CLAUDE.md. Fits 1.5's doc sweep.
- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-capture-geometry-as-a-pure-type-checked-across-display-layou-plan.md`
  summary: Update CLAUDE.md's `Core/` source-map entry (CaptureGeometry now holds globalRect, scale, pixelRect and the CG↔AppKit flips) and CONTRIBUTING's Testing line that says the runner covers only the Y-flip.
  evidence: Both false after 1.2; the epic's decision routes 2–4's source-map and CONTRIBUTING edits to 1.5.
