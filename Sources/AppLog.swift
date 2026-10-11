import os

/// The app's diagnostics, in the unified log under the bundle id — stdout is lost for an app
/// launched from Finder or the Dock, so this is the only place a recording's trail survives
/// for a bug report (`log show --predicate 'subsystem == "io.mesoneer.mcapture"'`, plus
/// `--debug` for per-buffer traces). One `Logger` per area; log through these, never
/// `print(` — `tests/run.sh` rejects it. Values interpolated as `.public` are status codes,
/// counts, timings and error descriptions; anything a user typed or captured stays private.
enum AppLog {
    private static let subsystem = "io.mesoneer.mcapture"

    /// The recording session: writer lifecycle, PTS normalisation, dropped or failed buffers.
    static let recording = Logger(subsystem: subsystem, category: "recording")
}
