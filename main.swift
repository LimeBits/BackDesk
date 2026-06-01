import Cocoa
import CoreGraphics
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var globalMonitor: Any?
    var isEnabled: Bool = true
    var lastTriggerTime: Date = Date.distantPast
    var permissionTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 创建状态栏图标与菜单
        setupStatusItem()
        
        // 2. 检查并请求辅助功能权限
        let hasAccess = checkAccessibility(prompt: false)
        if hasAccess {
            startMonitoring()
        } else {
            promptForAccessibility()
            startPermissionPolling()
        }
        
        print("ToDesktop App Started successfully.")
    }

    func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.checkAccessibility(prompt: false) {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.startMonitoring()
                self.buildMenu()
                print("🎉 自动检测到系统辅助功能权限已开通，全局监听已激活！")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
    }
    
    // MARK: - 状态栏 UI 设置
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // 使用 SF Symbols 的 🖥️ (desktopcomputer) 作为图标，如果不可用则回退到文本
            if let image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "ToDesktop") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🖥️"
            }
        }
        
        buildMenu()
    }
    
    func buildMenu() {
        let menu = NSMenu()
        
        // 功能开关项
        let toggleItem = NSMenuItem(title: "启用桌面壁纸点击", action: #selector(toggleFeature), keyEquivalent: "e")
        toggleItem.state = isEnabled ? .on : .off
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 权限状态/请求项
        let hasAccess = checkAccessibility(prompt: false)
        let authItem = NSMenuItem(title: hasAccess ? "✓ 已获得系统辅助权限" : "⚠️ 请求系统辅助权限...", action: #selector(requestAuth), keyEquivalent: "")
        if hasAccess {
            authItem.isEnabled = false
        }
        menu.addItem(authItem)
        
        // 开机自启开关项
        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 关于与退出
        menu.addItem(NSMenuItem(title: "关于 ToDesktop", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    // MARK: - 菜单事件响应
    @objc func toggleFeature() {
        isEnabled.toggle()
        if isEnabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
        buildMenu()
    }
    
    @objc func requestAuth() {
        _ = checkAccessibility(prompt: true)
        // 稍后检查是否已经被授权
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.buildMenu()
            if self.checkAccessibility(prompt: false) {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.startMonitoring()
            }
        }
    }
    
    @objc func toggleLaunchAtLogin() {
        let current = isLaunchAtLoginEnabled()
        setLaunchAtLogin(enabled: !current)
        buildMenu()
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "关于 ToDesktop"
        alert.informativeText = "ToDesktop v0.1.0\n专为 macOS 12/13 系统开发的桌面快速展示工具。\n\n点击屏幕空白壁纸即可快速摊开所有窗口露出桌面，再次点击桌面试图可恢复原样。\n\n原生支持 Intel 及 Apple Silicon (ARM) 架构芯片。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - 辅助功能权限管理
    func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "需要系统辅助功能权限"
        alert.informativeText = "ToDesktop 需要“辅助功能”权限来监听您的鼠标点击，以识别何时点击了桌面空白壁纸。\n\n请在随后的系统弹窗中，打开「系统设置」并允许 ToDesktop 运行。开启后请重新点击状态栏菜单更新状态。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "去设置")
        alert.addButton(withTitle: "稍后")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = checkAccessibility(prompt: true)
        }
    }
    
    // MARK: - 点击监听与判定
    func startMonitoring() {
        guard globalMonitor == nil && isEnabled else { return }
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleGlobalClick(event)
        }
        print("已成功开启全局点击监听")
    }
    
    func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        print("已关闭全局点击监听")
    }
    
    func handleGlobalClick(_ event: NSEvent) {
        // 获取当前鼠标位置 (Y 轴从屏幕底部向上增加)
        let mouseLocation = NSEvent.mouseLocation
        
        // 转换为 CG 坐标系 (Y 轴从屏幕顶部向下增加)
        let clickPoint = convertToCGCoordinate(mouseLocation)
        
        // 智能分析是否点击了桌面壁纸
        if isClickOnDesktop(at: clickPoint) {
            triggerShowDesktop()
        }
    }
    
    func convertToCGCoordinate(_ point: NSPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return point }
        let screenHeight = mainScreen.frame.height
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
    
    func isClickOnDesktop(at point: CGPoint) -> Bool {
        // 获取所有在屏幕上显示的窗口（按前后遮挡顺序排布）
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }
            
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[kCGWindowName as String] as? String ?? ""
            
            // 核心修复 2: 拦截点击落在系统 Dock 栏以及系统菜单栏/通知中心区域
            if ownerName == "Dock" || ownerName == "SystemUIServer" || ownerName == "ControlCenter" {
                if rect.contains(point) {
                    print("点击被系统服务窗口拦截: \(ownerName), Rect: \(rect)")
                    return false
                }
            }
            
            // 我们只关注普通应用程序窗口（Layer 0）
            if layer == 0 {
                // 排除 Finder 自身的桌面壁纸窗口和桌面图标所在的容器窗口
                if ownerName == "Finder" && (windowName == "" || windowName == "Desktop") {
                    continue
                }
                
                // 排除我们自己
                if ownerName == "ToDesktop" {
                    continue
                }
                
                // 核心突破：利用 NSRunningApplication 检查窗口所有者是否为标准常规 GUI 应用程序。
                // 这一步能彻底排除输入法、手势工具、截图挂件、系统通知等后台运行的“全屏隐形透明窗口”！
                if isRegularApplication(pid: pid) {
                    // 如果鼠标点击点落在了当前可见的常规普通应用窗口边界内
                    if rect.contains(point) {
                        print("点击被常规应用拦截: \(ownerName) (\(windowName)), PID: \(pid), Rect: \(rect)")
                        return false
                    }
                }
            }
        }
        
        // 核心修复 1: 利用 Accessibility API 深度判断鼠标是否落在了 Finder 桌面文件/文件夹图标上
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axResult = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        
        if axResult == .success, let clickedElement = element {
            var elementPid: pid_t = 0
            if AXUIElementGetPid(clickedElement, &elementPid) == .success {
                if let app = NSRunningApplication(processIdentifier: elementPid) {
                    let bundleId = app.bundleIdentifier ?? ""
                    
                    // 如果点击的元素属于 Finder 进程
                    if bundleId == "com.apple.finder" {
                        var roleValue: AnyObject?
                        AXUIElementCopyAttributeValue(clickedElement, kAXRoleAttribute as CFString, &roleValue)
                        if let role = roleValue as? String {
                            // 桌面图标的文件名是 AXStaticText，图标图片是 AXImage
                            if role == "AXStaticText" || role == "AXImage" || role == "AXButton" {
                                print("点击落在桌面文件或文件夹图标上 (Role: \(role))，已拦截")
                                return false
                            }
                        }
                    }
                    
                    // 双重保障：若是点击了 Dock 栏或其他系统元素
                    if bundleId == "com.apple.dock" || bundleId == "com.apple.systemuiserver" || bundleId == "com.apple.controlcenter" {
                        print("点击落在系统特权进程元素上 (\(bundleId))，已拦截")
                        return false
                    }
                }
            }
        }
        
        // 没有落在任何普通活动窗口、系统栏或桌面文件图标上，意味着用户点击了桌面空白壁纸区域！
        return true
    }
    
    // 检查应用是否属于标准的 Regular 前台图形应用（例如 Safari, Finder 文件夹窗口等）
    func isRegularApplication(pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.activationPolicy == .regular
        }
        return false
    }
    
    func triggerShowDesktop() {
        // 限流防抖：每次触发最小间隔为 0.5 秒，防止连续误触导致窗口动画闪烁
        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) > 0.5 else {
            return
        }
        lastTriggerTime = now
        
        print("点击了桌面空白处！正在唤醒 Mission Control 摊开窗口。")
        
        // 原生调用 Mission Control 1 展示/恢复桌面，保持丝滑的原生动画
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        process.arguments = ["1"]
        do {
            try process.run()
        } catch {
            print("调用 Mission Control 失败: \(error)")
        }
    }
    
    // MARK: - 开机自启控制 (AppleScript 实现)
    func setLaunchAtLogin(enabled: Bool) {
        let bundlePath = Bundle.main.bundlePath
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ToDesktop"
        
        var script = ""
        if enabled {
            script = """
            tell application "System Events"
                if not (exists login item "\(bundleName)") then
                    make new login item at end with properties {name:"\(bundleName)", path:"\(bundlePath)", hidden:false}
                end if
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                if exists login item "\(bundleName)" then
                    delete login item "\(bundleName)"
                end if
            end tell
            """
        }
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("设置自启失败: \(error)")
            } else {
                print("已设置自启状态为: \(enabled)")
            }
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ToDesktop"
        let script = """
        tell application "System Events"
            return exists login item "\(bundleName)"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(nil).stringValue {
            return result == "true"
        }
        return false
    }
}

// 主应用启动入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
