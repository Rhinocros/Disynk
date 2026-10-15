import AppKit
import DKCapture
import DKCompose
import DKCore
import DKSettings
import DKShot
import DKVirtualDisplay
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主窗口（菜单栏项/快捷键唤起）

enum MainWindowController {
    static var window: NSWindow?

    @MainActor
    static func show(model: AppModel, section: NavSection? = nil) {
        if let section { model.navSection = section }
        // 非录制状态重新打开设置时，清除可能残留的上次会话提示
        if !model.isRecording { model.statusLine = "就绪" }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: MainWindowView().environmentObject(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Disynk 设置"
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.fullSizeContentView)   // 内容铺满整窗，左栏自绘顶到标题栏下，避免系统可折叠分栏
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden                 // 隐藏居中标题，让位给自绘左栏
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.window = window
    }
}

// MARK: - 主界面：左侧导航分区 + 右侧详情（参考 CleanShot 设置窗口：分区式设置页）

struct MainWindowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // 状态栏改为整窗底部的兄弟视图（而非 safeAreaInset）：
            // 录制页的 HSplitView 会忽略安全区、把卡片压到底栏下面，
            // 用 VStack 让底栏先占位、内容只拿剩余高度，保证所有页都留出底部间距。
            Divider()
            statusBar
        }
        .tint(Theme.accent)
    }

    // MARK: 左栏导航（固定宽度、不可折叠；选中项用协调的整行胶囊高亮）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 顶部留出标题栏/交通灯高度
            HStack(spacing: 8) {
                Image(nsImage: AboutInfo.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                Text("Disynk").font(.system(size: EP.fontTitle, weight: .semibold))
                    .foregroundStyle(EP.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 12)

            ForEach(NavSection.allCases) { s in
                navRow(s)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(EP.bgCard)
    }

    private func navRow(_ s: NavSection) -> some View {
        let selected = model.navSection == s
        return Button {
            model.navSection = s
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon)
                    .font(.system(size: 15))
                    .frame(width: 18, alignment: .center)
                Text(s.rawValue)
                    .font(.system(size: EP.fontBody))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? EP.primary : EP.textRegular)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                    .fill(selected ? EP.primarySoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // 去掉首个导航项默认聚焦时的系统焦点环（“通用一直有个框”）
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.navSection {
        case .general: GeneralTab()
        case .record: RecordTab()
        case .shot: ShotTab()
        case .shortcuts: ShortcutsTab()
        case .virtual: VirtualTab()
        case .permission: PermissionTab()
        case .about: AboutTab()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isRecording ? EP.danger : EP.success)
                .frame(width: 8, height: 8)
            if model.isRecording {
                Text(String(format: "%02d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(EP.danger)
            }
            Text(model.statusLine)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(EP.bgOverlay)
    }
}

// MARK: - 录制页（三栏 HSplitView：分隔条可拖拽调宽；显示器栏窄且内容靠左）

struct RecordTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            encodePane
            layoutPane
        }
        .padding(12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        // 录制按钮不再浮在整个页面右下角（会盖住右栏布局编辑器的宽高滑杆），
        // 改放到「录制参数」栏内部右下角，见 encodePane 底部。
        // 切到窗口来源时自动拉一次窗口列表
        .onChange(of: model.recordSource) { _, src in
            if src == .window, model.recordableWindows.isEmpty { model.refreshRecordableWindows() }
        }
    }

    // MARK: 左栏：产出格式/编码参数/录制来源/输出目录

    private var encodePane: some View {
        let fmt = model.snapshot.recording.outputFormat
        return VStack(alignment: .leading, spacing: 0) {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 20) {
            // 录制时直接选择产出格式（不再离线导出）；GIF/WebM 停录后自动转码
            Picker("输出格式", selection: outputFormatBinding) {
                ForEach(RecordOutputFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(model.isRecording)

            // 录制来源（方案第三节：全屏/窗口/范围）
            Picker("录制来源", selection: $model.recordSource) {
                ForEach(AppModel.RecordSourceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isRecording)
            switch model.recordSource {
            case .fullScreen:
                Text("在右侧「显示器」里勾选要录制的屏幕（可多选）。")
                    .font(.caption).foregroundStyle(.secondary)
            case .window:
                Picker("窗口", selection: $model.selectedWindowID) {
                    Text("（自动：最前窗口）").tag(Optional<UInt32>.none)
                    ForEach(model.recordableWindows) { w in
                        Text(w.displayLabel).tag(Optional(w.id))
                    }
                }
                .disabled(model.isRecording)
                HStack(spacing: 6) {
                    Button("刷新窗口列表") { model.refreshRecordableWindows() }
                        .disabled(model.isRecording)
                        .epButton(small: true)
                    Text("共 \(model.recordableWindows.count) 个可选")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .region:
                Text("点「开始录制」后拖动鼠标框选范围，Esc 取消。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if fmt == .video {
                Picker("编码", selection: codecBinding) {
                    ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("容器", selection: containerBinding) {
                    ForEach(ContainerFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                Picker("质量档", selection: qualityBinding) {
                    Text("高").tag(QualityTier.high)
                    Text("中").tag(QualityTier.medium)
                    Text("低").tag(QualityTier.low)
                }
            }
            Picker("分辨率", selection: resolutionBinding) {
                Text("原生").tag(ResolutionTag.native)
                ForEach(Array(ResolutionMode.presets16x9.enumerated()), id: \.offset) { idx, size in
                    Text("\(size.width)×\(size.height)").tag(ResolutionTag.preset(idx))
                }
                Text("自定义…").tag(ResolutionTag.custom)
            }
            if selectedResolutionTag == .custom {
                // 方案：分辨率自定义仅允许输入数字 → 拆为宽/高两个数字框（format .number 自动拒绝非数字）
                HStack(spacing: 4) {
                    TextField("宽", value: $model.customWidth, format: .number)
                        .epField().frame(width: 84)
                    Text("×").foregroundStyle(.secondary)
                    TextField("高", value: $model.customHeight, format: .number)
                        .epField().frame(width: 84)
                    Button("应用") { model.applyCustomResolution() }
                        .epButton(small: true)
                }
                .onChange(of: model.customWidth) { _, _ in model.applyCustomResolution() }
                .onChange(of: model.customHeight) { _, _ in model.applyCustomResolution() }
            }
            Picker("帧率", selection: fpsBinding) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
                Text("自定义…").tag(0)
            }

            if fmt == .video {
                // 方案第三节：关键帧间隔（GOP）可调——直接映射编码器 MaxKeyFrameInterval
                Picker("关键帧间隔", selection: keyframeBinding) {
                    Text("1 秒").tag(1)
                    Text("2 秒").tag(2)
                    Text("4 秒").tag(4)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                }
                Picker("输出模式", selection: outputModeBinding) {
                    Text("多路独立文件").tag(OutputMode.separateFiles)
                    Text("合并单文件").tag(OutputMode.composedOnly)
                    Text("两者同时").tag(OutputMode.both)
                }
                .disabled(model.recordSource != .fullScreen)
                // 方案第四节：编码会话数上限/ProRes 软编——UI 显式容量提示
                if let hint = encodeCapacityAdvisory {
                    EPAlert(kind: hint.warn ? .warning : .info, text: hint.text)
                }
                Toggle("系统音频", isOn: systemAudioBinding)
                Toggle("麦克风", isOn: micBinding)
            } else {
                // GIF/WebM：内部录 mp4 中间产物，停止后自动转码首个输出（其余保留视频）
                if fmt == .gif {
                    HStack(spacing: 8) {
                        Text("GIF 帧率")
                        TextField("", value: gifFpsInt, format: .number)
                            .epField()
                            .frame(width: 76)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: gifFpsInt, in: 2...15).labelsHidden()
                        Text("fps").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("GIF 长边上限")
                        TextField("", value: gifMaxEdgeInt, format: .number)
                            .epField()
                            .frame(width: 76)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: gifMaxEdgeInt, in: 240...1920, step: 40).labelsHidden()
                        Text("px").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("WebM 需 VP8 软编：捆绑 libvpx 并以 DISYNK_WITH_LIBVPX=1 构建才可用。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("内部以视频管线录制，停止后自动转码为 \(fmt.displayName)（无声轨）；转码失败时保留 mp4。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ── 指针与入画 ──────────────────────────────────────────────
            Divider()
            Toggle("录屏时排除本软件窗口", isOn: excludeOwnBinding)
                .help("开启后 Disynk 自身所有窗口将不会出现在录制画面里")
            Text("指针入画（每屏单独设置）")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.displays.filter { model.selectedIDs.contains($0.id) }) { d in
                Toggle(isOn: cursorBinding(for: d.id)) {
                    HStack(spacing: 4) {
                        Text(d.name)
                        if d.isVirtual { Text("（虚拟）").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
            }
            if model.selectedIDs.isEmpty {
                Text("（请先在左栏勾选屏幕）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("点击效果覆盖层", isOn: clickEffectsBinding)
                .help("鼠标点击时在画面上显示高亮圆圈效果")
            Toggle("按键显示覆盖层", isOn: keypressBinding)
                .help("录制时实时显示当前按下的键盘快捷键")
            if model.snapshot.recording.overlayShortcutDisplay {
                Picker("显示范围", selection: keyModeBinding) {
                    ForEach(KeyDisplayMode.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 220)
                Text("拖拽预览调整位置：")
                    .font(.caption).foregroundStyle(.secondary)
                KeyPositionPreview(model: model)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            // 文件命名自定义
            HStack {
                Text("文件名")
                TextField("留空 = Disynk-{datetime}-{display}", text: filenameFormatBinding)
                    .epField()
                    .frame(maxWidth: 260)
            }
            Text("变量：{date} 日期 | {time} 时间 | {datetime} 日期+时间 | {display} 屏幕名 | {index} 序号")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 28)
        .padding(.trailing, 16)   // 内容右侧留白，与外移后的滚动条拉开间距（否则选项条紧贴滚动条）
        }  // ScrollView
        .padding(.trailing, -14)   // 滚动条外移到贴近卡片右缘，不再挤在内容里（卡片内边距 20，取 14 仍留 6pt）
        // 开始/停止录制：本栏底部居中（左右留白，不贴右分隔条，避免遮挡布局编辑器）
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.isRecording {
                Text(String(format: "⏺ %02d:%02d",
                            Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                    .font(.system(.title3, design: .monospaced)).foregroundStyle(EP.danger)
            }
            Button(model.isRecording ? "停止录制" : "开始录制") {
                model.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .epButton(model.isRecording ? .danger : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        }  // outer VStack
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card("录制参数")
        .padding(.horizontal, 8)
        .frame(minWidth: 250, idealWidth: 300, maxWidth: 440)
    }

    // MARK: 右栏：显示器选择（顶部单独成区）+ 合并布局（占剩余高，原独立左栏并入此栏省一栏）

    private var layoutPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 显示器选择：原独立左栏并入本栏顶部，单独成区
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.displays) { d in
                    Toggle(isOn: binding(for: d.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(d.name)\(d.isVirtual ? "（虚拟）" : "")")
                                .font(.body)
                            Text("\(d.sourceSize.width)×\(d.sourceSize.height) @ \(Int(d.refreshRateHz))Hz")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("刷新列表") { Task { await model.refreshDisplays() } }
                    .disabled(model.isRecording)
                    .epButton(small: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .card("显示器", fill: false)

            // 合并布局：占剩余高度
            VStack(alignment: .leading, spacing: 8) {
                LayoutEditorView()
                HStack {
                    Button("横排") { model.applyPreset(.horizontal) }
                        .epButton(small: true)
                    Button("竖排") { model.applyPreset(.vertical) }
                        .epButton(small: true)
                    Button("网格") { model.applyPreset(.mixedGrid) }
                        .epButton(small: true)
                }
                .disabled(model.isRecording)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card("合并布局", subtitle: "拖动方框自由摆放；按钮为快捷预设")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
        .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
    }

    // MARK: 绑定（统一经 AppModel.mutateSettings 持久化）

    /// 方案第四节：估算并发编码会话数，并在接近硬件上限或 ProRes 多路软编时给出显式提示。
    /// 会话数与建议算法下沉至 DKCore.EncodeCapacity（单一真相 + 可单测），此处仅负责文案。
    private var encodeCapacityAdvisory: (text: String, warn: Bool)? {
        let n = model.selectedIDs.count
        guard n > 0 else { return nil }
        let mode = model.snapshot.recording.outputMode
        let codec = model.snapshot.recording.codec
        let sessions = EncodeCapacity.sessionCount(displayCount: n, mode: mode)
        switch EncodeCapacity.advise(displayCount: n, mode: mode, codec: codec) {
        case .softwareMultiSession:
            return ("\(codec.displayName) 为 CPU 软编（非硬编），\(sessions) 路同录会显著抬高 CPU，建议改单路使用。", true)
        case .overHardwareLimit:
            return ("预计 ~\(sessions) 个并发编码会话，已超硬件引擎经验上限（3~5 路 4K60），建议降帧率/低分辨率或改用合并单路。", true)
        case .info:
            return ("预计 \(sessions) 个编码会话（\(n) 屏 × \(mode.displayName)）。", false)
        }
    }

    private func binding(for id: UInt32) -> Binding<Bool> {
        Binding(get: { model.selectedIDs.contains(id) },
                set: { on in
                    var next = model.selectedIDs
                    if on { next.insert(id) } else { next.remove(id) }
                    // 复选框与桌面点选遮罩是同一份勾选：一起写，否则「开始录制」仍按遮罩里的旧集合走
                    model.setRecordedDisplays(next)
                })
    }
    private var codecBinding: Binding<VideoCodec> {
        Binding(get: { model.snapshot.recording.codec },
                set: { v in model.mutateSettings { $0.recording.codec = v } })
    }
    private var outputFormatBinding: Binding<RecordOutputFormat> {
        Binding(get: { model.snapshot.recording.outputFormat },
                set: { v in model.mutateSettings { $0.recording.outputFormat = v } })
    }
    private var containerBinding: Binding<ContainerFormat> {
        Binding(get: { model.snapshot.recording.container },
                set: { v in model.mutateSettings { $0.recording.container = v } })
    }
    private var qualityBinding: Binding<QualityTier> {
        Binding(get: { model.snapshot.recording.quality },
                set: { v in model.mutateSettings { $0.recording.quality = v } })
    }
    private var keyframeBinding: Binding<Int> {
        Binding(get: { model.snapshot.recording.keyframeIntervalSeconds },
                set: { v in model.mutateSettings { $0.recording.keyframeIntervalSeconds = v } })
    }
    private var outputModeBinding: Binding<OutputMode> {
        Binding(get: { model.snapshot.recording.outputMode },
                set: { v in model.mutateSettings { $0.recording.outputMode = v } })
    }
    private var systemAudioBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.captureSystemAudio },
                set: { v in model.mutateSettings { $0.recording.captureSystemAudio = v } })
    }
    private var micBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.captureMicrophone },
                set: { v in model.mutateSettings { $0.recording.captureMicrophone = v } })
    }
    private var cursorBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.captureCursor },
                set: { v in model.mutateSettings { $0.recording.captureCursor = v } })
    }
    /// 每屏指针入画绑定：读取「有效值」（包含 DisplayOverride），写入 DisplayOverride.captureCursor
    private func cursorBinding(for id: UInt32) -> Binding<Bool> {
        Binding(
            get: { model.snapshot.effective(for: id).captureCursor },
            set: { v in
                model.mutateSettings {
                    var o = $0.perDisplay[id] ?? DisplayOverride()
                    // 用户第一次修改某屏时，将当前全局值作为基线写入，避免误继承历史 null 状态
                    if o.captureCursor == nil { o.captureCursor = $0.recording.captureCursor }
                    o.captureCursor = v
                    $0.perDisplay[id] = o
                }
            }
        )
    }
    private var excludeOwnBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.excludeOwnWindows },
                set: { v in model.mutateSettings { $0.recording.excludeOwnWindows = v } })
    }
    private var clickEffectsBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.overlayClickEffects },
                set: { v in model.mutateSettings { $0.recording.overlayClickEffects = v } })
    }
    private var keypressBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.overlayShortcutDisplay },
                set: { v in model.mutateSettings { $0.recording.overlayShortcutDisplay = v } })
    }
    private var keyModeBinding: Binding<KeyDisplayMode> {
        Binding(get: { model.snapshot.recording.overlayKeyMode },
                set: { v in model.mutateSettings { $0.recording.overlayKeyMode = v } })
    }
    private var filenameFormatBinding: Binding<String> {
        Binding(get: { model.snapshot.recording.filenameFormat },
                set: { v in model.mutateSettings { $0.recording.filenameFormat = v } })
    }

    // 分辨率/帧率以标签形式映射（Codable 枚举不便直接做 Picker tag）
    enum ResolutionTag: Hashable { case native, preset(Int), custom }

    private var selectedResolutionTag: ResolutionTag {
        switch model.snapshot.recording.resolution {
        case .native: return .native
        case .preset: return .preset(presetIndex(matching: model.snapshot.recording.resolution))
        case .custom: return .custom
        }
    }

    private func presetIndex(matching mode: ResolutionMode) -> Int {
        if case .preset(let s) = mode,
           let idx = ResolutionMode.presets16x9.firstIndex(where: { $0 == s }) { return idx }
        return 0
    }

    private var resolutionBinding: Binding<ResolutionTag> {
        Binding(get: { selectedResolutionTag },
                set: { tag in
                    let mode: ResolutionMode
                    switch tag {
                    case .native: mode = .native
                    case .preset(let i): mode = .preset(ResolutionMode.presets16x9[i])
                    case .custom:
                        if model.customWidth >= 2, model.customHeight >= 2 {
                            mode = .custom(PixelSize(width: model.customWidth, height: model.customHeight))
                        } else {
                            mode = model.snapshot.recording.resolution
                        }
                    }
                    model.mutateSettings { $0.recording.resolution = mode }
                })
    }

    private var fpsBinding: Binding<Int> {
        Binding(get: { Int(model.snapshot.recording.frameRate.fps.rounded()) },
                set: { fps in
                    if fps >= 30 {
                        model.mutateSettings { $0.recording.frameRate = FrameRate(fps: Double(fps)) }
                    }
                })
    }

    // GIF 参数：文本框可手动输入（超出范围自动钳位），与步进器共用同一 Int 绑定保持同步
    private var gifFpsInt: Binding<Int> {
        Binding(get: { Int(model.gifFps.rounded()) },
                set: { v in model.gifFps = Double(min(15, max(2, v))) })
    }
    private var gifMaxEdgeInt: Binding<Int> {
        Binding(get: { Int(model.gifMaxEdge.rounded()) },
                set: { v in model.gifMaxEdge = Double(min(1920, max(240, v))) })
    }
}

// MARK: - 通用页（参考 CleanShot 设置 General：输出位置/覆盖层/入口/关于）

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @State private var desktopHidden = false
    @State private var launchEnabled = false

    /// 驱动分段选择器的本地枚举（WindowBackground 带关联值，不能直接当 tag）。
    private enum WindowBGKind: Hashable { case transparent, custom }

    var body: some View {
        EPGridCardStack {
            // 导出位置：截图/录制产物落此，直达打开
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("导出位置").font(.callout)
                        Spacer(minLength: 0)
                        Button {
                            model.openOutputDirectory()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                Text("打开")
                            }
                        }
                        .epButton(small: true)
                        Button("更改…") { model.chooseOutputDirectory() }
                            .epButton(small: true)
                    }
                    Text(model.snapshot.outputDirectoryPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("保存截图与录制产物使用的默认位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("导出位置")

                // 覆盖层（仅保留「是否入画」开关；点击效果/按键显示开关已移入「录制」页）
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("覆盖层录入画面（关闭=仅本机可见）", isOn: overlayInCaptureBinding)
                    Text("点击效果 / 按键显示开关在「录制」页配置。关闭此项后覆盖层仅本机可见、不进录制画面。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("覆盖层")

                // 录制增强：延迟起录 + 窗口背景（仅窗口录制）
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: delayBinding, in: 0...60, step: 1) {
                        Text("延迟录制：\(model.snapshot.recording.recordDelaySeconds) 秒").font(.callout)
                    }
                    Divider()
                    HStack {
                        Text("窗口录制背景").font(.callout)
                        Spacer()
                        Picker("", selection: windowBGBinding) {
                            Text("透明").tag(WindowBGKind.transparent)
                            Text("自定义壁纸").tag(WindowBGKind.custom)
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    if case .customImage(let p) = model.snapshot.recording.windowBackground {
                        Text("壁纸：\(p)").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Button("选择壁纸图片…") { model.chooseWindowWallpaper() }
                        .epButton(small: true)
                    Text("背景仅对「窗口」来源生效；透明=窗口外框留空（需 GIF/WebM 才能真保留透明）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("录制增强", subtitle: "延迟倒计时起录；窗口录制的背景")

                // 系统：桌面图标显隐 + 开机自启
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("隐藏桌面图标", isOn: Binding(
                        get: { desktopHidden },
                        set: { v in desktopHidden = v; DesktopIcons.setHidden(v) }))
                    Toggle("开机自启", isOn: Binding(
                        get: { launchEnabled },
                        set: { v in
                            if LaunchAtLogin.setEnabled(v) { launchEnabled = v }
                            else { model.statusLine = "开机自启设置失败，请到「系统设置→通用→登录项」手动添加" }
                        }))
                    Text("隐藏桌面图标会重启 Finder 生效；开机自启使用系统登录项。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("系统")

                // 入口
                HStack {
                    Button("录制面板…") { RecordingPanelController.shared.toggle(model: model) }
                        .epButton(small: true)
                    Button("摄像头小窗") { CameraWindowController.shared.toggle() }
                        .epButton(small: true)
                }
                .card("快捷入口", subtitle: "录制面板：悬浮图标栏，一键录制视频/GIF/WebM")

                // 关于
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(nsImage: AboutInfo.appIcon)
                            .resizable().interpolation(.high)
                            .frame(width: 18, height: 18)
                        Text("Disynk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(.headline)
                    }
                    Text("多屏录制 · 截图 OCR · 虚拟屏；菜单栏常驻，⌘⇧R 开始/停止录制。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("关于")
        }
        .onAppear {
            desktopHidden = DesktopIcons.isHidden()
            launchEnabled = LaunchAtLogin.isEnabled
        }
    }

    private var delayBinding: Binding<Int> {
        Binding(get: { model.snapshot.recording.recordDelaySeconds },
                set: { v in model.mutateSettings { $0.recording.recordDelaySeconds = v } })
    }

    private var windowBGBinding: Binding<WindowBGKind> {
        Binding(
            get: { if case .customImage = model.snapshot.recording.windowBackground { return .custom } else { return .transparent } },
            set: { kind in
                switch kind {
                case .transparent:
                    model.mutateSettings { $0.recording.windowBackground = .transparent }
                case .custom:
                    if case .customImage = model.snapshot.recording.windowBackground { }
                    else { model.chooseWindowWallpaper() }
                }
            })
    }

    private var overlayInCaptureBinding: Binding<Bool> {
        Binding(get: { model.snapshot.recording.overlayIncludedInRecording },
                set: { v in model.mutateSettings { $0.recording.overlayIncludedInRecording = v } })
    }
}

// MARK: - 截图/OCR 页

struct ShotTab: View {
    @EnvironmentObject var model: AppModel

    /// 「截图后 OCR」开关：与截图面板共享同一持久化设置。
    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.ocrEnabled },
            set: { on in model.mutateSettings { $0.ocrEnabled = on } }
        )
    }

    /// 「滚动截图包含标题栏」开关：关闭时拼接前从每帧裁掉顶部标题栏及左右固定侧栏，缓解重复。
    private var scrollChromeBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.scrollCaptureIncludeTitlebar },
            set: { on in model.mutateSettings { $0.scrollCaptureIncludeTitlebar = on } }
        )
    }

    /// 截图保存格式：与截图面板工具条的格式菜单共享同一持久化设置。
    private var shotFormatBinding: Binding<ShotFormat> {
        Binding(
            get: { model.snapshot.screenshotFormat },
            set: { f in model.mutateSettings { $0.screenshotFormat = f } }
        )
    }

    var body: some View {
        EPGridCardStack {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: ocrBinding) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.viewfinder")
                            Text("截图后自动 OCR（关闭=仅存图不识别）")
                        }
                    }
                    .toggleStyle(.switch)
                    Picker("保存格式", selection: shotFormatBinding) {
                        // 未装配 libvpx 的构建不提供 WebP（选了也会回退 PNG，干脆藏掉）
                        ForEach(ShotFormat.allCases.filter { $0 != .webp || WebPEncoder.isAvailable }) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("WebP 需 libvpx 装配构建（未装配时自动改存 PNG）；AVIF 不支持：macOS 无系统编码器。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("全屏截图（首屏）") { model.screenshotAndOCR(displayID: nil) }
                            .epButton(small: true)
                        Button("最前窗口") { model.screenshotWindowAndOCR() }
                            .epButton(small: true)
                        Button("区域框选") { model.screenshotRegionAndOCR() }
                            .disabled(model.regionCapturing)
                            .epButton(small: true)
                    }
                    HStack {
                        Button("剪贴板图片 OCR") { model.ocrClipboard() }
                            .epButton(small: true)
                        Button("复制文本") { model.copyOCRText() }.disabled(model.ocrText.isEmpty)
                            .epButton(small: true)
                        Button("导出 TXT") { model.saveOCRText() }.disabled(model.ocrText.isEmpty)
                            .epButton(small: true)
                        Button("导出 MD") { model.saveOCRMarkdown() }.disabled(model.ocrText.isEmpty)
                            .epButton(small: true)
                        Button("清空结果") { model.clearOCRText() }
                            .disabled(model.ocrText.isEmpty)
                            .epButton(.danger, small: true)
                    }
                }
                .card("截图", subtitle: "开关开启时附带 Vision 离线识别（中英双语）；结果可复制或导出 TXT/Markdown")

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: scrollChromeBinding) {
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow")
                            Text("滚动截图包含标题栏（关闭=拼接前裁掉顶部标题栏/工具栏，缓解重复）")
                        }
                    }
                    .toggleStyle(.switch)
                    HStack {
                        Button("滚动截图…") { model.beginScrollCapture() }
                            .disabled(model.scrollCapturing || model.regionCapturing)
                            .epButton(small: true)
                        Button("点选窗口滚动截图…") { model.pickScrollWindow() }
                            .disabled(model.scrollCapturing || model.regionCapturing)
                            .epButton(small: true)
                            .help("遮罩里直接点哪个窗就滚哪个；滚动发生在点击处，比窗口中心可靠")
                        if model.scrollCapturing {
                            Button("停止并保存") { model.finishScrollCapture() }.epButton(.primary)
                            Button("取消") { model.cancelScrollCapture() }.epButton(small: true)
                        }
                    }
                    Text("选择窗口自动滚动逐帧截取，或框选区域后手动滚动；停止后自动去重叠合成为一张长图。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.scrollCapturing {
                        Text(model.scrollStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card("滚动长截图", subtitle: "选窗口自动滚动 / 框选区域手动滚动 → 拼接为长图")

                TextEditor(text: $model.ocrText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .card("识别结果")
        }
    }
}

