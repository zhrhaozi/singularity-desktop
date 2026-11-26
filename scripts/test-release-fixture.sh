#!/bin/bash
# Exercise the tag workflow with an already built, signed package and a local gh recorder only.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; t=$(mktemp -d "${TMPDIR:-/tmp}/singularity-release-qa.XXXXXX"); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/project/scripts" "$t/project/dist"; cp VERSION "$t/project/"; cp scripts/release-tag.sh "$t/project/scripts/"
export PATH="$t/bin:$PATH" QA_GH_CALLS="$t/calls"
cat > "$t/bin/gh" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >> "$QA_GH_CALLS"
MOCK
chmod +x "$t/bin/gh"
version=$(cat VERSION); prefix="Singularity-$version-AppleSilicon"
for f in 奇点.app "$prefix.zip" "$prefix.dmg"; do ln -s "$root/dist/$f" "$t/project/dist/$f"; done
cp dist/SHA256SUMS.txt "$t/project/dist/"
export GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v$version"
export MACOS_TEAM_ID=$(codesign -dv --verbose=4 dist/奇点.app 2>&1 | sed -n 's/^TeamIdentifier=//p'); [[ -n "$MACOS_TEAM_ID" && "$MACOS_TEAM_ID" != 'not set' ]]
cd "$t/project"; script=./scripts/release-tag.sh
if GITHUB_REF_TYPE=branch "$script" > /dev/null 2>&1; then exit 1; fi
if GITHUB_REF_NAME=v0.0.0 "$script" > /dev/null 2>&1; then exit 1; fi
if MACOS_TEAM_ID=incorrect "$script" > /dev/null 2>&1; then exit 1; fi
printf 'tampered\n' >> dist/SHA256SUMS.txt
if "$script" > /dev/null 2>&1; then exit 1; fi
[[ ! -e "$QA_GH_CALLS" ]]; cp "$root/dist/SHA256SUMS.txt" dist/
"$script"
printf '%s\n' release create "v$version" "dist/$prefix.dmg" "dist/$prefix.zip" dist/SHA256SUMS.txt --verify-tag --title "奇点 $version" --generate-notes | diff - "$QA_GH_CALLS"
echo 'RELEASE_FIXTURE_PASS: branch, wrong tag, wrong team and tampered assets rejected; correct package reaches only the local gh recorder'
