import Cocoa
import CoreGraphics
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var globalMonitor: Any?
    
    var isSingleClickEnabled: Bool = true
    var isDoubleClickEnabled: Bool = true
    var lastTriggerTime: Date = Date.distantPast
    var permissionTimer: Timer?
    var pendingClickWorkItem: DispatchWorkItem?
    
    // 自研的高保真双击判定状态机属性
    var lastClickTime: Date = Date.distantPast
    var lastClickPoint: CGPoint = .zero
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从 UserDefaults 加载用户偏好设置，若不存在则默认为 true
        if UserDefaults.standard.object(forKey: "isSingleClickEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "isSingleClickEnabled")
        }
        if UserDefaults.standard.object(forKey: "isDoubleClickEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "isDoubleClickEnabled")
        }
        
        isSingleClickEnabled = UserDefaults.standard.bool(forKey: "isSingleClickEnabled")
        isDoubleClickEnabled = UserDefaults.standard.bool(forKey: "isDoubleClickEnabled")
        
        // 1. 创建状态栏图标与菜单
        setupStatusItem()
        
        // 2. 检查并请求辅助功能权限
        let hasAccess = checkAccessibility(prompt: false)
        let shouldMonitor = hasAccess && (isSingleClickEnabled || isDoubleClickEnabled)
        
        if shouldMonitor {
            startMonitoring()
        } else if !hasAccess {
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
                
                let shouldMonitor = self.isSingleClickEnabled || self.isDoubleClickEnabled
                if shouldMonitor {
                    self.startMonitoring()
                }
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
        
        // 0. 智能检测并展示系统原生冲突引导警告
        if isSystemClickToRevealConflict() {
            let conflictItem = NSMenuItem(title: "⚠️ 建议优化系统设置以避免冲突...", action: #selector(handleSettingsConflict), keyEquivalent: "")
            menu.addItem(conflictItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // 1. 单击开关项
        let singleClickItem = NSMenuItem(title: "🖥️ 单击壁纸展示桌面", action: #selector(toggleSingleClick), keyEquivalent: "s")
        singleClickItem.state = isSingleClickEnabled ? .on : .off
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
        let shouldMonitor = hasAccess && (isSingleClickEnabled || isDoubleClickEnabled)
        
        if shouldMonitor {
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
        alert.informativeText = "ToDesktop v0.2.1\n专为 macOS 12/13/14+ 系统开发的桌面快速展示与误触防护工具。\n\n点击屏幕空白壁纸即可快速展示桌面，双击即可平铺所有窗口。\n\n在 macOS 14+ 上，支持独创的【屏蔽系统壁纸误触】主动防护罩技术。\n\n原生支持 Intel 及 Apple Silicon (ARM) 架构芯片。"
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
        guard globalMonitor == nil && (isSingleClickEnabled || isDoubleClickEnabled) else { return }
        
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
        let mouseLocation = NSEvent.mouseLocation
        let clickPoint = convertToCGCoordinate(mouseLocation)
        
        // 智能分析是否点击了桌面壁纸
        guard isClickOnDesktop(at: clickPoint) else { return }
        
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastClickTime)
        let clickDistance = hypot(clickPoint.x - lastClickPoint.x, clickPoint.y - lastClickPoint.y)
        
        let doubleClickInterval = NSEvent.doubleClickInterval
        
        if isDoubleClickEnabled && timeDiff < doubleClickInterval && clickDistance < 10 {
            // 【判定为双击】
            pendingClickWorkItem?.cancel()
            pendingClickWorkItem = nil
            
            triggerMissionControl()
            
            lastClickTime = Date.distantPast
            lastClickPoint = .zero
        } else {
            // 【判定为单击第一下】
            lastClickTime = now
            lastClickPoint = clickPoint
            
            pendingClickWorkItem?.cancel()
            
            if isSingleClickEnabled {
                if isDoubleClickEnabled {
                    // 若双击功能开启，延迟等待系统标准的双击间隔后再执行“单击”逻辑，防止双击事件在判定前流失
                    let workItem = DispatchWorkItem { [weak self] in
                        self?.triggerShowDesktop()
                    }
                    pendingClickWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: workItem)
                } else {
                    // 若双击功能关闭，完全无冲突，直接以 0 毫秒绝对零延迟即刻展示桌面！
                    triggerShowDesktop()
                }
            }
        }
    }
    
    func convertToCGCoordinate(_ point: NSPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return point }
        let screenHeight = mainScreen.frame.height
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
    
    func isClickOnDesktop(at point: CGPoint) -> Bool {
        // 1. 核心修复：高精度拦截系统顶部菜单栏/状态栏区域的点击（仅限屏幕最顶部那一条窄边）。
        // 采用 visibleFrame 的顶层高度分界比对，不拦截底部 Dock 栏两端的空白壁纸区域。
        guard let primaryScreen = NSScreen.screens.first else { return false }
        let primaryHeight = primaryScreen.frame.height
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            if screenFrame.contains(cocoaPoint) {
                let visibleFrame = screen.visibleFrame
                let menuBarTopBoundary = visibleFrame.origin.y + visibleFrame.height
                if cocoaPoint.y >= menuBarTopBoundary {
                    print("点击落在顶部菜单栏区域，已拦截")
                    return false
                }
                break
            }
        }

        // 2. 获取所有在屏幕上显示的窗口（按前后遮挡顺序排布）
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        // 核心修复：精准判定点击是否落在 Dock 的实际物理像素渲染区域（包含左右和边缘的一定容错余量）。
        // 这样可以完美支持点击 Dock 栏两侧底部的空白壁纸露出区，同时也把废纸篓和所有最小化图标完全覆盖进去拦截！
        if isClickInPhysicalDock(point: point, windowList: windowList) {
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
                
                // 核心突破：多维度判定当前窗口是否为真实、用户可交互的窗口。
                // 这一步能彻底排除手势工具、截图背景层等全屏隐形透明背景窗口，同时完美支持浏览器渲染进程等辅助窗口！
                if isRealInteractiveWindow(pid: pid, windowName: windowName, rect: rect) {
                    // 如果鼠标点击点落在了当前可见的常规普通应用窗口边界内
                    if rect.contains(point) {
                        print("点击被真实应用窗口拦截: \(ownerName) (\(windowName)), PID: \(pid), Rect: \(rect)")
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
        var dockRects = [CGRect]()
        for window in windowList {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            if ownerName == "Dock" {
                if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                   let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                    // 忽略极小的窗口（如通知角标、隐藏指示线等小于50px的微小图层）
                    if rect.width > 50 && rect.height > 50 {
                        dockRects.append(rect)
                    }
                }
            }
        }
        
        guard !dockRects.isEmpty else { return false }
        
        // 计算囊括所有有效 Dock 窗口（主面板、图标区、废纸篓与堆栈等）的合并包围盒
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        
        for rect in dockRects {
            minX = min(minX, rect.origin.x)
            maxX = max(maxX, rect.origin.x + rect.size.width)
            minY = min(minY, rect.origin.y)
            maxY = max(maxY, rect.origin.y + rect.size.height)
        }
        
        let unionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        
        // 给合并盒四周增加 15 像素的外延保护带（确保手势误触、废纸篓圆角边缘以及最小化堆栈的点击完全被包裹拦截）
        let paddedRect = unionRect.insetBy(dx: -15, dy: -15)
        
        if paddedRect.contains(point) {
            print("点击落在物理 Dock 栏范围之内，予以拦截。包围盒: \(unionRect)")
            return true
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
    
    func triggerMissionControl() {
        // 限流防抖：每次触发最小间隔为 0.5 秒，防止连续误触导致窗口动画闪烁
        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) > 0.5 else {
            return
        }
        lastTriggerTime = now
        
        print("双击了桌面空白处！正在唤醒 Mission Control 展开所有窗口列表。")
        
        // 原生调用 Mission Control，不带参数（默认无参数是展开所有窗口平铺列表）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        do {
            try process.run()
        } catch {
            print("调用 Mission Control 展开所有窗口列表失败: \(error)")
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
