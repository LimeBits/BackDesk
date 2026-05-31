#!/bin/bash

# 确保脚本发生任何错误时立即退出
set -e

VERSION="0.1.0"
APP_NAME="ToDesktop"
BUILD_DIR="build"

echo "=== 开始编译 ToDesktop v${VERSION} (macOS 12/13/14 通用多平台版) ==="

# 1. 清理旧编译和打包产物
echo "🧹 清除以往的旧版本和编译临时文件..."
rm -rf "$BUILD_DIR"
rm -rf ${APP_NAME}_v*.app
rm -f ${APP_NAME}_v*.zip
rm -f ${APP_NAME}_v*.dmg
rm -f AppIcon.icns
# 同时清理之前步骤生成的旧无版本号应用
rm -rf "${APP_NAME}.app"
rm -f "${APP_NAME}.zip"
rm -f "${APP_NAME}.dmg"

# 2. 生成公用的 macOS .icns 矢量图标资源
if [ -f "AppIcon.png" ]; then
    echo "🎨 检测到 AppIcon.png，正在生成共享的 macOS 尺寸规格的图标集 (.icns)..."
    ICONSET_DIR="AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    
    # 使用 sips 缩放并强制转换格式为真正的 PNG 无损格式
    sips -s format png -z 16 16     AppIcon.png --out "${ICONSET_DIR}/icon_16x16.png" > /dev/null 2>&1
    sips -s format png -z 32 32     AppIcon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" > /dev/null 2>&1
    sips -z 32 32                   "${ICONSET_DIR}/icon_16x16@2x.png" --out "${ICONSET_DIR}/icon_32x32.png" > /dev/null 2>&1
    sips -s format png -z 64 64     AppIcon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" > /dev/null 2>&1
    sips -s format png -z 128 128   AppIcon.png --out "${ICONSET_DIR}/icon_128x128.png" > /dev/null 2>&1
    sips -s format png -z 256 256   AppIcon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256                 "${ICONSET_DIR}/icon_128x128@2x.png" --out "${ICONSET_DIR}/icon_256x256.png" > /dev/null 2>&1
    sips -s format png -z 512 512   AppIcon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512                 "${ICONSET_DIR}/icon_256x256@2x.png" --out "${ICONSET_DIR}/icon_512x512.png" > /dev/null 2>&1
    sips -s format png -z 1024 1024 AppIcon.png --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null 2>&1
    
    # 编译成 .icns 图标文件
    iconutil -c icns "$ICONSET_DIR"
    
    # 清理临时转换目录
    rm -rf "$ICONSET_DIR"
    echo "✓ 共享图标编译成功: AppIcon.icns"
else
    echo "⚠️ 未检测到 AppIcon.png，将打包为无主图标版本。"
fi

# 3. 准备编译临时空间
mkdir -p "$BUILD_DIR"

# 4. 分别针对两种架构编译
echo "🖥️  [1/2] 正在编译 Intel (x86_64) 架构..."
if swiftc -target x86_64-apple-macos12.0 -O main.swift -o "${BUILD_DIR}/${APP_NAME}_x86_64"; then
    echo "✓ Intel 架构编译成功！"
    X86_OK=true
else
    echo "❌ Intel 架构编译失败！"
    X86_OK=false
fi

echo "🚀  [2/2] 正在编译 Apple Silicon (arm64) 架构..."
if swiftc -target arm64-apple-macos12.0 -O main.swift -o "${BUILD_DIR}/${APP_NAME}_arm64"; then
    echo "✓ ARM64 架构编译成功！"
    ARM_OK=true
else
    echo "❌ ARM64 架构编译失败！"
    ARM_OK=false
fi

# 5. 生成合并的 Universal (通用二进制) 文件
if [ "$X86_OK" = true ] && [ "$ARM_OK" = true ]; then
    echo "🔗 合并 Intel 与 ARM 架构为通用二进制 (Universal Binary)..."
    lipo -create "${BUILD_DIR}/${APP_NAME}_x86_64" "${BUILD_DIR}/${APP_NAME}_arm64" -output "${BUILD_DIR}/${APP_NAME}_universal"
    echo "✓ 通用二进制合并完成！"
    UNIVERSAL_OK=true
