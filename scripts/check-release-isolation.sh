#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${1:-dist/奇点.app/Contents/MacOS/Singularity}
# Reachable native suites and mutable injection hooks must not be linked, even if their CLI is guarded.
symbols=$(nm "$bin" | xcrun swift-demangle)
if grep -Eq 'NativeSelfTest|NativeInteractionQA|selfTestScreenshotDelay|interruptForSelfTest|supplyBenchmarkSnapshot' <<< "$symbols"; then
  echo 'Native QA leaked into release' >&2; exit 1
fi
rc=0; "$bin" --self-test --self-test-render-only >/dev/null 2>&1 || rc=$?
[[ $rc == 64 ]] || { echo "Unexpected QA flag result: $rc" >&2; exit 1; }
"$bin" --capture-policy-test
