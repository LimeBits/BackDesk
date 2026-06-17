#!/usr/bin/env bash
# Build a local BackDesk.app bundle.
# Usage: ./Scripts/package-app.sh [--debug|--production] [--arm64|--x86_64] [--output-name NAME]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BackDesk"
BUILD_DIR="${ROOT_DIR}/build/local-app"
SWIFT_MODULE_CACHE="/tmp/BackDeskSwiftModuleCache"
PROFILE="production"
ARCH="$(/usr/bin/uname -m)"
OUTPUT_NAME="${APP_NAME}.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            PROFILE="debug"
            shift
            ;;
        --production)
            PROFILE="production"
            shift
            ;;
        --arm64)
            ARCH="arm64"
            shift
            ;;
        --x86_64)
            ARCH="x86_64"
            shift
            ;;
        --arch)
            if [[ $# -lt 2 ]]; then
                printf '--arch 需要指定 arm64 或 x86_64\n' >&2
                exit 1
            fi
            ARCH="$2"
            shift 2
            ;;
        --output-name)
            if [[ $# -lt 2 ]]; then
                printf '--output-name 需要指定 .app 目录名\n' >&2
                exit 1
            fi
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '1,6p' "$0"
            exit 0
            ;;
        *)
            printf '未知参数: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

case "${PROFILE}" in
    debug|production) ;;
    *)
        printf '不支持的构建类型: %s\n' "${PROFILE}" >&2
        exit 1
        ;;
esac

case "${ARCH}" in
    arm64|x86_64) ;;
    *)
        printf '不支持的架构: %s，仅支持 arm64 或 x86_64\n' "${ARCH}" >&2
        exit 1
        ;;
esac

APP_DIR="${ROOT_DIR}/${OUTPUT_NAME}"

generate_icon() {
    local icon_path="${ROOT_DIR}/AppIcon.icns"
    local iconset_dir="${BUILD_DIR}/AppIcon.iconset"

    if [[ ! -f "${ROOT_DIR}/AppIcon.png" ]]; then
        return 0
    fi

    rm -rf "${iconset_dir}"
    mkdir -p "${iconset_dir}"

    /usr/bin/sips -s format png -z 16 16     "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_16x16.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 32 32     "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 32 32     "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_32x32.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 64 64     "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 128 128   "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_128x128.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 256 256   "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 256 256   "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_256x256.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 512 512   "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 512 512   "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_512x512.png" >/dev/null 2>&1
    /usr/bin/sips -s format png -z 1024 1024 "${ROOT_DIR}/AppIcon.png" --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null 2>&1

    if /usr/bin/iconutil -c icns "${iconset_dir}" -o "${icon_path}" >/dev/null 2>&1; then
        rm -rf "${iconset_dir}"
        return 0
    fi

    node - "${iconset_dir}" "${icon_path}" <<'NODE'
const fs = require('fs');
const path = require('path');
const base = process.argv[2];
const output = process.argv[3];
const chunks = [
  ['icp4', 'icon_16x16.png'],
  ['icp5', 'icon_32x32.png'],
  ['icp6', 'icon_32x32@2x.png'],
  ['ic07', 'icon_128x128.png'],
  ['ic08', 'icon_256x256.png'],
  ['ic09', 'icon_512x512.png'],
  ['ic10', 'icon_512x512@2x.png']
];
const parts = [];
let total = 8;
for (const [type, file] of chunks) {
  const data = fs.readFileSync(path.join(base, file));
  const header = Buffer.alloc(8);
  header.write(type, 0, 4, 'ascii');
  header.writeUInt32BE(data.length + 8, 4);
  parts.push(header, data);
  total += data.length + 8;
}
const fileHeader = Buffer.alloc(8);
fileHeader.write('icns', 0, 4, 'ascii');
fileHeader.writeUInt32BE(total, 4);
fs.writeFileSync(output, Buffer.concat([fileHeader, ...parts], total));
NODE

    rm -rf "${iconset_dir}"
}

mkdir -p "${BUILD_DIR}" "${SWIFT_MODULE_CACHE}"

BINARY_PATH="${BUILD_DIR}/${APP_NAME}-${PROFILE}-${ARCH}"
SWIFT_FLAGS=(-module-cache-path "${SWIFT_MODULE_CACHE}" -target "${ARCH}-apple-macos12.0")

if [[ "${PROFILE}" == "debug" ]]; then
    SWIFT_FLAGS+=(-Onone -g -D BACKDESK_DEBUG_MENU)
else
    SWIFT_FLAGS+=(-O)
fi

printf '→ 构建 %s 目标版本 (%s)...\n' "${PROFILE}" "${ARCH}"
swiftc "${SWIFT_FLAGS[@]}" "${ROOT_DIR}/main.swift" -o "${BINARY_PATH}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${ROOT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

generate_icon
if [[ -f "${ROOT_DIR}/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    rm -f "${ROOT_DIR}/AppIcon.icns"
fi

codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1

printf '✓ 已生成: %s\n' "${APP_DIR}"
printf '  构建类型: %s\n' "${PROFILE}"
if [[ "${PROFILE}" == "debug" ]]; then
    printf '  调试菜单: 已启用\n'
else
    printf '  调试菜单: 未启用\n'
fi
