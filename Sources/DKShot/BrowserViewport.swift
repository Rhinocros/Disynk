import AppKit
import CoreGraphics
import Foundation
import DKCore

#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// 浏览器窗口「网页视口」（`AXWebArea`）定位，用于滚动长截图裁掉浏览器 UI。
///
/// 背景（macOS 特有）：Chrome / Safari 是单窗口 App，标签栏、地址栏、侧边书签栏全部属于
/// 同一个窗口的渲染内容，系统窗口 API（CGWindowList / ScreenCaptureKit 整窗）拿到的都是整个
/// 浏览器窗口——无法像 Windows 那样只抓网页渲染子窗口。于是整窗滚动截图会把深色标签栏/侧边栏
/// 一并截进长图；而纯图像列检测又分不清「固定标签栏（该裁）」与「随页滚动的分类菜单/正文（该留）」
/// （见 ScrollStitch 侧栏裁剪回退）。
///
/// 方案 A（本项目采纳）：用无障碍 API 读取网页渲染容器 `AXWebArea` 的屏幕矩形——它就是「网页视口
/// 本身」，天然不含标题栏/标签栏/地址栏/侧边书签栏。据此从整窗截图中裁出视口子矩形，即得到干净网页。
///
/// 设计：几何裁剪数学抽成纯函数 `cropRect(...)` 可离线单测；真正读取 AX 树依赖「辅助功能」权限
/// 与目标 App，仅真机生效，故封装为 `cropRectForWindow(...)`，无权限 / 非浏览器 / 分屏 / Safari 隐私
/// 模式等取不到时返回 nil，调用方据此回退整窗采集。
public enum BrowserViewport {

