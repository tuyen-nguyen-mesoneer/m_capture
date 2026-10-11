---
type: brainstorm-intent
initiative: initiative-improve-current-features
source: .memlog.md (105 ideas, 6 techniques, converged by affinity clustering + MoSCoW)
date: 2026-10-11
---

# Intent: improve m_capture's existing features

## Goal

Make the features mesoneer colleagues use daily faster and safer to share, without adding to the
regression churn. This initiative improves what already exists; it adds no new capability areas.

## Evidence (why these, why now)

- No open GitHub issues, so the strongest signal is the fix log. Over the last 120 days the
  highest-churn files are `EditorWindow` + `CanvasView` (50 commits) and `ScreenshotController` +
  `SelectionOverlay` (47).
- Regressions recur: multi-monitor capture was fixed four times (#22, #38, #53, #54), and
  focus/cursor glitches in the overlay keep coming back. There are no automated tests, and CI
  builds only on version tags, which is why the macOS 15 SDK break went unnoticed until the 1.8.5
  release (#67).
- Captures go straight into Jira and Teams at a fintech/regtech company, and the only redaction
  tool is a Gaussian blur.

## Scope: three epics, in this order

### 1. Reliability guardrails (first: the next two epics change the files it protects)

- A minimal test runner compiled with `swiftc` (assert-based, built like `tools/shots.swift`; no
  Xcode project, no dependency).
- Extract the overlay → ScreenCaptureKit `sourceRect` → pixel math from
  `ScreenshotController.finish` into a pure type. Test it against simulated layouts: mixed
  backing scale, negative origins, stacked displays.
- Make the editor gap-model simulation (today run ad hoc over 1764 shapes × 9 screens) a check
  anyone can rerun: no card overlaps another, none sits over the capture, none lands off-screen.
- CI builds on every pull request, not only on tags.
- Replace `print` with `os.Logger` categories (20 calls in `VideoRecordSession` alone), so a bug
  report can include `log show` output.

### 2. Capture-to-share speed

- One-key actions on the selection overlay, so a capture can skip the editor: copy and close,
  save, pin. Today the overlay handles only Esc, Space and the last-region key.
- Hold ⇧ on release to skip the editor for that one capture.
- A quick-access thumbnail after a capture (drag out, copy, annotate, pin), offered as a
  `CaptureBehavior` alongside today's editor / save / copy.
- Re-edit the last capture: the editor state survives closing.

### 3. Safer redaction

- A solid redact bar, alongside the current Gaussian blur and a pixelate option. A solid bar is
  the only safe choice for secrets.
- One-click detection of emails, tokens, IBANs and phone numbers, using the existing
  `TextRecognizer` (Vision). It proposes regions to redact; the user confirms them.

## Design constraints the spec must keep

- No external dependencies; system frameworks only. All styling goes through `Theme`; every
  string goes through `L(...)` in EN/DE/VI; macOS 14 is the floor.
- **The frozen still is the platform.** Overlay actions and redaction run on the freeze `begin()`
  already takes; none of them adds a new capture path.
- **One OCR pass, reused.** Run recognition once per capture and keep the result, so redaction now
  (and a copy-text mode or History text search later) share it.
- Respect the window-level ladder and the cursor-rect rules in `CLAUDE.md`. Both are areas where
  the overlay has regressed before.

## Explicitly out of scope (this initiative)

Jira upload, webcam overlay, scrolling capture, cloud share links, on-device AI descriptions, CLI
or URL-scheme automation.

## Follow-up candidates (not in this spec)

- Should: the editor trade-offs `CLAUDE.md` flags (show the display boundary while dragging the
  resize knobs; ⌥-drag hand zoom); annotation style presets; open any image or the clipboard in
  the editor; recording markers + keystroke overlay + purpose presets / GIF size target.
- Could: History search by OCR text and a thumbnail cache; presenter mode; translating a capture;
  pin opacity / click-through; a pseudo-localization layout check; per-app post-capture behaviour.
