#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/奇点.app}"
LOG_DIR="${SINGULARITY_TEST_BUILD_DIR:-$PWD/.build}/native"
mkdir -p "$LOG_DIR"
export SINGULARITY_QA_OUTPUT="${SINGULARITY_QA_OUTPUT:-$LOG_DIR/frames}"
swiftc Tests/CaptureBackdrop.swift -o "$LOG_DIR/CaptureBackdrop" -framework Cocoa
export SINGULARITY_CAPTURE_FIXTURE="$LOG_DIR/CaptureBackdrop"

# The optimized app performs explicit checks, exits, and does not save preferences.
"$APP/Contents/MacOS/Singularity" --pet-only --self-test > "$LOG_DIR/pass.log" 2>&1
grep -F 'RENDER_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_EQUIVALENCE_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_CACHE_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_GPU_BENCHMARK' "$LOG_DIR/pass.log"
grep -F 'TEXTURE_SYNTHETIC_TEST_PASS shared=true' "$LOG_DIR/pass.log"
grep -F 'TEXTURE_SYNTHETIC_TEST_PASS shared=false' "$LOG_DIR/pass.log"
grep -F 'SELF_TEST_PASS' "$LOG_DIR/pass.log"
grep -E 'CAPTURE_TEST_(PASS|SKIPPED)' "$LOG_DIR/pass.log"
grep -F 'CAPTURE_POLICY_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'CAPTURE_PIXEL_TEST_PASS' "$LOG_DIR/pass.log"
if grep -Fq 'CAPTURE_TEST_PASS' "$LOG_DIR/pass.log"; then
  grep -F 'CAPTURE_RECOVERY_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_START_RETARGET_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_REFRESH_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_RENDER_TEST_PASS' "$LOG_DIR/pass.log"
  grep -E 'TEXTURE_(EQUIVALENCE_TEST_PASS|ZERO_COPY_SKIPPED)' "$LOG_DIR/pass.log"
  grep -F 'RENDER_SCHEDULING_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'IDLE_RESOURCE_TEST_PASS' "$LOG_DIR/pass.log"
  if [[ "$(sw_vers -productVersion)" != 13.0* ]]; then
    grep -F 'CAPTURE_REGION_TEST_PASS' "$LOG_DIR/pass.log"
  fi
  if [[ "$(sw_vers -productVersion)" != 13.* && "${SINGULARITY_CAPTURE_BACKEND:-}" != stream ]]; then
    grep -F 'CAPTURE_SNAPSHOT_TEST_PASS' "$LOG_DIR/pass.log"
    grep -F 'CAPTURE_ADAPTIVE_TEST_PASS' "$LOG_DIR/pass.log"
  fi
fi
if "$APP/Contents/MacOS/Singularity" --pet-only --self-test --self-test-fail > "$LOG_DIR/fail.log" 2>&1; then
  echo "FAIL: release self-test accepted an intentional failure" >&2
  exit 1
fi
grep -F 'SELF_TEST_FAIL intentional failure' "$LOG_DIR/fail.log"
echo "PASS: native release tests and failure exit status"
