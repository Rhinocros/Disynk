import AppKit
import ApplicationServices
import CoreGraphics
import DKCore
import Foundation
import QuartzCore

/// 文件级诊断日志（不受 os_log 限流影响）：追录每次 tap 事件/渲染，定位真实事件投递数。
enum OVFileLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Disynk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ovtap.log")
    }()
    private static let q = DispatchQueue(label: "com.disynk.ovlog")
    private static let fmt = DateFormatter()
    /// 每次启动 tap 前清空，避免多次录制的日志混在一起难以判读。
    static func reset() {
        q.async { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
    static func log(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}

/// 录制覆盖层（方案 M4）：CGEventTap 监听点击/按键 + 透明 NSPanel 渲染。
/// 两开关独立（点击涟漪 / 快捷键横幅）；SCK 采屏自然包含本窗口 → 所见即所得。
/// 「不入画」模式由上层在 SCContentFilter 排除本面板窗口实现。
public final class OverlayController: @unchecked Sendable {
    public struct ClickEvent: Sendable {
        public var point: CGPoint     // 全局桌面坐标（AppKit 左下原点）
        public var isRight: Bool
    }
    public struct KeyEvent: Sendable {
        public var combo: String      // 如 "⌘⇧2"
    }

    public var onClick: ((ClickEvent) -> Void)?
    public var onKey: ((KeyEvent) -> Void)?

    // 事件源改用 NSEvent 全局/本地监听：旧 CGEventTap 经 HB 心跳坐实「tap 线程 runloop 存活、tap 已启用，
    // 但 ScreenCaptureKit 采集启动后系统即停止向 session tap 投递事件（整段只进第 1 个），每秒 tapEnable
    // 也救不回」→ 改走 WindowServer 的 AppKit 事件派发通道，与屏幕采集互不干扰。
    private var globalMonitor: Any?
    private var localMonitor: Any?
    public private(set) var isActive = false

    public init() {}

    /// 启动事件监听。键盘全局监听需辅助功能权限（无权限时鼠标仍可用、按键静默不投递）。
    public func start() throws {
        guard !isActive else { return }
        try enable()
    }

    @discardableResult
    public func enable() throws -> Bool {
        guard !isActive else { return true }
        OVFileLog.reset()
        OVFileLog.log("=== enable NSEvent ===")
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
        // 全局监听：事件流向其它 App（录制时用户操作别的窗口）——覆盖层要采的就是这些。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handle(ev)
        }
        // 本地监听：事件流向本 App 自身窗口；回调需原样返回事件，避免吞掉自身输入。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handle(ev)
            return ev
        }
        isActive = true
        // 【关键诊断】键盘全局监听需要辅助功能权限（鼠标监听不需要）：
        // 现象「鼠标正常、按键一条都不进」最常见就是重编译后 TCC 把辅助功能权限重置了。
        let trusted = AXIsProcessTrusted()
        OVFileLog.log("monitors global=\(globalMonitor != nil) local=\(localMonitor != nil) AXTrusted=\(trusted)")
        DKLog.overlay.error("OVDIAG NSEvent global=\(self.globalMonitor != nil, privacy: .public) local=\(self.localMonitor != nil, privacy: .public) AXTrusted=\(trusted, privacy: .public)")
        if !trusted {
            // 未授权 → 弹系统「辅助功能」授权框，引导用户勾选后重启生效。
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        DKLog.overlay.info("覆盖层事件监听已启动（NSEvent 全局/本地监听）")
        return true
    }

    public func disable() {
        guard isActive else { return }
        isActive = false
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// NSEvent 回调（在主线程派发，与 monitors 添加所在线程一致）：鼠标直接取 AppKit 全局坐标（左下原点，
    /// 无需 CGEvent 那套翻转），按键合成展示串。仍写文件日志以便核对真实投递次数。
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let p = NSEvent.mouseLocation   // AppKit 全局坐标（主屏左下原点），与涟漪坐标一致
            let isRight = event.type == .rightMouseDown
            OVFileLog.log("EV mouse \(isRight ? "right" : "left") pt=\(p)")
            onClick?(ClickEvent(point: p, isRight: isRight))
        case .keyDown:
            let combo = Self.comboString(from: event)
            OVFileLog.log("EV key combo=\(combo)")
            onKey?(KeyEvent(combo: combo))
        default:
            break
        }
    }

    /// 由 NSEvent 合成组合键展示串（⌘⌃⌥⇧ + 特殊键名 / 忽略修饰的字符）。
    public static func comboString(from event: NSEvent) -> String {
        let f = event.modifierFlags
        var combo = ""
        if f.contains(.command) { combo += "⌘" }
        if f.contains(.control) { combo += "⌃" }
        if f.contains(.option) { combo += "⌥" }
        if f.contains(.shift) { combo += "⇧" }
        if let name = mappedKeyName(code: event.keyCode) {
            combo += name
        } else if let ch = event.charactersIgnoringModifiers, let first = ch.unicodeScalars.first {
            combo += String(Character(first)).uppercased()
        } else {
            combo += "?"
        }
        return combo
    }

    /// 纯函数：修饰键 + 键码 → 展示串（如 "⌘⇧2"）。与 CGEvent 解耦，可单测（方案 M4）。
    /// 修饰键固定按 ⌘⌃⌥⇧ 顺序拼接（Apple HIG 约定）。
    public static func comboString(flags: CGEventFlags, code: UInt16, charFallback: String?) -> String {
        var combo = ""
        if flags.contains(.maskCommand) { combo += "⌘" }
        if flags.contains(.maskControl) { combo += "⌃" }
        if flags.contains(.maskAlternate) { combo += "⌥" }
        if flags.contains(.maskShift) { combo += "⇧" }
        combo += mappedKeyName(code: code) ?? (charFallback?.uppercased() ?? "?")
        return combo
    }

    /// 特殊键键码 → 展示符号；普通字符返回 nil（由调用方回退到 unicode）。
    public static func mappedKeyName(code: UInt16) -> String? {
        let map: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            126: "↑", 125: "↓", 124: "→", 123: "←",
        ]
        return map[code]
    }
}

