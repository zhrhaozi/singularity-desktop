#!/bin/bash
# Compare the formatter's exact output without rewriting the checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/singularity-format.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
for f in main.swift Model.swift Capture.swift PetView.swift SettingsView.swift AppDelegate.swift \
         GlobalShortcuts.swift LivePreview.swift CapturePolicyDiagnostic.swift; do
    xcrun swift-format format --configuration .swift-format "$f" > "$tmp/$f"
    diff -u "$f" "$tmp/$f" || exit 1
done
printf '%s\n' 'PASS: Swift source formatting'