// MARK: - 虚拟屏页

struct VirtualTab: View {
    @EnvironmentObject var model: AppModel
    @State private var vWidth = 2560
    @State private var vHeight = 1440
    @State private var hiDPI = true

    var body: some View {
        EPGridCardStack {
            if !model.virtualSupported {
                EPAlert(kind: .warning,
                        text: "当前系统未暴露 CGVirtualDisplay 类，虚拟屏不可用（已自动探测降级）。")
            }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("创建 1080p") { model.createVirtualDisplay(preset: .fullHD) }
                            .disabled(!model.virtualSupported)
                            .epButton(small: true)
                        Button("创建 2K") { model.createVirtualDisplay(preset: .retina2K) }
                            .disabled(!model.virtualSupported)
                            .epButton(small: true)
                        Button("创建 4K") { model.createVirtualDisplay(preset: .fourK) }
                            .disabled(!model.virtualSupported)
                            .epButton(small: true)
                        Button("全部移除") { model.destroyAllVirtualDisplays() }
                            .epButton(.danger, small: true)
                    }
                    // 方案第三节：自定义分辨率与 HiDPI（仅数字：宽/高两个数字框）
                    HStack {
                        TextField("宽", value: $vWidth, format: .number)
                            .epField().frame(width: 84)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", value: $vHeight, format: .number)
                            .epField().frame(width: 84)
                        Toggle("HiDPI", isOn: $hiDPI)
                        Button("创建自定义") { model.createVirtualDisplay(width: vWidth, height: vHeight, hiDPI: hiDPI) }
                            .disabled(!model.virtualSupported)
                            .epButton(.primary, small: true)
                    }
                }
                .card("创建虚拟屏", subtitle: "CGVirtualDisplay 私有 API · 自定义分辨率仅数字")

