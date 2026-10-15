import AppKit
import SwiftUI
import DKCore

/// 滚动截图进行中的浮动控制条（胶囊 HUD）——取代原来塞在滚动面板里的“停止截图栏”。
///
/// 为什么单独做一层：
/// - 选择面板宽 340、含一堆选项，当停止栏太笨重，且默认停在屏幕顶部正中，
///   正好压住窗口几何中心 → 滚轮事件被浮层吃掉，目标窗口完全不滚；
/// - 会话期间不能再抢焦点：一旦 activate/makeKey，键盘滚动事件（Page Down）就会
///   发给本应用而不是目标窗口。所以这里只用 orderFrontRegardless + 非激活面板。
///
/// sharingType = .none → HUD 本身绝不进入任何采集画面。
@MainActor
final class ScrollHUDController {
    static let shared = ScrollHUDController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var model: AppModel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// - Parameter avoiding: 需避开的全局坐标（CG 左上原点，即滚动事件落点）。
    func show(model: AppModel, avoiding: CGPoint?) {
        self.model = model
        if panel == nil { build(model: model) }
        resizeToFit()
        place(avoiding: avoiding)
        panel?.orderFrontRegardless()
        installKeyMonitors()
    }

    func hide() {
        removeKeyMonitors()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model = nil
    }

    func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let s = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(320, s.width), height: max(56, s.height)))
    }

    /// 默认停在主屏底部居中（远离多数页面的正文与顶部工具栏），压住滚动点则依次退让。
    private func place(avoiding: CGPoint?) {
        guard let panel, let screen = NSScreen.main else { return }
        resizeToFit()
        let f = screen.frame
        let size = panel.frame.size
        let margin: CGFloat = 20
        let candidates: [NSPoint] = [
            NSPoint(x: f.midX - size.width / 2, y: f.minY + size.height + margin),   // 底部居中
            NSPoint(x: f.maxX - size.width - margin, y: f.maxY - margin),             // 右上
            NSPoint(x: f.minX + margin, y: f.maxY - margin),                          // 左上
            NSPoint(x: f.maxX - size.width - margin, y: f.minY + size.height + margin), // 右下
            NSPoint(x: f.minX + margin, y: f.minY + size.height + margin),            // 左下
            NSPoint(x: f.midX - size.width / 2, y: f.maxY - margin),                  // 顶部居中
        ]
        guard let avoiding else {
            panel.setFrameTopLeftPoint(candidates[0])
            return
        }
        // CG 左上原点 → AppKit 左下原点（以主屏顶边为镜像轴）
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        let hit = CGPoint(x: avoiding.x, y: primaryTop - avoiding.y)
        for c in candidates {
            let rect = CGRect(x: c.x, y: c.y - size.height, width: size.width, height: size.height)
            if !rect.contains(hit) {
                panel.setFrameTopLeftPoint(c)
                return
            }
        }
        panel.setFrameTopLeftPoint(candidates[candidates.count - 1])
    }

    private func build(model: AppModel) {
        let root = AnyView(ScrollHUDView().environmentObject(model))
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 76),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hideStandardWindowButtons()
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = hosting
        panel.hasShadow = false        // 背板自带阴影，避免双层边框
        panel.isOpaque = false
        panel.backgroundColor = .clear
        self.hosting = hosting
        self.panel = panel
    }

    // MARK: 快捷键（Return 停止并保存 / Esc 取消）

    private func installKeyMonitors() {
        guard globalKeyMonitor == nil else { return }
        // 全局监听：会话期间焦点在目标窗口，本地监听收不到键；无权限时静默失效，按钮仍可用。
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            Task { @MainActor [weak self] in self?.handleKey(code) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event.keyCode)
            return event
        }
    }

    private func removeKeyMonitors() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private func handleKey(_ keyCode: UInt16) {
        guard let model, model.scrollCapturing else { return }
        switch keyCode {
        case 53: model.cancelScrollCapture()                 // Esc
        case 36, 76: model.finishScrollCapture()             // Return / 小键盘 Enter
        default: break
        }
    }
}

// MARK: - HUD 视图

private struct ScrollHUDView: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(EP.danger)
                        .frame(width: 7, height: 7)
                        .opacity(pulse ? 1 : 0.3)
                    Text("滚动截图中").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.scrollModeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                Text(model.scrollStatus.isEmpty ? "准备中…" : model.scrollStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            Divider().frame(height: 28)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Button {
                        model.finishScrollCapture()
                    } label: {
                        Label("停止并保存", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(EP.danger)
                    .help("停止滚动并拼接保存整图（Return）")

                    Button {
                        model.cancelScrollCapture()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .help("放弃本次滚动截图（Esc）")
                }
                Text("Return 停止 · Esc 取消 · 可拖动")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        )
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 6)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }
}
