---
title: 'Diagnostics to the unified log'
type: 'chore'
ticket: '4'
created: '2026-10-11'
status: 'built'
baseline_revision: 'e390226c702e8ebdfcd28f03d355490ca60fb0e4'
route: 'oneshot'
route_source: 'auto'
risk: 'low'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/initiative-improve-current-features/epic-reliability-guardrails/epic-reliability-guardrails.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `VideoRecordSession`'s 20 `[VRS]` diagnostics go to stdout via `print(`, which is lost for an app launched from Finder or the Dock, so a recording bug report carries no evidence; and nothing stops new `print(` calls creeping in.

**Approach:** Add one shared app logger (`os.Logger`, subsystem `io.mesoneer.mcapture`, per-area categories) that later epics also use; move the session diagnostics onto it — start/stop/finish/failure at notice (failures at error) with `privacy: .public` on status codes, counts, timings and error descriptions, per-buffer traces at debug; keep `--zoom-benchmark`'s results table on stdout through a small output helper (it is CLI output, not diagnostics — epic decision); and make `./tests/run.sh` fail when `Sources/` contains `print(`.

</frozen-after-approval>

## Implementation Notes

Oneshot: about 80 lines across `VideoRecordSession` (20 call sites), `RecordZoomEngine` (6, the benchmark table), a new logger file and `tests/run.sh` — mechanical, under the 100-line threshold.

- Files: new `Sources/AppLog.swift` (`AppLog.recording`, subsystem `io.mesoneer.mcapture`); `VideoRecordSession.swift` — all 20 `[VRS]` prints moved: writer lifecycle (startWriting OK, resume, stop, finishWriting) at notice, failures (startWriting, writer error after first append, append failed, didStopWithError) at error, per-buffer traces at debug; status codes, counts, timings and error descriptions `.public`; instance properties take explicit `self.` (Logger interpolations are escaping); `RecordZoomEngine.swift` — the benchmark's 6 lines go through a local `out` that writes stdout; `tests/run.sh` — guard rejecting `print(` in `Sources/` (comment lines skipped; `debugPrint(` / `.print(` don't match).
- Verified (sandbox): `./build.sh --ci` exit 0, only the two pre-existing warnings; `./tests/run.sh` 16/16 exit 0; a real `print(` added to a Sources file → exit 1 naming the line; `print(` inside a `//` comment, and `debugPrint(`, → still exit 0.
- Not verifiable here: the sandbox refuses an AppKit process's window-server connection, so neither `--zoom-benchmark`'s stdout table nor a real recording's `log show` output could be run — manual checks for the user (Verification section).

## Verification

**Commands:**
- `./tests/run.sh` -- expected: all checks pass, plus the no-`print(` guard; adding a `print(` to any `Sources/` file makes it exit 1
- `./build.sh --ci` -- expected: exit 0, no new warnings
- `./build.sh --run --simulate` won't exercise the session; after a real recording: `log show --predicate 'subsystem == "io.mesoneer.mcapture"' --last 5m` -- expected: the session's start/stop lines (add `--debug` for per-buffer traces)
- `./build.sh && open build/m_capture.app --args --zoom-benchmark` -- expected: the results table still prints to stdout

## Review Triage Log

Pass 1 (quick lens, 2026-10-11) — 6 findings: high 0, medium 2, low 4, false 0. All patched by the orchestrator (oneshot route), then re-verified: `./build.sh --ci` exit 0 with only the two pre-existing warnings; `./tests/run.sh` 16/16; the guard now rejects `Swift.print(` and `print (` and still passes `debugPrint(`, `// print(` and `blueprint`.

- medium — guard missed `Swift.print(` and `print (` (verified by probe). Patched: the pattern takes `Swift.` and optional whitespace. Its false positive on a code line with a trailing `// print(` comment, or a `/* */` line, is loud and rare, and fixing it means parsing comments, so it was left.
- medium — a failed `finishWriting` (status .failed, no moov atom) logged at notice. Patched: error when `writer.status == .failed`, notice otherwise. The `stop —` line stays notice: it is lifecycle, and the failures it can report are already logged at error where they happen.
- low — `didStopWithError` always at error, though a clean `stopCapture()` triggers it on some macOS versions (per its own comment). Patched: notice when `isStopping`, error otherwise.
- low — a `startCapture` failure (e.g. a reset Screen Recording grant) left no entry. Patched: an error line in its catch. The two `addStreamOutput` throws above it are rarer and still unlogged (pre-existing).
- low — `resume` logged with no matching `pause`. Patched: `pause` logs at notice.
- low — `FileHandle.write(_:)` raises an ObjC exception on EPIPE/EBADF, where `print` ignored the error. Patched: `try? write(contentsOf:)`; dev-only `--zoom-benchmark` path.

