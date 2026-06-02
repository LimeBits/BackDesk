import Cocoa
import CoreGraphics
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    
    var isSingleClickEnabled: Bool = true
    var isDoubleClickEnabled: Bool = true
    var lastTriggerTime: Date = Date.distantPast
    var permissionTimer: Timer?
    var pendingClickWorkItem: DispatchWorkItem?
    
    // 自研的高保真双击判定状态机属性
    var lastClickTime: Date = Date.distantPast
    var lastClickPoint: CGPoint = .zero
    
    func logToFile(_ message: String) {
        let logPath = "/Users/bruce/Desktop/b-vibe/todesktop/app_test.log"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        print(message)
        
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            try? logLine.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // 清理以前的旧日志文件，开启本次运行的干净日志
        try? FileManager.default.removeItem(atPath: "/Users/bruce/Desktop/b-vibe/todesktop/app_test.log")
        
        logToFile("==================================================================")
        logToFile("🚀 ToDesktop 应用启动成功！正在载入极客监测日志系统...")
        logToFile("==================================================================")
        
        // 从 UserDefaults 加载用户偏好设置，若不存在则默认为 true
        if UserDefaults.standard.object(forKey: "isSingleClickEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "isSingleClickEnabled")
        }
        if UserDefaults.standard.object(forKey: "isDoubleClickEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "isDoubleClickEnabled")
        }
        
        isSingleClickEnabled = UserDefaults.standard.bool(forKey: "isSingleClickEnabled")
        isDoubleClickEnabled = UserDefaults.standard.bool(forKey: "isDoubleClickEnabled")
        
        logToFile("加载配置偏好: isSingleClickEnabled = \(isSingleClickEnabled)")
        logToFile("加载配置偏好: isDoubleClickEnabled = \(isDoubleClickEnabled)")
        
        // 1. 创建状态栏图标与菜单
        setupStatusItem()
        
        // 2. 检查并请求辅助功能权限
        let hasAccess = checkAccessibility(prompt: false)
        logToFile("系统辅助功能检测结果 (Trust State) = \(hasAccess)")
        
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
            let hasAccess = self.checkAccessibility(prompt: false)
            if hasAccess {
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
    
    func isSystemClickToRevealConflict() -> Bool {
        if #available(macOS 14.0, *) {
            let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
            // 1代表“总是”（开启系统壁纸点击），0代表“仅台前调度”或关闭
            let hideDesktop = defaults?.object(forKey: "HideDesktop") as? Int ?? 1
            return hideDesktop == 1
        }
        return false
    }
    
    @objc func handleSettingsConflict() {
        let alert = NSAlert()
        alert.messageText = "系统原生点击壁纸冲突引导"
        alert.informativeText = "macOS 14+ 系统的「点击壁纸显示桌面」功能会与 ToDesktop 的「双击壁纸平铺」产生时序冲突，且容易引发日常误触。\n\n推荐将系统选项更改为「仅在台前调度时」或关闭。我们将为您打开「系统设置」，请在其页面中进行配置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "去设置")
        alert.addButton(withTitle: "好的")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        
        let is14OrAbove: Bool
        if #available(macOS 14.0, *) {
            is14OrAbove = true
        } else {
            is14OrAbove = false
        }
        
        // 1. 单击开关项 (动态文案)
        let singleClickTitle: String
        let singleClickState: NSControl.StateValue
        if isSingleClickEnabled {
            singleClickTitle = "🖥️ 单击壁纸展示桌面"
            singleClickState = .on
        } else {
            if is14OrAbove {
                singleClickTitle = "🛡️ 屏蔽系统壁纸误触 (推荐)"
                singleClickState = .on // 屏蔽罩处于激活工作状态，显示勾选框以示正常工作
            } else {
                singleClickTitle = "🖥️ 关闭单击壁纸展示桌面"
                singleClickState = .off
            }
        }
        
        let singleClickItem = NSMenuItem(title: singleClickTitle, action: #selector(toggleSingleClick), keyEquivalent: "s")
        singleClickItem.state = singleClickState
        menu.addItem(singleClickItem)
        
        // 2. 双击开关项
        let doubleClickItem = NSMenuItem(title: "🎴 双击壁纸平铺窗口", action: #selector(toggleDoubleClick), keyEquivalent: "d")
        doubleClickItem.state = isDoubleClickEnabled ? .on : .off
        menu.addItem(doubleClickItem)
        
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
    @objc func toggleSingleClick() {
        isSingleClickEnabled.toggle()
        UserDefaults.standard.set(isSingleClickEnabled, forKey: "isSingleClickEnabled")
        
        updateMonitoringState()
        buildMenu()
    }
    
    @objc func toggleDoubleClick() {
        isDoubleClickEnabled.toggle()
        UserDefaults.standard.set(isDoubleClickEnabled, forKey: "isDoubleClickEnabled")
        
        updateMonitoringState()
        buildMenu()
    }
    
    func updateMonitoringState() {
        let hasAccess = checkAccessibility(prompt: false)
        if hasAccess {
            startMonitoring()
        } else {
            stopMonitoring()
        }
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
        alert.informativeText = "ToDesktop v0.2.2\n专为 macOS 12/13/14+ 系统开发的桌面快速展示与误触防护工具。\n\n点击屏幕空白壁纸即可快速展示桌面，双击即可平铺所有窗口。\n\n在 macOS 14+ 上，支持独创的【屏蔽系统壁纸误触】主动防护罩技术。\n\n原生支持 Intel 及 Apple Silicon (ARM) 架构芯片。"
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
    
    func showAccessibilityErrorAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "⚠️ 系统辅助功能授权已失效"
            alert.informativeText = "由于 ToDesktop 进行了重新编译与安装，macOS 安全系统已经置空了之前的隐私授权缓存。\n\n请打开「系统设置 -> 隐私与安全性 -> 辅助功能」，在列表中将 [ToDesktop] 的开关先【关闭】然后再【重新开启】一次，即可彻底恢复正常工作！"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "去系统设置")
            alert.addButton(withTitle: "好的")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    // MARK: - 点击监听与判定
    func startMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.eventTap == nil else { return }
            
            self.logToFile("🔄 准备异步创建 CGEventTap 事件过滤器...")
            
            let eventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            
            AppDelegate.shared = self
            
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let delegate = AppDelegate.shared else {
                        return Unmanaged.passRetained(event)
                    }
                    return delegate.handleCGEvent(proxy: proxy, type: type, event: event)
                },
                userInfo: nil
            ) else {
                self.logToFile("❌ 创建 CGEventTap 失败！系统辅助功能授权静默失效，显示警告向导。")
                self.showAccessibilityErrorAlert()
                return
            }
            
            self.eventTap = tap
            self.runLoopSource = autoreleasepool {
                CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            }
            
            if let source = self.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            
            CGEvent.tapEnable(tap: tap, enable: true)
            self.logToFile("🎉 [EventTap] 已成功启用，开始截获系统鼠标左键按下事件监控。")
        }
    }
    
    func stopMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        print("已关闭 CGEventTap 主动过滤监听")
    }
    
    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .leftMouseDown {
            let point = event.location
            logToFile("🖱️ [Click] 监听到鼠标左键按下，位置坐标: \(point)")
            
            // 核心修复：检查当前屏幕上是否有展开的弹出菜单（Menu Popup）。
            if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                let popUpMenuLevel = CGWindowLevelForKey(.popUpMenuWindow)
                let isMenuExpanded = windowList.contains { window in
                    guard let layer = window[kCGWindowLayer as String] as? Int else { return false }
                    return layer == Int(popUpMenuLevel)
                }
                
                if isMenuExpanded {
                    logToFile("👉 [检测到菜单展开] 当前屏幕上有活跃的弹出菜单(Layer 101)，放行点击以收起菜单。")
                    return Unmanaged.passRetained(event)
                }
            }
            
            // 智能分析是否点击了桌面壁纸
            if isClickOnDesktop(at: point) {
                logToFile("🎯 [壁纸点击判定] 确认点击落在空白壁纸区域！")
                let now = Date()
                let timeDiff = now.timeIntervalSince(lastClickTime)
                let clickDistance = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y)
                
                // 系统双击阈值判定 (NSEvent.doubleClickInterval，通常为 0.25s - 0.3s)
                let doubleClickInterval = NSEvent.doubleClickInterval
                logToFile("状态机判定: doubleClickInterval = \(doubleClickInterval)s, 时间差 = \(timeDiff)s, 距离 = \(clickDistance)px")
                
                if isDoubleClickEnabled && timeDiff < doubleClickInterval && clickDistance < 10 {
                    logToFile("🔥 [双击触发] 判定为双击壁纸！彻底取消单击延迟任务，立即触发 Mission Control 平铺。")
                    
                    // 1. 彻底取消挂起的延迟单击任务，防止屏幕闪烁
                    pendingClickWorkItem?.cancel()
                    pendingClickWorkItem = nil
                    
                    // 2. 立即触发双击平铺
                    triggerMissionControl()
                    
                    // 3. 重置状态戳防止连续多次点击导致的二次触发
                    lastClickTime = Date.distantPast
                    lastClickPoint = .zero
                    
                    logToFile("🚫 [吞噬事件] 返回 nil，物理屏蔽此双击首发点击。")
                    return nil
                } else {
                    logToFile("⏱️ [单击第一下] 判定为可能是单击的第一下。")
                    lastClickTime = now
                    lastClickPoint = point
                    
                    pendingClickWorkItem?.cancel()
                    
                    if isSingleClickEnabled {
                        if isDoubleClickEnabled {
                            // 2a. 若双击功能开启，必须延迟等待系统标准的双击间隔后再执行“单击”逻辑，防止双击事件在判定前流失
                            let workItem = DispatchWorkItem { [weak self] in
                                self?.triggerShowDesktop()
                            }
                            pendingClickWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: workItem)
                        } else {
                            // 2b. 若双击功能关闭，完全无冲突，直接以 0 毫秒绝对零延迟即刻展示桌面！
                            triggerShowDesktop()
                        }
                        // 返回 nil，吞噬该事件，避免系统原生功能的冲突
                        return nil
                    } else {
                        // 单击功能被关闭了
                        // 如果是 macOS 14+，我们通过返回 nil 彻底吞噬它，达到“屏蔽系统壁纸误触”的保护罩效果！
                        if #available(macOS 14.0, *) {
                            return nil
                        } else {
                            // macOS 13 及以下没有原生点击壁纸功能，直接传回原事件即可
                            return Unmanaged.passRetained(event)
                        }
                    }
                }
            }
        }
        
        // 其它地方的点击，直接原样返回放行
        return Unmanaged.passRetained(event)
    }
    
    func convertToCGCoordinate(_ point: NSPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return point }
        let screenHeight = mainScreen.frame.height
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
    
    func isClickOnDesktop(at point: CGPoint) -> Bool {
        logToFile("🔍 [壁纸分析] 开始进行多维度坐标重叠检测...")
        
        // 1. 核心修复：高精度拦截系统顶部菜单栏/状态栏区域的点击（仅限屏幕最顶部那一条窄边）。
        guard let primaryScreen = NSScreen.screens.first else { return false }
        let primaryHeight = primaryScreen.frame.height
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            if screenFrame.contains(cocoaPoint) {
                let visibleFrame = screen.visibleFrame
                let menuBarTopBoundary = visibleFrame.origin.y + visibleFrame.height
                if cocoaPoint.y >= menuBarTopBoundary {
                    logToFile("⚠️ [拦截] 点击落在了系统顶部状态栏/菜单栏内，坐标 CocoaY=\(cocoaPoint.y) >= MenuBarBoundary=\(menuBarTopBoundary)")
                    return false
                }
                break
            }
        }

        // 2. 获取所有在屏幕上显示的窗口（按前后遮挡顺序排布）
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            logToFile("❌ 无法获取系统可见窗口信息列表！")
            return false
        }
        
        // 核心修复：精准判定点击是否落在 Dock 的实际物理像素渲染区域
        if isClickInPhysicalDock(point: point, windowList: windowList) {
            logToFile("⚠️ [拦截] 点击落在了系统 Dock 物理绘制区域内。")
            return false
        }
        
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[kCGWindowName as String] as? String ?? ""
            let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
            
            // 过滤完全透明的窗口
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha == 0 {
                continue
            }
            
            // 核心突破：我们检查所有在屏幕上层绘制的真实图层窗口（Layer >= 0）
            if layer >= 0 {
                // 使用 Bundle ID 检查，彻底消除本地化名称差异对 Finder 的误判
                var isFinder = false
                if let app = NSRunningApplication(processIdentifier: pid) {
                    isFinder = app.bundleIdentifier == "com.apple.finder"
                }
                
                // 排除 Finder 自身的桌面壁纸窗口和桌面图标所在的容器窗口 (兼容多语言系统，加入“桌面”的识别)
                if isFinder && (windowName == "" || windowName == "Desktop" || windowName == "桌面") {
                    continue
                }
                
                // 核心突破：多维度判定当前窗口是否为真实、用户可交互的窗口。
                if isRealInteractiveWindow(pid: pid, windowName: windowName, rect: rect) {
                    if rect.contains(point) {
                        logToFile("🛡️ [常规窗口遮挡] 点击落在活跃窗口范围内! 拦截者: [\(ownerName)] (PID: \(pid), Layer: \(layer), Title: '\(windowName)', Bounds: \(rect))")
                        return false
                    }
                }
            }
        }
        
        // 3. 核心修复：利用 Accessibility API 深度探测鼠标是否落在了 Finder 桌面上的文件/文件夹/磁盘挂载等图标上。
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
                        let role = roleValue as? String ?? ""
                        
                        var titleValue: AnyObject?
                        AXUIElementCopyAttributeValue(clickedElement, kAXTitleAttribute as CFString, &titleValue)
                        let title = (titleValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        print("点击了 Finder 元素 - Role: \(role), Title: \(title)")
                        
                        if role == "AXScrollArea" || role == "AXWindow" {
                            // 极速判定：点击在壁纸的最底层，放行触发桌面摊开
                        } else {
                            // 只要角色不是桌面最底层壁纸背景，且标题不为空、不为 "Desktop"/"桌面"/"Finder"，
                            // 或者角色本身是文字（标签）、图片（图标）、按钮或通用图标，就一律判定为点击了桌面文件图标
                            let isDesktopTitle = (title == "Desktop" || title == "桌面" || title == "Finder" || title.isEmpty)
                            if !isDesktopTitle || role == "AXStaticText" || role == "AXImage" || role == "AXIcon" || role == "AXButton" {
                                print("判定为点击了桌面文件或文件夹图标，已拦截")
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
    
    // 多维度判定窗口是否为真实、用户可交互的窗口
    func isRealInteractiveWindow(pid: Int32, windowName: String, rect: CGRect) -> Bool {
        // 1. 如果是标准的常规前台 GUI 应用程序，那绝对是真实交互窗口
        if isRegularApplication(pid: pid) {
            return true
        }
        
        // 2. 如果窗口有非空的标题，几乎可以肯定是真实窗口（如浏览器弹窗、特定辅助界面、辅助软件的主窗口等）
        if !windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        
        // 3. 如果窗口尺寸不是全屏的，说明是小型浮动面板（如输入法候选词框、悬浮小挂件、Spotlight 搜索栏等），也是真实可交互窗口
        if !isFullscreen(rect: rect) {
            return true
        }
        
        // 其它情况（非常规应用 + 无标题 + 全屏尺寸）：大概率是手势软件全局抓取层、壁纸渲染层等“全屏隐形透明窗口”，不视为真实可交互窗口
        return false
    }
    
    // 检测窗口是否等于任意一个物理显示器的全屏尺寸（允许 2 像素以内的误差以兼容多屏幕分界线偏移）
    func isFullscreen(rect: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            if abs(rect.width - screenFrame.width) < 2 && abs(rect.height - screenFrame.height) < 2 {
                return true
            }
        }
        return false
    }
    
    // 检测点击是否落在 Dock 栏的实际物理绘制范围内（支持两侧空白区域点击触发，且完美覆盖废纸篓与堆栈栏）
    func isClickInPhysicalDock(point: CGPoint, windowList: [[String: Any]]) -> Bool {
        // 我们改用基于 NSScreen.visibleFrame 与 frame 差集的绝对数学几何算法。
        // 这是 macOS 官方原生支持的最优雅、100% 准确、且完全不受任何多语言或全屏 Dock 交互窗口干扰的黄金判定！
        guard let primaryScreen = NSScreen.screens.first else { return false }
        let primaryHeight = primaryScreen.frame.height
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            if screenFrame.contains(cocoaPoint) {
                let visibleFrame = screen.visibleFrame
                
                // 1. 如果点击落在 visibleFrame 内部，这绝对是可用的屏幕区域（非物理 Dock 区域），直接放行
                if visibleFrame.contains(cocoaPoint) {
                    return false
                }
                
                // 2. 如果点击落在顶部状态栏/菜单栏（由 isClickOnDesktop 独立检测放过，这里也放行）
                let menuBarTopBoundary = visibleFrame.origin.y + visibleFrame.height
                if cocoaPoint.y >= menuBarTopBoundary {
                    return false
                }
                
                // 3. 如果点击在 screenFrame 内，但不在 visibleFrame 内，且不在顶部菜单栏：
                // 这必然就是 Dock 物理条所在的像素区域（支持底部、左侧、右侧等任何摆放位置，且自动兼容自动隐藏状态）！
                logToFile("Dock几何拦截: 点击落在 Dock 物理条区域! CocoaPoint=\(cocoaPoint), VisibleFrame=\(visibleFrame), ScreenFrame=\(screenFrame)")
                return true
            }
        }
        return false
    }
    
    func triggerShowDesktop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 限流防抖：每次触发最小间隔为 0.5 秒，防止连续误触导致窗口动画闪烁
            let now = Date()
            guard now.timeIntervalSince(self.lastTriggerTime) > 0.5 else {
                return
            }
            self.lastTriggerTime = now
            
            self.logToFile("唤醒 Mission Control 展示桌面 (Show Desktop)")
            
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["1"]
            
            NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                if let error = error {
                    self?.logToFile("❌ NSWorkspace launch ShowDesktop failed: \(error.localizedDescription)")
                } else {
                    self?.logToFile("✓ NSWorkspace launch ShowDesktop success.")
                }
            }
        }
    }
    
    func triggerMissionControl() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 限流防抖：每次触发最小间隔为 0.5 秒，防止连续误触导致窗口动画闪烁
            let now = Date()
            guard now.timeIntervalSince(self.lastTriggerTime) > 0.5 else {
                return
            }
            self.lastTriggerTime = now
            
            self.logToFile("唤醒 Mission Control 展开所有窗口列表")
            
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let config = NSWorkspace.OpenConfiguration()
            
            NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                if let error = error {
                    self?.logToFile("❌ NSWorkspace launch MissionControl failed: \(error.localizedDescription)")
                } else {
                    self?.logToFile("✓ NSWorkspace launch MissionControl success.")
                }
            }
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
