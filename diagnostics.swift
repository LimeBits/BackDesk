import Cocoa
import CoreGraphics
import ApplicationServices

class DiagnosticsDelegate: NSObject, NSApplicationDelegate {
    var globalMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== ToDesktop 诊断程序启动 ===")
        print("请注意：首次启动可能需要获取系统辅助功能权限，如果在 System Preferences 中已经勾选过 ToDesktop，只需在终端中同意即可。")
        print("【诊断操作】: 请点击一次您的【桌面空白壁纸】，我将在此打印出您鼠标指针下所有窗口的详细层级信息。")
        
        let hasAccess = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !hasAccess {
            print("⚠️ 警告：目前尚未获得辅助功能权限，请确保在 系统偏好设置 -> 安全性与隐私 -> 隐私 -> 辅助功能 中允许终端 (Terminal) 或当前应用运行。")
        }
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.analyzeClick(event)
        }
        fflush(nil)
    }
    
    func analyzeClick(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation
        let mainScreen = NSScreen.screens.first!
        let screenHeight = mainScreen.frame.height
        
        // 转换为 CG 坐标 (origin at top-left)
        let clickPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)
        
        print("\n📍 检测到鼠标点击！坐标为: \(clickPoint)")
        print("--------------------------------------------------------------------------------")
        print("【1】Accessibility API 深度探测 (AX Element)")
        print("--------------------------------------------------------------------------------")
        
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axResult = AXUIElementCopyElementAtPosition(systemWide, Float(clickPoint.x), Float(clickPoint.y), &element)
        
        if axResult == .success, let clickedElement = element {
            var elementPid: pid_t = 0
            if AXUIElementGetPid(clickedElement, &elementPid) == .success {
                let appName: String
                let bundleId: String
                if let app = NSRunningApplication(processIdentifier: elementPid) {
                    appName = app.localizedName ?? "Unknown"
                    bundleId = app.bundleIdentifier ?? "Unknown"
                } else {
                    appName = "Process \(elementPid)"
                    bundleId = "Unknown"
                }
                
                var roleValue: AnyObject?
                AXUIElementCopyAttributeValue(clickedElement, kAXRoleAttribute as CFString, &roleValue)
                let role = roleValue as? String ?? "None"
                
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(clickedElement, kAXTitleAttribute as CFString, &titleValue)
                let title = titleValue as? String ?? "None"
                
                print("Owner App : \(appName) (\(bundleId))")
                print("AX Role   : \(role)")
                print("AX Title  : '\(title)'")
            } else {
                print("❌ 无法获取 AX 元素的 PID")
            }
        } else {
            print("❌ Accessibility API 探测失败，错误码: \(axResult.rawValue)")
        }
        
        print("\n--------------------------------------------------------------------------------")
        print("【2】CGWindowList 几何碰撞检测 (Layer >= 0 且包含点击点)")
        print("--------------------------------------------------------------------------------")
        print(String(format: "%-25@ | %-30@ | %-6@ | %@", "应用名称 (Owner)", "窗口标题 (WindowName)", "Layer", "窗口范围 (Bounds)"))
        print("--------------------------------------------------------------------------------")
        
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            print("❌ 无法获取窗口列表")
            return
        }
        
        var matchCount = 0
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let windowName = window[kCGWindowName as String] as? String ?? ""
            
            // 只要窗口包含了点击点，无论什么层级，都打印出来分析
            if rect.contains(clickPoint) {
                matchCount += 1
                let nameTruncated = windowName.count > 30 ? String(windowName.prefix(27)) + "..." : windowName
                print(String(format: "%-25@ | %-30@ | %-6d | %@", ownerName, nameTruncated, layer, "\(rect)"))
            }
        }
        
        print("--------------------------------------------------------------------------------")
        print("诊断完成！共有 \(matchCount) 个窗口包含此点击坐标点。")
        print("请在终端中复制以上输出，发送给我分析！按 Control + C 可以退出诊断程序。")
        fflush(nil)
    }
}

let app = NSApplication.shared
let delegate = DiagnosticsDelegate()
app.delegate = delegate
app.run()
