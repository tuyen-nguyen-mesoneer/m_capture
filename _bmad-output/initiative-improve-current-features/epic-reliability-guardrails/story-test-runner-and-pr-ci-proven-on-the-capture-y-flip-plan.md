---
title: 'Test runner and PR CI, proven on the capture Y-flip'
type: 'chore'
ticket: '1'
created: '2026-10-11'
status: 'built'
baseline_revision: 'fee7981dfb7b545c8d888fe5f0c68bd82944c254'
route: 'full'
route_source: 'auto'
risk: 'medium'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/epic-reliability-guardrails.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing in the repo is checked automatically and CI builds only on version tags, so geometry regressions and SDK breaks (#67) surface after release. Entries 1.2–1.4 need a runner and a PR check to add their checks to.

**Approach:** Build the thinnest path through every layer — a CI build mode in `build.sh`, a Command-Line-Tools-only check runner with automatic discovery, one pure function extracted from `ScreenshotController.finish` with one check, and a PR workflow running both — then correct the docs that become false.

## Boundaries & Constraints

**Always:** system frameworks only (Foundation + ObjC runtime for discovery; no XCTest, no Xcode project); the runner fails by counting failures and exiting non-zero, never via `assert`/`precondition` (compiled out under `-O`), and builds with `-Onone`; pure code is UI-free (no AppKit) and compiled by both `build.sh` and the runner; `./build.sh` (no flag) keeps its release-identity guard byte-for-byte in behaviour; `--ci` signs ad-hoc and needs no secrets, keychain or GUI session; capture output is pixel-identical to before.
**Never:** change `release.yml`; move any logic beyond the Y-flip (that is entry 1.2); add the full geometry/layout matrices (1.2/1.3); touch logging (1.4); edit the ticket tree files.

**Decisions (2026-10-11, user delegated):** pure code opts in by living in `Sources/Core/` — `build.sh`, `tests/run.sh` and the shots compile line all compile `Sources/Core/*.swift`, and anything there that imports AppKit fails the runner (the ticket's import-based rule was unworkable: `L10n.swift` and `HomebrewReceipt.swift` match it but need app types). The plan is kept whole at ~2,400 tokens rather than split: the tracer's value is crossing build, runner, code and CI in one pass.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Runner, all pass | `./tests/run.sh` on the branch | Lists each check, prints a pass count, exits 0 | — |
| Runner, a check fails | Y-flip sign inverted | Names the failing check with file:line, exits non-zero | — |
| Runner, compile error | Broken test or pure source | swiftc error shown, exits non-zero | `set -euo pipefail` |
| CI build | `./build.sh --ci` with no signing identity | `build/m_capture.app` ad-hoc signed; no DMG, no relaunch, exit 0 | — |
| Release guard | `./build.sh` with no identity | Unchanged: aborts "WRONG identity", exit 1 | — |
| Flag clash | `--ci` with `--run`/`--simulate`/`--no-simulate` | Aborts with a message, exit 1 | — |
| PR | Any PR against `trunk` | Workflow builds + runs checks; red on compile or check failure | — |

</frozen-after-approval>

## Code Map

- `build.sh` -- flags parsed at 21-40; `rm -rf "$BUILD"` at 42; swiftc compiles `"$DIR"/Sources/*.swift` at 50-53 (non-recursive); signing block 130-162 (`RUN=1` → ad-hoc fallback; else release guard 151-160); relaunch 164-193; DMG 195-209. `--ci`: like the `--run` signing path but always `-`, skip `MCAutoInstall` (59-61), exit after `codesign` before relaunch/DMG.
- `.github/workflows/release.yml` -- reference only: `runs-on: macos-15` (needs 15.2+ SDK for `SCScreenshotManager.captureImage(in:)`), `actions/checkout@v4`. Do not edit.
- `Sources/ScreenshotController.swift:636-638` -- `let sourceRect = CGRect(x: viewRect.minX, y: screen.frame.height - viewRect.maxY, …)` inside `finish(viewRect:screen:showsCursor:)`; replace with the pure call. Leave `global` (622-624), `crop` (522) and everything else for 1.2.
- `Sources/L10n.swift`, `Sources/HomebrewReceipt.swift` -- import only Foundation yet depend on `Settings.shared` / `Bundle.main`; they do NOT compile standalone, which is why pure code lives in `Sources/Core/` instead of being picked by imports.
- `tools/shots.swift` compile line in `CONTRIBUTING.md:153-154` -- `$(ls Sources/*.swift | grep -v main.swift)`; must also compile `Sources/Core/*.swift`.
- `CONTRIBUTING.md` -- Testing (136-155) says "No automated suite"; Pull requests (178-184) step 2. `CLAUDE.md:22` "No automated tests; smoke-test by hand." and the source map (add `Sources/Core/` + `tests/`).
- Local verification in the Claude sandbox needs `-module-cache-path "$TMPDIR/swift-mc"` for swiftc; not needed on a normal shell or CI.

## Tasks & Acceptance

**Execution:**
- [x] `build.sh` -- add `--ci` (compile, fonts, plist, icon, ad-hoc sign; no `MCAutoInstall`, no identity check, no relaunch, no DMG; reject with `--run`/`--simulate`/`--no-simulate`); compile `Sources/Core/*.swift` too -- CI cannot hold the release cert
- [x] `Sources/Core/CaptureGeometry.swift` -- `enum CaptureGeometry` with `static func sourceRect(viewRect: CGRect, displayHeight: CGFloat) -> CGRect` (Foundation/CoreGraphics only, `///` doc on why the flip exists) -- the first pure seam 1.2 grows
- [x] `Sources/ScreenshotController.swift` -- call `CaptureGeometry.sourceRect(viewRect:displayHeight: screen.frame.height)` at 636 -- behaviour unchanged
- [x] `tests/Harness.swift` -- `class CheckSuite: NSObject` (required init); discovery enumerates `objc_getClassList` for direct subclasses and runs every instance method whose selector starts with `check`; `expect(_:_:file:line:)` records failures; summary + exit code -- adding a suite is adding a file
- [x] `tests/main.swift` -- calls the harness and exits with its status
- [x] `tests/CaptureGeometryChecks.swift` -- `CheckSuite` subclass: top/bottom/full-height regions on a 900-pt display map to the expected top-left-origin rects
- [x] `tests/run.sh` -- `set -euo pipefail`; `swiftc -swift-version 5 -Onone -target "$(uname -m)-apple-macos14.0"` over `Sources/Core/*.swift` + `tests/*.swift` into `build/tests/run-checks`, then run it -- one local command
- [x] `.github/workflows/checks.yml` -- `pull_request` (and `push` to `trunk`), `permissions: contents: read`, `macos-15`, checkout, `./build.sh --ci`, `./tests/run.sh`; job name stable for branch protection
- [x] `CONTRIBUTING.md` -- Testing: the command, what it checks, how to add a suite, that PRs run it; PR rules step 2 adds `./tests/run.sh`; shots compile line includes `Sources/Core/*.swift`
- [x] `CLAUDE.md` -- replace "No automated tests" with the runner + PR check; source-map entries for `Sources/Core/` (UI-free, runner-checked) and `tests/`

**Acceptance Criteria:**
- Given a clean checkout with only Command Line Tools, when `./tests/run.sh` runs, then it reports the geometry checks passed and exits 0.
- Given the Y-flip sign inverted in `CaptureGeometry`, when `./tests/run.sh` runs, then it names the failing check and exits non-zero.
- Given no `m_capture-release` identity, when `./build.sh --ci` runs, then `build/m_capture.app` exists, `codesign -dv` shows an ad-hoc signature, and no DMG is written; and plain `./build.sh` still aborts with the WRONG-identity message.
- Given a PR against `trunk`, when the workflow runs, then it goes green on this branch and red for a compile error or a failing check.
- Given the app built with `./build.sh --run`, when a region is captured on each of two displays, then the captures match pre-change ones.
- (hitl) Given the workflow has run once, when a repo admin marks its job required on `trunk`, then a red run blocks merge.

## Implementation Notes

- Implemented by a fresh subagent from this plan; files: `build.sh`, `Sources/Core/CaptureGeometry.swift`, `Sources/ScreenshotController.swift`, `tests/{Harness,main,CaptureGeometryChecks}.swift`, `tests/run.sh`, `.github/workflows/checks.yml`, `CONTRIBUTING.md`, `CLAUDE.md`, plus one comment line in `tools/shots.swift` (its build comment would otherwise go stale).
- Beyond the plan: the harness fails when no suites exist or a suite has no `@objc` checks (Swift 5 doesn't expose methods to the runtime on its own, so a forgotten `@objc` would pass silently); `run.sh` greps `Sources/Core` for AppKit/Cocoa/SwiftUI imports, because swiftc autolinks frameworks and a compile alone wouldn't reject them; the build.sh variable is `CI_BUILD`, not `CI`, to avoid shadowing GitHub's `CI` env var; failures also print `::error` annotations under GitHub Actions.
- Matrix verified by the orchestrator, not just the implementer (2026-10-11, sandbox with `CLANG_MODULE_CACHE_PATH`): all-pass 3/3 exit 0; flip inverted → the two non-symmetric checks fail, exit 1 (full-height passes either way, as it should); AppKit import in Core → exit 1; `--ci --run` → exit 1; `--ci` → exit 0, `Signature=adhoc`, no `MCAutoInstall`, no DMG; plain `./build.sh` with `security` stubbed to list no identities → "WRONG identity (ad-hoc)", exit 1, no DMG.
- Not yet verified: the PR row (needs a push — no remote ops in this step), the two-display capture comparison (manual), and the hitl required-check step.

## Plan Change Log

## Review Triage Log

Pass 1 (quick lens, 2026-10-11) — 10 findings: high 0, medium 0, low 7, false 1, maybe-false 0; 2 not code defects folded below.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | Three ACs unverified (PR run, two-display capture, required check) | false | rejected | Not a defect in the diff: they need a push, a manual capture and an admin step, already recorded in Implementation Notes and carried to step 5. |
| 2 | `precondition` claimed compiled out under `-O` (Harness.swift doc, CLAUDE.md `tests/` entry) | low | defer | True — only `assert` is removed at `-O`; `precondition` survives until `-Ounchecked`. One root cause in two places; the fix edits CLAUDE.md, so deferred per the agent-context rule. |
| 3 | CLAUDE.md multi-monitor gotcha + ScreenshotController map entry still place the flip in `finish` | low | defer | True — the flip now lives in `Sources/Core/CaptureGeometry.swift`. Fix edits CLAUDE.md → deferred; entry 1.2 already owns correcting that gotcha. |
| 4 | `run.sh` UI-import guard misses `import class AppKit.NSView` | low | patch | Confirmed: the regex does not match that line, and swiftc autolinks AppKit, so it compiles. Direct regex correction. |
| 5 | Intermediate base class breaks discovery | low | rejected | Real but loud (run goes red, message blames the base); CONTRIBUTING says subclass `CheckSuite` directly; shared fixtures can be helpers. Fix adds traversal and branching. |
| 6 | `@objc` helper named `check…` runs as a check; arg-taking checks dropped | low | rejected | Real but unlikely — helpers need not be `@objc`, and checks take no arguments by convention; fix adds branches. |
| 7 | `::error` annotation text not escaped | low | rejected | Real for messages with `%`/newlines; current messages interpolate `CGRect` descriptions (no `%`, no newline) and the plain `FAIL` line is unaffected; fix adds an escaping helper. |
| 8 | `cancel-in-progress` cancels trunk push runs | low | patch | Confirmed in checks.yml: group keys on `github.ref`, cancel unconditional. One-line conditional. |
| 9 | No `timeout-minutes` (360-min default) | low | patch | Confirmed absent. One line. |
| 10 | CONTRIBUTING says PRs "against `trunk`"; workflow has no branch filter | low | patch | Confirmed (CONTRIBUTING.md:158). Doc wording; workflow trigger kept (runs on stacked PRs too). |

Patches 4, 8, 9, 10 applied by the implementer and re-verified by the orchestrator: runner 3/3 exit 0; `import class AppKit.NSView` in Core → exit 1; `--ci` ad-hoc, no DMG; release guard still aborts. Residual on 8 (noted, not patched): GitHub keeps one running + one pending run per concurrency group, so with three trunk merges inside one run's duration the middle commit's pending run is superseded; each was already checked on its PR, so accepted.

## Design Notes

ObjC-runtime discovery mirrors XCTest without needing it: suites are `NSObject` subclasses, so a new file is found with no list to edit — the parallel stories 1.2–1.4 each add a suite file and never collide. Golden shape:

```swift
final class CaptureGeometryChecks: CheckSuite {
    @objc func checkTopRegionFlipsToTopLeftOrigin() {
        let r = CaptureGeometry.sourceRect(viewRect: CGRect(x: 10, y: 800, width: 100, height: 50), displayHeight: 900)
        expect(r == CGRect(x: 10, y: 50, width: 100, height: 50), "top region → y=50")
    }
}
```

## Verification

**Commands:**
- `./tests/run.sh` -- expected: all checks pass, exit 0
- `./build.sh --ci && codesign -dv build/m_capture.app 2>&1 | grep -i 'Signature=adhoc'` -- expected: match, no `m_capture.dmg` created by this run
- `./build.sh` (without the release identity) -- expected: exit 1 with the WRONG-identity message

**Manual checks (if no CLI):**
- `./build.sh --run`, capture a region on each display; compare with captures from `trunk`.
