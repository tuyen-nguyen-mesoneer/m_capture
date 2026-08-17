#!/bin/bash
# Import the shared 'm_capture-release' code-signing identity into your login keychain.
#
# Why: macOS keys the Screen Recording grant to the signing certificate's SHA-1, not to
# the app's name or path. Ad-hoc signing ("codesign -s -") mints a new identity on every
# build, so every rebuild forces you to re-grant. Importing this one cert means your dev
# builds keep the grant — and share it with the shipped release, since CI signs with the
# same certificate.
#
# The .p12 ships in the repo with an empty password — it guards nothing a reader of the
# repo doesn't already have (see CONTRIBUTING).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
P12="$DIR/certs/m_capture-release.p12"
PASSWORD="${MCAPTURE_CERT_PASSWORD-}"

[ -f "$P12" ] || { echo "!!! Missing $P12" >&2; exit 1; }

if security find-identity -p codesigning 2>/dev/null | grep -q "m_capture-release"; then
    echo "==> 'm_capture-release' is already in your keychain — nothing to do."
    exit 0
fi

echo "==> Importing $P12 (macOS may ask for your login password)"
# -T codesign pre-authorizes codesign to use the key, so builds don't prompt each time.
security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASSWORD" -T /usr/bin/codesign

# The cert is self-signed and therefore untrusted; codesign accepts it anyway. Don't add
# it to the trust store — that would make macOS trust anything signed with it.
echo "==> Done. Verify with: security find-identity -p codesigning"
