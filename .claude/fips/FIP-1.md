# FIP-1: Settings — VideoQuality and VideoAudioSource Enums

## Context

Before any recording UI or engine can be built, the app needs a single source of truth for video preferences. This task establishes two new enums in `Settings.swift` — `VideoQuality` and `VideoAudioSource` — and exposes them as computed properties on `Settings.shared`, backed by `UserDefaults`.

This is the foundation all later tasks depend on. Getting the keys and defaults right here avoids chasing UserDefaults mismatches across tasks 2–7.

**How to verify:** After implementation, use `defaults read io.mesoneer.mcapture` to confirm keys appear with correct default values. Run `leaks` to confirm zero allocations introduced.

---

## What to Build

**`VideoQuality` enum** (String RawRepresentable, CaseIterable)
- Cases: `high`, `medium`, `low`
- Display labels: `"High (8 Mbps)"`, `"Medium (4 Mbps)"`, `"Low (2 Mbps)"` for 1080p
- Computed `bitrate(for resolution: CGSize) -> Int` — scales bitrate proportionally for 4K
- UserDefaults key: `"videoQuality"`, default: `.high`

**`VideoAudioSource` enum** (String RawRepresentable, CaseIterable)
- Cases: `none`, `system`, `mic`, `both`
- Display labels: `"None"`, `"System Audio"`, `"Microphone"`, `"System + Mic"`
- UserDefaults key: `"videoAudioSource"`, default: `.system`

**`Settings.shared` additions**
- `var videoQuality: VideoQuality { get set }`
- `var videoAudioSource: VideoAudioSource { get set }`

Both follow the identical read/write pattern as `captureBehavior` and `format`.

---

## Implementation Direction

1. Locate the existing enum block in `Settings.swift` (after `PaddingSize`, before `Settings` class).
2. Add `VideoQuality` and `VideoAudioSource` following the same `RawRepresentable + CaseIterable` pattern as `CaptureBehavior`.
3. Add key constants to the private `Key` struct inside `Settings`:
   - `static let videoQuality = "videoQuality"`
   - `static let videoAudioSource = "videoAudioSource"`
4. Add two computed properties on `Settings` using `d.string(forKey:)` get / `d.set(_:forKey:)` set — identical to `captureBehavior`.
5. `./build.sh` — confirm zero errors before moving on.

---

## Acceptance Criteria

### CPU
- `top -pid $(pgrep m_capture) -l 2 -s 1 -stats pid,cpu,mem` — idle CPU delta < 0.2% vs pre-task baseline.

### Memory
- `leaks $(pgrep m_capture)` — 0 new leaks. No objects allocated at enum definition time.

### UX / Correctness
- `defaults read io.mesoneer.mcapture` shows `videoQuality = high` and `videoAudioSource = system` on first launch.
- Writing `Settings.shared.videoQuality = .medium` persists across app relaunch.
- `VideoQuality.allCases` and `VideoAudioSource.allCases` enumerate in declaration order.
- `./build.sh` compiles clean — zero errors, zero new warnings.

---

## Known Risks

- **Circular dependency:** `Settings.swift` already has a mutual dep with `Background.swift`. Keep new enums fully self-contained — no reference to Background or any other app type.
- **Key string stability:** Lock key strings now (`"videoQuality"`, `"videoAudioSource"`). Changing them later silently resets user preferences.
- **`allCases` order:** SettingsWindow (Task 2) iterates `allCases` to populate pickers. Declare cases in UI-display order: `high → medium → low`, `none → system → mic → both`.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Edit | `Sources/Settings.swift` | Add `VideoQuality` enum, `VideoAudioSource` enum, two Key constants, two computed properties on `Settings` |

No new files. No other files touched.

---

## Out of Scope

- Settings UI (Task 2)
- Any recording or audio capture logic (Tasks 3–5)
- `Info.plist` microphone usage description (Task 5)
- Bitrate lookup tables — a simple linear scale in `bitrate(for:)` is sufficient
