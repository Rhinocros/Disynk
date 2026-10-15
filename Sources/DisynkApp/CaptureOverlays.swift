import AppKit
import CoreGraphics

// MARK: - 范围采集期间的「选区外压暗」边框遮罩

/// 范围录制 / 范围截图时，在**选区之外**覆盖一层半透明压暗，选区内保持透亮并描边，
/// 直观标示「正在采集这一块」。每块命中选区的屏各开一个 borderless 窗口
/// （单块并集窗口跨显示器渲染/命中不可靠，沿用点选遮罩的「每屏一窗」经验）。
/// 关键：`sharingType = .none` + `ignoresMouseEvents = true` → 既绝不进任何采集画面，也不干扰鼠标。
@MainActor
enum RegionFrameController {
    private static var windows: [NSWindow] = []

    /// 按选区（displayID + 屏内左上原点、单位点矩形）铺压暗遮罩。重复调用先清旧的。
    /// 虚拟屏等无 NSScreen 映射者无处显式压暗，跳过（录制本身仍照常进行）。
    static func present(regions: [RegionSelection]) {
        dismiss()
        let grouped = Dictionary(grouping: regions) { $0.displayID }
        for (id, sels) in grouped {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
            }) else { continue }
            let win = makeWindow(frame: screen.frame)
            let view = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            // 屏内左上点矩形 → 视图（左下原点）本地坐标
            view.holes = sels.map {
                CGRect(x: $0.rect.minX,
                       y: screen.frame.height - $0.rect.minY - $0.rect.height,
                       width: $0.rect.width, height: $0.rect.height)
            }
            win.contentView = view
            win.orderFrontRegardless()
            windows.append(win)
        }
    }

    static func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private static func makeWindow(frame: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = .popUpMenu   // 低于 ControlBar 的 .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }
}

/// 单屏压暗视图：整窗铺半透明黑，选区处用 clear+.copy 挖出透亮洞并描白边。
private final class DimView: NSView {
    var holes: [CGRect] = []
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard !holes.isEmpty else { return }
        NSColor.clear.set()
        for h in holes { h.fill(using: .copy) }      // 选区内清空（透亮）
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for h in holes {
            let p = NSBezierPath(rect: h)
            p.lineWidth = 2
            p.stroke()
        }
    }
}

// MARK: - 截图「拍照闪光」动效

/// 截图完成后在整屏白闪一下（相机快门样式，约 0.18s 淡出）。
/// 触发时机在采集之后（像素已拿到），且 `sharingType = .none`，故绝不会被录入画面/截图。
@MainActor
enum CaptureFlash {
    private static var windows: [NSWindow] = []
    private static var fadeTimer: Timer?

    /// 在所有屏同时白闪（覆盖整屏，读起来像快门）。
    static func fire() {
        teardown()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let view = FlashView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.alpha = 0.85
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }
        // 逐帧淡出后自动收起（计时器在主线程触发，用 assumeIsolated 回主隔离域）
        let start = Date()
        let duration = 0.18
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start) / duration
                let a = max(0, 0.85 * (1 - min(1, t)))
                for w in windows {
                    (w.contentView as? FlashView)?.alpha = a
                    w.contentView?.needsDisplay = true
                }
                if t >= 1 { teardown() }
            }
        }
    }

    private static func teardown() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

/// 闪光视图：整窗纯白，alpha 由外部门控渐隐。
private final class FlashView: NSView {
    var alpha: CGFloat = 0.85
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(alpha).setFill()
        bounds.fill()
    }
}