                VStack(alignment: .leading, spacing: 6) {
                    if model.virtualDisplays.isEmpty {
                        Text("（本会话尚未创建虚拟屏）").foregroundStyle(.secondary)
                    }
                    ForEach(model.virtualDisplays, id: \.displayID) { v in
                        HStack {
                            Text("\(v.name)（#\(v.displayID)）\(v.hiDPI ? " \u{2B50}HiDPI" : "")").font(.system(.body, design: .monospaced))
                            Spacer()
                            // 方案第三节「向虚拟屏拖放窗口」：经 AX 把最前窗口居中移到该虚拟屏
                            Button("移入最前窗口") { model.moveFocusedWindow(toVirtualDisplay: v.displayID) }
                                .help("需「辅助功能」权限；把当前前台 App 的焦点窗口移到该虚拟屏")
                                .epButton(small: true)
                            // 单独移除这一块虚拟屏（不影响其余）
                            Button("移除", role: .destructive) { model.destroyVirtualDisplay(displayID: v.displayID) }
                                .help("仅移除该虚拟屏")
                                .epButton(.danger, small: true)
                        }
                    }
                    Text("虚拟屏创建后会出现在「录制」页屏幕列表中，可像物理屏一样勾选录制；窗口可拖入虚拟屏隔离录制内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("本会话创建的虚拟屏")
        }
    }
}

