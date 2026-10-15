import AppKit
import CoreGraphics
import DKCore

/// 最前层「非本应用」窗口解析：用于窗口截图。
/// CGWindowListCopyWindowInfo(.optionOnScreenOnly) 返回自前而后的窗口列表，
/// 取第一个普通层（layer==0）、非本进程、有标题的窗口。
enum FrontWindowResolver {
    static func frontmostOtherWindowID() -> CGWindowID? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != selfPID,
                  let numberNum = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) >= 40,
                  ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0) >= 40
            else { continue }
            return CGWindowID(numberNum.uint32Value)
        }
        return nil
    }
}

/// 跨屏框选结果：命中的显示屏 + 该屏内、左上原点、单位点的矩形
struct RegionSelection: Equatable {
    let displayID: UInt32
    let rect: CGRect
}

/// 一次框选的结局：选定 / 跳过本屏（逐屏模式用）/ 取消全部
enum RegionOutcome: Equatable {
    case picked(RegionSelection)
    case skipped
    case cancelled
}

/// 遮罩窗口：borderless 默认不能成为 key window（Esc/回车收不到 keyDown），此处放开。
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 橡胶筋区域选择遮罩：单窗口铺满给定屏幕集合的并集，回报命中的屏 + 屏内选区。
/// 两种用法：
/// - 跨屏单选（截图/OCR/滚动）：传全部屏，在任意一块屏框一块区域；
/// - 累加多范围（范围录制）：每次传全部屏框一块区域，由 AppModel 循环调用直到用户结束框选。
/// 旧实现只在指定单块屏（回落 NSScreen.main）铺遮罩 → 副屏无法框选。
/// 关键：回调前必须先 orderOut 遮罩窗口，避免把遮罩自身截进图里。
@MainActor
final class RegionPickerController {
    private static var current: RegionPickerController?

    /// 跨屏单选（历史 API）：skipped/cancelled 均回调 nil
    static func present(completion: @escaping (RegionSelection?) -> Void) {
        present(screens: NSScreen.screens, hint: "拖动鼠标框选（可切到副屏），Esc 取消",
                allowsSkip: false) { outcome in
            switch outcome {
            case .picked(let sel): completion(sel)
            case .skipped, .cancelled: completion(nil)
            }
        }
    }

    /// 通用入口：在指定屏幕集合上弹遮罩
    static func present(screens: [NSScreen], hint: String, allowsSkip: Bool,
                        completion: @escaping (RegionOutcome) -> Void) {
        current?.dismiss(outcome: .cancelled)
        guard let controller = RegionPickerController(screens: screens, hint: hint,
                                                      allowsSkip: allowsSkip,
                                                      completion: completion) else {
            completion(.cancelled); return
        }
        current = controller
        controller.show()
    }

    private let window: NSWindow
    private let completion: (RegionOutcome) -> Void
    private let unionFrame: CGRect
    private let topEdge: CGFloat
    private let areas: [ScreenGeometry.DisplayArea]

    private init?(screens: [NSScreen], hint: String, allowsSkip: Bool,
                  completion: @escaping (RegionOutcome) -> Void) {
        guard !screens.isEmpty else { return nil }

        // 全局（AppKit 左下原点）并集 = 遮罩窗口覆盖范围
        let union = ScreenGeometry.union(screens.map(\.frame))
        let top = screens.map(\.frame.maxY).max() ?? union.maxY
        // 各屏在遮罩视图坐标系中的边框（提示屏边界，方便跨屏选择）
        let boundaryRects = screens.map { s in
            CGRect(x: s.frame.minX - union.minX,
                   y: s.frame.minY - union.minY,
                   width: s.frame.width, height: s.frame.height)
        }
        // displayID → 全局左上原点矩形（命中判定用）
        let hitAreas: [ScreenGeometry.DisplayArea] = screens.compactMap { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return ScreenGeometry.DisplayArea(id: num,
                                              frame: CGRect(x: s.frame.minX, y: top - s.frame.maxY,
                                                            width: s.frame.width, height: s.frame.height))
        }

        self.completion = completion
        self.unionFrame = union
        self.topEdge = top
        self.areas = hitAreas

        // 单窗口铺满并集：遮罩与拖拽状态都在同一视图坐标系里，跨屏选区可直接换算
        let w = OverlayWindow(contentRect: union, styleMask: .borderless,
                              backing: .buffered, defer: false)
        w.level = .popUpMenu   // 低于 ControlBar 的 .screenSaver，保证控制栏始终不被遮挡
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        w.sharingType = .none          // 遮罩自身也不该被任何采集路径录进去
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = SelectionView(frame: NSRect(origin: .zero, size: union.size),
                                      boundaries: boundaryRects,
                                      hint: hint, allowsSkip: allowsSkip)
        window = w
    }

