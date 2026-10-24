# Sourced by scripts that run `swift` from the repository root.
swift_args=(--scratch-path .build/slatrix-spm --disable-keychain)
swift_test_args=("${swift_args[@]}")

# Command Line Tools only; nothing changes when full Xcode is selected.
# CLT's macOS 27 SDK lacks the SwiftUI macro plugin, so build against 26.x, and
# `swift test` intermittently fails to find the swift-testing macro plugin.
clt=/Library/Developer/CommandLineTools
if [[ $(xcode-select -p) == "$clt" ]]; then
    swift_test_args+=(-Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing")
    if [[ -d $clt/SDKs/MacOSX26.sdk ]]; then export SDKROOT=$clt/SDKs/MacOSX26.sdk; fi
fi
