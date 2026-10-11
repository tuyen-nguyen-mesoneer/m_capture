---
type: epic
title: "Captures reach the clipboard, disk or a pin without the editor"
parent: initiative-improve-current-features
covers: [CAP-5, CAP-6, CAP-7, CAP-8]
after: []
assignee: ""
risk: high
---

<!-- Envelope. Requirements are completed at this epic's inception, and its children are planned in tickets.toml beside this file. -->

# Captures reach the clipboard, disk or a pin without the editor

## Description

Overlay one-key actions held at release in every mode, ⇧ to skip the editor once, an opt-in
quick-access thumbnail, and re-editing the last capture.

## Outcome

A colleague copies a region into Jira with one key and no editor; the first clause of the spec's
success signal.

## Done when

1. Holding the copy, save or pin key at release in Region, Window and Screen completes the capture with that action; the output matches the editor's with no marks; the keycap hints read correctly in EN, DE and VI.
2. A ⇧-release capture copies without the editor; the next capture opens it.
3. Quick access can be selected in Settings; drag-out, Copy, Annotate and Pin work; it dismisses after about 6 s and stays while hovered.
4. Re-edit reopens the last capture with each mark selectable, movable and deletable.
5. Epic 1's checks stay green in CI; smoke-tested on two displays; shipped in a tagged release. Each user-facing story's PR bumps `VERSION`, adds the `docs/index.html` release-note pair (en and de) and is tagged after merge, the repo's convention. The first release also carries epic 1's guardrail code.

## Boundaries

Covers SelectionOverlay, ScreenshotController routing, CaptureBehavior and Settings, a thumbnail
panel, and keeping the editor's state. Not redaction (epic 3).

Handoff to epic 3: every editor-free exit leaves through one routing point. That covers one-key,
⇧-release, quick access and the existing save/copy behaviours. The routing point takes a
completion-based gate (async-capable), so a pre-exit check can hold or cancel the exit before
clipboard or disk, or before a thumbnail or pin window appears.

## References

- spec — _bmad-output/initiative-improve-current-features/spec-improve-current-features/spec-improve-current-features.md, CAP-5 to CAP-8 and Constraints
- brownfield — same folder, brownfield.md, rows CAP-5 to CAP-8
- conventions — CLAUDE.md: window-level ladder, the cursor-rect hand-back, `OverlayKey`, `KeyHint`, the `SelectionOverlay` pre-drag chrome

## Notes

- Waits on epic-reliability-guardrails because the spec requires the guardrails before SelectionOverlay, ScreenshotController or EditorWindow change. Epic 2 needs those geometry and layout checks green in PR CI.
- Decision (2026-10-11): the action is chosen by a key held at release (the same gesture as ⇧) in all three modes; the thumbnail dismisses after about 6 s; re-edit lasts for the current launch only.
