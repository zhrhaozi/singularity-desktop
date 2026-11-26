#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/build-app.sh self-test "${1:-.build/native}"
