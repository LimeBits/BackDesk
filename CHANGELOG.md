# BackDesk 更新说明 (Release Notes)

## 🏷️ 版本号: v0.2.3

BackDesk `v0.2.3` 是一次具有重大里程碑意义的跨版本兼容与防御机制更新。我们成功实现了对 **macOS 14.0+ (Sonoma)** 新系统的完美防穿透支撑，同时为 **macOS 13.0 及以下系统** 提供了高保真的防误触优化，打造了无缝契合的多版本并行运行架构。

---

## 🚀 新增功能与深度修复

### 1. 📂 macOS 14.0+ (Sonoma) Finder 文件夹空白分栏防穿透
*   **问题**：Sonoma 系统引入了对 `CGWindowListCopyWindowInfo` 中窗口标题（`kCGWindowName`）的跨进程隐私封锁（不具有录屏权限的应用均获取为空）。这导致原有的几何检测失效，在 Finder **分栏视图 (Column View)** 点击最右侧空白列区域时，会错误穿透到壁纸，触发显示桌面。
*   **解决**：全新引入 **Accessibility API (辅助功能 API) 链式父级探测**。当鼠标点击落在 Finder 进程的元素上时，我们顺着 AX 节点链向上爬升，如果在其容器链中找到了子角色为标准实体窗口（`AXStandardWindow`）的祖先，则**百分百确认为实体窗口空白区域并安全拦截放行**，杜绝任何穿透！

### 2. 🛡️ macOS 13.0 及以下系统全场景防误触 (Dock/菜单栏/桌面图标)
*   **问题**：由于老系统（macOS 12/13）的桌面背景窗口在 Accessibility 中也被系统标记为了 `AXStandardWindow`，简单使用 AX 检查会导致点击空白壁纸时被错误拦截（软件完全失效）。为此退回 0.1.0 纯几何计算后，又引发了**点击 Dock 栏、顶部菜单栏、以及桌面文件/文件夹图标时频繁误触显示桌面**的历史遗留问题。
*   **解决**：我们为老系统重构并升级了**高精度三合一拦截机制**，并将老系统的广播监听完美接入新检测器：
    *   **顶部菜单栏拦截**：在 Cocoa 坐标转换层通过屏幕绝对边界对最顶部窄条进行高精度拦截。
    *   **物理 Dock 栏拦截**：通过 visibleFrame 和 screenFrame 的绝对数学差集，计算出 Dock 栏物理像素渲染盒，精准剔除 Dock 两侧空白与废纸篓/堆栈的任何点击。
    *   **桌面图标/文件拦截**：点击桌面文件时，AX API 能精确嗅探出点击元素为 `AXImage`/`AXStaticText` 等文件属性，且窗口**没有关闭按钮（`kAXCloseButtonAttribute`）且标题属于桌面黑名单**，从而安全拦截防误触。

### 3. 🚦 版本运行时双路隔离架构 (Dual-Path Architecture)
*   为了确保 macOS 14+ 现代拦截特性与 macOS 13- 极速稳定特性的双重绝对安全，我们构建了严格的分流架构：
    *   **监听分流**：macOS 14+ 启用 `CGEventTap` 实现“主动屏蔽误触”，macOS 13- 启用 `NSEvent` 广播监听实现“零系统阻碍”。
    *   **触发分流**：macOS 14+ 使用 Sonoma 支持的 `NSWorkspace.shared.open` 代理唤醒 Mission Control，macOS 13- 使用 `Process` 直接对二进制发送 IPC 指令（避免 arguments 丢失），保证两端动画丝滑可靠！

---

## 📦 官方安装包分发

推荐直接安装本次全新编译的通用二进制版磁盘映像（已在此版本中提交归档）：
*   **双芯片通用版 (Intel + Apple Silicon)**: `BackDesk_v0.2.3_universal.dmg` (已随仓库一并上传)
