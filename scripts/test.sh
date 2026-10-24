#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

scripts/build-sdk.sh
swift test "${swift_test_args[@]}" "$@"
