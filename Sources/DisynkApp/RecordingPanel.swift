import AppKit
import DKSettings
import SwiftUI

/// 浮动录制面板（参考 CleanShot 录制界面菜单）：
/// 第一行：录制来源图标 + 当前输出分辨率；第二行：产出格式图标 + 音频/指针开关；
/// 第三行：一键「录制视频 / 录制 GIF / 录制 WebM」大按钮；录制中显示计时与停止。
@MainActor
final class RecordingPanelController {
    static let shared = RecordingPanelController()
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    func toggle(model: AppModel) {
        if panel != nil {
            hide()
            return
        }
        show(model: model)
    }

    /// 面板已开 → 关闭并释放（开始录制、再次点菜单项均走这里）
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        // 延后一帧再释放 hosting：避免在按钮动作执行中同步销毁 NSHostingView，
        // 打断 hide() 之后才派发的采集逻辑。
        let stale = hosting
        hosting = nil
        if let stale { DispatchQueue.main.async { _ = stale } }
    }

    /// 内容高度随来源切换变化时，重算面板尺寸（顶部左不拆点，向下生长）。
    func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        panel.setContentSize(NSSize(width: 340, height: max(120, h)))
    }

    /// 打开录制面板（点选窗口完成后也需回开面板，供 AppModel 调用）
    func show(model: AppModel) {
        // 打开面板先把宽高框同步到当前分辨率模式（.native=屏幕真实像素，不再定死 1920×1080）
        model.syncPanelResolutionToScreen()
        let root = AnyView(RecordingPanelView().environmentObject(model))
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.titlebarSeparatorStyle = .none   // 去掉标题栏与内容之间的分隔条/材质
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.hasShadow = true
        panel.isOpaque = false        // 透出桌面：窗体非不透明
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.sharingType = .readOnly   // 普通可被截图/录制的窗口；开始录制时会自动关闭→自然不会入画
        panel.hideStandardWindowButtons()   // 交通灯在浮层上点不着 → 改用自绘 X
        self.hosting = hosting
        // 顶部居中停靠（菜单栏下方）
        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 170, y: f.maxY - 60))
        }
        // 成为 key 窗 + 激活 App：否则非活跃窗口的交通灯只在悬停时出现，关闭按钮像“点不到”
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        resizeToFit()
    }
}

// MARK: - 面板内容

