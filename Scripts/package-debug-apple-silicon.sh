#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "${ROOT_DIR}/Scripts/package-app.sh" \
    --debug \
    --arm64 \
    --output-name "BackDesk_debug_arm64.app"