// MARK: - 权限页（方案 M7 路径 A：引导重新授权 = tccutil 提示 + 直达隐私面板 URL）

struct PermissionTab: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false

    private struct Item {
        let pane: ScreenPermissions.Pane
        let title: String
        let icon: String
        let blurb: String
        let required: Bool
    }

    private let items: [Item] = [
        Item(pane: .screenRecording, title: "屏幕录制", icon: "record.circle",
             blurb: "捕获屏幕画面，是录制视频与截图的核心能力。", required: true),
        Item(pane: .accessibility, title: "辅助功能", icon: "hand.raised.circle",
             blurb: "录制覆盖层用它实时显示点击涟漪与按键横幅；全局快捷键也依赖此权限。", required: true),
        Item(pane: .microphone, title: "麦克风", icon: "mic.circle",
             blurb: "仅当你想把麦克风声音一起录进视频时才需要，可跳过。", required: false),
    ]

    var body: some View {
        EPGridCardStack {
            Text("Disynk 需要以下系统权限才能完整工作。逐项点「去开启」，在系统设置里勾选后回到本页会自动检测授权状态。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .card("系统权限", subtitle: "授予后即可开始录制")

                ForEach(items, id: \.title) { item in
                    permissionRow(item)
                        .card()
                }

                // 重置命令对普通用户是噪声，折叠进「高级」里。
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("若已在系统设置勾选却仍无法录制/覆盖层不生效：多为重新编译后签名与系统授权记录不匹配，用下方命令重置该服务后重新授权。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(items, id: \.title) { item in
                            resetRow(item)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("高级：授权失效时的重置命令")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(EP.fillLight, in: RoundedRectangle(cornerRadius: EP.radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func permissionRow(_ item: Item) -> some View {
        let granted = ScreenPermissions.isGranted(item.pane)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : item.icon)
                .font(.system(size: 26))
                .foregroundStyle(granted ? EP.success : (item.required ? EP.warning : EP.textSecondary))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: EP.fontBody, weight: .semibold))
                    EPTag(text: item.required ? "必需" : "可选", role: item.required ? .warning : .info)
                }
                Text(item.blurb).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(granted ? "已授予" : "未授予")
                    .font(.caption).foregroundStyle(granted ? EP.success : EP.textSecondary)
                if granted {
                    Button("打开设置") { ScreenPermissions.openPrivacyPane(item.pane) }
                        .epButton(small: true)
                } else {
                    Button("去开启") { grant(item.pane) }
                        .epButton(.primary, small: true)
                }
            }
        }
    }

    @ViewBuilder
    private func resetRow(_ item: Item) -> some View {
        let hint = ScreenPermissions.reauthorizationHint(
            bundleID: ScreenPermissions.currentBundleID(), pane: item.pane)
        HStack(spacing: 8) {
            Text(item.title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(hint.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 0)
            Button("复制") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(hint.command, forType: .string)
            }
            .epButton(small: true)
        }
    }

    /// 先尝试即时请求（录屏/麦克风会弹系统框），同时直达对应隐私面板方便手动勾选。
    private func grant(_ pane: ScreenPermissions.Pane) {
        switch pane {
        case .screenRecording: _ = ScreenPermissions.requestScreenRecording()
        case .accessibility:   ScreenPermissions.promptAccessibility()
        case .microphone:      Task { _ = await ScreenPermissions.requestMicrophone() }
        }
        ScreenPermissions.openPrivacyPane(pane)
    }
}

