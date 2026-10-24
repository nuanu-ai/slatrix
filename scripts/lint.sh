#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive Sources Tests
# `.plain` leaves the gaps inside a button's label unclickable; `.row` makes the whole frame hit-testable.
if grep -rn 'buttonStyle(\.plain)' Sources; then
    echo "error: use .buttonStyle(.row) instead of .plain" >&2
    exit 1
fi
