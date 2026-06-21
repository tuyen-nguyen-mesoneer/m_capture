#!/usr/bin/env sh
# Preview the GitHub Pages landing site (docs/) locally.
# Serve from docs/ so the relative asset/font paths resolve (file:// can't).
# Usage: ./serve.sh [port]   — default 8000
port="${1:-8000}"
echo "Serving docs/ at http://localhost:$port  (Ctrl+C to stop)"
echo "Force a locale with ?lang=en or ?lang=de"
exec python3 -m http.server "$port" --directory docs
