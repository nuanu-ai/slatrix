#!/bin/bash
# Builds build/Slatrix.app. Signs ad hoc unless SLATRIX_SIGN_IDENTITY names a
# real identity (e.g. "Developer ID Application: ..."), which also enables the
# hardened runtime. SLATRIX_VERSION (e.g. 1.2.3) stamps the bundle version.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

scripts/build-sdk.sh
swift build "${swift_args[@]}" -c release --product Slatrix
bin=$(swift build "${swift_args[@]}" -c release --show-bin-path)

app=build/Slatrix.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Slatrix" "$app/Contents/MacOS/"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Slatrix"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp Config/Info.plist "$app/Contents/"
if [[ -n ${SLATRIX_VERSION:-} ]]; then
    plutil -replace CFBundleShortVersionString -string "$SLATRIX_VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$SLATRIX_VERSION" "$app/Contents/Info.plist"
fi
cp Config/Slatrix.icns "$app/Contents/Resources/"
shopt -s nullglob
for bundle in "$bin"/*.bundle; do
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done

identity=${SLATRIX_SIGN_IDENTITY:--}
sign() {
    if [[ $identity == - ]]; then
        codesign --force --sign - "$@"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$@"
    fi
}
# Inside out, as Sparkle documents: its helpers, the framework, then the app.
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
