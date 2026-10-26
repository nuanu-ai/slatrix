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
# The search modal gets its own tab bar next; until then it keeps its picker.
offsystem "use TabBar" 'pickerStyle\(\.segmented\)' --exclude=ConversationSheets.swift
exit $failed
