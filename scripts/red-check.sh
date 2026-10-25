#!/bin/bash
# Proves a change's tests fail on the base branch's sources, so every behavior change starts red.
# Usage: scripts/red-check.sh <base-ref>. CI skips it for pull requests labelled `refactor`.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
base=$1

if [[ -z $(git diff --name-only "$base"...HEAD -- Sources) || -z $(git diff --name-only "$base"...HEAD -- Tests) ]]; then
    echo "Nothing to prove: this change doesn't touch both Sources and Tests."
    exit 0
fi
if [[ -n $(git status --porcelain -- Sources) ]]; then
    echo "error: commit or discard your changes to Sources first." >&2
    exit 1
fi

restore() { rm -rf Sources && git checkout -q HEAD -- Sources; }
trap restore EXIT
rm -rf Sources
git checkout -q "$(git merge-base "$base" HEAD)" -- Sources

mkdir -p .build
if swift test "${swift_test_args[@]}" --quiet > .build/red-check.log 2>&1; then
    echo "error: this change's tests pass on the base sources, so they prove nothing about the change." >&2
    echo "Commit a test that fails first, or label a behavior-preserving change 'refactor'." >&2
    exit 1
fi
echo "Red as it should be: the tests fail on the base sources."
grep -E '✘ Test "|error:' .build/red-check.log | head -n 5 || true
