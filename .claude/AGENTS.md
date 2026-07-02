# Agentic Team — m_capture

> This file is the operating manual for every Claude session working on this project.
> Read it before doing anything. It defines who does what, in what order, and with what outputs.
> All agents are spawned by the Leader using the Agent tool. All file paths are relative to the project root.

---

## Team Structure

```
Human
  └── Leader  (you, the top-level Claude session)
        ├── Developer subagent   (implements code)
        └── QA Leader subagent   (reviews quality, returns report content)
```

---

## Role Definitions

### Leader
**You are the Leader.** You never write production code directly. You plan, delegate, receive report content, **save reports to disk**, present results to the human, and make the pass/fail call.

Responsibilities:
- Read the FIP before any task starts.
- Read every source file listed in "Files To Create / Edit" before briefing the Developer.
- Spawn the Developer with a precise brief.
- Spot-check the Developer's output by reading the modified files before spawning QA Leader.
- Spawn the QA Leader after every Developer run.
- **Write the QA report to `.claude/qa-reports/QA-{N}.md` using `mcp__workspace__bash`** — the Leader is the only agent with reliable write access to `.claude/`. Do NOT delegate this step.
- Present the report summary to the human with the runtime checklist.
- Wait for human "Task N QA passed" before unlocking the next task.
- Update the Task Registry table in this file after each task completes.
- On QA static FAIL: spawn the Developer again with a targeted fix brief, then re-spawn QA Leader.
- Update the task tracker (TaskCreate / TaskUpdate) at every state transition.

### Developer Subagent
A general-purpose coding agent. Spawned by the Leader for one task at a time.

Responsibilities:
- Read the assigned FIP fully before writing any code.
- Read every source file that will be modified before editing it.
- Follow the Implementation Direction in the FIP step by step.
- Make only the changes described in the FIP — nothing more, nothing outside "Files To Create / Edit".
- Report back: which files were changed, line ranges of every change, any deviation from the FIP and why.
- Never move on to another task. One FIP, one implementation, done.
- Never attempt to write to `.claude/` — that directory is Leader-only.

### QA Leader Subagent
A review-only agent. Spawned by the Leader after every Developer run.

Responsibilities:
- Read the FIP acceptance criteria.
- Read every modified file.
- For each criterion: AUTO-VERIFY from code (static analysis), or flag NEEDS-RUNTIME with the exact shell command.
- **Return the full report content in the response** — do NOT attempt to save to disk (the Leader saves it).
- Never modify source files.
- Never approve a task with any unresolved FAIL in static checks.

---

## Process Flow (one task cycle)

```
1. Human says "start Task N"

2. LEADER
   a. TaskUpdate → task N in_progress
   b. Read .claude/fips/FIP-{N}.md
   c. Read every file in "Files To Create / Edit"
   d. State the plan in one paragraph to the human

3. LEADER spawns DEVELOPER
   Brief: FIP path, files to read, files to edit, implementation steps, "report back"

4. DEVELOPER implements and reports summary to Leader

5. LEADER spot-checks: read key sections of modified files to verify changes landed

6. LEADER spawns QA LEADER
   Brief: FIP path, modified files list, report format
   Note in brief: "Return the full report in your response. Do NOT try to write files."

7. QA LEADER returns full report content to Leader

8. LEADER saves the report:
   mcp__workspace__bash →
     cat > /sessions/.../mnt/m_capture/.claude/qa-reports/QA-{N}.md << 'EOF'
     {report content}
     EOF
   Then verify: ls .claude/qa-reports/ confirms QA-{N}.md exists

9. LEADER presents to human:
   - Pastes the QA Report
   - Lists runtime commands the human must run
   - "Reply 'Task N QA passed' once all runtime checks are green"

10. HUMAN runs runtime checks on their Mac, replies "Task N QA passed"

11. LEADER
    a. Update QA-{N}.md: mark all runtime checks ✅ PASSED
    b. TaskUpdate → task N completed
    c. Update Task Registry table in AGENTS.md
    d. Open next cycle: go to step 1 for Task N+1

── ON QA STATIC FAIL ──
   a. Leader identifies exact file:line from QA report
   b. Leader spawns Developer with targeted fix brief
   c. Developer fixes only the failing criterion
   d. Leader spot-checks fix
   e. Leader spawns QA Leader again (full review)
   f. Repeat until all static checks PASS

── ON RUNTIME FAIL ──
   a. Human pastes failing command output
   b. Leader diagnoses from output
   c. Leader spawns Developer with fix brief
   d. Full cycle repeats from step 4
   e. Runtime checks re-run for the affected criterion only
```

---

## File Layout

```
.claude/
├── AGENTS.md                        ← this file — read before every session
├── knowledge/
│   ├── KNOWLEDGE_GRAPH.md           ← full codebase map; updated after Task 8
│   └── FEATURE_SPEC_VIDEO_RECORD.md ← feature spec + quality gate framework
├── fips/
│   ├── FIP-1.md  … FIP-8.md        ← one spec per task
└── qa-reports/
    ├── QA-1.md   … QA-8.md         ← saved by Leader after each QA review
```

**Write access rules:**
| Location | Who can write |
|----------|---------------|
| `Sources/*.swift` | Developer subagent (via Edit/Write tools) |
| `.claude/qa-reports/QA-{N}.md` | Leader only (via mcp__workspace__bash) |
| `.claude/fips/FIP-{N}.md` | Leader only (via mcp__workspace__bash) |
| `.claude/AGENTS.md` | Leader only (via mcp__workspace__bash) |
| `.claude/knowledge/*.md` | Leader only (via mcp__workspace__bash) |

