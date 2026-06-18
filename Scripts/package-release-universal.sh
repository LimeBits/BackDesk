#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/local-app"
SWIFT_MODULE_CACHE="/tmp/BackDeskSwiftModuleCache"
APP_NAME="BackDesk"
OUTPUT_APP="${ROOT_DIR}/BackDesk_release_universal.app"
X86_BINARY="${BUILD_DIR}/${APP_NAME}-production-x86_64"
ARM_BINARY="${BUILD_DIR}/${APP_NAME}-production-arm64"
UNIVERSAL_BINARY="${BUILD_DIR}/${APP_NAME}-production-universal"

printf '→ 构建 production 通用版本 (arm64 + x86_64)...\n'

mkdir -p "${BUILD_DIR}" "${SWIFT_MODULE_CACHE}"

printf '→ 编译 Intel 切片 (x86_64)...\n'
swiftc -module-cache-path "${SWIFT_MODULE_CACHE}" \
    -target x86_64-apple-macos12.0 \
    -O \
    "${ROOT_DIR}/main.swift" \
    -o "${X86_BINARY}"

printf '→ 编译 Apple Silicon 切片 (arm64)...\n'
swiftc -module-cache-path "${SWIFT_MODULE_CACHE}" \
    -target arm64-apple-macos12.0 \
    -O \
    "${ROOT_DIR}/main.swift" \
    -o "${ARM_BINARY}"

printf '→ 合并 Universal 2 二进制...\n'
/usr/bin/lipo -create "${X86_BINARY}" "${ARM_BINARY}" -output "${UNIVERSAL_BINARY}"

"${ROOT_DIR}/Scripts/package-app.sh" \
    --production \
    --arch "$(/usr/bin/uname -m)" \
    --output-name "$(basename "${OUTPUT_APP}")"

/bin/cp "${UNIVERSAL_BINARY}" "${OUTPUT_APP}/Contents/MacOS/${APP_NAME}"
/usr/bin/codesign --force --deep --sign - "${OUTPUT_APP}" >/dev/null 2>&1

printf '→ 校验通用二进制架构...\n'
ARCHS="$(/usr/bin/lipo -archs "${OUTPUT_APP}/Contents/MacOS/${APP_NAME}")"

if [[ " ${ARCHS} " != *" x86_64 "* ]]; then
    printf '❌ 通用包缺少 x86_64 架构: %s\n' "${ARCHS}" >&2
    exit 1
fi

if [[ " ${ARCHS} " != *" arm64 "* ]]; then
    printf '❌ 通用包缺少 arm64 架构: %s\n' "${ARCHS}" >&2
    exit 1
fi

printf '✓ 已生成通用 release 包: %s\n' "${OUTPUT_APP}"
printf '  架构: %s\n' "${ARCHS}"
printf '  调试菜单: 未启用\n'
