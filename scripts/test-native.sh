#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---render-only}"
case "$MODE" in
  --render-only) ARGS=(--self-test-render-only);;
  --live-capture) ARGS=();;
  *) echo 'Usage: test-native.sh [--render-only|--live-capture]' >&2; exit 64;;
esac
LOG_DIR="${SINGULARITY_TEST_BUILD_DIR:-$PWD/.build}/native"
mkdir -p "$LOG_DIR"
./scripts/build-self-test.sh "$LOG_DIR"
APP="$LOG_DIR/SingularityQA.app"
export SINGULARITY_QA_OUTPUT="${SINGULARITY_QA_OUTPUT:-$LOG_DIR/frames}"
swiftc Tests/CaptureBackdrop.swift -o "$LOG_DIR/CaptureBackdrop" -framework Cocoa
export SINGULARITY_CAPTURE_FIXTURE="$LOG_DIR/CaptureBackdrop"

# The optimized app performs explicit checks, exits, and does not save preferences.
"$APP/Contents/MacOS/Singularity" --pet-only --self-test ${ARGS[@]+"${ARGS[@]}"} > "$LOG_DIR/pass.log" 2>&1
grep -F 'RENDER_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_EQUIVALENCE_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_CACHE_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'MULTIBODY_RENDER_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'GEOMETRY_GPU_BENCHMARK' "$LOG_DIR/pass.log"
grep -F 'TEXTURE_SYNTHETIC_TEST_PASS shared=true' "$LOG_DIR/pass.log"
grep -F 'TEXTURE_SYNTHETIC_TEST_PASS shared=false' "$LOG_DIR/pass.log"
grep -F 'SELF_TEST_PASS' "$LOG_DIR/pass.log"
if [[ "$MODE" == --live-capture ]]; then grep -F 'CAPTURE_TEST_PASS' "$LOG_DIR/pass.log"; fi
grep -F 'CAPTURE_POLICY_TEST_PASS' "$LOG_DIR/pass.log"
grep -F 'CAPTURE_PIXEL_TEST_PASS' "$LOG_DIR/pass.log"
if grep -Fq 'CAPTURE_TEST_PASS' "$LOG_DIR/pass.log"; then
  grep -F 'CAPTURE_RECOVERY_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_WAKE_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CODEX_VISIBILITY_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_START_RETARGET_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_REFRESH_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'CAPTURE_RENDER_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'MULTIBODY_CAPTURE_TEST_PASS count=2' "$LOG_DIR/pass.log"
  grep -F 'MULTIBODY_CAPTURE_TEST_PASS count=3' "$LOG_DIR/pass.log"
  grep -E 'TEXTURE_(EQUIVALENCE_TEST_PASS|ZERO_COPY_SKIPPED)' "$LOG_DIR/pass.log"
  grep -F 'RENDER_SCHEDULING_TEST_PASS' "$LOG_DIR/pass.log"
  grep -F 'IDLE_RESOURCE_TEST_PASS' "$LOG_DIR/pass.log"
  if [[ "$(sw_vers -productVersion)" != 13.0* ]]; then
    grep -F 'CAPTURE_REGION_TEST_PASS' "$LOG_DIR/pass.log"
  fi
  if [[ "$(sw_vers -productVersion)" != 13.* && "${SINGULARITY_CAPTURE_BACKEND:-}" != stream ]]; then
    grep -F 'CAPTURE_SNAPSHOT_TEST_PASS' "$LOG_DIR/pass.log"
    grep -F 'CAPTURE_BACKEND_RETRY_TEST_PASS' "$LOG_DIR/pass.log"
    grep -F 'CAPTURE_ADAPTIVE_TEST_PASS' "$LOG_DIR/pass.log"
  fi
fi
if "$APP/Contents/MacOS/Singularity" --pet-only --self-test --self-test-render-only --self-test-fail > "$LOG_DIR/fail.log" 2>&1; then
  echo "FAIL: QA self-test accepted an intentional failure" >&2
  exit 1
fi
grep -F 'SELF_TEST_FAIL intentional failure' "$LOG_DIR/fail.log"
if [[ "$MODE" == --render-only ]]; then
  "$APP/Contents/MacOS/Singularity" --pet-only --self-test --self-test-render-only --self-test-interactions > "$LOG_DIR/interactions.log" 2>&1
  grep -F INTERACTION_QA_PASS "$LOG_DIR/interactions.log"
  grep -E 'OWN_WINDOW_CAPTURE_(PASS|UNAVAILABLE)' "$LOG_DIR/interactions.log" || true  # own-window API is 14.4+
fi
echo "PASS: isolated native tests and failure exit status"
