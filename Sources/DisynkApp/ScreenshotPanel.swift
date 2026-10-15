import AppKit
import DKSettings
import DKShot
import SwiftUI

/// 浮动截图面板（与录制面板风格统一）：把原先散落在状态栏菜单里的截图/OCR 项收拢到这里，
/// 一行一个大按钮；顶部一个「截图后 OCR」全局开关（与主窗口共享同一设置）；
/// 滚动长截图进行中时，追加「追截一帧 / 拼接保存」两个操作；OCR 开启且有结果时就地显示可复制/导出。
@MainActor
final class ScreenshotPanelController {
    static let shared = ScreenshotPanelController()
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    func toggle(model: AppModel) {
        if panel != nil { hide(); return }
        show(model: model)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        // 延后一帧再释放 hosting：避免在按钮动作执行中同步销毁 NSHostingView，
        // 打断 hide() 之后才派发的采集逻辑（表现为“点了面板却截不到图”）。
        let stale = hosting
        hosting = nil
        if let stale { DispatchQueue.main.async { _ = stale } }
    }

    /// 内容高度随 OCR 开关/结果变化时，重算面板尺寸（顶部左不拆点，向下生长）。
    func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        panel.setContentSize(NSSize(width: 420, height: max(120, h)))
    }

    func show(model: AppModel) {
        let root = AnyView(ScreenshotPanelView().environmentObject(model))
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.titlebarSeparatorStyle = .none   // 去掉标题栏与内容之间的分隔条/材质
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .readOnly   // 普通可被截图/录制的窗口；开始截图/录制时会自动关闭→自然不会入画
        panel.contentView = hosting
        panel.hasShadow = true
        panel.isOpaque = false        // 透出桌面：窗体非不透明
        panel.backgroundColor = .clear
        panel.hideStandardWindowButtons()   // 交通灯在浮层上点不着 → 改用自绘 X
        self.hosting = hosting
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 210, y: f.maxY - 60))
        }
        // 必须成为 key 窗（并让 App 激活）：否则非活跃窗口的交通灯按钮只在悬停时出现，
        // 第一次点击只用于激活 → 用户感知为“关闭按钮点不到”。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        resizeToFit()
    }
}

private struct ScreenshotPanelView: View {
    @EnvironmentObject var model: AppModel

    /// 「截图后 OCR」开关：绑定持久化设置，面板与主窗口共享。
    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.ocrEnabled },
            set: { on in model.mutateSettings { $0.ocrEnabled = on } }
        )
    }

    /// 截图保存格式：与主窗口「截图/OCR」页共享同一持久化设置。
    private var shotFormatBinding: Binding<ShotFormat> {
        Binding(
            get: { model.snapshot.screenshotFormat },
            set: { f in model.mutateSettings { $0.screenshotFormat = f } }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            PanelHeader(title: "截图 · OCR") { ScreenshotPanelController.shared.hide() }

            // CleanShot 风格横向图标工具条：一行图标按钮，图标在上、文字在下；
            // 工具条底部附保存格式菜单（与主窗口设置同源持久化）。
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    toolButton("区域", "rectangle.dashed") { model.screenshotRegionAndOCR() }
                        .disabled(model.regionCapturing)
                    toolButton("全屏", "display") { model.screenshotAndOCR(displayID: nil) }
                    // 点选任意窗口截图（兼登记窗口录制目标）；选完下面出现「录制该窗口」
                    toolButton("窗口", "macwindow") { model.pickWindowForShot() }
                        .disabled(model.regionCapturing || model.scrollCapturing)
                    toolButton("滚动", "arrow.down.doc") { model.beginScrollCapture() }
                        .disabled(model.scrollCapturing || model.regionCapturing)
                    // OCR：切换「截图后自动识别」开关，开启时高亮
                    toolButton("OCR", "text.viewfinder", selected: model.snapshot.ocrEnabled) {
                        ocrBinding.wrappedValue.toggle()
                    }
                    toolButton("剪贴板", "list.clipboard") { model.ocrClipboard() }
                    // 录屏：收起本面板，打开录制面板
                    toolButton("录屏", "video") {
                        ScreenshotPanelController.shared.hide()
                        RecordingPanelController.shared.toggle(model: model)
                    }
                }
                // 保存格式：菜单式单选（PNG/JPG/HEIC/WebP；未装配 libvpx 的构建藏掉 WebP）
                HStack(spacing: 6) {
                    Text("保存格式").font(.system(size: 11)).foregroundStyle(.secondary)
                    Menu {
                        Picker("保存格式", selection: shotFormatBinding) {
                            ForEach(ShotFormat.allCases.filter { $0 != .webp || WebPEncoder.isAvailable }) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 3) {
                            Text(model.snapshot.screenshotFormat.displayName)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.up.down").font(.system(size: 9))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(EP.fillLight, in: RoundedRectangle(cornerRadius: EP.radius))
                        .overlay(RoundedRectangle(cornerRadius: EP.radius)
                            .strokeBorder(EP.borderBase, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(card)

            // 刚点选过窗口 → 就地提供「录制该窗口」：选择即可录制，免去设置页翻下拉列表
            if let win = model.lastPickedWindow, !model.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(win.displayLabel)
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("录制该窗口") { model.recordPickedWindow() }
                        .epButton(.primary, small: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(card)
            }

            // OCR 结果就地显示：不受「截图后 OCR」开关控制（剪贴板 OCR 永远要看到结果）
            if !model.ocrText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别结果").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(model.ocrText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    HStack(spacing: 8) {
                        Button("复制") { model.copyOCRText() }.epButton(small: true)
                        Button("导出 TXT") { model.saveOCRText() }.epButton(small: true)
                        Button("导出 MD") { model.saveOCRMarkdown() }.epButton(small: true)
                        Spacer()
                        Button("清空") { model.clearOCRText() }
                            .epButton(small: true)
                            .foregroundStyle(EP.danger)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(card)
            }
        }
        // 顶部留给自绘标题行（交通灯已隐藏）：收窄顶内边距 + 行间距，降低标题栏高度
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 12)
        .frame(width: 420)
        // 真·透出桌面：背板叠近不透明窗体色，保证标题栏区域与按钮看得清、点得着
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
        .onChange(of: model.snapshot.ocrEnabled) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
        .onChange(of: model.snapshot.screenshotFormat) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
        .onChange(of: model.ocrText) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
        .onChange(of: model.scrollCapturing) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
        .onChange(of: model.lastPickedWindow) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
        .onChange(of: model.isRecording) { _, _ in ScreenshotPanelController.shared.resizeToFit() }
    }

    /// EP 描边小卡：实底 bg-card + 1px border-color（面板内分组统一复用）。
    private var card: some View {
        RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
            .fill(EP.bgCard)
            .overlay(RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .strokeBorder(EP.borderBase, lineWidth: 1))
    }

    /// CleanShot 风格图标按钮：图标在上、文字在下，选中态用强调色高亮。
    private func toolButton(_ label: String, _ symbol: String, selected: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                    .fill(selected ? EP.primarySoft : EP.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                    .strokeBorder(selected ? EP.primary : EP.borderBase, lineWidth: 1)
            )
            .foregroundStyle(selected ? EP.primary : Color.primary)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
