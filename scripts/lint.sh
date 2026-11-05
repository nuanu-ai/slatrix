#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive Sources Tests
# `.plain` leaves the gaps inside a button's label unclickable; `.row` makes the whole frame hit-testable.
if grep -rn 'buttonStyle(\.plain)' Sources; then
    echo "error: use .buttonStyle(.row) instead of .plain" >&2
    exit 1
fi

# Views draw with the design system; raw values and off-system styles live only in Views/DesignSystem.
failed=0
offsystem() {
    if grep -rnE "$2" Sources/Slatrix/Views --exclude-dir=DesignSystem "${@:3}"; then
        echo "error: $1" >&2
        failed=1
    fi
}
offsystem "use a color role from AppColors" \
    'Color\((hex|red|nsColor):|accentColor|Color\.primary\.opacity|\.(orange|red|green|yellow|blue|white|black)\b'
offsystem "use .primary, .secondary, .destructive, .textLink or .icon" \
    'buttonStyle\(\.(bordered|borderedProminent|borderless|link)\)|\.tint\('
offsystem "use DelayedProgress or SkeletonRows" 'ProgressView\('
offsystem "use .elevation(_:cornerRadius:)" '\.shadow\('
offsystem "use Motion for animation" '(withAnimation|\.animation)\(\.(easeIn|easeOut|easeInOut|linear|spring)'
offsystem "use .textFieldStyle(.field)" 'textFieldStyle\(\.roundedBorder\)'
offsystem "use .modal with Modal or ConfirmModal" '\.sheet\(|\.alert\(|confirmationDialog\('
offsystem "use TabBar" 'pickerStyle\(\.segmented\)'
# A bare number skips the zoom (⌘= / ⌘-); a one-off size goes through m(_:).
offsystem "scale sizes with m(_:) or a Metrics token" \
    '\.(padding|offset)\(([.a-zA-Z]+, )?(x: |y: )?-?([2-9]|[1-9][0-9]+)(\.[0-9]+)?\)|\.padding\([^)]*\? -?([2-9]|[1-9][0-9]+)(\.[0-9]+)? : -?([2-9]|[1-9][0-9]+)(\.[0-9]+)?\)|\.frame\(((min|max)?([Ww]idth|[Hh]eight)): -?([2-9]|[1-9][0-9]+)(\.[0-9]+)?[,)]|cornerRadius: -?([2-9]|[1-9][0-9]+)(\.[0-9]+)?[,)]'
scripts/lint-buttons.py || failed=1
# Tests must never show a window on the screen of whoever runs them.
if grep -rn 'NSWindow(' Tests --exclude-dir=Support; then
    echo "error: open test windows with offscreenWindow(_:)" >&2
    failed=1
fi
exit $failed