// MARK: - 按键覆盖层可拖拽位置预览

/// 小屏幕预览框，按实际主屏比例显示，用户可拖拽胶囊调整覆盖层位置。
/// 归一化坐标 X/Y 写入 settings.overlayKeyPositionX/Y。
struct KeyPositionPreview: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> KeyPreviewNSView {
        let v = KeyPreviewNSView()
        v.onDrag = { nx, ny in
            model.mutateSettings {
                $0.recording.overlayKeyPositionX = nx
                $0.recording.overlayKeyPositionY = ny
            }
        }
        return v
    }

    func updateNSView(_ v: KeyPreviewNSView, context: Context) {
        v.posX = CGFloat(model.snapshot.recording.overlayKeyPositionX)
        v.posY = CGFloat(model.snapshot.recording.overlayKeyPositionY)
        if let s = NSScreen.main { v.aspect = s.frame.width / s.frame.height }
        v.needsDisplay = true
    }
}

/// 预览框宿主视图：拖拽坐标取自 `convert(locationInWindow, from: nil)`（视图自身坐标系），
/// 不受外层 ScrollView 滚动偏移与 SwiftUI 重排抖动影响，彻底消除「胶囊漂移」。
final class KeyPreviewNSView: NSView {
    var onDrag: ((Double, Double) -> Void)?
    var posX: CGFloat = 0.5
    var posY: CGFloat = 0.08
    var aspect: CGFloat = 16.0 / 9.0

