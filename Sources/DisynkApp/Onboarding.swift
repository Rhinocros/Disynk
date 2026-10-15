import AppKit
import AVFoundation
import Combine
import DKCapture
import SwiftUI

/// 首次运行的「权限说明 + 引导」窗口。
/// 先解释三项权限各自用途，再逐项引导授权：屏幕录制、辅助功能为必需（二者未授予则不能继续），
/// 麦克风仅录音需要、可跳过。点「开始使用」后写入完成标记，后续启动不再弹出。
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    /// 完成标记 key（带版本号，便于日后重置引导）。
    static let doneKey = "disynk.onboarding.completed.v1"
    private var window: NSWindow?

    /// 若尚未完成引导、或必需权限已失效（重编译/重装会重置屏录 TCC，而 doneKey 仍在
    /// UserDefaults）则（重新）弹出引导，返回是否已弹出（供调用方决定是否走旧的兜底引导）。
    @discardableResult
    func presentIfNeeded(model: AppModel) -> Bool {
        let done = UserDefaults.standard.bool(forKey: Self.doneKey)
        // 屏录是采集/截图的必需权限：一旦缺失就重新引导，避免静默失败。
        if done && ScreenPermissions.isGranted(.screenRecording) { return false }
        present(model: model)
        return true
    }

    func present(model: AppModel) {
        guard window == nil else { NSApp.activate(ignoringOtherApps: true); return }
        let root = OnboardingView(
            onFinish: { [weak self] in self?.finish() },
            onRelaunch: { [weak self] in self?.relaunch() }
        ).environmentObject(model)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]   // 跟随 SwiftUI 内容高度，配合去掉固定 frame 高度
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable]
        win.title = "欢迎使用 Disynk"
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.orderOut(nil)
        window = nil
    }

    /// 重启进程让 TCC 授权可靠生效（屏幕录制 / 辅助功能常在重启后才稳定）。
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 引导内容

private struct OnboardingView: View {
    var onFinish: () -> Void
    var onRelaunch: () -> Void

    @State private var screen = ScreenPermissions.isGranted(.screenRecording)
    @State private var mic = ScreenPermissions.isGranted(.microphone)
    @State private var ax = ScreenPermissions.isGranted(.accessibility)
    // 轮询系统授权状态：用户在「系统设置」里勾选后，这里 1 秒内自动反映出来。
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var requiredDone: Bool { screen && ax }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开始使用前，Disynk 需要几项系统权限")
                .font(.title2).bold()
            Text("先说明每项权限的用途，再按提示完成授权。授予「屏幕录制」与「辅助功能」后即可开始录制；麦克风只在录制人声时需要，可以跳过。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 屏幕录制（必需）
            GrantRow(icon: "record.circle", title: "屏幕录制（必需）", granted: screen,
                     why: "捕获屏幕画面，是录制视频与截图的核心能力。") {
                Button("请求权限") { _ = ScreenPermissions.requestScreenRecording() }
                    .epButton(.primary, small: true)
                Button("打开系统设置") { ScreenPermissions.openPrivacyPane(.screenRecording) }
                    .epButton(small: true)
            }

            // 辅助功能（必需）
            GrantRow(icon: "hand.raised.circle", title: "辅助功能（必需）", granted: ax,
                     why: "录制覆盖层需要它监听鼠标点击与按键，才能在视频里显示点击涟漪和按键横幅；全局快捷键也依赖此权限。") {
                Button("授权引导") { ScreenPermissions.promptAccessibility() }
                    .epButton(.primary, small: true)
                Button("打开系统设置") { ScreenPermissions.openPrivacyPane(.accessibility) }
                    .epButton(small: true)
            }

            // 麦克风（可跳过）
            GrantRow(icon: "mic.circle", title: "麦克风（可选，可跳过）", granted: mic,
                     why: "仅当你想把麦克风声音一起录进视频时才需要；不需要可直接跳过。") {
                Button("授权麦克风") {
                    Task { _ = await ScreenPermissions.requestMicrophone(); await MainActor.run { refresh() } }
                }
                .epButton(small: true)
                Text("跳过不影响录制画面")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !requiredDone {
                    Text("完成「屏幕录制」与「辅助功能」授权后即可开始使用。若已在系统设置勾选但状态未刷新，请点「重启 Disynk」让授权生效。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("重启 Disynk", action: onRelaunch)
                        .epButton(small: true)
                    Spacer()
                    Button("开始使用", action: onFinish)
                        .epButton(.primary, small: true)
                        .disabled(!requiredDone)
                }
            }
        }
        .padding(22)
        .frame(width: 540, alignment: .topLeading)   // 不再定死高度：窗口高度自适配内容，避免底部大空隙
        .background(EP.bgPage)
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        screen = ScreenPermissions.isGranted(.screenRecording)
        mic = ScreenPermissions.isGranted(.microphone)
        ax = ScreenPermissions.isGranted(.accessibility)
    }
}

/// 单行权限说明：图标 + 标题 + 用途 + 授权按钮 + 当前状态。
private struct GrantRow<Content: View>: View {
    let icon: String
    let title: String
    let granted: Bool
    let why: String
    let actions: () -> Content

    init(icon: String, title: String, granted: Bool, why: String,
         @ViewBuilder actions: @escaping () -> Content) {
        self.icon = icon; self.title = title; self.granted = granted; self.why = why; self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 22))
                .foregroundStyle(granted ? EP.success : EP.warning)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: EP.fontBody, weight: .semibold))
                    EPTag(text: granted ? "已授予" : "未授予", role: granted ? .success : .info)
                }
                Text(why).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .fill(EP.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .strokeBorder(EP.borderBase, lineWidth: 1)
        )
    }
}
