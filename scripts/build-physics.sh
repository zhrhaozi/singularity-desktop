#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${1:-.build/physics}"
mkdir -p "$BUILD"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
for source in Vendor/Chipmunk2D/src/*.c PhysicsBridge.c; do
  name="$(basename "$source" .c)"
  [ "$name" = cpHastySpace ] && continue
  xcrun clang -O2 -DNDEBUG -target arm64-apple-macosx13.0 \
    -I Vendor/Chipmunk2D/include -c "$source" -o "$BUILD/$name.o"
done
xcrun libtool -static -o "$BUILD/libSingularityPhysics.a" "$BUILD"/*.o