    override var isFlipped: Bool { true }        // 左上原点，映射直观
    override var acceptsFirstResponder: Bool { true }

    /// 预览框：按主屏宽高比在可用区域内取最大矩形（顶部左对齐）
    private var box: CGRect {
        let w = bounds.width
        let h = min(bounds.height, w / max(aspect, 0.0001))
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = box
        EP.previewScreen.setFill()
        let bg = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
        bg.fill()
        EP.previewBorder.withAlphaComponent(0.55).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let text = "⌘⇧3" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ts = text.size(withAttributes: attrs)
        let padX: CGFloat = 8, padY: CGFloat = 4
        let pillW = ts.width + padX * 2, pillH = ts.height + padY * 2
        let cx = b.minX + posX * b.width
        let cy = b.minY + (1 - posY) * b.height   // posY: 0=底,1=顶 → flipped 下从顶部算
        let pill = CGRect(x: cx - pillW / 2, y: cy - pillH / 2, width: pillW, height: pillH)
        EP.previewPill.setFill()
        let capsule = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
        capsule.fill()
        text.draw(at: CGPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attrs)
    }

    private func updateLocal(windowPoint: NSPoint) {
        let b = box
        guard b.width > 1, b.height > 1 else { return }
        let p = convert(windowPoint, from: nil)   // 视图自身坐标（flipped：y 从顶）
        let nx = min(max(Double((p.x - b.minX) / b.width), 0.05), 0.95)
        let ny = min(max(1 - Double((p.y - b.minY) / b.height), 0.03), 0.97)
        posX = CGFloat(nx); posY = CGFloat(ny)
        needsDisplay = true
    }

    // 拖拽期间只更新本地坐标 + 轻量重绘；不逐帧写 settings。
    // 否则每个 mouseDragged 都触发 mutateSettings → 整个设置页重排，追不上 60~120Hz 鼠标事件
    // → 事件缓冲，松手后集中排空→胶囊「自己再走一遍刚才的轨迹」。松手时才落盘一次。
    override func mouseDown(with event: NSEvent) { updateLocal(windowPoint: event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { updateLocal(windowPoint: event.locationInWindow) }
    override func mouseUp(with event: NSEvent) {
        updateLocal(windowPoint: event.locationInWindow)
        onDrag?(Double(posX), Double(posY))
    }
}
