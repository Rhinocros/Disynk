import AppKit
import SwiftUI
import DKCore

/// 滚动截图「选择」面板：选窗口自动 / 框选区域手动。
/// 会话进行中不显示本面板（改由 ScrollHUDController 的紧凑控制条接管，见 ScrollHUD.swift）。
/// sharingType = .none → 面板本身绝不进任何采集画面。
@MainActor
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    func show(model: AppModel) {
        if panel == nil { build(model: model) }
        resizeToFit()
        // 成为 key 窗 + 激活 App：非活跃浮层上的按钮首击只用于激活，看起来“点不着”
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        panel.setContentSize(NSSize(width: 340, height: max(120, h)))
    }

    private func build(model: AppModel) {
        let root = AnyView(ScrollCaptureView().environmentObject(model))
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hideStandardWindowButtons()   // 交通灯在浮层上点不着 → 改用自绘 X
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = hosting
        panel.hasShadow = true
        panel.isOpaque = false        // 透出桌面：窗体非不透明（背板由 PanelBackdrop 负责可读性）
        panel.backgroundColor = .clear
        self.hosting = hosting
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 170, y: f.maxY - 60))
        }
        self.panel = panel
    }
}

private struct ScrollCaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedWindowID: UInt32?

    /// 「滚动截图包含标题栏」开关：与设置页共享同一持久化设置；关闭时拼接前裁掉顶部标题栏及左右固定侧栏。
    private var chromeBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.scrollCaptureIncludeTitlebar },
            set: { on in model.mutateSettings { $0.scrollCaptureIncludeTitlebar = on } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "滚动长截图") { ScrollCaptureController.shared.hide() }

            Text("点选/选一个窗口自动滚动，或框选一块区域后手动滚动。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: chromeBinding) {
                Text("包含标题栏（关闭=裁掉顶部标题栏/工具栏，缓解重复）")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .font(.system(size: 11))

            // 方式一：选窗口 → 自动滚动
            VStack(alignment: .leading, spacing: 6) {
                Text("① 选择窗口（自动滚动）").font(.system(size: 11, weight: .medium))
                Picker("", selection: $selectedWindowID) {
                    Text("（选择窗口…）").tag(Optional<UInt32>.none)
                    ForEach(model.recordableWindows) { w in
                        Text(w.displayLabel).tag(Optional(w.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Button("刷新窗口") { model.refreshRecordableWindows() }.epButton(small: true)
                    Button("点选窗口") { model.pickScrollWindow() }
                        .epButton(.primary, small: true)
                        .help("遮罩里直接点哪个窗就滚哪个；滚动发生在点击处，比窗口中心可靠")
                    Button("开始自动滚动截图") {
                        if let id = selectedWindowID { model.startScrollWindow(id) }
                    }
                    .epButton(small: true)
                    .disabled(selectedWindowID == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(card)

            // 方式二：框选区域 → 手动滚动
            VStack(alignment: .leading, spacing: 6) {
                Text("② 框选区域（手动滚动）").font(.system(size: 11, weight: .medium))
                Button("框选区域并开始") { model.pickScrollRegion() }
                    .epButton(small: true)
                    .disabled(model.regionCapturing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(card)

            Text("进行中可用浮动控制条上的「停止并保存」，或按 Return 停止、Esc 取消。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 340)
        // 背板：以前无任何底颜 → 内容直接贴在桌面上，标题栏区域完全透明
        .background(
            PanelBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke)
        )
        .shadow(color: Theme.panelShadowColor, radius: Theme.panelShadowRadius, x: 0, y: 6)
        .onAppear {
            if selectedWindowID == nil { selectedWindowID = model.recordableWindows.first?.id }
        }
        .onChange(of: model.recordableWindows.count) { _, _ in
            if selectedWindowID == nil { selectedWindowID = model.recordableWindows.first?.id }
        }
    }

    /// EP 描边小卡：实底 bg-card + 1px border-color。
    private var card: some View {
        RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
            .fill(EP.bgCard)
            .overlay(RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .strokeBorder(EP.borderBase, lineWidth: 1))
    }
}
