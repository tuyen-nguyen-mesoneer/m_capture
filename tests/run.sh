#!/bin/bash
# Build and run the check suite: the UI-free code in Sources/Core/ plus every tests/*.swift.
# Command Line Tools only — no Xcode, no XCTest. Exits non-zero on a compile error or any
# failing check. A new suite is a new tests/*.swift file (see tests/Harness.swift).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/build/tests"
cd "$DIR"

# Sources/Core/ is the pure seam: build.sh compiles it into the app and this script compiles
# it alone, so it must not reach for UI frameworks (or app types, which fail to compile here).
if grep -nE '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*import[[:space:]]+((class|struct|enum|protocol|typealias|func|var|let)[[:space:]]+)?(AppKit|Cocoa|SwiftUI)\b' Sources/Core/*.swift; then
    echo "!!! Sources/Core/ must stay UI-free — the import(s) above belong in Sources/." >&2
    exit 1
fi

# Diagnostics go to the unified log (Sources/AppLog.swift): stdout is lost for an app launched
# from Finder or the Dock. Comment lines are skipped; `debugPrint(` / `.print(` don't match,
# but `Swift.print(` and `print (` do.
if grep -rnE '(^|[^A-Za-z0-9_.]|Swift\.)print[[:space:]]*\(' --include='*.swift' Sources | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; then
    echo "!!! print( in Sources/ — log through AppLog instead (CLI output: write to stdout explicitly)." >&2
    exit 1
fi

mkdir -p "$OUT"
echo "==> Compiling checks"
# -Onone: the harness counts failures rather than asserting, but checks should run the code
# as written, with nothing optimised away.
swiftc -swift-version 5 -Onone -target "$(uname -m)-apple-macos14.0" \
    -module-name Checks \
    -o "$OUT/run-checks" \
    Sources/Core/*.swift tests/*.swift

echo "==> Running checks"
"$OUT/run-checks"