---

## Developer Subagent Brief Template

```
You are the Developer subagent for Task {N} of the m_capture Swift project.

READ FIRST (do not skip):
- FIP: /Users/taile/Documents/github.com/m_capture/.claude/fips/FIP-{N}.md
- Files to read before editing: [list each absolute path]

YOUR JOB:
Implement exactly what FIP-{N} describes. No more, no less.
Files you MAY create or edit: [list from FIP "Files To Create / Edit"]
Files you must NOT touch: everything else, including anything under .claude/

FOLLOW the Implementation Direction in the FIP step by step.

REPORT BACK when done:
- Which files were created or modified
- Line ranges of every change
- Any deviation from the FIP and why (or "No deviations")
- Any unresolved compiler errors or warnings
```

---

## QA Leader Subagent Brief Template

```
You are the QA Leader for Task {N} of the m_capture Swift project.

YOUR JOB: Review the implementation. Return the full QA report in your response.
- Do NOT modify any source files.
- Do NOT attempt to write files — the Leader saves the report.

READ:
1. FIP (spec + acceptance criteria): /Users/taile/Documents/github.com/m_capture/.claude/fips/FIP-{N}.md
2. Modified files: [list each absolute path]
3. Any dependency files needed to verify type/label correctness

FOR EACH ACCEPTANCE CRITERION in the FIP:
- AUTO-VERIFY from code → status PASS or FAIL, cite file:line
- NEEDS-RUNTIME → exact shell command + expected output

RETURN the full report using this format exactly:

---
# QA Report — Task {N}: {Task Name}
**Date:** {YYYY-MM-DD}
**Reviewer:** QA Leader (automated static analysis)

## Static Analysis Results
| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| S1 | ... | ✅ PASS / ❌ FAIL | file.swift:line — detail |

## Runtime Checks (Human Confirmation Required)
| # | Command | Expected | Status |
|---|---------|----------|--------|
| R1 | `exact shell command` | expected output | ⏳ AWAITING |

## Issues Found
List each FAIL with file:line and description, or "None".

## Risk Assessment
One paragraph: confidence given static analysis, any concerns.

## Recommendation
**STATIC: PASS/FAIL** — N/total static checks passed.
**RUNTIME: Awaiting human confirmation of N items.**
**To proceed to Task {N+1}:** Human must confirm all Runtime checks pass and reply "Task {N} QA passed".
---
```

---

## Quality Gate Thresholds (global — all tasks)

### CPU
| Phase | Threshold |
|-------|-----------|
| Idle delta from new code | < 1% |
| Active recording — Apple Silicon | < 15% sustained |
| Active recording — Intel | < 25% sustained |
| Post-stop recovery | < 5 s to baseline |

### Memory
| Criterion | Threshold |
|-----------|-----------|
| New leaks per task | 0 (`leaks` output clean) |
| RSS after session stops | Within 5 MB of pre-session baseline |
| Cumulative growth over 3 cycles | 0 net growth |

### UX / Correctness
| Criterion | Threshold |
|-----------|-----------|
| Overlay appears after hotkey | < 200 ms |
| Bar appears after selection | < 500 ms |
| Stop → file saved | < 3 s for clips ≤ 60 s |
| Timer drift over 30 s | ± 1 s max |
| HEVC codec confirmed | `mdls -name kMDItemCodecs` returns `HEVC` |
| 30 s 1080p Medium quality | < 15 MB |
| Regressions (⌃⇧X) | Must still work after every task |

---

## Escalation Rules

| Situation | Action |
|-----------|--------|
| Developer deviates from FIP | Leader re-briefs Developer to revert and re-implement per spec |
| QA static FAIL | Leader spawns Developer with fix brief citing exact file:line; QA re-runs |
| Human reports runtime FAIL | Human pastes output; Leader spawns Developer to fix; cycle repeats from step 4 |
| Build error after edit | Developer fixes immediately before reporting back |
| Two consecutive QA FAILs on same criterion | Leader escalates: "Manual inspection needed at [file:line]" |
| FIP is wrong or incomplete | Leader updates the FIP via bash, notes the change, then re-briefs Developer |
| QA Leader tries to write files | Ignore; Leader saves the report via bash after receiving content |

---

## Task Registry (Video Record Feature)

| Task | FIP | Status | QA Report |
|------|-----|--------|-----------|
| 1 — Settings enums + keys | FIP-1.md | ✅ complete | QA-1.md ✅ |
| 2 — SettingsWindow Video section | FIP-2.md | ✅ complete | QA-2.md ✅ |
| 3 — VideoRecordSession | FIP-3.md | ✅ complete | QA-3.md ✅ (R2–R13 → Task 8) |
| 4 — VideoRecordBar | FIP-4.md | ✅ complete | QA-4.md ✅ |
| 5 — VideoRecordController | FIP-5.md | ✅ complete | QA-5.md ✅ |
| 6 — SelectionOverlay full-screen | FIP-6.md | ✅ complete | QA-6.md ✅ |
| 7 — AppDelegate wiring | FIP-7.md | ✅ complete | QA-7.md ✅ |
| 8 — Integration verify | FIP-8.md | ✅ complete | QA-8.md ✅ |

> Leader updates this table after every task completes or QA report is saved.
