---
type: epic
title: "No secret leaves a capture unredacted without a warning"
parent: initiative-improve-current-features
covers: [CAP-9, CAP-10, CAP-11]
after: []
assignee: ""
risk: medium
---

<!-- Envelope. Requirements are completed at this epic's inception, and its children are planned in tickets.toml beside this file. -->

# No secret leaves a capture unredacted without a warning

## Description

An opaque redact bar beside blur and pixelate; one-click proposals for emails, tokens, IBANs and
phone numbers from one OCR pass per capture; and a warning before any editor-free exit carries
sensitive text.

## Outcome

A capture showing an email and an API key is safely redacted in two clicks; the second clause of the
spec's success signal.

## Done when

1. Every pixel inside a solid-redacted region of an exported image is one colour; pixelate can be selected.
2. On the fixture capture, all four kinds are proposed, none is applied unconfirmed, and ordinary prose yields none. The fixture is built by this epic's first redaction story, stored beside `tools/sample.png` as `tools/redaction-fixture.png`, and reused by CAP-11's check.
3. Sending the fixture through every editor-free exit warns before clipboard or disk, or before a thumbnail or pin window appears. That covers one-key, ⇧-release, quick access, and the Save-to-file and Copy-to-clipboard behaviours. "Open in editor" works, and a clean capture leaves without a warning.
4. OCR runs once per capture, and its measured cost doesn't noticeably slow a one-key copy (the number is recorded in the CAP-11 plan).
5. Smoke-tested on two displays; shipped in a tagged release (closing hitl release step).

## Boundaries

Covers the CanvasView/Annotations redaction tools, reuse of `TextRecognizer`, and a check added at
epic 2's single editor-free routing point through its completion-based gate, which holds or cancels
the exit until OCR answers. The pure detection rules (patterns, IBAN checksum, entropy) are checked
in epic 1's runner, with no second harness. Not automatic redaction without confirmation.

## References

- spec — _bmad-output/initiative-improve-current-features/spec-improve-current-features/spec-improve-current-features.md, CAP-9 to CAP-11 and Constraints
- brownfield — same folder, brownfield.md, rows CAP-9 to CAP-11 and Leak paths

## Notes

- Waits on epic-reliability-guardrails because the spec requires the guardrails before EditorWindow or CanvasView change.
- Waits on epic-capture-to-share because CAP-11 checks the editor-free exits that epic builds, through its routing point.
- Decision (2026-10-11): CAP-11 covers the existing Save-to-file and Copy-to-clipboard behaviours too, and checks once, before the thumbnail or pin window appears (user approved).