/// 点击涟漪 + 快捷键横幅的透明面板（覆盖所有屏，点击穿透）
public final class OverlayPanel {
    private var panels: [NSPanel] = []
    private var views: [OverlayView] = []

    /// 横幅位置（归一化坐标 0-1，(0,0)=左下，(1,1)=右上）
    public var posX: CGFloat = 0.5
    public var posY: CGFloat = 0.08

    public init() {}

    /// 在所有屏创建穿透面板
    @MainActor
    public func show(on screen: NSScreen) { showAll() }

    @MainActor
    public func showAll() {
        hide()
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .screenSaver
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.hasShadow = false
            // 注意：不能设 sharingType = .none，否则 SCK 完全看不到本窗口，覆盖层永远不入画。
            // 「不入画」由上层在 SCContentFilter 排除本面板 windowID 实现。
            let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.posX = posX
            v.posY = posY
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
            views.append(v)
        }
    }

    @MainActor
    public func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    /// 第一块屏的面板窗口 ID（供 SCK 排除「不入画」模式）
    public var windowNumber: CGWindowID {
        CGWindowID(panels.first?.windowNumber ?? 0)
    }

    /// 所有屏面板的窗口 ID 集合（供 excludeOwnWindows 时反向过滤，确保覆盖层不被误排除）
    public var allWindowNumbers: Set<UInt32> {
        Set(panels.filter { $0.windowNumber > 0 }.map { UInt32($0.windowNumber) })
    }

    /// 面板数量（诊断用：确认覆盖层窗口是否真的建出来了）
    public var panelCount: Int { panels.count }

    @MainActor
    public func ripple(at globalPoint: CGPoint, isRight: Bool) {
        // 找到指针所在屏，并把全局坐标换算为该屏视图的局部坐标（屏视图 frame.origin 为 .zero，
        // 不能直接减 frame.origin，否则副屏涟漪会跑到屏外）。
        for (i, screen) in NSScreen.screens.enumerated() where i < views.count {
            if screen.frame.contains(globalPoint) {
                let local = CGPoint(x: globalPoint.x - screen.frame.minX,
                                    y: globalPoint.y - screen.frame.minY)
                views[i].addRipple(localPoint: local, strong: isRight)
                return
            }
        }
        if let v = views.first, let s = NSScreen.screens.first {
            let local = CGPoint(x: globalPoint.x - s.frame.minX, y: globalPoint.y - s.frame.minY)
            v.addRipple(localPoint: local, strong: isRight)
        }
    }

    @MainActor
    public func banner(_ text: String) {
        for v in views { v.showBanner(text, posX: posX, posY: posY) }
    }
}

