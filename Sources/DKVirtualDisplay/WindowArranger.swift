import Foundation
import CoreGraphics
import DKCore

#if canImport(AppKit)
import AppKit
#endif

#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// 向虚拟屏「拖放窗口」的能力（方案第三节：虚拟屏…向虚拟屏拖放窗口）。
///
/// 设计：把「给定目标屏可见区 + 期望窗口尺寸 → 计算落点」的几何逻辑抽成
/// 可离线单测的纯函数 `place(...)`；真正移动窗口依赖辅助功能（AX）权限与
/// 前台 App，只能在真机 GUI 下生效，故单独封装为 `moveFocusedWindow(...)`，
/// 在无法验证的环境里以权限/返回值优雅降级，不影响纯几何逻辑的可测性。
public enum WindowArranger {

    /// 在目标屏可见区 `visible`（CG 全局坐标：左上原点、y 向下）内为
    /// `windowSize` 的窗口计算落点：优先保持期望尺寸并水平/垂直居中；
    /// 当窗口大于可见区（扣除 `margin` 边距）时钳制尺寸，始终完整落在可见区内。
    public static func place(windowSize: CGSize, in visible: CGRect, margin: CGFloat = 20) -> CGRect {
        let maxW = max(1, visible.width - 2 * margin)
        let maxH = max(1, visible.height - 2 * margin)
        let w = min(max(1, windowSize.width), maxW)
        let h = min(max(1, windowSize.height), maxH)
        let x = visible.minX + (visible.width - w) / 2
        // CG 坐标系原点在左上角，故垂直居中直接用可见区顶部 + 余量/2，无需翻转。
        let y = visible.minY + (visible.height - h) / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// 某显示器（含 `CGVirtualDisplay` 创建的虚拟屏）在 CG 全局坐标下的 frame。
    public static func globalFrame(ofDisplay id: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(id)
    }

    #if canImport(AppKit) && canImport(ApplicationServices)
    /// 把当前前台 App 的焦点窗口移动到目标全局矩形（用于「拖放到虚拟屏」）。
    /// 需辅助功能权限（`AXIsProcessTrusted`）；无权限时抛 `.windowAutomation`。
    /// 无焦点窗口（前台无 App / 窗口不可移动）时返回 false，不抛错。
    @discardableResult
    public static func moveFocusedWindow(to target: CGRect) throws -> Bool {
        guard AXIsProcessTrusted() else {
            throw DKError.windowAutomation("移动窗口需要「辅助功能」权限，请在系统设置中授权后重试")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw DKError.windowAutomation("无法确定前台应用")
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else {
            return false
        }
        let win = (winRef as! AXUIElement)

        // 先定尺寸再定位：部分窗口有最小尺寸约束，先应用目标尺寸可让随后定位不被回弹修正。
        var size = target.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw DKError.windowAutomation("AXValue(size) 构造失败")
        }
        var origin = target.origin
        guard let posValue = AXValueCreate(.cgPoint, &origin) else {
            throw DKError.windowAutomation("AXValue(point) 构造失败")
        }
        let setSize = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeValue)
        let setPos = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
        guard setSize == .success, setPos == .success else {
            throw DKError.windowAutomation("窗口拒绝被移动（size=\(setSize.rawValue) pos=\(setPos.rawValue)）")
        }
        DKLog.window.info("焦点窗口已移至 (\(Int(target.minX)),\(Int(target.minY))) \(Int(target.width))x\(Int(target.height))")
        return true
    }

    /// 便捷入口：把焦点窗口居中放到指定（虚拟）屏。
    @discardableResult
    public static func moveFocusedWindow(toDisplay id: CGDirectDisplayID,
                                         windowSize: CGSize = CGSize(width: 1280, height: 800)) throws -> Bool {
        let screen = globalFrame(ofDisplay: id)
        return try moveFocusedWindow(to: place(windowSize: windowSize, in: screen))
    }
    #endif
}
