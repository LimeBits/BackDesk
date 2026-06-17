#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "${ROOT_DIR}/Scripts/package-app.sh" \
    --debug \
    --x86_64 \
    --output-name "BackDesk_debug_x86_64.app"
