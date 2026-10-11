- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-test-runner-and-pr-ci-proven-on-the-capture-y-flip-plan.md`
  summary: Correct the claim that `precondition` is compiled out under `-O` in tests/Harness.swift's CheckSuite doc and CLAUDE.md's `tests/` entry — only `assert` is.
  evidence: Swift removes `assert` at -O and `precondition` only at -Ounchecked; deferred because the fix edits CLAUDE.md (agent-context rule). Fits entry 1.5's doc sweep.
- source_plan: `_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/story-test-runner-and-pr-ci-proven-on-the-capture-y-flip-plan.md`
  summary: Point CLAUDE.md's multi-monitor gotcha and the ScreenshotController source-map entry at Sources/Core/CaptureGeometry.swift, where the Y-flip now lives.
  evidence: Both still say the math lives in `finish`; entry 1.2 already owns correcting that gotcha (it also names backingScaleFactor wrongly).