private struct RecordingPanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            // 顶部标题行：交通灯已隐藏，改用自绘 X（与截图面板一致）
            PanelHeader(title: "录制") { RecordingPanelController.shared.hide() }

            // 控制区（来源/分辨率 + 开关）：包进卡片，与标题行清晰分层，避免遮挡
            VStack(spacing: 8) {
                // 行 1：设置图标 + 宽×高 + 全屏/裁剪按钮
                HStack(spacing: 8) {
                    // 设置图标（打开设置窗口）
                    iconTile("slider.horizontal.3", iconSize: 16, help: "打开设置") {
                        RecordingPanelController.shared.hide()
                        MainWindowController.show(model: model, section: .record)
                    }

                    // 宽度输入
                    resolutionField(value: $model.customWidth, label: "宽")
                    Text("×").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    // 高度输入
                    resolutionField(value: $model.customHeight, label: "高")

                    // 全屏来源（选中时高亮，给出可见反馈）
                    sourceBtn("arrow.up.left.and.arrow.down.right", help: "全屏录制",
                              selected: model.recordSource == .fullScreen) {
                        model.recordSource = .fullScreen
                    }
                    // 范围来源
                    sourceBtn("crop", help: "范围录制",
                              selected: model.recordSource == .region) {
                        model.recordSource = .region
                    }
                }
                .disabled(model.isRecording)

                // 行 2：麦克风 / 系统音频 / 窗口录制 / 点击效果 / 指针
                HStack(spacing: 8) {
                    toggleIcon("mic", on: model.snapshot.recording.captureMicrophone,
                               help: "麦克风") {
                        model.mutateSettings { $0.recording.captureMicrophone.toggle() }
                    }
                    toggleIcon("pc", on: model.snapshot.recording.captureSystemAudio,
                               help: "系统音频") {
                        model.mutateSettings { $0.recording.captureSystemAudio.toggle() }
                    }
                    toggleIcon("video", on: model.recordSource == .window,
                               help: "窗口录制") {
                        model.recordSource = (model.recordSource == .window) ? .fullScreen : .window
                    }
                    toggleIcon("cursorarrow.click", on: model.snapshot.recording.overlayClickEffects,
                               help: "点击效果") {
                        model.mutateSettings { $0.recording.overlayClickEffects.toggle() }
                    }
                    toggleIcon("cursorarrow", on: model.snapshot.recording.captureCursor,
                               help: "指针入画") {
                        model.mutateSettings { $0.recording.captureCursor.toggle() }
                    }
                }
                .disabled(model.isRecording)

                // 窗口来源：显示当前录制目标，可直接点选窗口（选择即可录，免去设置页翻下拉）
                if model.recordSource == .window {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(windowTargetLabel)
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(model.selectedWindowID == nil ? .secondary : .primary)
                        Spacer(minLength: 6)
                        Button("点选窗口") { model.pickRecordWindow() }
                            .epButton(small: true)
                            .help("遮罩里点哪个窗就录哪个；选完点下方录制按钮即开始")
                    }
                    .padding(.horizontal, 4)
                    .disabled(model.isRecording)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(card)

            // 行 3：录制动作按钮（GIF / Video）
            VStack(spacing: 4) {
                if model.isRecording {
                    HStack(spacing: 10) {
                        Text(String(format: "\u{23FA} %02d:%02d",
                                    Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                            .font(.system(.body, design: .monospaced)).foregroundStyle(EP.danger)
                        Spacer()
                        Button("停止") { model.stopRecording() }
                            .epButton(.danger)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    actionRow(badge: "GIF", title: "录制 GIF", action: { startWith(.gif) })
                    actionRow(badge: nil, symbol: "video.fill", title: "录制视频", action: { startWith(.video) })
                }
            }
            .background(card)
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 18)
        .frame(width: 340)
        .background(
            PanelBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke)
        )
        .shadow(color: Theme.panelShadowColor, radius: Theme.panelShadowRadius, x: 0, y: 6)
        // 让内容/背板铺到窗口真正的顶部，盖住系统标题栏区域（否则浅色桌面下顶部会露一条半透明条）
        .ignoresSafeArea()
        .onChange(of: model.isRecording) { _, recording in
            if recording { RecordingPanelController.shared.hide() }
        }
        // 切换录制来源 → 重算面板尺寸；目标屏可能变 → 宽高框重新跟随真实分辨率
        .onChange(of: model.recordSource) { _, _ in
            RecordingPanelController.shared.resizeToFit()
            model.syncPanelResolutionToScreen()
        }
        .onChange(of: model.pendingDisplayIDs) { _, _ in model.syncPanelResolutionToScreen() }
    }

    // MARK: 组件

    /// 窗口录制目标展示：已选→「应用 — 标题」；未选→提示将回退最前窗。
    private var windowTargetLabel: String {
        if let id = model.selectedWindowID,
           let w = model.recordableWindows.first(where: { $0.id == id }) {
            return w.displayLabel
        }
        return "未选定：将录最前窗口"
    }

    /// 卡片背景（EP 描边小卡，与截图面板统一）。
    private var card: some View {
        RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
            .fill(EP.bgCard)
            .overlay(RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .strokeBorder(EP.borderBase, lineWidth: 1))
    }

    /// 分辨率数字输入框
    private func resolutionField(value: Binding<Int>, label: String) -> some View {
        TextField(label, value: value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(width: 52)
            .multilineTextAlignment(.center)
            .padding(.vertical, 6)
            .background(EP.fillLight, in: RoundedRectangle(cornerRadius: EP.radius))
            .overlay(RoundedRectangle(cornerRadius: EP.radius)
                .strokeBorder(EP.borderBase, lineWidth: 1))
            .onChange(of: value.wrappedValue) { _, _ in
                model.applyCustomResolution()
            }
    }

    /// 面板统一图标按钮：EP 令牌、4pt 圆角、30×30；选中/开启态用主色浅底 + 主色描边 + 主色图标，
    /// 与截图面板工具按钮风格一致（修掉此前 8pt 圆角 + Color.primary.opacity 灰底与实底蓝的不协调）。
    private func iconTile(_ symbol: String, active: Bool = false, iconSize: CGFloat = 15,
                          help: String = "", _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? EP.primary : EP.textRegular)
                .background(
                    RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                        .fill(active ? EP.primarySoft : EP.fillLight)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                        .strokeBorder(active ? EP.primary : EP.borderBase, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: EP.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }

    /// 来源图标按钮：当前来源命中时高亮（与开关按钮同一套主色浅底样式）。
    private func sourceBtn(_ symbol: String, help: String, selected: Bool,
                           _ action: @escaping () -> Void) -> some View {
        iconTile(symbol, active: selected, iconSize: 14, help: help, action)
    }

    /// 图标开关：选中/开启态直接用主色浅底 + 主色描边 + 主色图标（不再画对勾角标），与 iconTile 同一套样式。
    private func toggleIcon(_ symbol: String, on: Bool, help: String,
                            _ action: @escaping () -> Void) -> some View {
        iconTile(symbolName(symbol), active: on, iconSize: 14, help: help, action)
    }

    /// 动作行（GIF / Video）
    private func actionRow(badge: String?, symbol: String = "", title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(EP.danger, in: RoundedRectangle(cornerRadius: EP.radius))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(EP.danger)
                        .frame(width: 24)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())   // 整行（含 Spacer 空白区）都可点，不必只点文字/箭头
        }
        .buttonStyle(.plain)
    }

    /// 映射简称到 SF Symbol 名称
    private func symbolName(_ s: String) -> String {
        switch s {
        case "pc": return "display"
        case "video": return "video"
        default: return s
        }
    }

    // MARK: 行为

    /// 一键按指定格式开始录制
    private func startWith(_ fmt: RecordOutputFormat) {
        model.mutateSettings { $0.recording.outputFormat = fmt }
        model.startRecording()
        if model.isRecording || model.regionCapturing || model.selectionStage != .none {
            RecordingPanelController.shared.hide()
        }
    }
}
