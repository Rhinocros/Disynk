import AppKit
import SwiftUI

/// 浮动控制条：录制/选择阶段的悬浮控制。
/// 样式对齐 ScrollHUD（胶囊、material、顶部居中、可拖动）。
/// 始终最前（.screenSaver）且不入画（sharingType = .none）。
@MainActor
final class ControlBar {
    static let shared = ControlBar()
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var model: AppModel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var placed = false

    func show(model: AppModel) {
        self.model = model
        if panel == nil {
            build(model: model)
            placed = false
        }
        resizeToFit()
        if !placed { place(); placed = true }
        panel?.orderFrontRegardless()
        installKeyMonitors()
    }

    func hide() {
        removeKeyMonitors()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model = nil
        placed = false
    }

    func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let s = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(320, s.width), height: max(52, s.height)))
    }

    /// 顶部居中（菜单栏下方），避免被 Dock 遮挡
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.frame
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(NSPoint(x: f.midX - size.width / 2, y: f.maxY - 40))
    }

    private func build(model: AppModel) {
        let root = AnyView(ControlBarView(model: model))
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 68),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hideStandardWindowButtons()
        panel.isMovableByWindowBackground = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        self.hosting = hosting
        self.panel = panel
    }

    // MARK: 快捷键（Esc = 取消选择/停止录制）

    private func installKeyMonitors() {
        guard globalKeyMonitor == nil else { return }
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
        guard let model else { return }
        switch keyCode {
        case 53: // Esc
            if model.countdown != nil { model.cancelCountdown() }
            else if model.selectionStage != .none { model.cancelSelection() }
            else if model.isRecording { model.stopRecording() }
        default: break
        }
    }
}

// MARK: - 视图（ScrollHUD 风格，强制深色 + 白色文字）

private struct ControlBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左侧：状态
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(EP.danger)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if model.isRecording {
                        Text(String(format: "%02d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Text(statusHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
            }

            Divider().frame(height: 28)

            // 右侧：操作按钮
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if let n = model.countdown {
                        Text("\(n)s")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(EP.danger)
                        Button { model.cancelCountdown() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                    } else if model.selectionStage != .none {
                        Button { model.commitSelection() } label: {
                            Label("开始录制", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .controlSize(.large).tint(EP.danger)
                        .disabled(!hasSelection)
                        Button { model.cancelSelection() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                    } else {
                        Button { model.stopRecording() } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .controlSize(.large).tint(EP.danger)
                        .disabled(!model.isRecording)
                    }
                }
                Text(hintText)
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
                .strokeBorder(Color.white.opacity(0.10))
        )
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 6)
    }

    // MARK: 文案

    private var hasSelection: Bool {
        switch model.selectionStage {
        case .pickingDisplays: return !model.pendingDisplayIDs.isEmpty
        case .pickingRegions: return !model.pendingRegions.isEmpty
        case .none: return false
        }
    }

    private var statusTitle: String {
        if model.countdown != nil { return "即将开始录制" }
        switch model.selectionStage {
        case .pickingDisplays: return "已选 \(model.pendingDisplayIDs.count) 块屏幕"
        case .pickingRegions: return "已选 \(model.pendingRegions.count) 个范围"
        case .none: return model.isRecording ? "REC" : "就绪"
        }
    }

    private var statusHint: String {
        if model.countdown != nil { return "延迟中…" }
        switch model.selectionStage {
        case .pickingDisplays: return "点屏幕卡片选择，可多选"
        case .pickingRegions: return "拖框选择；再框一个或点开始录制"
        case .none: return model.isRecording ? "录制中" : ""
        }
    }

    private var hintText: String {
        if model.countdown != nil { return "Esc 取消" }
        switch model.selectionStage {
        case .none: return "Esc 停止 · 可拖动"
        default: return "Esc 取消 · 可拖动"
        }
    }
}