/// 点击涟漪 + 快捷键横幅的绘制视图。
/// 关键：动画全部交给 Core Animation（渲染服务/WindowServer 驱动），不再依赖主 runloop 的 draw 周期。
/// 旧实现用 Timer 反复触发 draw() 做逐帧动画，录制期间主线程繁忙 → draw 不被调用 →
/// 「点击效果只显示一次」且覆盖层内容进不了 SCK 采到的帧（视频里看不到按键）。
/// CAShapeLayer/CABasicAnimation 由渲染服务插值，SCK 捕获的是 WindowServer 实时合成结果，故稳定入画。
final class OverlayView: NSView {
    /// 横幅位置（归一化 0-1）
    var posX: CGFloat = 0.5
    var posY: CGFloat = 0.08
    /// 当前横幅承载视图（静态文字用 drawRect 绘制保证 Retina 清晰，仅透明度由 CA 动画驱动）
    private weak var bannerHost: BannerHostView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        // 允许子视图（横幅）也走独立 layer，从而可被 CA 动画驱动
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 点击涟漪：一次点击 = 一个 CAShapeLayer 扩散环，动画完成后自动移除。无需主线程逐帧重绘。
    func addRipple(localPoint: CGPoint, strong: Bool) {
        DKLog.overlay.error("OVDIAG ripple pt=\(String(describing: localPoint), privacy: .public) layerNil=\(self.layer == nil, privacy: .public) bounds=\(String(describing: self.bounds), privacy: .public)")
        OVFileLog.log("ripple pt=\(localPoint) layerNil=\(self.layer == nil)")
        guard let root = layer else { return }
        let ring = CAShapeLayer()
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = (strong ? NSColor.systemRed : NSColor.systemBlue).cgColor
        ring.lineWidth = 3
        let r0: CGFloat = 12
        ring.bounds = CGRect(x: -r0, y: -r0, width: r0 * 2, height: r0 * 2)
        ring.position = localPoint
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 4.0            // 半径 12 → 48
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        root.addSublayer(ring)
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    /// 快捷键横幅：静态文字层 + 透明度关键帧动画（淡入→停留→淡出→移除），全程渲染服务驱动。
    func showBanner(_ text: String, posX: CGFloat? = nil, posY: CGFloat? = nil) {
        DKLog.overlay.error("OVDIAG banner text=\(text, privacy: .public) bounds=\(String(describing: self.bounds), privacy: .public)")
        OVFileLog.log("banner text=\(text)")
        if let x = posX { self.posX = x }
        if let y = posY { self.posY = y }

        bannerHost?.removeFromSuperview()
        let host = BannerHostView(frame: bounds)
        host.text = text
        host.posX = self.posX
        host.posY = self.posY
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        addSubview(host)
        bannerHost = host

        guard let hostLayer = host.layer else {
            // 极端兜底：拿不到 layer 就直接显示后延时移除
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { host.removeFromSuperview() }
            return
        }
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.06, 0.85, 1.0]
        anim.duration = 2.0
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { host.removeFromSuperview() }
        hostLayer.add(anim, forKey: "banner")
        CATransaction.commit()
    }
}

/// 横幅承载视图：文字内容静态，用 drawRect 一次绘制（Retina 清晰）；淡入淡出由父层 CA 动画控制。
private final class BannerHostView: NSView {
    var text: String = ""
    var posX: CGFloat = 0.5
    var posY: CGFloat = 0.08

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点击穿透

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 18
        let boxW = size.width + pad * 2, boxH = size.height + pad
        let box = CGRect(x: bounds.width * posX - boxW / 2,
                         y: bounds.height * posY,
                         width: boxW, height: boxH)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.60).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2),
                                withAttributes: attrs)
    }
}