    private func show() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 拖拽回调在 init 完成后才接线（闭包引用 self，避开未初始化引用）
        guard let view = window.contentView as? SelectionView else { return }
        view.onSelection = { [weak self] rectAppKit in self?.handleDragRect(rectAppKit) }
        view.onCancel = { [weak self] in self?.dismiss(outcome: .cancelled) }
        view.onSkip = { [weak self] in self?.dismiss(outcome: .skipped) }
    }

    /// 视图内（左下原点）选区 → 全局左上 → 命中屏 + 屏内左上选区
    private func handleDragRect(_ rectAppKit: CGRect) {
        if rectAppKit.width < 2 || rectAppKit.height < 2 { dismiss(outcome: .cancelled); return }
        let global = ScreenGeometry.toGlobalTopLeft(rect: rectAppKit, viewGlobal: unionFrame, topEdge: topEdge)
        guard let hit = ScreenGeometry.hitDisplay(global, in: areas) else {
            dismiss(outcome: .cancelled); return
        }
        dismiss(outcome: .picked(RegionSelection(displayID: hit.0, rect: hit.1)))
    }

    private func dismiss(outcome: RegionOutcome) {
        window.orderOut(nil)
        if RegionPickerController.current === self { RegionPickerController.current = nil }
        // 让 WindowServer 一拍彻底移除遮罩，再回调触发 SCK 截图/录制
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [completion] in
            completion(outcome)
        }
    }
}

/// 遮罩内容视图：半透明压暗 + 屏边界 + 顶部提示条 + 白色描边选区与尺寸提示，
/// 处理拖拽、Esc（取消）与回车/空格（逐屏模式：跳过此屏）。
/// 回调在控制器完成初始化后接线（避免闭包引用未初始化的 self）。
private final class SelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onSkip: (() -> Void)?
    private let boundaries: [CGRect]
    private let hint: String
    private let allowsSkip: Bool
    private var startPoint: NSPoint?
    private var currentRect: CGRect = .zero

    init(frame: NSRect, boundaries: [CGRect], hint: String, allowsSkip: Bool) {
        self.boundaries = boundaries
        self.hint = hint
        self.allowsSkip = allowsSkip
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        drawHintBar()
        // 屏边界（多屏时看清选区落在哪块屏）
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for b in boundaries {
            let p = NSBezierPath(rect: b)
            p.lineWidth = 1
            p.stroke()
        }
        if currentRect.width > 0, currentRect.height > 0 {
            // 选区内清空（更亮）+ 描边 + 尺寸提示
            NSColor.clear.set()
            currentRect.fill(using: .copy)
            NSColor.white.setStroke()
            let p = NSBezierPath(rect: currentRect)
            p.lineWidth = 1.5
            p.stroke()
            drawSizeLabel()
        }
    }

    /// 顶部提示条（逐屏模式在这里告知“回车=跳过此屏”）
    private func drawHintBar() {
        guard !hint.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attrs)
        let pad: CGFloat = 10
        let bar = NSRect(x: bounds.midX - size.width / 2 - pad,
                         y: bounds.maxY - size.height - pad * 2,
                         width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        hint.draw(at: NSPoint(x: bar.minX + pad, y: bar.minY + pad / 2), withAttributes: attrs)
    }

    private func drawSizeLabel() {
        let text = "\(Int(currentRect.width.rounded())) × \(Int(currentRect.height.rounded())) pt"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: currentRect.minX, y: max(bounds.minY, currentRect.minY - size.height - 4))
        text.draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let now = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                             width: abs(now.x - start.x), height: abs(now.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
        // 微拖（< 8pt）视为误操作：清空重选，不取消整场框选
        if rect.width < 8 || rect.height < 8 { return }
        onSelection?(rect)
    }

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        if code == 53 {
            onCancel?()                                   // Esc：取消全部
        } else if allowsSkip, code == 36 || code == 76 || code == 49 {
            onSkip?()                                     // 回车/小回车/空格：跳过此屏
        } else {
            super.keyDown(with: event)
        }
    }
}
