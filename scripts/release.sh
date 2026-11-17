#!/bin/bash
# Ships an annotated tag like v1.2.3 from this Mac, as a GitHub release Sparkle installs: signs the app with the
# keychain's Developer ID, has Apple notarize it, signs the update with the Sparkle key in the keychain, and
# publishes the zip and appcast.xml. The tag message becomes the release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

tag=${1:-}
version=$(scripts/version-from-tag.sh "$tag")
if [[ $(git rev-parse --abbrev-ref HEAD) != main || -n $(git status --porcelain) ]]; then
    echo "error: release from a clean main, so the app matches the tag" >&2
    exit 1
fi
git fetch -q origin main
if [[ $(git cat-file -t "$tag" 2>/dev/null) != tag || $(git rev-list -n 1 "$tag") != $(git rev-parse origin/main) ]]; then
    echo "error: $tag must be an annotated tag on origin/main" >&2
    exit 1
fi

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -z $identity ]]; then
    echo "error: no Developer ID Application certificate in the keychain" >&2
    exit 1
fi
# The team's notarytool profile, made once with `xcrun notarytool store-credentials`; Git Sight ships with it too.
profile=${SLATRIX_NOTARY_PROFILE:-git-sight}

SLATRIX_VERSION=$version SLATRIX_SIGN_IDENTITY=$identity scripts/build-app.sh
app=build/Slatrix.app
release=build/release
rm -rf "$release"
mkdir -p "$release"

# Apple checks the signed app and issues a ticket; stapling it lets Gatekeeper open a first download offline.
# A rejected app has no ticket, so stapler stops the release.
ditto -c -k --keepParent "$app" "$release/notarize.zip"
xcrun notarytool submit "$release/notarize.zip" --keychain-profile "$profile" --wait
rm "$release/notarize.zip"
xcrun stapler staple "$app"
spctl --assess --type execute "$app"

zip=$release/Slatrix-$version.zip
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
# generate_appcast embeds the Markdown file named like the archive as the update's release notes.
notes=$release/Slatrix-$version.md
git tag -l --format='%(contents:subject)%0a%0a%(contents:body)' "$tag" > "$notes"
repo=$(gh repo view --json url -q .url)
.build/slatrix-spm/artifacts/sparkle/Sparkle/bin/generate_appcast --account ai.nuanu.slatrix --embed-release-notes \
    --download-url-prefix "$repo/releases/download/$tag/" -o "$release/appcast.xml" "$release"
# generate_appcast only warns when it can't sign, and leaves the update unsigned.
if ! grep -q 'sparkle:edSignature=' "$release/appcast.xml"; then
    echo "error: the update is unsigned; is the Sparkle key from scripts/setup-update-key.sh in this keychain?" >&2
    exit 1
fi

git push -q origin "$tag"
gh release create "$tag" "$zip" "$release/appcast.xml" --verify-tag --title "Slatrix $version" --notes-file "$notes"
