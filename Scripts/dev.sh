#!/usr/bin/env bash
# Install a full-feature debug build to /Applications and launch it.
# Usage: ./Scripts/dev.sh [--build-only] [--no-launch] [--reset-accessibility]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BackDesk"
LOCAL_APP="${ROOT_DIR}/${APP_NAME}.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"
BUILD_ONLY=false
LAUNCH=true
RESET_ACCESSIBILITY=false

wait_for_app_exit() {
    local attempts=30
    while [[ "${attempts}" -gt 0 ]]; do
        if ! /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
        attempts=$((attempts - 1))
    done

    printf '⚠️ %s 还没有完全退出，继续安装；如后续启动异常，请手动退出菜单栏旧实例后重试。\n' "${APP_NAME}"
}

wait_for_app_launch() {
    local attempts=20
    while [[ "${attempts}" -gt 0 ]]; do
        if /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
        attempts=$((attempts - 1))
    done

    return 1
}

launch_app() {
    local binary="${INSTALLED_APP}/Contents/MacOS/${APP_NAME}"
    local fallback_log="/tmp/backdesk-dev-launch.log"

    if /usr/bin/open -n "${INSTALLED_APP}" >/dev/null 2>&1 && wait_for_app_launch; then
        return 0
    fi

    printf '⚠️ open 启动失败，改用二进制兜底启动...\n'
    if [[ -x "${binary}" ]]; then
        /usr/bin/nohup "${binary}" >"${fallback_log}" 2>&1 &
        if wait_for_app_launch; then
            return 0
        fi
    fi

    printf '✗ 启动失败，请手动打开 %s；兜底日志: %s\n' "${INSTALLED_APP}" "${fallback_log}" >&2
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --no-launch)
            LAUNCH=false
            shift
            ;;
        --reset-accessibility)
            RESET_ACCESSIBILITY=true
            shift
            ;;
        -h|--help)
            sed -n '1,5p' "$0"
            exit 0
            ;;
        *)
            printf '未知参数: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

"${ROOT_DIR}/Scripts/package-app.sh" --debug

if [[ "${BUILD_ONLY}" == true ]]; then
    printf '✓ 已完成调试版构建，未安装到 /Applications。\n'
    exit 0
fi

printf '→ 关闭正在运行的 %s...\n' "${APP_NAME}"
/usr/bin/pkill -x "${APP_NAME}" 2>/dev/null || true
wait_for_app_exit

printf '→ 安装调试版到 %s...\n' "${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${LOCAL_APP}" "${INSTALLED_APP}"

if [[ "${RESET_ACCESSIBILITY}" == true ]]; then
    printf '→ 打开辅助功能设置，请关闭并重新打开 BackDesk 权限。\n'
    /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
fi

if [[ "${LAUNCH}" == true ]]; then
    printf '→ 启动调试版 %s...\n' "${APP_NAME}"
    launch_app
fi

printf '✓ 本地调试版已安装。\n'
printf '  菜单位置: 应用兼容模式 -> 记录点击调试日志 / 紧急暂停监听 5 分钟\n'
printf '  日志位置: ~/Library/Application Support/BackDesk/backdesk.log\n'
