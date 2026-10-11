---
type: initiative
title: "Faster, safer sharing from captures, without new regressions"
parent: none
covers: [CAP-1, CAP-2, CAP-3, CAP-4, CAP-5, CAP-6, CAP-7, CAP-8, CAP-9, CAP-10, CAP-11]
after: []
assignee: ""
risk: high
---

# Faster, safer sharing from captures, without new regressions

## Description

mesoneer colleagues capture, share and redact faster and more safely, and the changes land on code
that is guarded against the regressions it keeps producing. The spec owns the capabilities,
constraints and non-goals; this initiative delivers them across three epics.

## Outcome

Colleagues who paste captures into Jira and Teams skip the editor when they don't need it, and can't
let a secret leave a capture without being warned; the spec's success signal is the measure.

## Done when

1. The spec's success signal is demonstrated end to end on a two-display Mac running a tagged release: one-key copy into Jira, two-click redaction of an email and an API key, and a PR that breaks multi-monitor geometry blocked by a red CI check.
2. CAP-1 to CAP-11 are live in a tagged release; only the quick-access thumbnail is opt-in.
3. The CONTRIBUTING baseline smoke test passes in EN, DE and VI on that release.
4. No multi-monitor or editor-layout regression is reported against that release in its first 30 days.

## Boundaries

A capability boundary inside one app and one repo: the capture overlay, the editor, post-capture
routing, and CI. Not the recording pipeline beyond CAP-4's logging swap, and not History, Pin
internals or the updater; see the spec's non-goals. Tracer path across epics: a region captured on a
two-display Mac, copied with one key, checked for sensitive text, and pasted into Jira.

- Touch point: `.github/workflows/` — a new PR workflow beside `release.yml` (`release.yml` unchanged); owner: epic-reliability-guardrails
- Touch point: GitHub branch protection on `trunk` — mark the PR check required (repo admin, hitl); owner: epic-reliability-guardrails
- Touch point: `VideoRecordSession` / `RecordZoomEngine` — `print(` → `os.Logger` only, no behaviour change; owner: epic-reliability-guardrails
- Touch point: Pin (`PinnedWindowController`) — consumed as-is by the overlay pin action and the thumbnail; owner: epic-capture-to-share

## References

- spec — _bmad-output/initiative-improve-current-features/spec-improve-current-features/spec-improve-current-features.md, section Capabilities
- constraint — same spec, section Constraints (system frameworks only, macOS 14, Theme/L10n, frozen still, OCR once, window ladder, guardrails first)
- brownfield — _bmad-output/initiative-improve-current-features/spec-improve-current-features/brownfield.md

## Notes

- Decision (2026-10-11): three epics in the order guardrails → capture-to-share → redaction (user, via brainstorm and "your call").
- Decision (2026-10-11): CAP-11 moves from capture-to-share to safer-redaction, because it needs CAP-10's detection and the single OCR pass that epic owns (user approved the recommendation).
- Decision (2026-10-11): no cross-epic contract. This is one repo and one unit, so the epics hand off through `after`; epic 2's single editor-free routing point, with a completion-based gate, is the handoff to epic 3.
- Decision (2026-10-11): each epic closes with a hitl release step (bump `VERSION`, add the `docs/index.html` release-note pair in en and de, push the tag), because every Done when requires a tagged release (user approved). (Superseded below.)
- Decision (2026-10-11): releases follow the repo's convention instead. Each user-facing story's PR bumps `VERSION` and adds its release note, and the user tags it after merge. Epic 1 is not user-visible, so it ships no release of its own and its code goes out in epic 2's first release (user agreed after PR #69).
