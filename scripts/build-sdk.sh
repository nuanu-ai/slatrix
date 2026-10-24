#!/bin/bash
# Builds the patched Matrix Rust SDK for macOS into .build/native-sdk-package.
# Official matrix-rust-components-swift releases ship iOS slices only.
set -euo pipefail

RUSTUP_VERSION=1.29.2
RUSTUP_SHA256=f7c7e11eb2e07f006e532a8aaac77b32f4527d305ac386c0c633ca6133d35ca9
RUST_TOOLCHAIN=1.99.1
SDK_REPO=https://github.com/matrix-org/matrix-rust-sdk.git
SDK_REV=4f7f4d49f571e613eb1cb35956e4649dc056f0af

root=$(cd "$(dirname "$0")/.." && pwd)
patches=$root/Support/MatrixSDK/patches
build=$root/.build
src=$build/native-sdk-src
package=$build/native-sdk-package

stamp=$(cat "$root/scripts/build-sdk.sh" "$patches"/*.patch | shasum -a 256 | cut -d' ' -f1)
if [[ -f $package/.stamp && $(<"$package/.stamp") == "$stamp" ]]; then
    echo "Matrix SDK package is up to date."
    exit 0
fi

# Cargo reads .cargo/config.toml from every ancestor directory; refuse rather than mix it in.
dir=$src
while dir=$(dirname "$dir") && [[ $dir != / ]]; do
    for config in "$dir/.cargo/config" "$dir/.cargo/config.toml"; do
        if [[ -f $config ]]; then
            echo "error: $config would apply to the SDK build; move it aside." >&2
            exit 1
        fi
    done
done

# Private toolchain: no shell profile edits, no user Cargo/Rust environment.
cargo_home=$build/native-cargo
isolated=(env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}"
    PATH="$cargo_home/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    RUSTUP_HOME="$build/native-rustup" CARGO_HOME="$cargo_home" MACOSX_DEPLOYMENT_TARGET=14.0)
if [[ -n ${DEVELOPER_DIR:-} ]]; then isolated+=(DEVELOPER_DIR="$DEVELOPER_DIR"); fi

echo "Building Matrix Rust SDK ${SDK_REV:0:12} (a cold build takes about 10 minutes)"
mkdir -p "$build"
if [[ ! -x $cargo_home/bin/rustup ]]; then
    init=$build/rustup-init
    curl --proto '=https' --tlsv1.2 -fsSL -o "$init" \
        "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/aarch64-apple-darwin/rustup-init"
    echo "$RUSTUP_SHA256  $init" | shasum -a 256 -c -
    chmod +x "$init"
    "${isolated[@]}" "$init" -y --no-modify-path --profile minimal --default-toolchain none
    rm "$init"
fi
"${isolated[@]}" rustup run "$RUST_TOOLCHAIN" rustc --version >/dev/null 2>&1 ||
    "${isolated[@]}" rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --no-self-update

# Reset to the pinned revision and apply the patches whenever either changes.
patch_state="$SDK_REV $(cat "$patches"/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [[ $(cat "$src/.git/slatrix-patches" 2>/dev/null) != "$patch_state" ]]; then
    [[ -d $src/.git ]] || git init -q "$src"
    git -C "$src" cat-file -e "$SDK_REV^{commit}" 2>/dev/null ||
        git -C "$src" fetch -q --depth=1 "$SDK_REPO" "$SDK_REV"
    git -C "$src" checkout -q --force --detach "$SDK_REV"
    git -C "$src" clean -fdq
    for patch in "$patches"/*.patch; do git -C "$src" apply "$patch"; done
    echo "$patch_state" > "$src/.git/slatrix-patches"
fi

# xtask localizes the private SQLite symbols in place, which fails on an
# already-localized archive, so make Cargo relink it.
archive=$src/target/aarch64-apple-darwin/small-release/libmatrix_sdk_ffi.a
rm -f "$archive"
(cd "$src" && "${isolated[@]}" cargo "+$RUST_TOOLCHAIN" xtask swift build-framework --release \
    --target aarch64-apple-darwin --macos-deployment-target 14.0 \
    --stable-toolchain "$RUST_TOOLCHAIN" --skip-xcodebuild)

staging=$package.tmp
slice=$staging/MatrixSDKFFI.xcframework/macos-arm64
rm -rf "$staging"
mkdir -p "$staging/Sources" "$slice"
cp -R "$src/bindings/apple/generated/swift" "$staging/Sources/MatrixRustSDK"
cp -R "$src/bindings/apple/generated/headers" "$slice/Headers"
cp "$archive" "$slice/"
cat > "$staging/MatrixSDKFFI.xcframework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key><string>libmatrix_sdk_ffi.a</string>
            <key>HeadersPath</key><string>Headers</string>
            <key>LibraryIdentifier</key><string>macos-arm64</string>
            <key>LibraryPath</key><string>libmatrix_sdk_ffi.a</string>
            <key>SupportedArchitectures</key><array><string>arm64</string></array>
            <key>SupportedPlatform</key><string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key><string>XFWK</string>
    <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
EOF
cat > "$staging/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MatrixRustSDK",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MatrixRustSDK", targets: ["MatrixRustSDK"])],
    targets: [
        .binaryTarget(name: "MatrixSDKFFI", path: "MatrixSDKFFI.xcframework"),
        .target(name: "MatrixRustSDK", dependencies: ["MatrixSDKFFI"]),
    ]
)
EOF
echo "$stamp" > "$staging/.stamp"

rm -rf "$package.old"
if [[ -d $package ]]; then mv "$package" "$package.old"; fi
mv "$staging" "$package"
rm -rf "$package.old"
echo "Built $package"
