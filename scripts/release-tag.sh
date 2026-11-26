#!/bin/bash
# Only upload prebuilt, verified artifacts; never create a Git tag or overwrite a release.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(cat VERSION)
tag=${GITHUB_REF_NAME:?expected a pushed tag}
[[ ${GITHUB_REF_TYPE:-} == tag && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$tag" == "v$version" ]] || { echo 'Version and pushed tag do not match' >&2; exit 1; }
if [[ ${1:-} == --check-tag ]]; then exit 0; fi
prefix="Singularity-$version-AppleSilicon"
app=dist/奇点.app
codesign --verify --deep --strict "$app"
identity=$(codesign -dv --verbose=4 "$app" 2>&1)
grep -Fxq "TeamIdentifier=${MACOS_TEAM_ID:?expected signing team}" <<< "$identity"
grep -Eq 'flags=.*runtime' <<< "$identity"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]]
(cd dist; shasum -a 256 "$prefix.dmg" "$prefix.zip" | diff - SHA256SUMS.txt)
gh release create "$tag" "dist/$prefix.dmg" "dist/$prefix.zip" dist/SHA256SUMS.txt --verify-tag --title "奇点 $version" --generate-notes
