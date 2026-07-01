# FIP-2: SettingsWindow — Video Section

## Context

With `VideoQuality` and `VideoAudioSource` defined in Settings (Task 1), this task surfaces them in the existing dark Settings panel so users can configure their recording preferences before they ever hit ⌃⇧R.

The Settings panel already has four sections (General, Shortcuts, Capture, Output). We add a fifth: **Video**. It must be visually indistinguishable from existing sections — same spacing, same `BrandPopUpButton` style, same `SectionHeader` separator.

**How to verify:** Open Settings, navigate to the Video section, change both pickers, close and reopen Settings — values must persist. No layout breakage in any of the existing sections.

---

## What to Build

A new **Video** section in `SettingsWindowController`, positioned after the Output section, containing:

- `SectionHeader` label: `"Video"`
- Row: label `"Quality"` + `BrandPopUpButton` populated from `VideoQuality.allCases`
- Row: label `"Audio"` + `BrandPopUpButton` populated from `VideoAudioSource.allCases`

Action selectors:
- `qualityChanged(_:)` → `Settings.shared.videoQuality = selected`
- `audioSourceChanged(_:)` → `Settings.shared.videoAudioSource = selected`

`refresh()` must populate both pickers from `Settings.shared` on every `show()` call.

---

## Implementation Direction

1. In `SettingsWindowController`, locate where the Output section ends (look for the Output `SectionHeader` and its rows).
2. After the last Output row, append in order:
   - `SectionHeader("Video")`
   - A label+picker row for Quality (mirror the Format row pattern exactly)
   - A label+picker row for Audio (mirror the Quality row)
3. Populate pickers: `VideoQuality.allCases.forEach { btn.addItem(withTitle: $0.label) }` — `.label` is the display string from Task 1.
4. Set `target` and `action` on each `BrandPopUpButton`.
5. In `refresh()`: set `qualityBtn.selectItem(withTitle: Settings.shared.videoQuality.label)` and same for audio.
6. Implement `qualityChanged` and `audioSourceChanged` action methods.
7. `./build.sh` — confirm zero errors.

---

## Acceptance Criteria

### CPU
- Opening/closing Settings: CPU spike < 1% (measured with `top`). No continuous polling or timer introduced.

### Memory
- Settings window open → change pickers → close → `leaks $(pgrep m_capture)` — 0 leaks.
- Window is `isReleasedWhenClosed = false` (existing behaviour) — confirm it does not accumulate duplicate subviews on repeated show/hide.

### UX / Correctness
- Video section appears after Output, before any window edge.
- Picker labels match `VideoQuality` and `VideoAudioSource` display strings exactly.
- Selecting Medium quality → closing Settings → reopening Settings → Quality picker shows Medium.
- Tab and arrow-key navigation works within the new section.
- Existing sections (General, Shortcuts, Capture, Output) are visually and functionally unchanged — regression check by eye.
- `./build.sh` compiles clean.

---

## Known Risks

- **Stack view / scroll view overflow:** If the Settings window has a fixed height, adding a new section may clip. Check whether the window auto-sizes or has a hardcoded frame — expand if needed.
- **`refresh()` completeness:** If `refresh()` is not updated, pickers will show stale values after an external `Settings.shared` write. Ensure both new pickers are populated in `refresh()`.
- **Label alignment:** The existing `BrandControl.textInset` alignment must apply to new rows. Do not hardcode insets.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Edit | `Sources/SettingsWindow.swift` | Add Video SectionHeader, two picker rows, two action methods, update `refresh()` |

No new files. No other files touched.

---

## Out of Scope

- Recording logic of any kind
- Microphone permission prompt (Task 5)
- Video-specific file-naming or save-path settings
- Any change to the Shortcuts section or existing pickers
