---
id: SPEC-improve-current-features
companions:
  - brownfield.md
  - ../../../CLAUDE.md
  - ../../../CONTRIBUTING.md
sources:
  - ../brainstorm-improve-current-features/brainstorm-improve-current-features.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Improve m_capture's existing features

## Why

A pain to solve. mesoneer colleagues capture daily and paste straight into Jira and Teams, but every
share goes through the full editor, and the only way to hide secrets is a Gaussian blur, which is
risky at a fintech/regtech company. Meanwhile the code these changes touch is the least stable: the
editor and capture overlay drew 97 commits in 120 days, multi-monitor capture was fixed four times,
and nothing is tested automatically. CI builds only on tags, which is why the macOS 15 SDK break
reached the 1.8.5 release. Sharing has to get faster and safer without adding more regressions.

## Capabilities

- **CAP-1**
  - **intent:** The overlay-to-capture geometry (selection → ScreenCaptureKit source rect → pixel rect) is checked automatically against multi-display layouts, with no display or permission needed.
  - **success:** One command runs checks covering mixed 1x/2x displays, a display at a negative origin, and vertically stacked displays; it passes on `trunk` and fails when the Y-flip is deliberately broken.
- **CAP-2**
  - **intent:** The editor's tool-card placement invariants are checked automatically across capture shapes and screen sizes.
  - **success:** One command sweeps the shape × screen matrix and reports zero card overlaps, zero cards over the capture and zero off-screen; it fails when the `gutterBand` clamp is reverted to screen bounds.
- **CAP-3**
  - **intent:** Every pull request is built in CI and runs the CAP-1 and CAP-2 checks.
  - **success:** A PR that fails to compile, or fails either check, shows a red required check before merge.
- **CAP-4**
  - **intent:** App diagnostics go to the unified log under the app's subsystem, so they can be retrieved after the fact.
  - **success:** `Sources/` contains no `print(`; a recording's session events appear in `log show --predicate 'subsystem == "io.mesoneer.mcapture"'`.
- **CAP-5**
  - **intent:** A user can finish a capture from the selection overlay — copy, save or pin — without opening the editor, in Region, Window and Screen modes.
  - **success:** Holding the action's key at release completes the capture with that action, in the same gesture and with no extra step; the output matches what the editor would produce with no marks; each key appears as a localized keycap hint in the overlay's guidance card.
- **CAP-6**
  - **intent:** A user can skip the editor for a single capture by holding ⇧ at release.
  - **success:** With the editor as the post-capture behaviour, a ⇧-release capture copies (honouring the save settings) and no editor opens; the next capture opens the editor as usual.
- **CAP-7**
  - **intent:** A user can act on a fresh capture from a quick-access thumbnail — drag out, copy, annotate, pin — selectable as a post-capture behaviour.
  - **success:** With the behaviour selected in Settings, a thumbnail appears on the capture's display; dragging it into another app drops the image, Copy, Annotate (opens the editor) and Pin each work; the thumbnail dismisses itself after about 6 s and stays while the pointer is over it.
- **CAP-8**
  - **intent:** A user can reopen the last capture in the editor with its marks still editable.
  - **success:** After annotating and closing via Copy or Save, re-edit reopens that capture, and each mark can be selected, moved and deleted individually.
- **CAP-9**
  - **intent:** A user can redact a region with an opaque bar that leaves no recoverable pixels, alongside blur and a pixelate option.
  - **success:** In an exported image, every pixel inside a solid-redacted region is the same colour; pixelate is selectable as a third style.
- **CAP-10**
  - **intent:** A user can have emails, tokens/API keys, IBANs and phone numbers in a capture detected and proposed for redaction, applied only after confirmation.
  - **success:** On a fixture capture with one of each, all four are proposed and none is applied unconfirmed; ordinary prose in the fixture yields no proposal.
- **CAP-11**
  - **intent:** When a capture leaves without the editor — the CAP-5/6/7 paths and the existing Save-to-file and Copy-to-clipboard behaviours — the user is warned once, before it leaves, if it contains sensitive text, and can open it in the editor instead.
  - **success:** Sending the CAP-10 fixture through each editor-free path warns before anything reaches the clipboard or disk, or before the quick-access thumbnail or pin window appears; "Open in editor" opens it there instead; a capture with no sensitive text leaves without a warning.

## Constraints

- System frameworks only. Checks and their runner build with `swiftc` under Command Line Tools: no Xcode project, and full Xcode is not required.
- macOS 14 deployment floor; compiles with the macOS 15.2+ SDK.
- PR CI builds without the release signing secrets (ad-hoc fallback), since PR runs don't get them.
- All UI uses `Theme` and brand chrome (square corners, `BrandAlert` / `PanelWindow`). Every string goes through `L()` in EN, DE and VI.
- Overlay actions and redaction work on the frozen still `begin()` already takes: no new capture path, no second grab.
- OCR runs once per capture and its result is reused.
- New overlay keys never displace Esc (cancel), Space (cycle mode) or the rebindable last-region key. They are plain overlay-owned keystrokes, not global hotkeys.
- Every new overlay or panel (thumbnail, redaction review) follows the window-level ladder and the cursor-rect hand-back rules in `CLAUDE.md`.
- CAP-1 to CAP-4 land before any work on CAP-5 to CAP-10 modifies `SelectionOverlay`, `ScreenshotController`, `EditorWindow` or `CanvasView`.

## Non-goals

- Jira upload, webcam overlay, scrolling capture, cloud share links, on-device AI descriptions, CLI or URL-scheme automation.
- The brainstorm's follow-up candidates: editor boundary/hand-zoom polish, style presets, opening arbitrary images, recording markers / keystroke overlay / purpose presets / GIF size target, History text search and thumbnail cache, presenter mode, translation, pin opacity / click-through, a pseudo-localization layout check, per-app post-capture behaviour.
- Re-edit that survives a relaunch (an editable sidecar file); CAP-8 holds the last capture for the current launch only.
- Automated end-to-end capture tests that need a Screen Recording grant. Capture itself stays smoke-tested by hand.

## Success signal

- A colleague copies a region into Jira with one keypress and no editor. A capture showing an email address and an API key is safely redacted in two clicks. A PR that breaks multi-monitor geometry or editor card layout is stopped by a red CI check before merge.

## Assumptions

- ⇧-at-release routes to copy-to-clipboard, honouring the auto-copy and save settings.
- The quick-access thumbnail is opt-in, as a new post-capture behaviour; the editor stays the default.
- The single OCR pass is fast enough to run before an editor-free capture leaves without defeating CAP-5's speed; the CAP-11 work measures it before building on it.
- Detection covers common formats only: email, IBAN (checksum-validated), international and local phone numbers, known key prefixes and high-entropy tokens. National ID formats are excluded.
