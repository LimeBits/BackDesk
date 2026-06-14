import Cocoa
import CoreGraphics
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var globalMonitor: Any?
    var eventTapWatchdogTimer: Timer?
    
    var isSingleClickEnabled: Bool = true
    var isDoubleClickEnabled: Bool = true
    var lastTriggerTime: Date = Date.distantPast
    var permissionTimer: Timer?
    var pendingClickWorkItem: DispatchWorkItem?
    var mouseDownPoint: CGPoint?
    var mouseDownStartedOnDesktop: Bool = false
    var cachedWindowList: [[String: Any]]?
    var cachedWindowListDate: Date = Date.distantPast
    var swallowedClickTimes: [Date] = []
    var monitoringResumeWorkItem: DispatchWorkItem?
    var currentDesktopHitCountsForFuse: Bool = true
    let userExcludedBundleIDsKey = "userExcludedBundleIDs"
    let clickDebugLoggingEnabledKey = "clickDebugLoggingEnabled"
    let dragCancelThreshold: CGFloat = 8
    let swallowedClickFuseLimit = 8
    let swallowedClickFuseWindow: TimeInterval = 6.0

    enum DockHitTestResult {
        case outsideDockArea
        case dockWindow
        case reservedEmptyArea
    }
    
    // 自研的高保真双击判定状态机属性
    var lastClickTime: Date = Date.distantPast
    var lastClickPoint: CGPoint = .zero

    func logFileURL() -> URL {
        let fileManager = FileManager.default
        do {
            let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let logDirectory = appSupport.appendingPathComponent("BackDesk", isDirectory: true)
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            return logDirectory.appendingPathComponent("backdesk.log")
        } catch {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backdesk.log")
        }
    }
    
    func logToFile(_ message: String) {
        let logURL = logFileURL()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        print(message)
        
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            fileHandle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            try? logLine.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func debugLog(_ message: String) {
        if UserDefaults.standard.bool(forKey: clickDebugLoggingEnabledKey) {
            logToFile(message)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // 清理以前的旧日志文件，开启本次运行的干净日志
        try? FileManager.default.removeItem(at: logFileURL())
        
        logToFile("==================================================================")
        logToFile("🚀 BackDesk 应用启动成功！正在载入极客监测日志系统...")
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
        
        print("BackDesk App Started successfully.")
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
        monitoringResumeWorkItem?.cancel()
        monitoringResumeWorkItem = nil
        stopMonitoring()
    }
    
    // MARK: - 状态栏 UI 设置
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // 使用 SF Symbols 的 🖥️ (desktopcomputer) 作为图标，如果不可用则回退到文本
            if let image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "BackDesk") {
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
        alert.informativeText = "macOS 14+ 系统的「点击壁纸显示桌面」功能会与 BackDesk 的「双击壁纸平铺」产生时序冲突，且容易引发日常误触。\n\n推荐将系统选项更改为「仅在台前调度时」或关闭。我们将为您打开「系统设置」，请在其页面中进行配置。"
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
        menu.addItem(buildCompatibilityMenuItem())
        
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
        menu.addItem(NSMenuItem(title: "关于 BackDesk", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }

    func buildCompatibilityMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "高级兼容性", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let frontmostApp = currentContextApp()

        let appExclusionTitle: String
        let appExclusionState: NSControl.StateValue
        if let app = frontmostApp {
            let appName = app.localizedName ?? app.bundleIdentifier ?? "当前应用"
            if isUserExcluded(bundleId: app.bundleIdentifier) {
                appExclusionTitle = "关闭当前应用兼容模式：\(appName)"
                appExclusionState = .on
            } else {
                appExclusionTitle = "开启当前应用兼容模式：\(appName)"
                appExclusionState = .off
            }
        } else {
            appExclusionTitle = "开启当前应用兼容模式"
            appExclusionState = .off
        }

        let appExclusionItem = NSMenuItem(title: appExclusionTitle, action: #selector(toggleCurrentAppExclusion), keyEquivalent: "")
        appExclusionItem.state = appExclusionState
        appExclusionItem.isEnabled = frontmostApp?.bundleIdentifier != nil
        submenu.addItem(appExclusionItem)

        let clearExclusionItem = NSMenuItem(title: "清空兼容模式应用列表", action: #selector(clearAppExclusions), keyEquivalent: "")
        clearExclusionItem.isEnabled = !userExcludedBundleIDs().isEmpty
        submenu.addItem(clearExclusionItem)

        submenu.addItem(NSMenuItem.separator())

        let debugItem = NSMenuItem(title: "记录点击调试日志", action: #selector(toggleClickDebugLogging), keyEquivalent: "")
        debugItem.state = UserDefaults.standard.bool(forKey: clickDebugLoggingEnabledKey) ? .on : .off
        submenu.addItem(debugItem)

        if monitoringResumeWorkItem == nil {
            let pauseItem = NSMenuItem(title: "紧急暂停监听 5 分钟", action: #selector(pauseMonitoringFromMenu), keyEquivalent: "")
            submenu.addItem(pauseItem)
        } else {
            let resumeItem = NSMenuItem(title: "立即恢复监听", action: #selector(resumeMonitoringFromMenu), keyEquivalent: "")
            submenu.addItem(resumeItem)
        }

        item.submenu = submenu
        return item
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

    @objc func toggleCurrentAppExclusion() {
        guard let app = currentContextApp(), let bundleId = app.bundleIdentifier else {
            return
        }

        var excluded = userExcludedBundleIDs()
        if excluded.contains(bundleId) {
            excluded.remove(bundleId)
            logToFile("✅ [应用排除] 已允许当前应用触发 BackDesk: \(bundleId)")
        } else {
            excluded.insert(bundleId)
            logToFile("🛡️ [应用排除] 已在当前应用中停用 BackDesk: \(bundleId)")
        }
        UserDefaults.standard.set(Array(excluded).sorted(), forKey: userExcludedBundleIDsKey)
        buildMenu()
    }

    @objc func clearAppExclusions() {
        UserDefaults.standard.removeObject(forKey: userExcludedBundleIDsKey)
        logToFile("✅ [应用排除] 已清空用户应用排除列表。")
        buildMenu()
    }

    @objc func toggleClickDebugLogging() {
        let newValue = !UserDefaults.standard.bool(forKey: clickDebugLoggingEnabledKey)
        UserDefaults.standard.set(newValue, forKey: clickDebugLoggingEnabledKey)
        logToFile(newValue ? "🧪 [调试日志] 已开启点击调试日志。" : "🧪 [调试日志] 已关闭点击调试日志。")
        buildMenu()
    }

    @objc func pauseMonitoringFromMenu() {
        emergencyPauseMonitoring(seconds: 300, reason: "用户从菜单执行紧急暂停")
    }

    @objc func resumeMonitoringFromMenu() {
        monitoringResumeWorkItem?.cancel()
        monitoringResumeWorkItem = nil
        logToFile("✅ [紧急暂停] 用户手动恢复监听。")
        startMonitoring()
        buildMenu()
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "关于 BackDesk"
        alert.informativeText = "BackDesk v0.2.5\n专为 macOS 12/13/14+ 系统开发的桌面快速展示与误触防护工具。\n\n点击屏幕空白壁纸即可快速展示桌面，双击即可平铺所有窗口。\n\n在 macOS 14+ 上，支持独创的【屏蔽系统壁纸误触】主动防护罩技术。\n\n原生支持 Intel 及 Apple Silicon (ARM) 架构芯片。"
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
        alert.informativeText = "BackDesk 需要“辅助功能”权限来监听您的鼠标点击，以识别何时点击了桌面空白壁纸。\n\n请在随后的系统弹窗中，打开「系统设置」并允许 BackDesk 运行。开启后请重新点击状态栏菜单更新状态。"
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
            alert.informativeText = "由于 BackDesk 进行了重新编译与安装，macOS 安全系统已经置空了之前的隐私授权缓存。\n\n请打开「系统设置 -> 隐私与安全性 -> 辅助功能」，在列表中将 [BackDesk] 的开关先【关闭】然后再【重新开启】一次，即可彻底恢复正常工作！"
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
            
            if #available(macOS 14.0, *) {
                guard self.eventTap == nil else { return }
                self.logToFile("🔄 准备异步创建 CGEventTap 事件过滤器...")
                
                let eventMask = CGEventMask(
                    (1 << CGEventType.leftMouseDown.rawValue) |
                    (1 << CGEventType.leftMouseDragged.rawValue) |
                    (1 << CGEventType.leftMouseUp.rawValue)
                )
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
                self.startEventTapWatchdog()
                self.logToFile("🎉 [EventTap] 已成功启用，开始截获系统鼠标左键按下事件监控。")
            } else {
                // macOS 13 及以下直接使用极稳定全局监听机制，不需也不应使用 CGEventTap
                guard self.globalMonitor == nil else { return }
                self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                    self?.handleGlobalClick(event)
                }
                self.logToFile("🎉 [GlobalMonitor] 已成功开启 macOS 13 及以下版本全局点击监听。")
            }
        }
    }
    
    func stopMonitoring() {
        if #available(macOS 14.0, *) {
            eventTapWatchdogTimer?.invalidate()
            eventTapWatchdogTimer = nil
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source = runLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                }
                eventTap = nil
                runLoopSource = nil
            }
            print("已关闭 CGEventTap 主动过滤监听")
        } else {
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
                globalMonitor = nil
            }
            print("已关闭全局点击监听")
        }
    }

    func emergencyPauseMonitoring(seconds: TimeInterval, reason: String) {
        logToFile("🚨 [紧急暂停] \(reason)。暂停监听 \(Int(seconds)) 秒，期间所有鼠标左键将原样放行。")
        cancelPendingClick(reason: "紧急暂停监听")
        resetMouseTracking()
        swallowedClickTimes.removeAll()

        monitoringResumeWorkItem?.cancel()
        monitoringResumeWorkItem = nil
        stopMonitoring()
        buildMenu()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logToFile("✅ [紧急暂停] 暂停时间结束，尝试恢复监听。")
            self.monitoringResumeWorkItem = nil
            self.startMonitoring()
            self.buildMenu()
        }
        monitoringResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func requestEmergencyPauseMonitoring(seconds: TimeInterval, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.emergencyPauseMonitoring(seconds: seconds, reason: reason)
        }
    }

    func startEventTapWatchdog() {
        eventTapWatchdogTimer?.invalidate()
        eventTapWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.checkAccessibility(prompt: false) else {
                self.logToFile("⚠️ [EventTap Watchdog] 辅助功能权限当前不可用，暂停重启事件监听。")
                return
            }

            if let tap = self.eventTap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                self.logToFile("⚠️ [EventTap Watchdog] 事件监听端口已失效，准备重建。")
                self.eventTap = nil
                self.runLoopSource = nil
                self.startMonitoring()
            }
        }
    }
    
    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logToFile("⚠️ [EventTap] 监听被系统禁用(type=\(type.rawValue))，立即重新启用。")
            if let tap = eventTap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                eventTap = nil
                runLoopSource = nil
                startMonitoring()
            }
            return Unmanaged.passRetained(event)
        }

        if isEmergencyBypassEvent(event) {
            requestEmergencyPauseMonitoring(seconds: 60, reason: "检测到 Control+Option+Command 左键兜底手势")
            return Unmanaged.passRetained(event)
        }

        if type == .leftMouseDragged {
            handleDragProgress(at: event.location)
            return mouseDownStartedOnDesktop ? nil : Unmanaged.passRetained(event)
        }

        if type == .leftMouseUp {
            let startedOnDesktop = mouseDownStartedOnDesktop
            resetMouseTracking()
            return startedOnDesktop ? nil : Unmanaged.passRetained(event)
        }

        if type == .leftMouseDown {
            let point = event.location
            mouseDownPoint = point
            mouseDownStartedOnDesktop = false
            logToFile("🖱️ [Click] 监听到鼠标左键按下，位置坐标: \(point)")
            
            // 核心修复：检查当前屏幕上是否有展开的弹出菜单（Menu Popup）。
            if let windowList = currentWindowList() {
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
                mouseDownStartedOnDesktop = true
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
                    recordSwallowedClick(at: point, reason: "双击壁纸触发")
                    return nil
                } else {
                    logToFile("⏱️ [单击第一下] 判定为可能是单击的第一下。")
                    lastClickTime = now
                    lastClickPoint = point
                    
                    pendingClickWorkItem?.cancel()
                    
                    if isSingleClickEnabled {
                        let isMCActive = self.isMissionControlActive()
                        self.logToFile("🕵️ [平铺检测] 当前平铺状态 active = \(isMCActive)")
                        
                        if isMCActive {
                            // 若当前处于平铺状态，单击空白处即可恢复窗口（通过调起 Mission Control 切换）
                            if isDoubleClickEnabled {
                                let workItem = DispatchWorkItem { [weak self] in
                                    self?.triggerMissionControl()
                                }
                                pendingClickWorkItem = workItem
                                DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: workItem)
                            } else {
                                triggerMissionControl()
                            }
                        } else {
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
                        }
                        // 返回 nil，吞噬该事件，避免系统原生功能的冲突
                        recordSwallowedClick(at: point, reason: "单击壁纸触发或等待双击")
                        return nil
                    } else {
                        // 单击功能被关闭了
                        // 如果是 macOS 14+，我们通过返回 nil 彻底吞噬它，达到“屏蔽系统壁纸误触”的保护罩效果！
                        if #available(macOS 14.0, *) {
                            recordSwallowedClick(at: point, reason: "单击功能关闭时屏蔽系统原生壁纸误触")
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
    
    func handleGlobalClick(_ event: NSEvent) {
        // 获取当前鼠标位置 (Y 轴从屏幕底部向上增加)
        let mouseLocation = NSEvent.mouseLocation
        
        // 转换为 CG 坐标系 (Y 轴从屏幕顶部向下增加)
        let clickPoint = convertToCGCoordinate(mouseLocation)

        if event.type == .leftMouseDragged {
            handleDragProgress(at: clickPoint)
            return
        }

        if event.type == .leftMouseUp {
            resetMouseTracking()
            return
        }

        guard event.type == .leftMouseDown else {
            return
        }

        mouseDownPoint = clickPoint
        mouseDownStartedOnDesktop = false
        
        logToFile("鼠标左键按下，位置坐标: \(clickPoint)")
        
        if isClickOnDesktop(at: clickPoint) {
            mouseDownStartedOnDesktop = true
            logToFile("🎯 [macOS 13 壁纸点击判定] 确认点击落在空白壁纸区域！")
            let now = Date()
            let timeDiff = now.timeIntervalSince(lastClickTime)
            let clickDistance = hypot(clickPoint.x - lastClickPoint.x, clickPoint.y - lastClickPoint.y)
            
            let doubleClickInterval = NSEvent.doubleClickInterval
            
            if isDoubleClickEnabled && timeDiff < doubleClickInterval && clickDistance < 10 {
                logToFile("🔥 [macOS 13 双击触发] 判定为双击壁纸！彻底取消单击延迟任务，立即触发 Mission Control 平铺。")
                pendingClickWorkItem?.cancel()
                pendingClickWorkItem = nil
                
                triggerMissionControl()
                
                lastClickTime = Date.distantPast
                lastClickPoint = .zero
            } else {
                logToFile("⏱️ [macOS 13 单击第一下] 判定为可能是单击的第一下。")
                lastClickTime = now
                lastClickPoint = clickPoint
                
                pendingClickWorkItem?.cancel()
                
                if isSingleClickEnabled {
                    let isMCActive = self.isMissionControlActive()
                    self.logToFile("🕵️ [macOS 13 平铺检测] 当前平铺状态 active = \(isMCActive)")
                    
                    if isMCActive {
                        if isDoubleClickEnabled {
                            let workItem = DispatchWorkItem { [weak self] in
                                self?.triggerMissionControl()
                            }
                            pendingClickWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: workItem)
                        } else {
                            triggerMissionControl()
                        }
                    } else {
                        if isDoubleClickEnabled {
                            let workItem = DispatchWorkItem { [weak self] in
                                self?.triggerShowDesktop()
                            }
                            pendingClickWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: workItem)
                        } else {
                            triggerShowDesktop()
                        }
                    }
                }
            }
        }
    }
    

    
    func convertToCGCoordinate(_ point: NSPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    func convertToCocoaCoordinate(_ point: CGPoint) -> NSPoint {
        guard let primaryScreen = NSScreen.screens.first else { return point }
        return NSPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    func screenContaining(cocoaPoint: NSPoint) -> NSScreen? {
        return NSScreen.screens.first { $0.frame.contains(cocoaPoint) }
    }

    func handleDragProgress(at point: CGPoint) {
        guard mouseDownStartedOnDesktop, let downPoint = mouseDownPoint else {
            return
        }

        let distance = hypot(point.x - downPoint.x, point.y - downPoint.y)
        if distance > dragCancelThreshold {
            cancelPendingClick(reason: "拖拽距离 \(String(format: "%.1f", distance))px 超过阈值")
            lastClickTime = Date.distantPast
            lastClickPoint = .zero
            mouseDownStartedOnDesktop = false
        }
    }

    func resetMouseTracking() {
        mouseDownPoint = nil
        mouseDownStartedOnDesktop = false
    }

    func cancelPendingClick(reason: String) {
        if pendingClickWorkItem != nil {
            logToFile("🛑 [取消触发] \(reason)，已取消挂起的单击动作。")
        }
        pendingClickWorkItem?.cancel()
        pendingClickWorkItem = nil
    }

    func recordSwallowedClick(at point: CGPoint, reason: String) {
        guard currentDesktopHitCountsForFuse else {
            debugLog("🧪 [吞噬统计] reason=\(reason), point=\(point), 当前命中来源不计入自动保险丝。")
            return
        }

        let now = Date()
        swallowedClickTimes = swallowedClickTimes.filter { now.timeIntervalSince($0) <= swallowedClickFuseWindow }
        swallowedClickTimes.append(now)
        debugLog("🧪 [吞噬统计] reason=\(reason), point=\(point), count=\(swallowedClickTimes.count)/\(swallowedClickFuseLimit)")

        if swallowedClickTimes.count >= swallowedClickFuseLimit {
            requestEmergencyPauseMonitoring(seconds: 60, reason: "连续 \(swallowedClickTimes.count) 次左键被 BackDesk 吞噬，触发自动保险丝")
        }
    }

    func userExcludedBundleIDs() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: userExcludedBundleIDsKey) ?? []
        return Set(values)
    }

    func isUserExcluded(bundleId: String?) -> Bool {
        guard let bundleId = bundleId else { return false }
        return userExcludedBundleIDs().contains(bundleId)
    }

    func currentContextApp() -> NSRunningApplication? {
        let ignoredBundleIds: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.systemuiserver",
            "com.apple.controlcenter",
            "com.apple.dock"
        ]

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           !ignoredBundleIds.contains(bundleId) {
            return frontmost
        }

        return NSWorkspace.shared.runningApplications.first { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return app.isActive && !ignoredBundleIds.contains(bundleId)
        }
    }

    func currentWindowList(maxAge: TimeInterval = 0.08) -> [[String: Any]]? {
        let now = Date()
        if let cachedWindowList = cachedWindowList, now.timeIntervalSince(cachedWindowListDate) <= maxAge {
            return cachedWindowList
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        cachedWindowList = windowList
        cachedWindowListDate = now
        return windowList
    }

    func isEmergencyBypassEvent(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }
    
    // 检查元素是否位于 Finder 实体标准文件夹窗口 (AXStandardWindow) 内部
    func isInsideStandardWindow(element: AXUIElement) -> Bool {
        var current = element
        while true {
            var roleValue: AnyObject?
            let roleResult = AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue)
            if roleResult == .success, let role = roleValue as? String {
                if role == "AXWindow" {
                    var subroleValue: AnyObject?
                    let subroleResult = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subroleValue)
                    if subroleResult == .success, let subrole = subroleValue as? String {
                        if subrole == "AXStandardWindow" {
                            if #available(macOS 14.0, *) {
                                // macOS 14.0+ 保持原汁原味、之前已经验证完美的逻辑，不要动它！
                                return true
                            } else {
                                // 为了区分真正的 Finder 文件夹窗口与 macOS 13 及以下系统的桌面背景窗口（其在 AX 树中也可能有 AXWindow 祖先），
                                // 我们双重检验其是否具有关闭按钮属性，或者其窗口标题是否不为“Desktop”/“桌面”/空。
                                var closeButtonValue: AnyObject?
                                let hasCloseButton = AXUIElementCopyAttributeValue(current, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success && closeButtonValue != nil
                                
                                var titleValue: AnyObject?
                                AXUIElementCopyAttributeValue(current, kAXTitleAttribute as CFString, &titleValue)
                                let title = (titleValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                let isDesktopTitle = (title == "Desktop" || title == "桌面" || title.isEmpty)
                                
                                // 只有具备关闭按钮（说明是实体交互窗口）或者其非桌面标题时，才确认为真正的 Finder 实体文件夹窗口
                                if hasCloseButton || !isDesktopTitle {
                                    return true
                                }
                            }
                        }
                    }
                    return false
                }
            }
            
            var parentValue: AnyObject?
            let parentResult = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue)
            if parentResult == .success, let parent = parentValue {
                current = parent as! AXUIElement
            } else {
                break
            }
        }
        return false
    }
    
    func isClickOnDesktop(at point: CGPoint) -> Bool {
        logToFile("🔍 [壁纸分析] 开始进行多维度坐标重叠检测...")
        currentDesktopHitCountsForFuse = true
        
        // 1. 核心检测：高精度拦截系统顶部菜单栏/状态栏区域的点击（仅限屏幕最顶部那一条窄边）。
        let cocoaPoint = convertToCocoaCoordinate(point)

        if let frontmostApp = currentContextApp(), isUserExcluded(bundleId: frontmostApp.bundleIdentifier) {
            logToFile("🛡️ [应用排除] 当前应用已停用 BackDesk: \(frontmostApp.localizedName ?? frontmostApp.bundleIdentifier ?? "Unknown")")
            return false
        }
        
        if let screen = screenContaining(cocoaPoint: cocoaPoint) {
            let visibleFrame = screen.visibleFrame
            let menuBarTopBoundary = visibleFrame.origin.y + visibleFrame.height
            if cocoaPoint.y >= menuBarTopBoundary {
                logToFile("⚠️ [拦截] 点击落在了系统顶部状态栏/菜单栏内，坐标 CocoaY=\(cocoaPoint.y) >= MenuBarBoundary=\(menuBarTopBoundary)")
                return false
            }
        }

        // 2. 获取所有在屏幕上显示的窗口，用于 Dock 点击几何辅助判定及兜底检测
        guard let windowList = currentWindowList() else {
            logToFile("❌ 无法获取系统可见窗口信息列表！")
            return false
        }
        
        // 3. 核心检测：精准判定点击是否落在 Dock 的实际物理像素渲染区域
        let dockHitTest = dockHitTest(point: point, windowList: windowList)
        if dockHitTest == .dockWindow {
            logToFile("⚠️ [Dock放行] 点击落在了系统 Dock 或可能的图标区域内，交给系统处理。")
            return false
        }
        if dockHitTest == .reservedEmptyArea {
            currentDesktopHitCountsForFuse = false
            logToFile("🎯 [Dock空白判定] 点击落在 Dock 预留区两侧空白，直接按桌面空白处理。")
            return true
        }

        if hasProtectedOverlay(at: point, windowList: windowList) {
            return false
        }
        
        // 4. 【核心黄金法则】第一优先：Accessibility API 深度穿透探测。
        // 这能极其完美地穿透所有不接收普通点击的第三方纯透明/监听全屏窗口（如微信 Layer 27、Chrome 的无标题 GPU 隐形层等），直接捕捉真实底层 UI 控件！
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axResult = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        
        if axResult == .success, let clickedElement = element {
            var elementPid: pid_t = 0
            if AXUIElementGetPid(clickedElement, &elementPid) == .success {
                if let app = NSRunningApplication(processIdentifier: elementPid) {
                    let bundleId = app.bundleIdentifier ?? ""
                    let appName = app.localizedName ?? bundleId
                    
                    // A. 如果点击的元素属于 Finder 进程
                    if bundleId == "com.apple.finder" {
                        var roleValue: AnyObject?
                        AXUIElementCopyAttributeValue(clickedElement, kAXRoleAttribute as CFString, &roleValue)
                        let role = roleValue as? String ?? ""
                        
                        var titleValue: AnyObject?
                        AXUIElementCopyAttributeValue(clickedElement, kAXTitleAttribute as CFString, &titleValue)
                        let title = (titleValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        logToFile("🔍 [AX分析] 点击了 Finder 元素 - Role: \(role), Title: '\(title)'")
                        
                        let isDesktopRole = (role == "AXScrollArea" || role == "AXWindow" || role == "AXGroup")
                        let isDesktopTitle = (title == "Desktop" || title == "桌面" || title.isEmpty)
                        
                        if isDesktopRole && isDesktopTitle {
                            // 为了排除真实 Finder 文件夹窗口中的空白区域或组组件，
                            // 我们使用 AX API 顺着父链检测该元素是否位于真实的 Finder 标准文件夹窗口 (AXStandardWindow) 内部。
                            let isInsideFolder = isInsideStandardWindow(element: clickedElement)
                            
                            if !isInsideFolder {
                                logToFile("🎯 [AX判定] 确认点击落在空白壁纸最底层区域！")
                                return true
                            } else {
                                logToFile("🛡️ [AX拦截] 点击落在 Finder 实体文件夹窗口的空白区域内")
                                return false
                            }
                        } else {
                            // 只要角色不是桌面背景本身，且属于 Finder（如桌面文件图标、Finder窗口的控制组件等），一律视为点击了文件图标或活动 Finder 窗口
                            logToFile("🛡️ [AX拦截] 点击落在 Finder 非桌面背景元素上 (Role: \(role), Title: '\(title)')")
                            return false
                        }
                    }
                    
                    // B. 双重保障：若是点击了 Dock 栏或其他系统 UI 特权元素
                    if bundleId == "com.apple.dock" || bundleId == "com.apple.systemuiserver" || bundleId == "com.apple.controlcenter" {
                        logToFile("🛡️ [AX拦截] 点击落在系统特权进程元素上 (\(bundleId))")
                        return false
                    }
                    
                    // C. 其它第三方 App 的真实 UI 元素拦截
                    // 如果点击到了其他任何第三方应用程序（如 Chrome, WeChat 聊天窗口，文本编辑等）的 UI 元素，说明物理上确实被真实可见窗口遮挡了
                    logToFile("🛡️ [AX拦截] 点击落在活跃 App [\(appName)] 的真实 UI 元素上")
                    return false
                }
            }
        }
        
        // 5. 第二优先：Geometry Fallback 几何兜底检测。
        // 当 Accessibility API 遇到无 AX 特性窗口、卡顿或未授权等异常返回失败时，我们以高性能的窗口重叠几何碰撞进行稳健兜底。
        logToFile("⚠️ [AX兜底] Accessibility 未能识别此坐标下的元素，启用几何重叠兜底检测...")
        
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
            
            if isProtectedOverlayWindow(pid: pid, ownerName: ownerName, windowName: windowName, layer: layer, rect: rect, window: window) {
                logToFile("🛡️ [遮罩拦截] 检测到截图/选区类高层遮罩，放行给前台工具处理。Owner: [\(ownerName)] PID: \(pid), Layer: \(layer), Bounds: \(rect)")
                return false
            }

            // 核心过滤：如果窗口位于 Layer > 0 且是全屏窗口（如微信 Layer 27 全屏透明监听层），默认视为纯隐形窗口，不予拦截
            if layer > 0 && isFullscreen(rect: rect) {
                continue
            }
            
            // 我们检查所有在屏幕上层绘制的真实图层窗口（Layer >= 0）
            if layer >= 0 {
                // 使用 Bundle ID 检查，彻底消除本地化名称差异对 Finder 的误判
                var isFinder = false
                if let app = NSRunningApplication(processIdentifier: pid) {
                    isFinder = app.bundleIdentifier == "com.apple.finder"
                }
                
                // 排除 Finder 自身的桌面壁纸窗口和桌面图标所在的容器窗口 (兼容多语言系统)
                if isFinder && (windowName == "" || windowName == "Desktop" || windowName == "桌面") {
                    continue
                }
                
                // 多维度判定当前窗口是否为真实、用户可交互的窗口。
                if isRealInteractiveWindow(pid: pid, windowName: windowName, rect: rect) {
                    if rect.contains(point) {
                        logToFile("🛡️ [几何拦截] 点击落在活跃窗口范围内! 拦截者: [\(ownerName)] (PID: \(pid), Layer: \(layer), Title: '\(windowName)', Bounds: \(rect))")
                        return false
                    }
                }
            }
        }
        
        logToFile("🎯 [几何判定] 未检测到任何实体常规窗口遮挡，判定为点击落在空白壁纸区域！")
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

    func isProtectedOverlayWindow(pid: Int32, ownerName: String, windowName: String, layer: Int, rect: CGRect, window: [String: Any]) -> Bool {
        guard layer > 0, isFullscreen(rect: rect) else {
            return false
        }

        guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.01 else {
            return false
        }

        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPid == pid else {
            return false
        }

        let protectedBundleIds: Set<String> = [
            "com.tencent.xinWeChat",
            "com.tencent.WeWorkMac",
            "com.tencent.qq",
            "com.tencent.QQ",
            "com.snipaste.mac",
            "cc.ffitch.shottr",
            "com.cleanshot.CleanShot-X",
            "com.xnipapp.Xnip",
            "com.apple.screenshot",
            "com.apple.ScreenCaptureKit"
        ]

        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier,
           protectedBundleIds.contains(bundleId) {
            return true
        }

        let combinedName = "\(ownerName) \(windowName)".lowercased()
        let protectedNameKeywords = [
            "wechat", "微信",
            "wecom", "企业微信",
            "qq",
            "screenshot", "screen shot", "screen capture",
            "截屏", "截图", "录屏", "选区",
            "snip", "snipaste",
            "cleanshot", "shottr", "xnip",
            "lark", "feishu", "飞书",
            "dingtalk", "钉钉"
        ]

        return protectedNameKeywords.contains { combinedName.contains($0.lowercased()) }
    }

    func hasProtectedOverlay(at point: CGPoint, windowList: [[String: Any]]) -> Bool {
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.contains(point) else {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[kCGWindowName as String] as? String ?? ""
            let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? 0

            if isProtectedOverlayWindow(pid: pid, ownerName: ownerName, windowName: windowName, layer: layer, rect: rect, window: window) {
                logToFile("🛡️ [遮罩预检] 点击位于截图/选区类高层遮罩内，放行给前台工具。Owner: [\(ownerName)] PID: \(pid), Layer: \(layer), Bounds: \(rect)")
                return true
            }
        }
        return false
    }
    
    // 检测当前是否处于平铺（Mission Control）状态
    func isMissionControlActive() -> Bool {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        let dockPid = dockApp.processIdentifier
        
        guard let windowList = currentWindowList() else {
            return false
        }
        
        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid == dockPid else {
                continue
            }
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let y = boundsDict["Y"] as? Double {
                // 当 Mission Control 处于平铺状态时，Dock 会维护一个 Y 轴起始位置为 -1 的特殊窗口
                if y == -1 {
                    return true
                }
            }
        }
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
    
    // 检测点击在 Dock 区域中的状态。
    // visibleFrame 只能说明 Dock 预留了哪条屏幕边，不能代表整条区域都是 Dock；两侧空白应允许触发桌面操作。
    // Dock 的窗口列表在部分系统状态下并不稳定，因此命不中实际窗口时，用 Dock 偏好和运行中 App 估算图标区域。
    func dockHitTest(point: CGPoint, windowList: [[String: Any]]) -> DockHitTestResult {
        let cocoaPoint = convertToCocoaCoordinate(point)
        
        guard let screen = screenContaining(cocoaPoint: cocoaPoint) else {
            return .outsideDockArea
        }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // 1. 如果点击落在 visibleFrame 内部，这绝对是可用的屏幕区域（非 Dock 预留区域），直接放行
        if visibleFrame.contains(cocoaPoint) {
            return .outsideDockArea
        }
        
        // 2. 如果点击落在顶部状态栏/菜单栏（由 isClickOnDesktop 独立检测放过，这里也放行）
        let menuBarTopBoundary = visibleFrame.origin.y + visibleFrame.height
        if cocoaPoint.y >= menuBarTopBoundary {
            return .outsideDockArea
        }
        
        guard screenFrame.contains(cocoaPoint) else {
            return .outsideDockArea
        }

        // 3. 处于 Dock 预留边缘区域时，只拦截 Dock 进程真正绘制出来的窗口范围。
        // 这样 Dock 两侧空白仍然可以作为桌面空白触发单击/双击。
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer >= 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
                continue
            }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "com.apple.dock",
                  !isFullscreen(rect: rect) else {
                continue
            }

            let hitRect = rect.insetBy(dx: -4, dy: -4)
            if hitRect.contains(point) {
                logToFile("Dock物理窗口拦截: 点击落在 Dock 实际窗口内! CGPoint=\(point), DockBounds=\(rect), Layer=\(layer)")
                return .dockWindow
            }
        }

        if let estimatedIconRect = estimatedDockIconRect(screenFrame: screenFrame, visibleFrame: visibleFrame),
           estimatedIconRect.contains(cocoaPoint) {
            logToFile("Dock自适应图标区保护: CocoaPoint=\(cocoaPoint), EstimatedIconRect=\(estimatedIconRect), VisibleFrame=\(visibleFrame), ScreenFrame=\(screenFrame)，放行给系统 Dock 处理")
            return .dockWindow
        }

        logToFile("Dock预留区域空白放行: CocoaPoint=\(cocoaPoint), VisibleFrame=\(visibleFrame), ScreenFrame=\(screenFrame)")
        return .reservedEmptyArea
    }

    func estimatedDockIconRect(screenFrame: NSRect, visibleFrame: NSRect) -> NSRect? {
        let bottomDock = visibleFrame.minY > screenFrame.minY + 1
        let topDock = visibleFrame.maxY < screenFrame.maxY - 1
        let leftDock = visibleFrame.minX > screenFrame.minX + 1
        let rightDock = visibleFrame.maxX < screenFrame.maxX - 1

        if bottomDock || topDock {
            let dockThickness = bottomDock ? visibleFrame.minY - screenFrame.minY : screenFrame.maxY - visibleFrame.maxY
            let length = estimatedDockIconBandLength(axisLength: screenFrame.width, dockThickness: dockThickness)
            let originX = dockIconBandOrigin(axisMin: screenFrame.minX, axisMax: screenFrame.maxX, length: length)
            let originY = bottomDock ? screenFrame.minY : visibleFrame.maxY
            return NSRect(x: originX, y: originY, width: length, height: dockThickness)
        }

        if leftDock || rightDock {
            let dockThickness = leftDock ? visibleFrame.minX - screenFrame.minX : screenFrame.maxX - visibleFrame.maxX
            let length = estimatedDockIconBandLength(axisLength: screenFrame.height, dockThickness: dockThickness)
            let originY = dockIconBandOrigin(axisMin: screenFrame.minY, axisMax: screenFrame.maxY, length: length)
            let originX = leftDock ? screenFrame.minX : visibleFrame.maxX
            return NSRect(x: originX, y: originY, width: dockThickness, height: length)
        }

        return nil
    }

    func estimatedDockIconBandLength(axisLength: CGFloat, dockThickness: CGFloat) -> CGFloat {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSizeValue = defaults?.double(forKey: "tilesize") ?? 64
        let tileSize = min(max(CGFloat(tileSizeValue), 32), 128)
        let iconCount = estimatedDockIconCount(defaults: defaults)
        let iconPitch = min(max(tileSize + 8, 40), max(dockThickness, tileSize) + 14)
        let separatorAndEdgePadding = max(tileSize, dockThickness) * 1.5
        let estimatedLength = CGFloat(iconCount) * iconPitch + separatorAndEdgePadding
        return min(max(estimatedLength, tileSize * 4), axisLength)
    }

    func dockIconBandOrigin(axisMin: CGFloat, axisMax: CGFloat, length: CGFloat) -> CGFloat {
        let axisLength = axisMax - axisMin
        guard length < axisLength else {
            return axisMin
        }

        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let pinning = defaults?.string(forKey: "pinning") ?? "middle"
        let edgePadding: CGFloat = 8

        switch pinning {
        case "start":
            return axisMin + edgePadding
        case "end":
            return axisMax - length - edgePadding
        default:
            return axisMin + (axisLength - length) / 2
        }
    }

    func estimatedDockIconCount(defaults: UserDefaults?) -> Int {
        let persistentApps = dockItems(defaults: defaults, key: "persistent-apps")
        let persistentOthers = dockItems(defaults: defaults, key: "persistent-others")
        let recentApps = dockItems(defaults: defaults, key: "recent-apps")
        let pinnedBundleIDs = Set(persistentApps.compactMap { dockItemBundleIdentifier($0) })
        let runningUnpinnedCount = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !pinnedBundleIDs.contains(bundleID) else {
                return false
            }
            return true
        }.count

        // +1 给废纸篓，+1 给分隔符/下载区等系统项目；最小值用于偏好读取失败时保持保守。
        return max(6, persistentApps.count + persistentOthers.count + recentApps.count + runningUnpinnedCount + 2)
    }

    func dockItems(defaults: UserDefaults?, key: String) -> [[String: Any]] {
        return (defaults?.array(forKey: key) ?? []).compactMap { $0 as? [String: Any] }
    }

    func dockItemBundleIdentifier(_ item: [String: Any]) -> String? {
        guard let tileData = item["tile-data"] as? [String: Any] else {
            return nil
        }
        return tileData["bundle-identifier"] as? String
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
            
            if #available(macOS 14.0, *) {
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
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
                process.arguments = ["1"]
                do {
                    try process.run()
                    self.logToFile("✓ Process launch ShowDesktop success.")
                } catch {
                    self.logToFile("❌ Process launch ShowDesktop failed: \(error.localizedDescription)")
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
            
            if #available(macOS 14.0, *) {
                let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                let config = NSWorkspace.OpenConfiguration()
                
                NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                    if let error = error {
                        self?.logToFile("❌ NSWorkspace launch MissionControl failed: \(error.localizedDescription)")
                    } else {
                        self?.logToFile("✓ NSWorkspace launch MissionControl success.")
                    }
                }
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
                do {
                    try process.run()
                    self.logToFile("✓ Process launch MissionControl success.")
                } catch {
                    self.logToFile("❌ Process launch MissionControl failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - 开机自启控制 (AppleScript 实现)
    func setLaunchAtLogin(enabled: Bool) {
        let bundlePath = Bundle.main.bundlePath
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "BackDesk"
        
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
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "BackDesk"
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
