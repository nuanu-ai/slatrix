#!/bin/bash
# One-time setup of the key Sparkle checks updates against, run by the owner on the Mac that ships releases.
# Creates (or reuses) the EdDSA key pair in the login keychain, writes the public key into Config/Info.plist for
# you to commit. scripts/release.sh signs updates with the private key from the keychain, which never leaves it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
swift package "${swift_args[@]}" resolve >/dev/null
keys=(.build/slatrix-spm/artifacts/sparkle/Sparkle/bin/generate_keys --account ai.nuanu.slatrix)
"${keys[@]}" >/dev/null # generates the pair on the first run, reuses it after
public=$("${keys[@]}" -p)

# A different key would strand every installed copy, so never replace one.
if current=$(plutil -extract SUPublicEDKey raw Config/Info.plist 2>/dev/null); then
    if [[ $current != "$public" ]]; then
        echo "error: Config/Info.plist has a different SUPublicEDKey than this Mac's keychain." >&2
        exit 1
    fi
else
    sed -i '' "s|^\(    <key>SUFeedURL</key>.*\)$|\1\\
    <key>SUPublicEDKey</key><string>$public</string>|" Config/Info.plist
fi
echo "Commit Config/Info.plist, which now holds the public key."
