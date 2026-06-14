#!/usr/bin/env bash
# Package BackDesk.app into a drag-install DMG.
# Usage: ./Scripts/package-dmg.sh [--build]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BackDesk"
APP_DIR="${ROOT_DIR}/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
MOUNT_ROOT="${DIST_DIR}/dmg-mount"
VOLUME_NAME="${APP_NAME}"

if [[ "${1:-}" == "--build" ]]; then
    "${ROOT_DIR}/build.sh"
fi

if [[ ! -d "${APP_DIR}" ]]; then
    printf '✗ %s 不存在，请先运行 ./build.sh\n' "${APP_DIR}" >&2
    exit 1
fi

PLIST="${APP_DIR}/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}" 2>/dev/null || echo "unknown")
DMG_NAME="${APP_NAME}_v${APP_VERSION}_universal"
DMG_PATH="${ROOT_DIR}/${DMG_NAME}.dmg"
DMG_RW_PATH="${DIST_DIR}/${DMG_NAME}-rw.dmg"

rm -rf "${MOUNT_ROOT}"
mkdir -p "${DIST_DIR}" "${MOUNT_ROOT}"
rm -f "${DMG_PATH}" "${DMG_RW_PATH}"

printf '→ 创建可写 DMG 镜像...\n'
/usr/bin/hdiutil create \
    -size 40m \
    -volname "${VOLUME_NAME}" \
    -ov \
    -fs "HFS+" \
    -layout SPUD \
    -type UDIF \
    "${DMG_RW_PATH}" >/dev/null

MOUNT_DIR="$(/usr/bin/mktemp -d "${MOUNT_ROOT}/${APP_NAME}.XXXXXX")"
/usr/bin/hdiutil attach "${DMG_RW_PATH}" -readwrite -noverify -noautoopen -mountpoint "${MOUNT_DIR}" >/dev/null

cleanup() {
    /usr/bin/hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true
}
trap cleanup EXIT

printf '→ 填充 DMG 内容...\n'
/bin/cp -R "${APP_DIR}" "${MOUNT_DIR}/"
/bin/ln -s /Applications "${MOUNT_DIR}/Applications"

ICNS="${APP_DIR}/Contents/Resources/AppIcon.icns"
if [[ -f "${ICNS}" ]]; then
    /bin/cp "${ICNS}" "${MOUNT_DIR}/.VolumeIcon.icns"
    /usr/bin/SetFile -a C "${MOUNT_DIR}" 2>/dev/null || true
    /usr/bin/SetFile -a V "${MOUNT_DIR}/.VolumeIcon.icns" 2>/dev/null || true
fi

printf '→ 设置 Finder 拖拽安装布局...\n'
/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  tell folder POSIX file "${MOUNT_DIR}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 100, 760, 440}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 120
    set text size of theViewOptions to 13
    set background color of theViewOptions to {56797, 56797, 61166}
    set position of item "${APP_NAME}.app" of container window to {170, 170}
    set position of item "Applications" of container window to {410, 170}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

printf '→ 压缩为只读 DMG...\n'
/usr/bin/hdiutil detach "${MOUNT_DIR}" -quiet
trap - EXIT

/usr/bin/hdiutil convert "${DMG_RW_PATH}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}" >/dev/null

rm -rf "${MOUNT_ROOT}"
rm -f "${DMG_RW_PATH}"

printf '✓ DMG 已生成: %s\n' "${DMG_PATH}"
du -sh "${DMG_PATH}" | awk '{print "  大小: " $1}'