    /// 由「网页视口全局矩形 + 窗口全局矩形」换算出在整窗截图（像素）中裁出视口的矩形。
    /// 坐标约定：`webArea` / `windowBounds` 均为 CG 全局、左上原点、单位「点」；输出为图像像素
    /// 坐标（`CGImage.cropping` 亦为左上原点）。逐轴钳制到图像范围，退化（宽/高 < 8）返回 nil。
    /// 纯映射，可离线单测（真实 AX/像素尺寸依赖运行环境）。
    public static func cropRect(webArea: CGRect, windowBounds: CGRect,
                                imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0,
              windowBounds.width > 1, windowBounds.height > 1 else { return nil }
        let sx = Double(imageWidth) / Double(windowBounds.width)
        let sy = Double(imageHeight) / Double(windowBounds.height)
        guard sx > 0, sy > 0, sx.isFinite, sy.isFinite else { return nil }
        var x = (webArea.minX - windowBounds.minX) * sx
        var y = (webArea.minY - windowBounds.minY) * sy
        var w = webArea.width * sx
        var h = webArea.height * sy
        // 视口超出窗口范围时钳制（AX 与窗口枚举极少不一致，防御式处理）
        if x < 0 { w += x; x = 0 }
        if y < 0 { h += y; y = 0 }
        if x + w > Double(imageWidth) { w = Double(imageWidth) - x }
        if y + h > Double(imageHeight) { h = Double(imageHeight) - y }
        guard w >= 8, h >= 8, x >= 0, y >= 0 else { return nil }
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    #if canImport(AppKit) && canImport(ApplicationServices)
    /// 预热：启用目标窗口宿主 App 的（Chromium 懒加载）无障碍树。
    /// 在滚动会话开始、发首帧之前调用，给浏览器一点时间把 `AXWebArea` 建出来。
    public static func enableAccessibility(for windowID: CGWindowID) {
        guard let (pid, _) = ownerInfo(windowID) else { return }
        enableChromiumAX(pid: pid)
    }

    /// 取目标窗口网页视口相对「整窗截图（imageWidth×imageHeight 像素）」的裁剪矩形。
    /// 需辅助功能权限；非浏览器 / 无权限 / 分屏 / 隐私模式等取不到 `AXWebArea` → nil（调用方回退整窗）。
    /// 调用方可逐帧重试（Chromium 建树是异步的，首帧常取不到、随后几帧才会出现），直至拿到或放弃。
    public static func cropRectForWindow(_ windowID: CGWindowID,
                                         imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard AXIsProcessTrusted(),
              let (pid, bounds) = ownerInfo(windowID) else { return nil }
        enableChromiumAX(pid: pid)   // 幂等；确保 Chromium 已建出网页 AX 树
        guard let web = webAreaRect(pid: pid, windowBounds: bounds) else { return nil }
        return cropRect(webArea: web, windowBounds: bounds, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Chromium（Chrome / Edge / Electron）默认懒加载网页无障碍树：不显式置位就没有 `AXWebArea`，
    /// 只有原生 UI（含竖排标签栏/地址栏/侧边栏）。设置这两个属性触发其构建（老/新内核各认一个，都设最稳）。
    private static func enableChromiumAX(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// 窗口宿主 pid 与全局矩形（点、左上原点）。
    private static func ownerInfo(_ windowID: CGWindowID) -> (pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let x = (b["X"] as? NSNumber)?.doubleValue,
              let y = (b["Y"] as? NSNumber)?.doubleValue,
              let w = (b["Width"] as? NSNumber)?.doubleValue,
              let h = (b["Height"] as? NSNumber)?.doubleValue, w > 1, h > 1 else { return nil }
        return (pid, CGRect(x: x, y: y, width: w, height: h))
    }

    /// 在该 App 的 AX 树中找到代表网页视口的 `AXWebArea` 全局矩形，多个时取面积最大者（iframe / 多标签取主视口）。
    /// 匹配放宽：App 只有一个窗口时直接取其内最大 `AXWebArea`（坐标偶有偏差也不漏）；
    /// 多窗口时要求视口中心落在目标窗口矩形内，避免抓到同 App 其它窗口的内容。
    /// `kAXWindows` 取不到/为空时退而求其次读 `AXMainWindow`/`AXFocusedWindow`（部分浏览器
    /// 建树中期或竖排标签栏模式下窗口列表会短暂为空）。
    private static func webAreaRect(pid: pid_t, windowBounds: CGRect) -> CGRect? {
        let appEl = AXUIElementCreateApplication(pid)
        var windows: [AXUIElement] = []
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let winsRef, CFGetTypeID(winsRef) == AXUIElementGetTypeID(),
           let wins = winsRef as? [AXUIElement] { windows = wins }
        if windows.isEmpty {
            for key in ["AXMainWindow", "AXFocusedWindow"] {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, key as CFString, &ref) == .success,
                   let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                    windows = [ref as! AXUIElement]; break
                }
            }
        }
        guard !windows.isEmpty else { return nil }
        var best: CGRect?
        for win in windows {
            for r in webAreas(in: win, depth: 0)
            where windows.count == 1 || centerInside(windowBounds, r) {
                if best == nil || r.width * r.height > best!.width * best!.height { best = r }
            }
        }
        return best
    }

    /// 视口中心是否落在窗口矩形内（留 2pt 容差）；两者同为全局左上原点、单位点。
    private static func centerInside(_ bounds: CGRect, _ r: CGRect) -> Bool {
        r.midX >= bounds.minX - 2 && r.midX <= bounds.maxX + 2 &&
        r.midY >= bounds.minY - 2 && r.midY <= bounds.maxY + 2
    }

    /// 递归收集元素子树里所有 role=`AXWebArea` 的全局矩形（深度上限防爆栈/巨树）。
    /// 上限取 64：开启竖排标签栏/侧边面板后，Chromium 原生 UI 嵌套明显变深，
    /// 旧的 24 层会在触底前截断、导致永远找不到 `AXWebArea`（标签栏残留的根因之一）。
    private static func webAreas(in el: AXUIElement, depth: Int) -> [CGRect] {
        guard depth < 64 else { return [] }
        var out: [CGRect] = []
        if axRole(el) == "AXWebArea", let f = axFrame(el) { out.append(f) }
        for child in axChildren(el) { out.append(contentsOf: webAreas(in: child, depth: depth + 1)) }
        return out
    }

    private static func axRole(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// AX 元素的屏幕矩形（全局点坐标，左上原点）；position/size 均为 AXValue，取不出或过小返回 nil。
    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((posRef as! AXValue), .cgPoint, &point),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: point, size: size)
    }
    #endif
}
