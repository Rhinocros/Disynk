import AppKit
import CoreGraphics
import DKCore

/// 全屏录制前的「点选屏幕」遮罩：为**每块屏各开一个**独立窗口（而非一块铺满并集的窗口）。
/// 旧实现用单个跨所有显示器的 borderless 窗口——不同屏的原点/倍率下只有主屏渲染与命中可靠，
/// 外接屏点不到、虚拟屏不可见。改为每屏一窗后，每块屏（含外接/虚拟）都能独立点选，可多选。
/// 点卡片即切换选中态并写回 model.pendingDisplayIDs；ControlBar 的 arm 栏实时显示已选数量。
/// 所有窗口 sharingType = .none：绝不会被任何采集路径录进画面。
@MainActor
enum DisplayPickerController {
    private static var controller: PickerController?

    /// 弹出点选遮罩；选择结果实时写回 model.pendingDisplayIDs。
    static func present(model: AppModel) {
        dismiss()
        let controller = PickerController(model: model)
        DisplayPickerController.controller = controller
        controller.show()
    }

    static func dismiss() {
        controller?.close()
        controller = nil
    }
}

@MainActor
private final class PickerController {
    /// borderless 默认不能成为 key window（Esc 收不到 keyDown），此处放开。
    private final class PickerWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        // 不裁剪到 visibleFrame：遮罩必须铺满整屏（含顶部菜单栏条与底部程序坞）。
        // 默认实现会把窗口高度压到可见区，导致顶/底各漏一条——就是用户看到的「没全屏」。
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            return frameRect
        }
    }

    private unowned let model: AppModel
    private var windows: [PickerWindow] = []
    private var views: [DisplayCardView] = []

    init(model: AppModel) { self.model = model }

    func show() {
        for d in model.displays {
            guard let frame = Self.displayGlobalFrame(d.id) else { continue }
            let w = PickerWindow(contentRect: frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
            // 高于系统菜单栏（.mainMenu=24）→ 压暗铺满整屏含顶部菜单栏条；
            // 仍低于 ControlBar 的 .screenSaver，右上角「开始录制栏」保持可点。
            w.level = .statusBar
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let title = "\(d.name)  \(d.sourceSize.width)×\(d.sourceSize.height)" + (d.isVirtual ? "（虚拟）" : "")
            let view = DisplayCardView(frame: NSRect(origin: .zero, size: frame.size),
                                       displayID: d.id, title: title, model: model,
                                       onToggle: { [weak self] in self?.redrawAll() })
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()   // 只需一块屏收 Esc 键盘事件
    }

    /// 任一屏卡片被点 → 所有窗口重绘，选中高亮跨屏同步。
    func redrawAll() { views.forEach { $0.needsDisplay = true } }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    /// displayID → AppKit 全局帧（左下原点）：优先命中 NSScreen；
    /// 虚拟屏等无对应 NSScreen 时用 CGDisplayBounds（左上原点）转 AppKit 坐标。
    static func displayGlobalFrame(_ id: UInt32) -> CGRect? {
        if let s = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
        }) { return s.frame }
        let b = CGDisplayBounds(id)
        guard b.width > 1, b.height > 1 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? b.height
        return CGRect(x: b.origin.x, y: primaryHeight - b.origin.y - b.height,
                      width: b.width, height: b.height)
    }
}

/// 窗口点选遮罩：整屏压暗 + 十字准星，点哪个窗就选哪个。
/// 滚动截图（目标窗 + 滚动坐标）与「点选窗口截图/录制」（目标窗）共用。
/// 比下拉列表可靠两个地方：
///  1) 命中用 CGWindowList(.optionOnScreenOnly) 前→后顺序取第一个包含该点的普通层窗口，
///     拿到的必然是该点最前窗 → 滚轮事件一定落在它身上；
///  2) 回报的是用户实际点击的全局坐标，滚动就发生在那里（而不是容易落在标题栏/侧栏的窗口几何中心）。
/// 遮罩 sharingType = .none → 不会出现在任何采集画面里。
@MainActor
enum WindowPickerController {
    /// 点选结果：窗口 ID + 点击处全局坐标（CG 左上原点，可直接喂 CGEvent）
    struct Pick {
        let windowID: CGWindowID
        let point: CGPoint
    }

    fileprivate static var current: WindowPickerSession?

    static func present(hint: String = "点击要滚动截图的窗口・悬停高亮最前窗・Esc 取消",
                        completion: @escaping (Pick?) -> Void) {
        current?.dismiss(pick: nil)
        let session = WindowPickerSession(screens: NSScreen.screens, hint: hint, completion: completion)
        current = session
        session?.show()
    }

    static func dismiss() {
        current?.dismiss(pick: nil)
    }
}

@MainActor
private final class WindowPickerSession {
    private final class PickWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let completion: ((WindowPickerController.Pick?) -> Void)
    private let window: NSWindow
    private let view: WindowPickView

