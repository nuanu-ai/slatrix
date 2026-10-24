#!/bin/bash
# Prints the app version for a release tag: v1.2.3 → 1.2.3. Sparkle orders updates by this version, so anything
# else (pre-release suffixes, missing parts) stops the release instead of shipping a version it cannot compare.
set -euo pipefail
if [[ ${1:-} =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
else
    echo "error: release tags look like v1.2.3, got '${1:-}'" >&2
    exit 1
fi
