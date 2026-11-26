#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/build-app.sh release "${1:-dist}"
