#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${SINGULARITY_TEST_BUILD_DIR:-$PWD/.build}/orbital-test"
bash scripts/build-physics.sh "$BUILD/physics"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -swift-version 5 -O -import-objc-header PhysicsBridge.h \
  OrbitalSystem.swift Tests/Orbital/main.swift "$BUILD/physics/libSingularityPhysics.a" \
  -o "$BUILD/orbital-test"
"$BUILD/orbital-test"
