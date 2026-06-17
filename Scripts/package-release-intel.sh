#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "${ROOT_DIR}/Scripts/package-app.sh" \
    --production \
    --x86_64 \
    --output-name "BackDesk_release_x86_64.app"
