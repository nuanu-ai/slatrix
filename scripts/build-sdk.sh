#!/bin/bash
# Puts the patched Matrix Rust SDK for macOS into .build/native-sdk-package, or with --android the Kotlin bindings and
# Android libraries into .build/native-sdk-android: downloads the prebuilt package that .github/workflows/sdk.yml
# publishes for this pin and these patches, or builds it from source when there is none (or SLATRIX_SDK_FROM_SOURCE=1).
# Official matrix-rust-components-swift releases ship iOS slices only, and the Kotlin ones lack our patches.
# --key prints the package key instead.
set -euo pipefail

# Bump when a change here alters the built package, so it gets a new key.
SDK_PACKAGE_FORMAT=1
ANDROID_PACKAGE_FORMAT=1
RUSTUP_VERSION=1.29.2
RUSTUP_SHA256_MACOS=f7c7e11eb2e07f006e532a8aaac77b32f4527d305ac386c0c633ca6133d35ca9
RUSTUP_SHA256_LINUX=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
RUST_TOOLCHAIN=1.99.1
SDK_REPO=https://github.com/matrix-org/matrix-rust-sdk.git
SDK_REV=4f7f4d49f571e613eb1cb35956e4649dc056f0af
# The macOS build's features (FFI_FEATURES in xtask/src/swift.rs), so both apps run the same SDK.
FFI_FEATURES=sentry
ANDROID_NDK_VERSION=29.0.14206865
ANDROID_MIN_SDK=24
CARGO_NDK_VERSION=4.1.2

android='' key=''
for arg in "$@"; do
    case $arg in
        --android) android=1 ;;
        --key) key=1 ;;
        *)
            echo "usage: $0 [--android] [--key]" >&2
            exit 2
            ;;
    esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
patches=$root/Support/MatrixSDK/patches
build=$root/.build
src=$build/native-sdk-src
if [[ -n $android ]]; then
    format="android $ANDROID_PACKAGE_FORMAT $FFI_FEATURES $ANDROID_NDK_VERSION $ANDROID_MIN_SDK $CARGO_NDK_VERSION"
    package=$build/native-sdk-android
    release='sdk-android'
    asset=MatrixRustSDK-android.tar.gz
else
    format=$SDK_PACKAGE_FORMAT
    package=$build/native-sdk-package
    release=sdk
    asset=MatrixRustSDK.tar.gz
fi

stamp=$({ printf '%s\n' "$SDK_REV" "$RUST_TOOLCHAIN" "$format"; cat "$patches"/*.patch; } |
    shasum -a 256 | cut -c1-16)
if [[ -n $key ]]; then
    echo "$stamp"
    exit 0
fi
if [[ -f $package/.stamp && $(<"$package/.stamp") == "$stamp" ]]; then
    echo "Matrix SDK package is up to date."
    exit 0
fi

install() { # moves a complete package from $1 into place
    rm -rf "$package.old"
    if [[ -d $package ]]; then mv "$package" "$package.old"; fi
    mv "$1" "$package"
    rm -rf "$package.old"
}
finish() { # stamps the built package and installs it
    echo "$stamp" > "$staging/.stamp"
    install "$staging"
    echo "Built $package"
    exit 0
}

prebuilt=https://github.com/nuanu-ai/slatrix/releases/download/$release-$stamp/$asset
if [[ -z ${SLATRIX_SDK_FROM_SOURCE:-} ]] && curl -fsIL -o /dev/null "$prebuilt" 2>/dev/null; then
    echo "Downloading the prebuilt Matrix SDK $stamp"
    mkdir -p "$build"
    download=$build/native-sdk-download
    rm -rf "$download"
    mkdir "$download"
    curl -fL --proto '=https' --progress-bar "$prebuilt" | tar -xz -C "$download"
    if [[ $(<"$download/${package##*/}/.stamp") != "$stamp" ]]; then
        echo "error: the prebuilt package doesn't match $stamp" >&2
        exit 1
    fi
    install "$download/${package##*/}"
    rm -rf "$download"
    echo "Installed $package"
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
    case $(uname -sm) in
        'Darwin arm64') host=aarch64-apple-darwin rustup_sha256=$RUSTUP_SHA256_MACOS ;;
        'Linux x86_64') host=x86_64-unknown-linux-gnu rustup_sha256=$RUSTUP_SHA256_LINUX ;;
        *)
            echo "error: no rustup-init is pinned for $(uname -sm)" >&2
            exit 1
            ;;
    esac
    init=$build/rustup-init
    curl --proto '=https' --tlsv1.2 -fsSL -o "$init" \
        "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$host/rustup-init"
    echo "$rustup_sha256  $init" | shasum -a 256 -c -
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

staging=$package.tmp
rm -rf "$staging"
if [[ -n $android ]]; then
    sdk=${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}
    ndk=$sdk/ndk/$ANDROID_NDK_VERSION
    if [[ ! -d $ndk ]]; then "$sdk/cmdline-tools/latest/bin/sdkmanager" --install "ndk;$ANDROID_NDK_VERSION"; fi
    isolated+=(ANDROID_NDK_HOME="$ndk")
    "${isolated[@]}" rustup target add --toolchain "$RUST_TOOLCHAIN" aarch64-linux-android x86_64-linux-android
    if [[ $("${isolated[@]}" cargo-ndk --version 2>/dev/null) != *" $CARGO_NDK_VERSION" ]]; then
        "${isolated[@]}" cargo "+$RUST_TOOLCHAIN" install cargo-ndk --version "$CARGO_NDK_VERSION" --locked
    fi

    (cd "$src" && "${isolated[@]}" cargo "+$RUST_TOOLCHAIN" ndk --platform "$ANDROID_MIN_SDK" \
        -t arm64-v8a -t x86_64 -o "$staging/jniLibs" \
        build -p matrix-sdk-ffi --profile small-release --features "$FFI_FEATURES")
    (cd "$src" && "${isolated[@]}" cargo "+$RUST_TOOLCHAIN" run -p uniffi-bindgen -- generate --language kotlin \
        --no-format --library target/aarch64-linux-android/small-release/libmatrix_sdk_ffi.so --out-dir "$staging/kotlin")
    # The JNI entry point android_platform.rs exports; TLS checks certificates through it.
    mkdir -p "$staging/kotlin/org/matrix/rustsdk"
    cat > "$staging/kotlin/org/matrix/rustsdk/Android.kt" <<'EOF'
package org.matrix.rustsdk

object Android {
    init {
        System.loadLibrary("matrix_sdk_ffi")
    }

    /** Call with the application context before initPlatform. */
    @JvmStatic external fun init(context: android.content.Context)
}
EOF
    # The app takes rustls-platform-verifier's Kotlin half at the version this lockfile pins.
    cp "$src/Cargo.lock" "$staging/"
    finish
fi

# xtask localizes the private SQLite symbols in place, which fails on an
# already-localized archive, so make Cargo relink it.
archive=$src/target/aarch64-apple-darwin/small-release/libmatrix_sdk_ffi.a
rm -f "$archive"
(cd "$src" && "${isolated[@]}" cargo "+$RUST_TOOLCHAIN" xtask swift build-framework --release \
    --target aarch64-apple-darwin --macos-deployment-target 14.0 \
    --stable-toolchain "$RUST_TOOLCHAIN" --skip-xcodebuild)

slice=$staging/MatrixSDKFFI.xcframework/macos-arm64
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
finish
