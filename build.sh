#!/bin/bash

# 确保脚本发生任何错误时立即退出
set -e

VERSION="0.2.3"
APP_NAME="BackDesk"
BUILD_DIR="build"

echo "=== 开始编译 BackDesk v${VERSION} (macOS 12/13/14 通用多平台版) ==="

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
    
    # 2. 制作 DMG 磁盘映像安装包 (支持个性化背景与图标排布)
    echo "💾 正在制作 DMG 镜像: ${target_dmg_name}..."
    
    if [ -f "dmg_background.png" ]; then
        echo "🎨 检测到 dmg_background.png，正在制作个性化背景和图标布局的精美 DMG 镜像..."
        
        # 确保弹出可能残留的挂载
        hdiutil detach "/Volumes/${APP_NAME}" -force >/dev/null 2>&1 || true
        
        # 确保清除可能重名的旧 dmg 和临时文件
        rm -f "${target_dmg_name}"
        local temp_raw_dmg="temp_raw_${arch}.dmg"
        rm -f "${temp_raw_dmg}"
        
        # 创建一个临时可写 HFS+ DMG 映像 (64MB 足够容纳多架构通用二进制)
        hdiutil create -size 64m -fs "HFS+" -volname "${APP_NAME}" -o "${temp_raw_dmg}" -quiet
        
        # 挂载此临时 writeable DMG
        echo "挂载临时可写 DMG 映像..."
        local mount_output
        mount_output=$(hdiutil attach -readwrite "${temp_raw_dmg}")
        local mount_point
        mount_point=$(echo "$mount_output" | grep -o "/Volumes/${APP_NAME}[^ ]*")
        if [ -z "$mount_point" ]; then
            mount_point="/Volumes/${APP_NAME}"
        fi
        
        # 复制 BackDesk.app 到挂载目录并创建 Applications 软链接
        echo "复制文件并创建 Applications 快捷方式..."
        cp -R "${target_app_name}" "${mount_point}/"
        ln -s /Applications "${mount_point}/Applications"
        
        # 创建隐藏的 .background 文件夹并复制背景图
        mkdir -p "${mount_point}/.background"
        cp dmg_background.png "${mount_point}/.background/dmg_background.png"
        
        # 使用 osascript 调整 Finder 窗口视图、背景图和图标位置
        echo "运行 AppleScript 脚本设置 DMG 窗口与图标布局..."
        
        # 我们使用 osascript 执行 Finder 脚本控制窗口，添加 || true 防护
        osascript -e "
        tell application \"Finder\"
            tell disk \"${APP_NAME}\"
                open
                delay 1
                set the_window to container window
                set current view of the_window to icon view
                set toolbar visible of the_window to false
                set statusbar visible of the_window to false
                # 设置窗口的 Bounds (左, 上, 右, 下)，大小为 600x400
                set bounds of the_window to {100, 100, 700, 500}
                
                set viewOptions to icon view options of the_window
                set icon size of viewOptions to 110
                set arrangement of viewOptions to not arranged
                
                # 设置自定义背景图
                set background picture of viewOptions to file \".background:dmg_background.png\"
                
                # 定位应用图标和 Applications 快捷方式
                # 600 宽的窗口，左侧定位在 160，右侧定位在 440，高度定位在 200（正中）
                set position of item \"${target_app_name}\" of the_window to {160, 200}
                set position of item \"Applications\" of the_window to {440, 200}
                
                close the_window
                open
                delay 2
            end tell
        end tell
        " || true
        
        # 对目录下的 .background 和其它隐藏文件进行完全隐藏处理
        echo "清理并优化 DMG 目录结构..."
        chmod -Rf go-w "${mount_point}" || true
        chflags -h hidden "${mount_point}/.background" || true
        chflags -h hidden "${mount_point}/.background/dmg_background.png" || true
        
        # 卸载临时映像
        echo "安全弹出临时可写 DMG 映像..."
        hdiutil detach "${mount_point}" -force
        
        # 将临时可写 DMG 映像转换为高度压缩的只读 DMG 安装包
        echo "将可写映像转换压缩为最终只读 DMG 安装包..."
        hdiutil convert "${temp_raw_dmg}" -format UDZO -imagekey zlib-level=9 -o "${target_dmg_name}" -quiet
        
        # 清理临时文件
        rm -f "${temp_raw_dmg}"
        echo "✓ 成功制作了个性化 DMG 镜像: ${target_dmg_name}"
    else
        echo "⚠️ 未检测到 dmg_background.png，将以经典免依赖的普通版 DMG 方式打包..."
        
        local temp_dmg_dir="dmg_temp_${arch}"
        rm -rf "${temp_dmg_dir}"
        mkdir -p "${temp_dmg_dir}"
        
        # 复制干净的 BackDesk.app 到临时目录，并创建 Applications 快捷方式
        cp -R "${target_app_name}" "${temp_dmg_dir}/"
        ln -s /Applications "${temp_dmg_dir}/Applications"
        
        # 确保清除可能重名的旧 dmg
        rm -f "${target_dmg_name}"
        
        # 使用 hdiutil 编译打包
        hdiutil create -volname "${APP_NAME}" -srcfolder "${temp_dmg_dir}" -ov -format UDZO "${target_dmg_name}" -quiet
        
        # 清理临时目录
        rm -rf "${temp_dmg_dir}"
        echo "✓ 成功生成普通版 DMG 镜像: ${target_dmg_name}"
    fi
    
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
echo "🎉 所有平台版本 BackDesk v${VERSION} 打包圆满成功！"
echo "👉 您工作区当前目录下已有以下可发布文件："
ls -lh ${APP_NAME}_v*.zip
ls -lh ${APP_NAME}_v*.dmg
if [ -d "${APP_NAME}.app" ]; then
    echo "👉 此外工作区中已保留编译好的原生应用目录: ${APP_NAME}.app"
fi
echo "=========================================="