    init?(screens: [NSScreen], hint: String,
          completion: @escaping (WindowPickerController.Pick?) -> Void) {
        guard !screens.isEmpty else { return nil }
        self.completion = completion
        let union = ScreenGeometry.union(screens.map(\.frame))
        let top = screens.map(\.frame.maxY).max() ?? union.maxY
        let v = WindowPickView(frame: NSRect(origin: .zero, size: union.size),
                               globalOrigin: union.origin, topEdge: top)
        v.hintText = hint
        let w = PickWindow(contentRect: union, styleMask: .borderless,
                           backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = v
        self.view = v
        self.window = w
        v.onPick = { [weak self] id, p in self?.dismiss(pick: .init(windowID: id, point: p)) }
        v.onCancel = { [weak self] in self?.dismiss(pick: nil) }
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss(pick: WindowPickerController.Pick?) {
        window.orderOut(nil)
        completion(pick)
        if let cur = WindowPickerController.current, cur === self {
            WindowPickerController.current = nil
        }
    }

    /// 全局点（CG 左上原点）命中的最前普通应用窗口：返回窗口 ID 与其全局矩形（供高亮）。
    static func hitWindow(at p: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != getpid() else { continue }
            guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let w = (b["Width"] as? NSNumber)?.doubleValue,
                  let h = (b["Height"] as? NSNumber)?.doubleValue,
                  w >= 40, h >= 40 else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if rect.contains(p) { return (CGWindowID(num), rect) }
        }
        return nil
    }
}

/// 点选遮罩视图：压暗背景 + 悬停窗口高亮 + 提示文字。
@MainActor
private final class WindowPickView: NSView {
    var onPick: ((CGWindowID, CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    private let globalOrigin: CGPoint   // 遮罩并集窗口在 AppKit 全局系里的原点
    private let topEdge: CGFloat        // 主屏顶边（AppKit y）→ 用于左上/左下原点换算
    var hintText = "点击要滚动截图的窗口・悬停高亮最前窗・Esc 取消"   // 顶部提示（按调用场景定制）
    private var hover: (id: CGWindowID, frame: CGRect)?
    private var tracking: NSTrackingArea?

    init(frame: NSRect, globalOrigin: CGPoint, topEdge: CGFloat) {
        self.globalOrigin = globalOrigin
        self.topEdge = topEdge
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                              options: [.mouseMoved, .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// 视图坐标 → 全局 CG 坐标（左上原点）
    private func globalPoint(inView p: NSPoint) -> CGPoint {
        let appkitY = globalOrigin.y + p.y
        return CGPoint(x: globalOrigin.x + p.x, y: topEdge - appkitY)
    }

    /// 全局 CG 矩形 → 视图坐标矩形
    private func viewRect(cg rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - globalOrigin.x,
               y: topEdge - rect.maxY - globalOrigin.y,
               width: rect.width, height: rect.height)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = globalPoint(inView: convert(event.locationInWindow, from: nil))
        let hit = WindowPickerSession.hitWindow(at: p)
        if hit?.id != hover?.id { hover = hit; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        let p = globalPoint(inView: vp)
        guard let hit = WindowPickerSession.hitWindow(at: p) ?? hover else {
            NSSound.beep()
            return
        }
        onPick?(hit.id, p)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        if let hover {
            let r = viewRect(cg: hover.frame).insetBy(dx: -3, dy: -3)
            EP.rgb(0x409EFF).withAlphaComponent(0.18).setFill()
            r.fill()
            EP.rgb(0x409EFF).setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 3
            path.stroke()
        }

        let hint = hintText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: hint, attributes: attrs)
        let size = text.size()
        let box = NSRect(x: bounds.midX - size.width / 2 - 14,
                         y: bounds.maxY - size.height - 56,
                         width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }
}
/// 单块屏的点选卡片视图：整窗即一张卡片，点击切换选中；Esc 取消全部。
@MainActor
final class DisplayCardView: NSView {
    private let displayID: UInt32
    private let title: String
    private unowned let model: AppModel
    private let onToggle: () -> Void

    init(frame: NSRect, displayID: UInt32, title: String, model: AppModel,
         onToggle: @escaping () -> Void) {
        self.displayID = displayID
        self.title = title
        self.model = model
        self.onToggle = onToggle
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let selected = model.pendingDisplayIDs.contains(displayID)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        if selected {
            // 选中：红色蒙层铺满整屏（不再内缩成圆角卡片），明确标识该屏会被录制；
            // 四边加一圈粗红边强化“整屏已选”的边界感。
            EP.rgb(0xF56C6C).withAlphaComponent(0.30).setFill()
            bounds.fill()
            EP.rgb(0xF56C6C).setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            border.lineWidth = 8
            border.stroke()
        } else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 18, dy: 18), xRadius: 16, yRadius: 16)
            NSColor.white.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        let label = selected ? "✓ \(title)" : title
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: selected ? 22 : 19, weight: .semibold),
            .foregroundColor: selected ? NSColor.white : NSColor.white.withAlphaComponent(0.8),
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))

        let hint = "点击选择 · Esc 取消"
        let hAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let hText = NSAttributedString(string: hint, attributes: hAttrs)
        let hSize = hText.size()
        hText.draw(at: CGPoint(x: bounds.midX - hSize.width / 2, y: bounds.maxY - hSize.height - 28))
    }

    override func mouseDown(with event: NSEvent) {
        model.toggleDisplay(displayID)
        onToggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {            // Esc
            model.cancelSelection()
        } else {
            super.keyDown(with: event)
        }
    }
}