else
    UNIVERSAL_OK=false
fi

# 6. 多架构独立打包函数
package_app() {
    local arch=$1            # "x86_64", "arm64", "universal"
    local binary_path=$2
    local target_app_name="${APP_NAME}.app"
    local target_zip_name="${APP_NAME}_v${VERSION}_${arch}.zip"
    local target_dmg_name="${APP_NAME}_v${VERSION}_${arch}.dmg"
    
    echo "📦 正在生成 ${arch} 架构的 ${target_app_name}..."
    
    # 清理上一次可能残留的 .app 目录
    rm -rf "${target_app_name}"
    
    # 建立包结构
    mkdir -p "${target_app_name}/Contents/MacOS"
    mkdir -p "${target_app_name}/Contents/Resources"
    
    # 复制 Info.plist 配置文件
    cp Info.plist "${target_app_name}/Contents/Info.plist"
    
    # 复制二进制运行文件
    cp "$binary_path" "${target_app_name}/Contents/MacOS/${APP_NAME}"
    
    # 复制图标资源
    if [ -f "AppIcon.icns" ]; then
        cp AppIcon.icns "${target_app_name}/Contents/Resources/AppIcon.icns"
    fi
    
    # 自动进行 Ad-Hoc 代码签名（静默运行）
    codesign --force --deep --sign - "${target_app_name}" > /dev/null 2>&1
    
    # 1. 压缩为 Zip 包以便跨机传输
    zip -r -q "$target_zip_name" "$target_app_name"
    echo "✓ 成功生成 Zip 包: ${target_zip_name}"
    
    # 2. 制作 DMG 磁盘映像安装包 (免依赖原生打包)
    echo "💾 正在制作 DMG 镜像: ${target_dmg_name}..."
    local temp_dmg_dir="dmg_temp_${arch}"
    rm -rf "${temp_dmg_dir}"
    mkdir -p "${temp_dmg_dir}"
    
    # 复制干净的 ToDesktop.app 到临时目录，并创建 Applications 快捷方式
    cp -R "${target_app_name}" "${temp_dmg_dir}/"
    ln -s /Applications "${temp_dmg_dir}/Applications"
    
    # 确保清除可能重名的旧 dmg
    rm -f "${target_dmg_name}"
    
    # 使用 hdiutil 编译打包
    hdiutil create -volname "${APP_NAME}" -srcfolder "${temp_dmg_dir}" -ov -format UDZO "${target_dmg_name}" > /dev/null 2>&1
    
    # 清理临时目录
    rm -rf "${temp_dmg_dir}"
    echo "✓ 成功生成 DMG 镜像: ${target_dmg_name}"
    
    # 如果不是最终的 universal 架构，清理 .app 目录以防混淆；如果是 universal，则保留供直接在终端运行测试
    if [ "$arch" != "universal" ]; then
        rm -rf "${target_app_name}"
    fi
}

# 7. 执行各平台的正式打包
echo "🎁 开始根据不同平台封装独立安装包..."

if [ "$X86_OK" = true ]; then
    package_app "x86_64" "${BUILD_DIR}/${APP_NAME}_x86_64"
fi

if [ "$ARM_OK" = true ]; then
    package_app "arm64" "${BUILD_DIR}/${APP_NAME}_arm64"
fi

if [ "$UNIVERSAL_OK" = true ]; then
    package_app "universal" "${BUILD_DIR}/${APP_NAME}_universal"
fi

# 8. 清理工作区共享的临时 icns 文件
rm -f AppIcon.icns
rm -rf "$BUILD_DIR"

echo "=========================================="
echo "🎉 所有平台版本 ToDesktop v${VERSION} 打包圆满成功！"
echo "👉 您工作区当前目录下已有以下可发布文件："
ls -lh ${APP_NAME}_v*.zip
ls -lh ${APP_NAME}_v*.dmg
if [ -d "${APP_NAME}.app" ]; then
    echo "👉 此外工作区中已保留编译好的原生应用目录: ${APP_NAME}.app"
fi
echo "=========================================="
