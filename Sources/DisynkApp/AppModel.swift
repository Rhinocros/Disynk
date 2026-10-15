import AppKit
import DKAudio
import DKCapture
import DKCompose
import DKCore
import DKExport
import DKOverlay
import DKSettings
import DKShot
import DKVirtualDisplay
import Foundation
import UniformTypeIdentifiers

/// 应用状态中枢（主线程）。设置、屏列表、录制引擎、覆盖层、虚拟屏、授权、导出全部经此接线。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: 发布状态
    @Published var snapshot = AppSettingsSnapshot()
    @Published var displays: [DisplaySnapshot] = []
    @Published var selectedIDs: Set<UInt32> = []
    @Published var layout: ComposeLayout?
    @Published var isRecording = false
    @Published var elapsed: Double = 0
    @Published var statusLine = "就绪"
    @Published var lastOutputs: [URL] = []
    @Published var lastScreenshots: [URL] = []
    @Published var ocrText = ""
    @Published var virtualDisplays: [VirtualDisplayManager.VirtualScreen] = []
    @Published var virtualSupported = false
    /// 区域框选进行中标记（避免叠叠弹选择遮罩）
    var regionCapturing = false

    // MARK: 录制前选择态（点选屏幕 / 累加范围，配合 ControlBar 的「开始录制栏」）
    /// 选择阶段：none 无 / pickingDisplays 点选屏幕 / pickingRegions 框选范围
    enum SelectionStage: Equatable {
        case none, pickingDisplays, pickingRegions
    }
    @Published var selectionStage: SelectionStage = .none
    /// 点选屏幕模式下的待录屏集合（由 DisplayPickerController 实时写回）
    /// 与 selectedIDs 是同一份勾选状态的两个视图，任何改动都必须走 setRecordedDisplays 保持同步。
    @Published var pendingDisplayIDs: Set<UInt32> = []
    /// 范围模式下的待录选区集合（可累加多个，每个含所属屏 displayID）
    @Published var pendingRegions: [RegionSelection] = []
    /// 逐屏框选调度（每块屏一个独立遮罩窗口，避免跨屏并集窗口在外接屏上不可靠）
    private var regionTargets: [NSScreen] = []
    private var regionStep = 0
    /// 延迟录制倒计时秒数（nil=无倒计时）；ControlBar 据此显示倒计时态。
    @Published var countdown: Int?
    private var countdownTask: Task<Void, Never>?
    @Published var customResolution = "1920x1080"
    /// 自定义分辨率拆为两个纯数字输入（方案：分辨率自定义只允许数字）。
    /// 同时也是录制面板宽高框的显示值：.native 时由 syncPanelResolutionToScreen 回填目标屏真实像素尺寸。
    @Published var customWidth: Int = 1920
    @Published var customHeight: Int = 1080
    /// 最近一次程序回填宽高框的值（非用户输入）：onChange 回调里等于它时不写 .custom，
    /// 避免回填原生分辨率反而把分辨率模式改成自定义。
    private var syncedResolutionFields: (w: Int, h: Int)?
    @Published var gifFps: Double = 12
    @Published var gifMaxEdge: Double = 800

    /// 录制来源模式（方案第三节：全屏/窗口/范围）
    @Published var recordSource: RecordSourceKind = .fullScreen
    /// 设置窗口当前分区（状态栏菜单可直达指定页，如「权限状态」）
    @Published var navSection: NavSection = .general
    private var activeSingleTarget = false
    /// 窗口录制候选列表与选中项（录制来源=窗口时可见；可由下拉选择或点选遮罩指定）
    @Published var recordableWindows: [WindowSnapshot] = []
    @Published var selectedWindowID: UInt32?
    /// 最近一次「点选窗口截图」选中的窗口：截图面板据此提供「录制该窗口」快捷按钮。
    @Published var lastPickedWindow: WindowSnapshot?

    // MARK: 组件
    let settingsStore = SettingsStore()
    private let engine = RecordingEngine()
    /// 当前活动单目标录制（窗口录制 1 路；范围录制可多路——每屏一块选区）
    private var stRecorders: [SingleTargetRecorder] = []
    private var overlayController: OverlayController?
    private var overlayPanel: OverlayPanel?
    private let virtualManager = VirtualDisplayManager()
    private var elapsedTimer: Timer?
    private var displayRefreshTimer: Timer?

    private init() {}

    // MARK: - 状备栏一次性提示

    /// 自动恢复「就继」的计时器；录制中 / 选择中 / 倒计时中不覆盖。
    private var statusResetTask: Task<Void, Never>?

    /// 显示一次性状态提示（默认 5 秒后自动恢复「就继」）。
    /// 适用于虚拟屏创建/移除、截图保存、壁纸设置等单次操作结果；
    /// 录制中、选择阶段、倒计时的状态行不走此方法。
    func notify(_ msg: String, dismissAfter seconds: Int = 5) {
        statusLine = msg
        statusResetTask?.cancel()
        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // 录制中 / 选择中 / 倒计时时不覆盖当前状态行
            if !self.isRecording, self.selectionStage == .none, self.countdown == nil {
                self.statusLine = "就绪"
            }
            self.statusResetTask = nil
        }
    }

    // MARK: - 初始化流

    func bootstrap() async {
        snapshot = await settingsStore.current()
        virtualSupported = VirtualDisplayManager.isSupported()
        await refreshDisplays()   // 末尾会 syncPanelResolutionToScreen 回填宽高框
        displayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                await self.refreshDisplays()
            }
        }
        // 设置变更广播
        let store = settingsStore
        Task { @MainActor in
            for await snap in await store.updates() {
                self.snapshot = snap
                // 分辨率模式在设置窗口被改（原生/预设/自定义）→ 面板宽高框同步显示
                self.syncPanelResolutionToScreen()
            }
        }
        statusLine = ScreenPermissions.hasScreenRecording()
            ? "就绪（屏幕录制权限已授予）"
            : "缺少屏幕录制权限，请在「系统设置 → 隐私与安全性」授权"
    }


    func refreshDisplays() async {
        do {
            displays = try await DisplayEnumerator.available(includeVirtual: true)
            let alive = Set(displays.map(\.id))
            selectedIDs = selectedIDs.intersection(alive)
            pendingDisplayIDs = pendingDisplayIDs.intersection(alive)
            if selectedIDs.isEmpty {
                selectedIDs = Set(displays.prefix(2).map(\.id))
            }
            // 布局默认覆盖当前选中屏（首次自动预设；后续仅增量同步，不重置手动拖拽）
            if layout == nil { applyPreset(.horizontal) } else { syncLayoutSelection() }
            // 屏列表变化（热插拔/虚拟屏）→ 面板宽高框跟随真实分辨率同步
            syncPanelResolutionToScreen()
        } catch {
            statusLine = "枚举屏幕失败：\(error.localizedDescription)"
        }
    }

    /// 刚创建虚拟屏后的刷新：立即刷一次，再延迟补刷两次，等屏真正 online 进入 SCK 可录列表。
    /// （CGVirtualDisplay 上线异步，单次立即枚举常漏掉新屏。）
    func refreshDisplaysSoon() async {
        await refreshDisplays()
        for delayMs in [700, 1800] {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            await refreshDisplays()
        }
    }

    func mutateSettings(_ block: @escaping @Sendable (inout AppSettingsSnapshot) -> Void) {
        block(&snapshot)
        Task { await settingsStore.mutate(block) }
    }

    /// 应用自定义分辨率（两个数字框）到录制设置；非法值仅提示不写。
    /// 程序回填（syncPanelResolutionToScreen）触发的 onChange 与当前值相同 → 直接返回，
    /// 不把 .native 误改写成 .custom(屏幕尺寸)。
    func applyCustomResolution() {
        guard customWidth >= 2, customHeight >= 2, customWidth <= 8192, customHeight <= 8192 else {
            statusLine = "分辨率需在 2–8192 之间"
            return
        }
        if case .native = snapshot.recording.resolution,
           syncedResolutionFields?.w == customWidth, syncedResolutionFields?.h == customHeight {
            return
        }
        let w = customWidth, h = customHeight
        mutateSettings { $0.recording.resolution = .custom(PixelSize(width: w, height: h)) }
    }

    /// 录制面板宽高框跟随当前分辨率模式回填：
    /// .native → 主屏真实像素尺寸（含 HiDPI 倍率）；preset/custom → 已选尺寸。
    /// 面板打开、录制来源/点选屏幕切换、设置变更时调用，避免全屏录制永远显示/锁定 1920×1080。
    func syncPanelResolutionToScreen() {
        let w: Int, h: Int
        switch snapshot.recording.resolution {
        case .native:
            let mainID = CGMainDisplayID()
            guard let size = (displays.first { $0.id == mainID }
                    ?? displays.first { selectedIDs.contains($0.id) }
                    ?? displays.first)?.sourceSize else { return }
            w = size.width; h = size.height
        case .preset(let s), .custom(let s):
            w = s.width; h = s.height
        }
        guard customWidth != w || customHeight != h else { return }
        syncedResolutionFields = (w, h)
        customWidth = w
        customHeight = h
    }

    /// 选择输出目录（方案：截图/录制存储路径）。
    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: snapshot.outputDirectoryPath)
        if panel.runModal() == .OK, let url = panel.url {
            mutateSettings { $0.outputDirectoryPath = url.path }
            statusLine = "输出目录：\(url.path)"
        }
    }

    /// 在访达中打开输出目录（不存在时先创建）。
    func openOutputDirectory() {
        let dir = URL(fileURLWithPath: snapshot.outputDirectoryPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 刷新可录制窗口列表（录制来源切到「窗口」时/手动点刷新）。
    func refreshRecordableWindows() {
        Task {
            do {
                recordableWindows = try await WindowEnumerator.available()
                if let sel = selectedWindowID, !recordableWindows.contains(where: { $0.id == sel }) {
                    selectedWindowID = nil
                    lastPickedWindow = nil   // 选中的窗口已关 → 面板撤回「录制该窗口」按钮
                }
                notify("窗口列表：\(recordableWindows.count) 个可选")
            } catch {
                notify("枚举窗口失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 点选窗口（截图 + 设为窗口录制目标）

    /// 截图面板「窗口」入口：遮罩里点哪个窗就截哪个，同时把它登记为窗口录制目标——
    /// 选完后截图面板出现「录制该窗口」，录制面板/设置页的窗口录制也直接录它。
    func pickWindowForShot() {
        guard !scrollCapturing, !regionCapturing, !isRecording else { return }
        guard ensureScreenRecordingForShot() else { return }
        ScreenshotPanelController.shared.hide()
        statusLine = "点选要截图的窗口（点击即截图并设为窗口录制目标，Esc 取消）…"
        WindowPickerController.present(hint: "点击要截图的窗口・悬停高亮最前窗・Esc 取消") { [weak self] win in
            Task { @MainActor in
                guard let self else { return }
                guard let win else {
                    self.statusLine = "已取消点选窗口"
                    ScreenshotPanelController.shared.show(model: self)
                    return
                }
                self.setWindowRecordTarget(windowID: win.windowID)
                do {
                    let img = try await Screenshotter.captureWindow(windowID: win.windowID)
                    self.saveShot(img, prefix: "Disynk-窗口")
                    if self.snapshot.ocrEnabled { await self.runOCR(on: img) }
                    self.presentOCRResultIfNeeded()
                } catch {
                    self.statusLine = "窗口截图失败：\(error.localizedDescription)"
                }
                // 重开截图面板：就地提供「录制该窗口」快捷按钮
                ScreenshotPanelController.shared.show(model: self)
            }
        }
    }

    /// 录制面板「点选窗口」入口：只选定录制目标，不截图。
    func pickRecordWindow() {
        guard !isRecording, selectionStage == .none, !scrollCapturing, !regionCapturing else { return }
        guard ensureScreenRecordingForShot() else { return }
        RecordingPanelController.shared.hide()
        statusLine = "点选要录制的窗口（Esc 取消）…"
        WindowPickerController.present(hint: "点击要录制的窗口・悬停高亮最前窗・Esc 取消") { [weak self] win in
            Task { @MainActor in
                guard let self else { return }
                guard let win else {
                    self.statusLine = "已取消点选窗口"
                    RecordingPanelController.shared.show(model: self)
                    return
                }
                self.setWindowRecordTarget(windowID: win.windowID)
                RecordingPanelController.shared.show(model: self)   // 回面板确认目标后点录制
            }
        }
    }

    /// 把点选窗口登记为录制目标：补齐窗口列表条目（列表可能未刷新/不含它，
    /// startWindowRecording 会在列表里校验选中项），切来源到窗口并记快照供面板显示。
    private func setWindowRecordTarget(windowID: CGWindowID) {
        let snap = Self.windowSnapshotForPick(windowID)
            ?? WindowSnapshot(id: windowID, title: "", appName: "所选窗口",
                              size: PixelSize(width: 2, height: 2))
        if let idx = recordableWindows.firstIndex(where: { $0.id == windowID }) {
            recordableWindows[idx] = snap
        } else {
            recordableWindows.insert(snap, at: 0)
        }
        selectedWindowID = windowID
        recordSource = .window
        lastPickedWindow = snap
        statusLine = "已选定窗口录制目标：\(snap.displayLabel)（点「录制视频」即录它）"
    }

    /// 从 CGWindowList 取指定窗口的快照（点选后异步枚举来不及/列表未含时的同步兜底）。
    private static func windowSnapshotForPick(_ id: CGWindowID) -> WindowSnapshot? {
        let opts: CGWindowListOption = [.optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, num == id else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "窗口"
            let name = info[kCGWindowName as String] as? String ?? ""
            let b = info[kCGWindowBounds as String] as? [String: Any]
            let w = (b?["Width"] as? NSNumber)?.intValue ?? 2
            let h = (b?["Height"] as? NSNumber)?.intValue ?? 2
            return WindowSnapshot(id: id, title: name, appName: owner, size: PixelSize(width: w, height: h))
        }
        return nil
    }

    /// 录制刚点选的窗口（截图面板的「录制该窗口」快捷按钮）。
    func recordPickedWindow() {
        guard let win = lastPickedWindow, !isRecording else { return }
        selectedWindowID = win.id
        recordSource = .window
        ScreenshotPanelController.shared.hide()
        startRecording()
    }

    // MARK: - 布局

    enum LayoutPreset { case horizontal, vertical, mixedGrid }

    func applyPreset(_ preset: LayoutPreset) {
        let chosen = displays.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        switch preset {
        case .horizontal: layout = ComposeLayout.horizontal(chosen)
        case .vertical: layout = ComposeLayout.vertical(chosen)
        case .mixedGrid: layout = ComposeLayout.mixedGrid(chosen)
        }
    }

    /// 选中集变更时增量同步布局（保留已有手动拖拽位，仅为新增屏补位、移除取消屏）。
    func syncLayoutSelection() {
        let chosen = displays.filter { selectedIDs.contains($0.id) }
        guard var l = layout else { applyPreset(.horizontal); return }
        l.sync(to: chosen)
        layout = l
    }

    // MARK: - 录制

    enum RecordSourceKind: String, CaseIterable, Sendable {
        case fullScreen = "全屏"
        case window = "窗口"
        case region = "范围"
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording else { return }
        switch recordSource {
        case .fullScreen:
            // 面板已勾选就直接录（带延迟）；未选则进入桌面点选。
            if pendingDisplayIDs.isEmpty { beginDisplaySelection() } else { commitDisplaySelection() }
        case .window:
            startWindowRecording()
        case .region:
            // 面板已框选就直接录（带延迟）；未框则进入逐屏框选。
            if pendingRegions.isEmpty { beginRegionSelection() } else { commitRegionSelection() }
        }
    }

    /// 按指定产出格式开始录制（供“录视频/录 GIF/录 WebM”快捷键直接调用）。
    /// 录制中不响应；GIF/WebM 需离线转码权限位（startRecording 内部已门控）。
    func startRecording(format: RecordOutputFormat) {
        guard !isRecording else { return }
        mutateSettings { $0.recording.outputFormat = format }
        startRecording()
    }

    // MARK: - 录制前选择流程（点选屏幕 / 累加范围，均配「开始录制栏」）

    /// 屏幕勾选的单一入口：主窗口复选框与桌面点选遮罩共用一份状态。
    /// 此前复选框只写 selectedIDs、遮罩只写 pendingDisplayIDs，而「开始录制」认的是后者 ——
    /// 录完单屏后在复选框里勾回外接屏，实际仍按上次的单屏集合起录，只录到一路。
    func setRecordedDisplays(_ ids: Set<UInt32>) {
        selectedIDs = ids
        pendingDisplayIDs = ids
        syncLayoutSelection()
    }

    /// 全屏录制：弹出点选屏幕遮罩，选中的屏实时写回 pendingDisplayIDs，右上角出现「开始录制栏」。
    func beginDisplaySelection() {
        guard selectionStage == .none else { return }
        RecordingPanelController.shared.hide()   // 进入桌面点选 → 收起录制面板免遮挡
        selectionStage = .pickingDisplays
        // 不清 pendingDisplayIDs：面板勾选与桌面点选共享同一集合（高亮连续）。
        if pendingDisplayIDs.isEmpty { pendingDisplayIDs = selectedIDs }
        ControlBar.shared.show(model: self)
        DisplayPickerController.present(model: self)
        statusLine = "点击屏幕选择要录制的屏（可多选），再点右上角「开始录制」"
    }

    /// 点选屏幕：切换某块屏的选中态（DisplayPickerController 点击卡片时调用）。
    func toggleDisplay(_ id: UInt32) {
        var next = pendingDisplayIDs
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        setRecordedDisplays(next)
    }

    /// 范围录制（逐屏）：进入框选态，右上角出现「开始录制栏」，随即在每块屏（各自独立窗口）上依次弹遮框。
    /// 旧实现用一块跨屏并集遮罩 → 外接屏无法拖框；现每屏一个窗、逐屏框选，外接/虚拟（有 NSScreen 者）都能框。
    func beginRegionSelection() {
        guard selectionStage == .none, !regionCapturing else { return }
        RecordingPanelController.shared.hide()   // 进入逐屏框选 → 收起录制面板免遮挡
        selectionStage = .pickingRegions
        pendingRegions = []
        regionTargets = NSScreen.screens
        regionStep = 0
        ControlBar.shared.show(model: self)
        promptRegionStep()
    }

    /// 逐屏框选的当前步：只在 regionTargets[regionStep] 这一屏（其自身 frame）弹遮标。
    /// picked/skipped 前进到下一屏；cancelled 结束循环（保留已选）。
    private func promptRegionStep() {
        guard selectionStage == .pickingRegions else { return }
        guard regionStep < regionTargets.count else {
            regionCapturing = false
            statusLine = "已选 \(pendingRegions.count) 个范围，点「开始录制」或「取消」"
            return
        }
        let screen = regionTargets[regionStep]
        regionCapturing = true
        let hint = "屏 \(regionStep + 1)/\(regionTargets.count)（\(screen.localizedName)）：拖动框选；回车跳过此屏；Esc 结束框选"
        RegionPickerController.present(screens: [screen], hint: hint, allowsSkip: true) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.regionCapturing = false
                switch outcome {
                case .picked(let sel):
                    self.pendingRegions.append(sel)
                    self.regionStep += 1
                    self.promptRegionStep()
                case .skipped:
                    self.regionStep += 1
                    self.promptRegionStep()
                case .cancelled:
                    self.statusLine = "已选 \(self.pendingRegions.count) 个范围，点「开始录制」或「取消」"
                }
            }
        }
    }

    /// 面板「在此屏框选」：只在指定屏弹一块遮标，选区累加进 pendingRegions（可反复对多屏各框一块）。
    func regionPick(displayID: UInt32) {
        guard !regionCapturing else { return }
        RecordingPanelController.shared.hide()   // 进入桌面框选 → 收起录制面板免遮挡
        if selectionStage != .pickingRegions {
            selectionStage = .pickingRegions
            pendingRegions = []
            ControlBar.shared.show(model: self)
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }) else {
            statusLine = "该屏无桌面映射，无法框选（请改用全屏整屏录制）"
            return
        }
        regionCapturing = true
        RegionPickerController.present(screens: [screen],
                                       hint: "在「\(screen.localizedName)」拖动框选；Esc 取消本次", allowsSkip: false) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.regionCapturing = false
                if case .picked(let sel) = outcome { self.pendingRegions.append(sel) }
                self.statusLine = "已选 \(self.pendingRegions.count) 个范围，继续框选或点「开始录制」"
            }
        }
    }

    /// 「开始录制栏」主按钮：按当前选择阶段提交录制。
    func commitSelection() {
        switch selectionStage {
        case .pickingDisplays: commitDisplaySelection()
        case .pickingRegions: commitRegionSelection()
        case .none: break
        }
    }

    /// 提交全屏选择（面板勾选或桌面点选均适用）：按 recordDelaySeconds 倒计时后起录。
    private func commitDisplaySelection() {
        let ids = pendingDisplayIDs
        guard !ids.isEmpty else { return }
        DisplayPickerController.dismiss()
        selectionStage = .none
        beginAfterDelay { [weak self] in self?.startFullScreenRecording(ids: ids) }
    }

    /// 提交范围选择（面板逐屏框选或桌面逐屏框选均适用）：倒计时后起录。
    private func commitRegionSelection() {
        guard !regionCapturing else { return }   // 框选进行中，等本轮遮罩收起再提交
        let sels = pendingRegions
        guard !sels.isEmpty else { return }
        selectionStage = .none
        let pairs: [(SingleTargetRecorder.Target, String)] = sels.map { sel in
            let dn = displays.first(where: { $0.id == sel.displayID })
                .map { RecordingEngine.fileSafeName($0.name) } ?? "\(sel.displayID)"
            return (.region(displayID: sel.displayID, rect: sel.rect), "范围-\(dn)")
        }
        beginAfterDelay { [weak self] in
            RegionFrameController.present(regions: sels)   // 选区外压暗边框，标示正在采集（不入画）
            self?.beginSingleTargets(pairs)
        }
    }

    /// 延迟录制：delay>0 时先在 ControlBar 逐秒倒计时（可取消）再执行 work；delay=0 直接执行。
    private func beginAfterDelay(_ work: @escaping () -> Void) {
        let delay = snapshot.recording.recordDelaySeconds
        guard delay > 0 else { work(); return }
        DisplayPickerController.dismiss()   // 倒计时前先收起可能残留的点选遮标
        countdown = delay
        ControlBar.shared.show(model: self)
        statusLine = "\(delay) 秒后开始录制…"
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let c = self.countdown, c > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.countdown = c - 1
            }
            self.countdown = nil
            self.countdownTask = nil
            work()
        }
    }

    /// 取消倒计时（ControlBar 倒计时态「取消」按钮）。
    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        ControlBar.shared.hide()
        statusLine = "已取消倒计时"
    }

    /// 「开始录制栏」取消：关闭选择遮罩、复位状态。
    func cancelSelection() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        DisplayPickerController.dismiss()
        selectionStage = .none
        pendingDisplayIDs = []
        pendingRegions = []
        regionCapturing = false
        ControlBar.shared.hide()
        statusLine = "已取消选择"
    }

    /// 窗口录制：优先用下拉选中的窗口，未选则取当前最前层非本应用窗口，单路编码封装。
    private func startWindowRecording() {
        let winID: UInt32
        if let sel = selectedWindowID, recordableWindows.contains(where: { $0.id == sel }) {
            winID = sel
        } else if let front = FrontWindowResolver.frontmostOtherWindowID() {
            winID = front
        } else {
            statusLine = "未找到可录制的窗口（请在下拉中选择窗口或让其它应用窗口在最前）"
            return
        }
        beginAfterDelay { [weak self] in
            self?.beginSingleTarget(.window(windowID: winID), label: "窗口")
        }
    }

    private func beginSingleTarget(_ target: SingleTargetRecorder.Target, label: String) {
        beginSingleTargets([(target, label)])
    }

    /// 启动 N 路单目标录制（每路一个输出文件）；任一路启动失败则停掉已起的全部路。
    private func beginSingleTargets(_ items: [(SingleTargetRecorder.Target, String)]) {
        guard !items.isEmpty else { return }
        let outDir = URL(fileURLWithPath: snapshot.outputDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // GIF/WebM：中间产物强制 mp4（AVFoundation 无法读 mkv；停止后自动转码）
        let fmt = snapshot.recording.outputFormat
        var recSettings = snapshot.recording
        if fmt != .video { recSettings.container = .mp4 }
        let ext = recSettings.container.rawValue

        startOverlayIfNeeded()
        isRecording = true
        elapsed = 0
        activeSingleTarget = true
        selectionStage = .none   // 开始录制 → 控制条从 arm 栏切到录制态
        
        // 计算单目标录制的排除窗口（与全屏录制同逻辑：保留覆盖层入画、排除本软件其它窗口）
        var stExcludedIDs: Set<UInt32> = []
        if !snapshot.recording.overlayIncludedInRecording, let panel = overlayPanel {
            stExcludedIDs = panel.allWindowNumbers
        }
        if snapshot.recording.excludeOwnWindows {
            let overlayIDs = overlayPanel?.allWindowNumbers ?? []
            let ownIDs: Set<UInt32> = Set(
                NSApp.windows
                    .filter { $0.isVisible && $0.windowNumber > 0 }
                    .map { UInt32($0.windowNumber) }
            )
            stExcludedIDs.formUnion(ownIDs.subtracting(overlayIDs))
        }
        
        var recorders: [SingleTargetRecorder] = []
        var params: [SingleTargetRecorder.Params] = []
        for (index, item) in items.enumerated() {
            let fname = RecordingEngine.resolveFilename(
                format: snapshot.recording.filenameFormat,
                display: item.1, index: index + 1)
            let url = outDir.appendingPathComponent("\(fname).\(ext)")
            let rec = SingleTargetRecorder()
            rec.onStatus = { [weak self] s in Task { @MainActor in self?.statusLine = s } }
            recorders.append(rec)
            var p = SingleTargetRecorder.Params(target: item.0, settings: recSettings, outputURL: url)
            p.excludedWindowIDs = stExcludedIDs
            params.append(p)
        }
        stRecorders = recorders
        let labels = items.map(\.1).joined(separator: "、")
        Task {
            var started = 0
            var lastError = ""
            for (rec, p) in zip(recorders, params) {
                do { try await rec.start(p); started += 1 }
                catch { lastError = error.localizedDescription; break }
            }
            await MainActor.run {
                if started == 0 {
                    self.isRecording = false
                    self.activeSingleTarget = false
                    self.stRecorders = []
                    self.stopOverlay()
                    RegionFrameController.dismiss()
                    ControlBar.shared.hide()
                    self.statusLine = "启动失败：\(lastError)"
                    NSSound.beep()
                    return
                }
                if started < recorders.count {
                    self.statusLine = "⚠ 仅启动 \(started)/\(recorders.count) 路（\(lastError)）"
                    self.stRecorders = Array(recorders.prefix(started))
                } else {
                    self.statusLine = "录制中（\(labels)，\(started) 路）"
                }
                self.startElapsedTimer()
                self.startNoContentWatchdog()
                ControlBar.shared.show(model: self)
            }
        }
        startElapsedTimer()
    }

    private func startFullScreenRecording(ids: Set<UInt32>) {
        let chosen = displays.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { statusLine = "未选择有效屏幕"; ControlBar.shared.hide(); return }
        selectionStage = .none   // 开始录制 → 控制条切到录制态
        // 点选的屏集合即本次录制目标：同步勾选集（复选框/遮罩/布局共用）
        setRecordedDisplays(ids)
        let mode = snapshot.recording.outputMode
        if mode != .separateFiles {
            guard let layout, layout.placements.count >= 2 else {
                statusLine = "合并模式需要至少 2 屏"
                ControlBar.shared.hide()
                return
            }
        }

        // 覆盖层（独立开关 + 辅助功能权限，方案 M4）
        startOverlayIfNeeded()

        isRecording = true
        elapsed = 0
        activeSingleTarget = false
        // 覆盖层「不入画」：排除所有屏的覆盖层面板窗口
        var excludedIDs: Set<UInt32> = []
        if !snapshot.recording.overlayIncludedInRecording, let panel = overlayPanel {
            excludedIDs = panel.allWindowNumbers
        }
        // 排除本软件窗口：将当前进程所有可见窗口的 CGWindowID 加入排除集，但保留覆盖层面板（它需要入画）
        if snapshot.recording.excludeOwnWindows {
            let overlayIDs = overlayPanel?.allWindowNumbers ?? []
            let ownIDs: Set<UInt32> = Set(
                NSApp.windows
                    .filter { $0.isVisible && $0.windowNumber > 0 }
                    .map { UInt32($0.windowNumber) }
            )
            excludedIDs.formUnion(ownIDs.subtracting(overlayIDs))
        }
        DKLog.overlay.error("OVDIAG exclude ownWin=\(self.snapshot.recording.excludeOwnWindows, privacy: .public) overlayWinIDs=\(String(describing: self.overlayPanel?.allWindowNumbers ?? []), privacy: .public) finalExcluded=\(String(describing: excludedIDs), privacy: .public)")
        // GIF/WebM：中间产物强制 mp4（AVFoundation 无法读 mkv；停止后自动转码）
        var snap = snapshot
        if snap.recording.outputFormat != .video { snap.recording.container = .mp4 }
        let params = RecordingEngine.Params(displays: chosen, settings: snap,
                                            layout: layout,
                                            excludedWindowIDs: excludedIDs)
        // 引擎侧状态（磁盘偏慢/编码器异常等）同步到状态行，不再静默
        engine.onStatus = { [weak self] s in Task { @MainActor in self?.statusLine = s } }
        Task {
            do {
                try await engine.start(params)
                await MainActor.run {
                    self.statusLine = "录制中…（\(chosen.count) 屏 / \(mode.rawValue)）"
                    self.startElapsedTimer()
                    self.startNoContentWatchdog()
                    ControlBar.shared.show(model: self)
                }
            } catch {
                await MainActor.run {
                    self.isRecording = false
                    self.stopOverlay()
                    ControlBar.shared.hide()
                    self.statusLine = "启动失败：\(error.localizedDescription)"
                    NSSound.beep()
                }
            }
        }
        startElapsedTimer()
    }

    private static func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 无画面看门狗：启动后 3.5s 仍零帧→多为屏幕录制权限对当前（ad-hoc 重编）构建失效，给出可操作提示。
    private func startNoContentWatchdog() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard self.isRecording else { return }
            let n = self.activeSingleTarget
                ? self.stRecorders.reduce(0) { $0 + $1.liveFramesIn() }
                : await self.engine.liveFramesIn()
            if n == 0 {
                self.statusLine = "⚠ 3.5 秒内未捕获到画面：多为屏幕录制权限对当前构建失效（ad-hoc 重编译 cdhash 变化）。请到「权限」页按提示 tccutil 重置后重新授权并重启应用。"
            }
        }
    }

    private func engineElapsed() -> Double {
        activeSingleTarget ? (stRecorders.first?.startedSeconds() ?? 0) : engine.elapsedSeconds()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = self.engineElapsed()
                if !self.isRecording { t.invalidate() }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        ControlBar.shared.hide()
        stopOverlay()
        RegionFrameController.dismiss()   // 范围录制停止 → 收起选区外压暗遮罩

        // 单目标（窗口/多路范围）路径
        if activeSingleTarget {
            activeSingleTarget = false
            let recs = stRecorders
            stRecorders = []
            let expected = engineElapsed()
            Task { @MainActor in
                var sums: [SingleTargetRecorder.Summary] = []
                for rec in recs { await sums.append(rec.stop()) }
                let outputs = sums.map(\.output)
                let framesIn = sums.reduce(0) { $0 + $1.framesIn }
                let dropped = sums.reduce(0) { $0 + $1.framesDropped }
                let idle = sums.reduce(0) { $0 + $1.framesIdle }
                let synth = sums.reduce(0) { $0 + $1.synthetic }
                for s in sums { DKLog.export.info("产物：\(s.output.path, privacy: .public)") }
                guard framesIn > 0 else {
                    self.notify("⚠ 未捕获到任何画面（无产物）：请确认屏幕录制权限已授予当前构建")
                    self.finalizeOutputs(outputs)
                    return
                }
                // 自检：真实帧/空壳投递/续帧/编码失败全部上报告，黑屏类问题一次看足
                var line = String(format: "完成 %d 路：真帧 %d、空壳投递 %d、续帧 %d、丢帧 %d",
                                  sums.count, framesIn, idle, synth, dropped)
                let fails = sums.map(\.encodeFailures).filter { !$0.isEmpty }
                if !fails.isEmpty { line += "；编码失败 " + fails.joined(separator: " / ") }
                if synth == 0 && expected > 3 {
                    line += "；⚠ 续帧为 0（静屏时时间轴不会再增长）"
                }
                let warns = await VideoSanity.warnings(for: outputs, expectedSeconds: expected)
                if !warns.isEmpty { line = "⚠ " + warns.joined(separator: "；") + "\n" + line }
                self.notify(line)
                self.finalizeOutputs(outputs)
            }
            return
        }

        // 多屏引擎路径
        let e = engine
        let expected = engineElapsed()
        Task { @MainActor in
            let summary = await e.stop()
            let dropped = summary.stats.values.reduce(0.0) { $0 + $1.dropRate }
            let avg = summary.stats.isEmpty ? 0 : dropped / Double(summary.stats.count)
            let synth = summary.synthetic.values.reduce(0, +)
            let real = summary.stats.values.reduce(0) { $0 + $1.framesIn }
            let idle = summary.stats.values.reduce(0) { $0 + $1.framesIdle }
            let completionLine = String(format: "完成 %d 个文件：真帧 %d、空壳投递 %d、续帧 %d、平均掉帧率 %.2f%%",
                                     summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
                                     real, idle, synth, avg * 100)
            for url in summary.outputs {
                DKLog.export.info("产物：\(url.path, privacy: .public)")
            }
            var warns = summary.pipelineErrors.map { "封装失败：\($0)" }
            warns += await VideoSanity.warnings(for: summary.outputs, expectedSeconds: expected)
            var finalLine = warns.isEmpty ? completionLine : "⚠ " + warns.joined(separator: "；") + "\n" + completionLine
            if !summary.diagnostics.isEmpty {
                finalLine += "\n" + summary.diagnostics.joined(separator: "；")
            }
            self.notify(finalLine)
            self.finalizeOutputs(summary.outputs)
        }
    }

    // MARK: - 停录后自动转码（录制时选 GIF/WebM 即转，不再提供导出页）

    /// 按录制时所选产出格式收尾：视频直出；GIF/WebM 把首个中间 mp4 转码到同目录并删除中间产物。
    private func finalizeOutputs(_ urls: [URL]) {
        let fmt = snapshot.recording.outputFormat
        guard fmt != .video, let src = urls.first else {
            lastOutputs = urls
            return
        }
        // 多路产物不能只转第一路（会错删中间件、剩下还是 mp4）：多路直接保留视频
        if urls.count > 1 {
            lastOutputs = urls
            statusLine = "多路录制（\(urls.count) 个文件）不支持 GIF/WebM 转码，已保留视频产物"
            return
        }
        let out = src.deletingPathExtension().appendingPathExtension(fmt == .gif ? "gif" : "webm")
        lastOutputs = [out] + urls.dropFirst()
        let fps = Int(gifFps), edge = Int(gifMaxEdge)
        statusLine = fmt == .gif ? "正在转码 GIF…" : "正在转码 WebM…"
        Task.detached(priority: .userInitiated) {
            do {
                switch fmt {
                case .gif:
                    let bytes = try await GIFExporter.export(input: src, to: out, fps: fps, maxLongEdge: edge)
                    await MainActor.run { self.notify(String(format: "GIF 完成（%.1f MB，已删除中间 mp4）", Double(bytes) / 1_048_576)) }
                case .webm:
                    try await WebMExporter.export(input: src, to: out, codec: .vp8)
                    await MainActor.run { self.notify("WebM 完成（已删除中间 mp4）") }
                case .video:
                    break
                }
                try? FileManager.default.removeItem(at: src)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            } catch {
                // 转码失败保留中间 mp4，不丢录制内容
                await MainActor.run { self.notify("\(fmt.displayName) 转码失败：\(error.localizedDescription)（已保留视频产物）") }
            }
        }
    }

    // MARK: - 覆盖层

    private func startOverlayIfNeeded() {
        guard snapshot.recording.overlayClickEffects || snapshot.recording.overlayShortcutDisplay else { return }
        let ctrl = OverlayController()
        let panel = OverlayPanel()
        panel.posX = CGFloat(snapshot.recording.overlayKeyPositionX)
        panel.posY = CGFloat(snapshot.recording.overlayKeyPositionY)
        panel.showAll()
        let keyMode = snapshot.recording.overlayKeyMode
        ctrl.onClick = { [weak panel] ev in
            // tap 回调已在 main runloop，直接同步调用涟漪绘制，避免 Task 异步跳转导致事件堆积/丢失
            MainActor.assumeIsolated {
                panel?.ripple(at: ev.point, isRight: ev.isRight)
            }
        }
        ctrl.onKey = { [weak panel, weak self] ev in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.snapshot.recording.overlayShortcutDisplay else { return }
                // 仅快捷键模式：过滤无修饰键的普通字符
                if keyMode == .shortcutsOnly {
                    let hasModifier = ev.combo.contains(where: { "\u{2318}\u{2303}\u{2325}\u{21E7}".contains($0) })
                    guard hasModifier else { return }
                }
                panel?.banner(ev.combo)
            }
        }
        do {
            try ctrl.start()
            overlayController = ctrl
            overlayPanel = panel
            DKLog.overlay.error("OVDIAG started tapActive=\(ctrl.isActive, privacy: .public) panels=\(panel.panelCount, privacy: .public) winIDs=\(String(describing: panel.allWindowNumbers), privacy: .public) clickFX=\(self.snapshot.recording.overlayClickEffects, privacy: .public) shortcut=\(self.snapshot.recording.overlayShortcutDisplay, privacy: .public) keyMode=\(String(describing: keyMode), privacy: .public) includedInRec=\(self.snapshot.recording.overlayIncludedInRecording, privacy: .public)")
        } catch {
            DKLog.overlay.error("OVDIAG start FAILED: \(error.localizedDescription, privacy: .public)")
            notify("覆盖层启动失败（需辅助功能权限）：\(error.localizedDescription)")
        }
    }

    private func stopOverlay() {
        overlayController?.disable()
        overlayPanel?.hide()
        overlayController = nil
        overlayPanel = nil
    }

    // MARK: - 截图 / OCR

    /// 截图前确保「屏幕录制」权限。重编译/重装会重置该 TCC 授权，
    /// 未授予时 SCShareableContent 会直接抛错导致“点了没反应/截不到图”。
    /// 这里主动弹系统请求，仍被拒则打开隐私面板并给出明确提示，返回 false 让调用方中止。
    @discardableResult
    private func ensureScreenRecordingForShot() -> Bool {
        if ScreenPermissions.hasScreenRecording() { return true }
        if ScreenPermissions.requestScreenRecording() { return true }
        ScreenPermissions.openPrivacyPane(.screenRecording)
        statusLine = "缺少「屏幕录制」权限，无法截图：请在系统设置勾选 Disynk 后重试"
        return false
    }

    func screenshotAndOCR(displayID: UInt32?) {
        ScreenshotPanelController.shared.hide()   // 采集方式已选定 → 收起面板免遮挡
        guard ensureScreenRecordingForShot() else { return }
        Task {
            do {
                let id = displayID ?? displays.first?.id
                guard let id else { throw DKError.noDisplaysAvailable }
                let img = try await Screenshotter.captureDisplay(displayID: id)
                saveShot(img, prefix: "Disynk-全屏")
                if snapshot.ocrEnabled { await runOCR(on: img) }
                presentOCRResultIfNeeded()
            } catch {
                statusLine = "截图/OCR 失败：\(error.localizedDescription)"
            }
        }
    }

    /// 窗口截图 + OCR（方案第三节：捕获最前层非本应用窗口）
    func screenshotWindowAndOCR() {
        ScreenshotPanelController.shared.hide()   // 先收起面板，再解析“最前其它窗口”
        guard ensureScreenRecordingForShot() else { return }
        guard let winID = FrontWindowResolver.frontmostOtherWindowID() else {
            statusLine = "未找到可截取的其它窗口"
            return
        }
        Task {
            do {
                let img = try await Screenshotter.captureWindow(windowID: winID)
                saveShot(img, prefix: "Disynk-窗口")
                if snapshot.ocrEnabled { await runOCR(on: img) }
                presentOCRResultIfNeeded()
            } catch {
                statusLine = "窗口截图/OCR 失败：\(error.localizedDescription)"
            }
        }
    }

    /// 区域截图 + OCR（跨屏框选：选区落在哪块屏就截那块屏）
    func screenshotRegionAndOCR() {
        guard !regionCapturing else { return }
        ScreenshotPanelController.shared.hide()   // 框选需看清桌面 → 先收起截图面板
        guard ensureScreenRecordingForShot() else { return }
        regionCapturing = true
        statusLine = "拖动鼠标选择区域（可切到副屏），Esc 取消…"
        RegionPickerController.present { [weak self] sel in
            Task { @MainActor in
                guard let self else { return }
                self.regionCapturing = false
                guard let sel, sel.rect.width >= 2, sel.rect.height >= 2 else {
                    self.statusLine = "已取消区域截图"
                    return
                }
                do {
                    // 选区外瞬时压暗边框（不入画）：与范围录制一致的视觉反馈
                    RegionFrameController.present(regions: [sel])
                    let img = try await Screenshotter.captureRegion(sel.rect, onDisplay: sel.displayID)
                    self.saveShot(img, prefix: "Disynk-区域")
                    if self.snapshot.ocrEnabled { await self.runOCR(on: img) }
                    self.presentOCRResultIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        RegionFrameController.dismiss()
                    }
                } catch {
                    RegionFrameController.dismiss()
                    self.statusLine = "区域截图/OCR 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 窗口录制背景（透明 / 自定义壁纸）

    /// 选一张图片作为窗口录制背景：拷贝进 App 支持目录后持久化为 customImage。
    func chooseWindowWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Disynk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("wallpaper-" + src.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            notify("壁纸拷贝失败：\(error.localizedDescription)")
            return
        }
        mutateSettings { $0.recording.windowBackground = .customImage(dest.path) }
        notify("已设置窗口录制壁纸")
    }

    // MARK: - 滚动长截图（选窗口=自动滚动；框选区域=手动滚动 + 停止栏）

    enum ScrollMode { case windowAuto, regionManual }

    @Published var scrollCapturing = false
    @Published var scrollStatus = ""
    /// HUD 上的会话模式标签（自动/手动）。
    var scrollModeLabel: String { scrollMode == .windowAuto ? "自动滚动" : "手动滚动" }
    private var scrollMode: ScrollMode = .regionManual
    private var scrollFrames: [CGImage] = []
    private var scrollDisplayID: UInt32?
    private var scrollRect: CGRect?
    private var scrollWindowID: CGWindowID?
    private var scrollTimer: Timer?
    private var scrollTask: Task<Void, Never>?
    /// 本次滚动会话是否成功按 `AXWebArea` 视口裁剪（浏览器 UI 已在外层裁掉）。
    /// true 时拼接阶段跳过「顶部标题栏自动裁」，避免把网页正文顶部误当固定栏裁掉。
    private var scrollViewportActive = false
    /// 会话中解析出的网页视口在整窗截图（像素）中的裁剪矩形；采集时统一存整窗原图，
    /// 拼接前用此矩形对所有帧统一裁剪（避免视口中途才解析成功导致帧宽不一致）。
    private var scrollViewportCrop: CGRect?

    /// 入口：弹出滚动截图面板（选窗口自动 / 框选区域手动）。
    func beginScrollCapture() {
        guard !regionCapturing, !scrollCapturing else { return }
        ScreenshotPanelController.shared.hide()   // 滚动面板接管 → 收起截图面板免遮挡
        guard ensureScreenRecordingForShot() else { return }
        refreshRecordableWindows()
        ScrollCaptureController.shared.show(model: self)
    }

    /// 选窗口 → 自动滚动截图：逐帧截该窗口内容，先向指针位置发滚轮、失效后改发 Page Down，
    /// 连续两帧无变化即判定到底，自动裁掉固定 UI 后拼接保存。
    /// 滚轮/键盘事件都依赖「辅助功能」权限（未授权时 CGEvent 静默失效 → 画面不滚动 → 拼出重复图）。
    /// - Parameter picked: 点选窗口时用户实际点击的全局坐标（左上原点）。给了它就滚那里，
    ///   不再用窗口几何中心（中心常落在标题栏/侧栏等不可滚区，是“给了权限也不滚”的主因之一）。
    ///   会话期间不再 warp 指针（否则鼠标老是被重置、点不到停止）。
    func startScrollWindow(_ windowID: CGWindowID, at picked: CGPoint? = nil) {
        guard !scrollCapturing else { return }
        guard ScreenPermissions.hasAccessibility() else {
            ScreenPermissions.promptAccessibility()
            statusLine = "自动滚动截图需「辅助功能」权限（用于发送滚轮事件），已打开授权面板，请勾选后重试"
            return
        }
        guard let center = picked ?? Self.windowCenter(windowID) else {
            statusLine = "无法定位窗口位置（可能已关闭）"
            return
        }
        // 滚轮事件永远落在指针位置的「最前窗口」上：若目标窗口不是那里最前的那一个，
        // 滚动会被别的窗口吃掉 → 画面看起来“没滚动”或拼进不相关内容。
        // 点选路径无需校验：命中测试拿到的就是该点最前窗（仅普通层窗口才校）。
        if picked == nil, Self.windowLayer(windowID) == 0,
           let front = Self.frontmostWindowID(at: center), front != windowID {
            statusLine = "自动滚动截图：目标窗口在该位置不是最前层（滚轮会发给别的窗口），请先把它点到最前或用「点选窗口」"
            return
        }
        scrollMode = .windowAuto
        scrollWindowID = windowID
        scrollFrames = []
        scrollViewportActive = false
        scrollViewportCrop = nil
        scrollCapturing = true
        scrollStatus = "自动滚动中…"
        // 会话期间只留紧凑 HUD，并避开滚动点：选择面板宽且默认停在顶部正中，
        // 一旦压在滚动点上，滚轮事件会发给浮层自己 → 目标窗口完全不滚。
        ScrollCaptureController.shared.hide()
        // Page Down 作为后备手段时按「焦点窗口」投递 → 先把目标应用置前（不激活我们自己）。
        Self.activateOwnerApp(of: windowID)
        // 预热 Chromium 懒加载的网页无障碍树（不主动激活则首帧取不到 AXWebArea）。
        BrowserViewport.enableAccessibility(for: windowID)
        ScrollHUDController.shared.show(model: self, avoiding: center)
        statusLine = "滚动截图：自动向下滚动窗口并逐帧截取（Return 停止、Esc 取消）…"
        scrollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 采集统一存整窗原图（保证帧宽一致）；只负责逐帧尝试解析网页视口矩形存下来，
            // 拼接前再对所有帧统一裁剪。Chromium 建树异步：前几帧可能取不到，逐帧重试至多 16 次后放弃
            //（开启竖排标签栏后 AX 树明显变深、建得更慢，8 次常在触底前耗尽）。
            var viewportCrop: CGRect?
            var viewportAttempts = 0
            func grabWindow() async throws -> CGImage {
                let img = try await Screenshotter.captureWindow(windowID: windowID)
                if viewportCrop == nil && viewportAttempts < 16 {
                    viewportAttempts += 1
                    viewportCrop = BrowserViewport.cropRectForWindow(windowID,
                                                                     imageWidth: img.width, imageHeight: img.height)
                }
                return img
            }
            do {
                var last = try await grabWindow()
                self.scrollFrames = [last]
                // 主用滚轮（在用户刚点过的位置，一定能滚到那块区域），持续 2 帧无变化
                // 则改用 Page Down（与指针位置无关 → 用户把鼠标移开去点停止也不会中断会话）。
                // 两者都不再重置指针位置。
                var step: AppModel.ScrollStep = .wheel
                var unchanged = 0
                for _ in 0..<40 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    switch step {
                    case .wheel:    await Self.postScrollDown(lines: 12)
                    case .pageDown: await Self.postPageDown()
                    }
                    try? await Task.sleep(nanoseconds: 540_000_000)
                    let f = try await grabWindow()
                    if Self.framesDiffer(last, f) {
                        unchanged = 0
                        self.scrollFrames.append(f)
                        last = f
                        self.scrollStatus = "自动滚动中…已截 \(self.scrollFrames.count) 帧"
                    } else {
                        unchanged += 1
                        if step == .wheel, unchanged >= 2 {
                            step = .pageDown
                            unchanged = 0
                            self.scrollStatus = "滚轮已失效（鼠标已移开），改用 Page Down…"
                        } else if step == .pageDown, unchanged >= 2 {
                            break                        // 两种机制都滚不动 → 到底
                        }
                    }
                }
                // 将本地解析结果写回属性（供 finishScrollCapture 统一裁剪所有帧）。
                self.scrollViewportCrop = viewportCrop
                // 只截到 1 帧 = 窗口完全没滚动（两种滚动机制都没生效）。
                if self.scrollFrames.count < 2 {
                    self.scrollCapturing = false
                    self.scrollTask = nil
                    self.statusLine = "自动滚动截图：窗口未滚动——若已勾选辅助功能仍无效，多为重新编译后签名与 TCC 记录不匹配，"
                        + "请在系统设置里移除 Disynk 后重新添加（或执行 tccutil reset "
                        + "\(ScreenPermissions.tccutilService(for: .accessibility)) com.disynk.app）后重试"
                    ScrollHUDController.shared.hide()
                    if let only = self.scrollFrames.first {
                        let out = self.scrollViewportCrop.flatMap { only.cropping(to: $0) } ?? only
                        self.saveShot(out, prefix: "Disynk-滚动")
                    }
                    self.scrollFrames = []
                    self.scrollViewportCrop = nil
                    self.scrollViewportActive = false
                    return
                }
                self.scrollViewportActive = self.scrollViewportCrop != nil
                self.finishScrollCapture()
            } catch {
                self.scrollCapturing = false
                self.scrollTask = nil
                self.statusLine = "自动滚动截图失败：\(error.localizedDescription)"
                ScrollHUDController.shared.hide()
            }
        }
    }

    /// 点选窗口入口：收起面板 → 全屏遮罩里点一下目标窗口 → 直接开始自动滚动截图。
    /// 比下拉列表更可靠：命中测试拿到的就是该点最前窗，且滚动坐标就是用户点的位置
    /// （可滚区），避开“窗口中心落在标题栏/侧栏 → 滚不动”。
    func pickScrollWindow() {
        guard !scrollCapturing, !regionCapturing else { return }
        guard ScreenPermissions.hasAccessibility() else {
            ScreenPermissions.promptAccessibility()
            statusLine = "自动滚动截图需「辅助功能」权限（用于发送滚轮事件），已打开授权面板，请勾选后重试"
            return
        }
        ScrollCaptureController.shared.hide()
        statusLine = "点选要滚动截图的窗口（Esc 取消）…"
        WindowPickerController.present { [weak self] win in
            Task { @MainActor in
                guard let self else { return }
                guard let win else {
                    self.statusLine = "已取消点选"
                    ScrollCaptureController.shared.show(model: self)
                    return
                }
                self.startScrollWindow(win.windowID, at: win.point)
            }
        }
    }

    /// 框选区域入口：收起面板 → 弹区域框选 → 选定后进入手动滚动会话。
    func pickScrollRegion() {
        guard !regionCapturing, !scrollCapturing else { return }
        ScrollCaptureController.shared.hide()
        regionCapturing = true
        statusLine = "拖动鼠标框选滚动区域（可切到副屏），Esc 取消…"
        RegionPickerController.present { [weak self] sel in
            Task { @MainActor in
                guard let self else { return }
                self.regionCapturing = false
                guard let sel, sel.rect.width >= 2, sel.rect.height >= 2 else {
                    self.statusLine = "已取消滚动截图"
                    return
                }
                self.startScrollRegion(sel)
            }
        }
    }

    /// 框选区域 → 手动滚动截图：定时对同一区域抓帧（去重相邻相同帧），
    /// 用户自行滚动，点「停止并保存」拼接整图。
    func startScrollRegion(_ sel: RegionSelection) {
        guard !scrollCapturing else { return }
        scrollMode = .regionManual
        scrollDisplayID = sel.displayID
        scrollRect = sel.rect
        scrollFrames = []
        scrollCapturing = true
        scrollStatus = "手动滚动中…请匀速向下滚动"
        // 同样避开滚动区域：选区是屏内左上原点坐标 → 叠加该屏全局原点换成全局点
        let b = CGDisplayBounds(sel.displayID)
        ScrollCaptureController.shared.hide()
        ScrollHUDController.shared.show(
            model: self,
            avoiding: CGPoint(x: b.minX + sel.rect.midX, y: b.minY + sel.rect.midY))
        statusLine = "滚动截图：向下滚动页面，完成后点「停止并保存」（Return）"
        Task { @MainActor [weak self] in
            guard let self, let rect = self.scrollRect, let did = self.scrollDisplayID else { return }
            do {
                let f = try await Screenshotter.captureRegion(rect, onDisplay: did)
                self.scrollFrames = [f]
            } catch {
                self.scrollCapturing = false
                self.statusLine = "区域首帧失败：\(error.localizedDescription)"
                ScrollHUDController.shared.hide()
                return
            }
            self.scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                // Timer 在主 runloop 触发 → 闭包体运行于主线程，回主隔离域安全访问 @MainActor 状态。
                MainActor.assumeIsolated {
                    guard let self, self.scrollCapturing,
                          let rect = self.scrollRect, let did = self.scrollDisplayID else { return }
                    Task { @MainActor in
                        guard let img = try? await Screenshotter.captureRegion(rect, onDisplay: did) else { return }
                        if let last = self.scrollFrames.last, !Self.framesDiffer(last, img) { return }
                        self.scrollFrames.append(img)
                        self.scrollStatus = "手动滚动中…已截 \(self.scrollFrames.count) 帧"
                    }
                }
            }
        }
    }

    /// 停止并拼接保存整图（自动/手动共用）。
    func finishScrollCapture() {
        guard scrollCapturing else { return }
        scrollTask?.cancel(); scrollTask = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        scrollCapturing = false
        ScrollCaptureController.shared.hide()
        ScrollHUDController.shared.hide()
        let raw = scrollFrames
        scrollFrames = []
        let wasWindow = scrollWindowID != nil
        let winID = scrollWindowID
        scrollDisplayID = nil; scrollRect = nil; scrollWindowID = nil
        var crop = scrollViewportCrop
        scrollViewportCrop = nil
        // 采集期逐帧重试仍未解析到 → 拼接前用首帧尺寸再补试一次（建树可能刚刚才完成）。
        if crop == nil, let winID, let f0 = raw.first {
            crop = BrowserViewport.cropRectForWindow(winID, imageWidth: f0.width, imageHeight: f0.height)
        }
        let viewportActive = (crop != nil)
        scrollViewportActive = false
        // 视口生效：拼接前对所有帧统一裁掉浏览器 UI（帧宽一致、彻底去掉标签栏/地址栏/侧边栏）。
        let basis: [CGImage] = crop.map { c in raw.map { $0.cropping(to: c) ?? $0 } } ?? raw
        // 去重：丢弃与上一保留帧高度相似（>90%）的帧，避免“未真正滚动却拼了两张一样的图”。
        let frames = Self.dedupeSimilar(basis, keepIfSimilarOrBelow: 0.90)
        if frames.count < basis.count {
            statusLine = "滚动截图：已丢弃 \(basis.count - frames.count) 张未变动的重复帧"
        }
        guard frames.count >= 2 else {
            if let only = frames.first { saveShot(only, prefix: "Disynk-滚动") }
            else { statusLine = "滚动截图：无帧可拼接" }
            return
        }
        statusLine = "滚动截图：拼接 \(frames.count) 帧中…"
        // 视口裁剪已在外层去掉浏览器标题栏/标签栏/侧边栏 → 拼接阶段不再顶部自动裁，免误伤网页正文顶部。
        let includeTitlebar = snapshot.scrollCaptureIncludeTitlebar || viewportActive
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                ScrollStitch.stitchDetailed(frames, options: .init(includeTitlebar: includeTitlebar))
            }.value
            guard let report else {
                statusLine = "滚动拼接失败（未检测到重叠或内存不足）"
                return
            }
            let stitched = report.image
            // 把“裁了多少固定 UI / 是否还有没去掉的重叠”说清楚，方便判断结果为何重复
            var notes: [String] = []
            if viewportActive {
                notes.append("已按网页视口裁剪（去掉浏览器标签栏/地址栏/侧边栏）")
            } else if wasWindow {
                notes.append("未检测到网页视口 AXWebArea（非浏览器属正常；若是浏览器仍带标签栏，则该浏览器可能不支持或需重试）")
            }
            if report.trimmedTop + report.trimmedBottom > 0 {
                notes.append("已裁掉不滚动的标题栏/工具栏 上\(report.trimmedTop) 下\(report.trimmedBottom) 行")
            }
            if report.trimmedLeft + report.trimmedRight > 0 {
                notes.append("已裁掉逐帧全同的左右固定栏 左\(report.trimmedLeft) 右\(report.trimmedRight) 列")
            }
            if report.stepRescuedPairs > 0 {
                notes.append("\(report.stepRescuedPairs) 处重叠漏判已按滚动步长中位数兜底去重")
            }
            if report.zeroOverlapPairs > 0 {
                notes.append("\(report.zeroOverlapPairs) 处未检测到重叠（可能仍有重复内容）")
            }
            if report.shiftRescuedPairs > 0 {
                notes.append("\(report.shiftRescuedPairs) 处发现残留固定栏（已只按内容区对齐、不重复入画）")
            }
            saveShot(stitched, prefix: "Disynk-滚动")
            if !notes.isEmpty { statusLine += "（" + notes.joined(separator: "；") + "）" }
            if snapshot.ocrEnabled { await runOCR(on: stitched) }
            presentOCRResultIfNeeded()
        }
    }

    /// 取消滚动截图会话（丢弃已截帧）。
    func cancelScrollCapture() {
        scrollTask?.cancel(); scrollTask = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        scrollCapturing = false
        scrollFrames = []
        scrollDisplayID = nil; scrollRect = nil; scrollWindowID = nil
        scrollViewportActive = false
        scrollViewportCrop = nil
        ScrollCaptureController.shared.hide()
        ScrollHUDController.shared.hide()
        statusLine = "已取消滚动截图"
    }

    // MARK: 滚动截图辅助（窗口中心 / 滚轮事件 / 帧差异）

    /// 窗口全局中心点（CGEvent 用的全局左上原点、单位点坐标）。
    private static func windowCenter(_ windowID: CGWindowID) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let b = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        let x = (b["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (b["Y"] as? NSNumber)?.doubleValue ?? 0
        let w = (b["Width"] as? NSNumber)?.doubleValue ?? 0
        let h = (b["Height"] as? NSNumber)?.doubleValue ?? 0
        guard w > 1, h > 1 else { return nil }
        return CGPoint(x: x + w / 2, y: y + h / 2)
    }

    /// 自动滚动的两级机制：滚轮事件（主，指针位置处）/ 键盘 Page Down（备，焦点窗口）。
    enum ScrollStep { case pageDown, wheel }

    /// 把目标窗口所属应用置前。Page Down 等键事件按「焦点窗口」投递，
    /// 不先激活目标应用就会滚到别的窗口上（而我们自己绝不能激活，否则事件发给自己）。
    private static func activateOwnerApp(of windowID: CGWindowID) {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0 else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// 发送一次 Page Down（一屏一步）。与指针位置无关，因此会话期间不会“鼠标老是被重置”。
    private static func postPageDown() async {
        let src = CGEventSource(stateID: .combinedSessionState)
        let pageDown: UInt16 = 0x79
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: pageDown, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: pageDown, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    /// 向「当前指针位置」发送向下滚轮事件。
    /// 不再 CGWarpMouseCursorPosition：会话中反复重置指针，用户就没法把鼠标移到停止栏上。
    /// 滚轮按指针命中的窗口投递，故仅在指针仍停在刚点过的滚动点附近时有效；
    /// 无效时调用方会退回 Page Down（事件源用 .combinedSessionState 继承当前指针状态）。
    private static func postScrollDown(lines: Int) async {
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<2 {
            // wheel1 负值 = 向下滚动（内容上移，露出下方）
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                  wheel1: Int32(-lines), wheel2: 0, wheel3: 0) else { continue }
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 窗口所在层（拿不到返回 -1）；只有普通层（0）才做“是否最前”校验，
    /// 悬浮/面板层目标窗口不参与校验，避免误判成后方普通窗口。
    private static func windowLayer(_ windowID: CGWindowID) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else { return -1 }
        return layer
    }

    /// 该全局点上最前的普通应用窗口 ID（排除本应用自己的面板/停止栏）。
    /// CGWindowList(.optionOnScreenOnly) 按前→后顺序返回，取第一个命中点且在普通层（layer==0）的窗。
    private static func frontmostWindowID(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != getpid() else { continue }
            guard let win = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let w = (b["Width"] as? NSNumber)?.doubleValue,
                  let h = (b["Height"] as? NSNumber)?.doubleValue else { continue }
            if p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h { return win }
        }
        return nil
    }

    /// 粗粒度帧差异：各自缩放到 48×48 灰度后比较采样块（>5% 不同视为有变化）。
    private static func framesDiffer(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        let sa = frameSignature(a), sb = frameSignature(b)
        var diff = 0
        for i in 0..<sa.count where sa[i] != sb[i] { diff += 1 }
        return diff > sa.count / 20
    }

    private static func frameSignature(_ img: CGImage) -> [UInt8] {
        let n = 48
        var buf = [UInt8](repeating: 0, count: n * n)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return buf }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        return buf
    }

    /// 两帧相似度（0…1）：48×48 灰度签名逐采样点相同比例。尺寸不同视为不相似。
    private static func frameSimilarity(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let sa = frameSignature(a), sb = frameSignature(b)
        guard !sa.isEmpty else { return 0 }
        var same = 0
        for i in 0..<sa.count where sa[i] == sb[i] { same += 1 }
        return Double(same) / Double(sa.count)
    }

    /// 丢弃与“上一保留帧”相似度 ≥ threshold 的帧（只保留真正发生了滚动的帧）。
    private static func dedupeSimilar(_ frames: [CGImage], keepIfSimilarOrBelow threshold: Double) -> [CGImage] {
        var out: [CGImage] = []
        for f in frames {
            if let last = out.last, frameSimilarity(last, f) >= threshold { continue }
            out.append(f)
        }
        return out
    }

    /// 按设置的截图格式（PNG/JPG/HEIC/WebP）保存到输出目录，并记入最近产物。
    /// WebP 需 libvpx 装配构建；未装配或编码失败时回退 PNG，不丢图。
    @discardableResult
    private func saveShot(_ img: CGImage, prefix: String) -> URL? {
        let dir = URL(fileURLWithPath: snapshot.outputDirectoryPath)
        var fmt = snapshot.screenshotFormat
        if fmt == .webp, !WebPEncoder.isAvailable {
            notify("当前构建未装配 libvpx，WebP 不可用，已改存 PNG（可选 PNG/JPG/HEIC）")
            fmt = .png
        }
        do {
            let url = try Screenshotter.save(img, format: fmt, to: dir, namePrefix: prefix)
            lastScreenshots = [url] + lastScreenshots
            notify("截图已保存：\(url.lastPathComponent)")
            DKLog.export.info("截图产物（\(fmt.rawValue, privacy: .public)）：\(url.path, privacy: .public)")
            CaptureFlash.fire()   // 采集完成后整屏白闪一下（拍照样式，sharingType=.none 不入画）
            return url
        } catch {
            // 有损格式编码失败（旧系统无 HEIC 编码器等）→ 保底再试一次 PNG，截图绝不丢图
            guard fmt != .png else {
                notify("截图保存失败：\(error.localizedDescription)")
                return nil
            }
            do {
                let url = try Screenshotter.save(img, format: .png, to: dir, namePrefix: prefix)
                lastScreenshots = [url] + lastScreenshots
                notify("\(fmt.displayName) 保存失败（\(error.localizedDescription)），已回退 PNG：\(url.lastPathComponent)")
                CaptureFlash.fire()
                return url
            } catch {
                notify("截图保存失败：\(error.localizedDescription)")
                return nil
            }
        }
    }

    /// 共享的 OCR 结果处理（全屏/窗口/区域/剪贴板均经此）
    private func runOCR(on img: CGImage) async {
        do {
            let result = try await Screenshotter.recognizeText(in: img)
            ocrText = result.text.isEmpty ? "（未识别到文字）" : result.text
            statusLine = String(format: "截图完成，OCR %d 行，平均置信度 %.0f%%",
                                result.lines.count, result.confidenceAvg * 100)
        } catch {
            statusLine = "OCR 失败：\(error.localizedDescription)"
        }
    }

    /// 开 OCR 时，采果完面板应自动把结果呈现出来：选采集方式时面板为免遮挡已自动收起，
    /// 不重新弹回的话用户只能看到状态栏一行字，看不到识别结果。
    private func presentOCRResultIfNeeded() {
        guard snapshot.ocrEnabled, !ocrText.isEmpty else { return }
        ScreenshotPanelController.shared.show(model: self)
    }

    func ocrClipboard() {
        // 剪贴板 OCR 不受「截图后 OCR」开关控制：用户主动点它就是明确要求识别一次。
        Task {
            do {
                let result = try await Screenshotter.recognizeClipboard()
                ocrText = result.text.isEmpty ? "（剪贴板无文字）" : result.text
            } catch {
                statusLine = "剪贴板 OCR 失败：\(error.localizedDescription)"
            }
            ScreenshotPanelController.shared.show(model: self)   // 无论开关如何，直接把结果弹给用户看
        }
    }

    func saveOCRText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "disynk-ocr.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ocrText.write(to: url, atomically: true, encoding: .utf8)
            statusLine = "OCR 文本已导出"
        } catch {
            statusLine = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 导出 Markdown（方案第三节：截图即 OCR “导出 TXT/MD”）
    func saveOCRMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "disynk-ocr.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let md = "# 识别文本\n\n\(ocrText)\n"
            try md.write(to: url, atomically: true, encoding: .utf8)
            statusLine = "OCR 文本已导出为 Markdown"
        } catch {
            statusLine = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 复制 OCR 结果到剪贴板（方案第三节：截图即 OCR “复制文本”）
    func copyOCRText() {
        guard !ocrText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ocrText, forType: .string)
        statusLine = "OCR 文本已复制到剪贴板"
    }

    /// 清空识别结果（面板与设置页共享的 ocrText）。
    func clearOCRText() {
        ocrText = ""
        statusLine = "已清空识别结果"
    }

    // MARK: - 虚拟屏

    func createVirtualDisplay(preset: VirtualDisplayManager.Preset) {
        Task {
            do {
                let s = try virtualManager.create(preset: preset)
                virtualDisplays = virtualManager.list()
                await refreshDisplaysSoon()
                notify(virtualDisplayReport(s))
            } catch {
                notify("虚拟屏创建失败：\(error.localizedDescription)")
            }
        }
    }

    /// 创建结果一句话：直接说清它有没有真的进入可录制列表（不再只给“若列表无此屏”的模糊提示）。
    private func virtualDisplayReport(_ s: VirtualDisplayManager.VirtualScreen) -> String {
        let title = "\(s.name) \(s.width)x\(s.height)\(s.hiDPI ? "（HiDPI）" : "")"
        return displays.contains { $0.id == s.displayID }
            ? "虚拟屏已上线：\(title)（已可在「录制」页勾选）"
            : "虚拟屏已创建：\(title)（系统尚未让它上线，稍等后点「刷新屏幕」）"
    }

    /// 自定义分辨率 + HiDPI 创建虚拟屏（方案第三节）。
    /// sizeText 形如 "2560x1440"；解析失败时仅提示不创建。
    func createVirtualDisplay(sizeText: String, hiDPI: Bool) {
        let parts = sizeText.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
            statusLine = "分辨率格式应为 宽x高，如 2560x1440"
            return
        }
        createVirtualDisplay(width: w, height: h, hiDPI: hiDPI)
    }

    /// 两个数字框直接创建虚拟屏（仅数字，≥ 64）。
    func createVirtualDisplay(width: Int, height: Int, hiDPI: Bool) {
        guard width >= 64, height >= 64 else {
            statusLine = "分辨率宽高需 ≥ 64"
            return
        }
        Task {
            do {
                let s = try virtualManager.create(width: width, height: height, hiDPI: hiDPI)
                virtualDisplays = virtualManager.list()
                await refreshDisplaysSoon()
                notify(virtualDisplayReport(s))
            } catch {
                notify("虚拟屏创建失败：\(error.localizedDescription)")
            }
        }
    }

    func destroyAllVirtualDisplays() {
        Task {
            virtualManager.destroyAll()
            virtualDisplays = []
            await refreshDisplays()
            notify("虚拟屏已全部移除")
        }
    }

    /// 单独移除某块虚拟屏（不影响其余）。
    func destroyVirtualDisplay(displayID: UInt32) {
        Task {
            do {
                try virtualManager.destroy(displayID: displayID)
                virtualDisplays = virtualManager.list()
                await refreshDisplays()
                notify("虚拟屏 #\(displayID) 已移除")
            } catch {
                notify("虚拟屏移除失败：\(error.localizedDescription)")
            }
        }
    }

    /// 方案第三节「向虚拟屏拖放窗口」：把当前前台 App 的焦点窗口居中移到指定虚拟屏。
    /// 依赖辅助功能权限；无权限时抛错并提示，无焦点窗口时返回提示不抛错。
    func moveFocusedWindow(toVirtualDisplay id: UInt32) {
        Task {
            do {
                let moved = try WindowArranger.moveFocusedWindow(toDisplay: CGDirectDisplayID(id))
                notify(moved ? "已将最前窗口移到虚拟屏 #\(id)" : "前台无可移动的焦点窗口")
            } catch {
                notify("移动窗口失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 录制产出转码（旧「导出页」入口已移除；逻辑并入 finalizeOutputs 自动触发）
}
