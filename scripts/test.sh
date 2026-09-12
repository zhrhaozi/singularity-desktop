#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${SINGULARITY_TEST_BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR"
FIXTURES="$(mktemp -d "$BUILD_DIR/codex-fixtures.XXXXXX")"
swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" Behavior.swift CodexState.swift Tests/main.swift -o "$BUILD_DIR/behavior-tests"
"$BUILD_DIR/behavior-tests" "$FIXTURES" "$PWD/singularity-codex-state"

SHADER="$PWD/Resources/blackhole.frag"
for required in \
  'uniform float diskPhase, dustPhase;' \
  'uniform float codexEnergySmooth, codexTrailSmooth, codexParticlesSmooth;' \
  'vec3 dust = codexDust(p, rh, dustPhase);' \
  'float swirl = rc * L.wind * 0.12 - diskPhase * kep * gloc * dil;'; do
  if ! rg -Fq "$required" "$SHADER"; then
    echo "FAIL: shader contract missing: $required" >&2
    exit 1
  fi
done
for forbidden in \
  'smoothstep(7.0 * rh, 0.78 * rh' \
  'smoothstep(0.10, 0.0' \
  'smoothstep(5.0 * rh, 0.25 * rh' \
  'fragColor = vec4(term + stars(d)'; do
  if rg -Fq "$forbidden" "$SHADER"; then
    echo "FAIL: shader regression pattern found: $forbidden" >&2
    exit 1
  fi
done
if command -v glslangValidator >/dev/null 2>&1; then
  glslangValidator -S frag "$SHADER"
fi
echo "PASS: GLSL shader contract and defined smoothstep paths"
