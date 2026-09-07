#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Behavior.swift Tests/main.swift -o .build/behavior-tests
.build/behavior-tests
