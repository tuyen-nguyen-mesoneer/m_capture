# FIP-8: Full Integration Verify + KNOWLEDGE_GRAPH Update

## Context

All seven implementation tasks are complete. This task has no new code to write — it is a structured verification pass across the entire feature, followed by updating the knowledge graph so future agents have an accurate map of the codebase.

A feature is not done until it is documented. Any agent picking up the next feature must be able to navigate `KNOWLEDGE_GRAPH.md` and understand how video recording fits into the existing architecture.

**How to verify:** Run the full QA checklist below manually, fix any failures before proceeding, then update `.claude/knowledge/KNOWLEDGE_GRAPH.md`.

---

## What to Build

No source code. Two deliverables:

1. **A signed-off QA checklist** — every item below checked ✓ or a bug filed.
2. **Updated `.claude/knowledge/KNOWLEDGE_GRAPH.md`** — three new sections added (new types, new data flow, updated extension points).

---

## Implementation Direction

### Step 1 — Build clean
```sh
./build.sh
# Must exit 0 with zero errors and zero new warnings.
```

### Step 2 — CPU baseline
```sh
open build/m_capture.app
top -pid $(pgrep m_capture) -l 4 -s 1 -stats pid,cpu,mem
# Idle CPU must be < 1% above pre-feature baseline.
```

### Step 3 — Record region flow
1. Press ⌃⇧R → overlay appears (< 200 ms).
2. Drag a region on the primary display.
3. Bar appears (< 500 ms); timer counts from 00:00:00.
4. Let it run for 30 seconds.
5. Click Stop.
6. File appears in save directory; capture sound plays.
7. Check: `mdls -name kMDItemCodecs <file>` → `HEVC`.
8. Check file size: Medium quality 30s 1080p < 15 MB.
9. Open in QuickTime: plays correctly, no corruption.

### Step 4 — Record full-screen flow
1. Press ⌃⇧R → overlay appears.
2. Press Space → full-screen border appears; hint label visible.
3. Click → bar appears; record 10 seconds; Stop.
4. Verify file as above.

### Step 5 — Pause / resume
1. Start a recording.
2. Click Pause: timer freezes, `●` animation stops, file size stops growing.
3. Click Resume: timer resumes, animation restarts.
4. Stop: file is valid and continuous (no gap artefact in QuickTime).

### Step 6 — Audio sources (repeat for each)
| Setting | Verification |
|---------|-------------|
| None | `mediainfo <file>` or QuickTime audio track inspector shows no audio track |
| System | Audio track present; plays system sounds recorded during clip |
| Mic | Audio track present; voice recorded (speak during clip) |
| Both | Audio track present; both system + voice audible |

### Step 7 — Regression: existing features
- ⌃⇧X: screenshot still works end-to-end (overlay → editor → save).
- Settings panel: all existing pickers still save/restore.
- Hotkey rebinding: rebind ⌃⇧R to another combination; verify new combo triggers recording.

### Step 8 — Memory / leaks
```sh
# After 3 full record cycles (region → stop → full-screen → stop → region → stop):
leaks $(pgrep m_capture)
# Must report 0 leaks.
# RSS via top must not have grown cumulatively.
```

### Step 9 — Quality size comparison
Record identical 30-second 1080p clip at all three quality settings:
| Quality | Expected max size |
|---------|------------------|
| High | < 30 MB |
| Medium | < 15 MB |
| Low | < 8 MB |
High must be larger than Medium, Medium larger than Low.

### Step 10 — KNOWLEDGE_GRAPH update
Add to `.claude/knowledge/KNOWLEDGE_GRAPH.md`:

**File Catalogue** — add three new rows:
- `VideoRecordSession.swift` — core engine
- `VideoRecordBar.swift` — floating HUD
- `VideoRecordController.swift` — singleton orchestrator

**Type Catalogue** — add entries for all new public types.

**Dependency Matrix** — update: `VideoRecordController` depends on `Settings`, `SelectionOverlay`, `VideoRecordSession`, `VideoRecordBar`.

**Data Flows** — add Flow 5: Video Recording (mirror the structure of Flow 1 and 2).

**Extension Points** — add: "Adding a new post-recording action" and "Replacing the HEVC codec".

---

## Acceptance Criteria

### CPU
- Sustained 30-second recording at Medium: < 12% Apple Silicon.
- Idle after stop: < 1% within 5 seconds.

### Memory
- 3 full cycles: zero cumulative RSS growth.
- `leaks`: 0 leaks.

### UX Checklist (all must be ✓ before sign-off)
- [ ] ⌃⇧R → region select → record → stop → HEVC .mp4 saved
- [ ] ⌃⇧R → Space (full-screen) → click → record → stop → HEVC .mp4 saved
- [ ] Pause freezes timer and file size; resume continues correctly
- [ ] Audio: None → no audio track
- [ ] Audio: System → audio track present
- [ ] Audio: Mic → audio track present
- [ ] Audio: Both → audio track present
- [ ] Quality sizes: High > Medium > Low for same clip duration
- [ ] All outputs pass `mdls -name kMDItemCodecs` → `HEVC`
- [ ] ⌃⇧X screenshot: no regression
- [ ] Settings Video pickers save/restore across relaunch
- [ ] Hotkey rebinding works for ⌃⇧R
- [ ] `./build.sh` exits 0, zero warnings
- [ ] `KNOWLEDGE_GRAPH.md` updated with all new types, flow, extension points

---

## Known Risks

- **Audio permission dialog** appears on first run with Mic or Both. This is expected and correct; the checklist step must be run on a machine where permission has not been pre-granted, to verify the prompt appears.
- **QA environment differences:** The CPU thresholds assume Apple Silicon. On Intel, allow up to 25% during recording. Document the test machine in the sign-off.
- **QuickTime audio track inspector** may not distinguish system vs mic audio by source. Use `mediainfo` CLI (`brew install mediainfo`) for authoritative track inspection.

---

## Files To Create / Edit

| Action | File | Change |
|--------|------|--------|
| Edit | `.claude/knowledge/KNOWLEDGE_GRAPH.md` | Add new files, types, dependency entries, Flow 5, updated extension points |

No source code changes. If any QA step fails, fixes go back to the relevant task (1–7), not here.

---

## Out of Scope

- New features or UX changes discovered during testing — file as separate issues
- Performance optimisation beyond the thresholds above
- Distribution / notarisation / DMG changes
- Any change to existing screenshot capture code
