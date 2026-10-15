import AVFoundation
import CoreMedia
import CoreVideo
import DKAudio
import DKCapture
import DKCompose
import DKEncode
import DKCore
import DKMux
import DKSettings
import Foundation

/// 录制管线整合（方案 M2/M2.5 贯通）：
/// - separateFiles：每屏 独立 HardwareEncoder(NV12 零拷贝) → 独立 Muxer
/// - composedOnly：BGRA 采集 → MetalCompositor 按布局合成 → 单编码器 → 单 Muxer
/// - both：BGRA 采集一路同时喂 每屏编码器(BGRA 输入) 与 合成器
/// 帧路由在单一串行队列（禁止在 SCK 回调做重活，方案第四节）；
/// 每封装目的用 FIFO AsyncStream 管线保证 append 顺序。
/// 合并模式为「定时器驱动合成」：SCK 在画面静止时不再投递新帧，若等齐所有屏的
/// 新帧才合成一帧（旧 ComposeGate 方案），静屏会导致合成永久饥饿 → 成片只有一帧
/// 后黑屏；现按目标帧率用各屏「最新帧」定时合成，PTS 取单调帧序号。
final class RecordingEngine: @unchecked Sendable {
    struct Params: Sendable {
        var displays: [DisplaySnapshot]
        var settings: AppSettingsSnapshot
        var layout: ComposeLayout?           // 合并/both 模式必填
        /// 需从录制画面排除的窗口 ID（覆盖层「不入画」+ 本软件窗口排除，由 AppModel 统一计算）
        var excludedWindowIDs: Set<UInt32> = []
    }

    struct Summary: Sendable {
        var outputs: [URL]
        var stats: [UInt32: CaptureStats]
        /// 各路「缺帧续帧」合成的帧数（画面静止时补的时间轴帧）
        var synthetic: [UInt32: Int]
        /// 目的管线错误描述（非空即代表某路封装失败，必须呈现给用户）
        var pipelineErrors: [String]
        /// 人读诊断行（编码器失败摘要 / 封装丢帧数）：黑屏类问题一次看足，不靠翻日志
        var diagnostics: [String]
    }

    // MARK: 状态（routeQueue 串行访问 / stop 时主流程访问）
    private let routeQueue = DispatchQueue(label: "com.disynk.engine.route", qos: .userInitiated)
    private let stateLock = NSLock()
    private var coordinator: CaptureCoordinator?
    private var mic: MicCapturer?
    private var displayEncoders: [UInt32: HardwareEncoder] = [:]
    private var pipelines: [DestPipeline] = []
    private var compositor: MetalCompositor?
    private var mergedEncoder: HardwareEncoder?
    /// 合并模式各屏最新帧像素缓冲（定时器按目标帧率取用；缺帧屏画布留黑）
    private var frameBuffers: [UInt32: CVPixelBuffer] = [:]
    private var composeTimer: DispatchSourceTimer?
    private var composeFrameIndex = 0
    private var mergedFPS: Double = 30
    /// 独立文件每路的出帧时钟（routeQueue 串行域访问）：缺帧时按帧间隔续帧，保证视频轨连续
    private struct FeedState {
        var clock: FrameClock
        var intervalSeconds: Double
        var lastFrame: CMSampleBuffer?
        /// 时间轴上「最近出帧」的墙钟时刻（真实帧到达即刷新；续帧按其推进一个间隔）
        var lastEmitAt: Date
        var synthetic = 0
    }
    private var feedStates: [UInt32: FeedState] = [:]
    private var pacerTimer: DispatchSourceTimer?
    /// 首帧采集 PTS（宿主时钟）：合成帧以此为基准叠加帧序号，保证与音轨同时间基
    private var startTime: CMTime?
    private var systemAudioOwner: UInt32?
    private(set) var startedAt: Date?

    private enum Route {
        case video(displayID: UInt32, sampleBuffer: CMSampleBuffer)
        case audio(displayID: UInt32, sampleBuffer: CMSampleBuffer)
    }

    /// 缺帧判定系数：距上次出帧超过 1.6 个帧间隔即续一拍（吸收 SCK 抖动，不误伤正常帧流）
    private static let pacerSlack = 1.6

    var onStatus: (@Sendable (String) -> Void)?

    // MARK: - 启动

    func start(_ params: Params) async throws {
        let mode = params.settings.recording.outputMode
        let needsSeparate = mode == .separateFiles || mode == .both
        let needsMerge = mode == .composedOnly || mode == .both

        }

        var layout: ComposeLayout?
        if needsMerge {
            guard let l = params.layout, l.placements.count >= 2 else {
                throw DKError.other("合并模式需要至少 2 屏的布局")
            }
            // 先裁到内容包围盒（用户在布局里怎么摆就怎么合，不留舞台黑边），再做 8K 宽兜底钳制。
            layout = l.croppedToContent().clamped()
        }

        let outDir = URL(fileURLWithPath: params.settings.outputDirectoryPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // 采集格式：需要进合成器就必须 BGRA；纯独立文件走 NV12 零拷贝
        let captureFormat: OSType = needsMerge ?
            kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // 全容器均支持音轨：MP4/MOV 由 AVAssetWriter 转 AAC；MKV 由内置 AACStreamEncoder 编码
        // （系统声/麦克风均为 48kHz 立体声 Float32，见 DKCapture/DisplayCapture 与 DKAudio/MicCapturer）
        let wantAudio = true
        let sysAudio = wantAudio && params.settings.recording.captureSystemAudio
        let micAudio = wantAudio && params.settings.recording.captureMicrophone
        var trackKinds: [AudioTrackKind] = []
        if sysAudio { trackKinds.append(.system) }
        if micAudio { trackKinds.append(.microphone) }

        var pipelines: [DestPipeline] = []
        var encoders: [UInt32: HardwareEncoder] = [:]
        feedStates.removeAll()   // 上一路残留（防新录制误用旧屏的时钟/画面）
        var comp: MetalCompositor?
        var mEncoder: HardwareEncoder?
        var aggregateBps = 0   // 各输出文件码率合计（磁盘写入速度探测用，方案第四节）

        // -- 独立多路 --
        if needsSeparate {
            for snap in params.displays {
                let s = params.settings.effective(for: snap.id)
                let out = s.resolution.resolve(source: snap.sourceSize)
                let fps = DisplayCapture.clampedFPS(requested: s.frameRate.fps, refreshHz: snap.refreshRateHz)
                let bitrate = Int(s.quality.bitrateBps(size: out, fps: fps, codec: s.codec))
                aggregateBps += bitrate
                let fname = Self.resolveFilename(format: s.filenameFormat, display: snap.name, index: pipelines.count + 1)
                let url = outDir.appendingPathComponent("\(fname).\(s.container.rawValue)")
                let muxer = try MuxerFactory.make(
                    container: s.container,
                    video: .init(codec: s.codec, pixelSize: out, displaySize: out, fps: fps),
                    audioTracks: trackKinds, outputURL: url)
                let dest = DestPipeline(muxer: muxer, displayID: snap.id)
                pipelines.append(dest)
                // 压缩帧直接入「本路目的管线」（旧实现在回调里按 id 查 self.pipelines，
                // 而 pipelines 要等 start 尾部才赋值 → 早期压缩帧可能被静默丢弃）
                let enc = try HardwareEncoder(
                    config: .init(codec: s.codec, size: out, frameRate: FrameRate(fps: fps),
                                  bitrateBps: bitrate,
                                  keyframeIntervalSeconds: s.keyframeIntervalSeconds,
                                  // 录屏一律不开 B 帧：屏幕内容是逐帧实时源，B 帧无收益，
                                  // 却会让输出样本按解码序到达（PTS 在 append 序上不单调，
                                  // 实测首帧 DTS 偏到 -1.0s），与自驱帧时钟叠加后时间轴极易错乱。
                                  allowFrameReordering: false,
                                  inputFormat: needsMerge ? kCVPixelFormatType_32BGRA : nil),
                    outputHandler: { [weak self] sb, _ in
                        let box = SendableBox(sb)
                        self?.routeQueue.async { dest.enqueueVideo(box.value) }
                        self?.noteEncoded(snap.id)
                    })
                enc.onError = { [weak self] msg in self?.emitStatus("⚠ 屏\(snap.id) 编码器异常：\(msg)") }
                encoders[snap.id] = enc
                feedStates[snap.id] = FeedState(clock: FrameClock(fps: fps),
                                                 intervalSeconds: 1.0 / max(fps, 1),
                                                 lastFrame: nil,
                                                 lastEmitAt: Date())
            }
        }

        // -- 合并单路 --
        if needsMerge, let layout {
            let s = params.settings.recording
            let canvas = layout.canvas
            let fps = s.frameRate.fps
            mergedFPS = fps
            let bitrate = Int(s.quality.bitrateBps(size: canvas, fps: fps, codec: s.codec))
            aggregateBps += bitrate
            let mergeName = Self.resolveFilename(format: params.settings.recording.filenameFormat, display: "合并", index: 1)
            let url = outDir.appendingPathComponent("\(mergeName).\(s.container.rawValue)")
            let muxer = try MuxerFactory.make(
                container: s.container,
                video: .init(codec: s.codec, pixelSize: canvas, displaySize: canvas, fps: fps),
                audioTracks: trackKinds, outputURL: url)
            let dest = DestPipeline(muxer: muxer, displayID: nil)
            pipelines.append(dest)
            let enc = try HardwareEncoder(
                config: .init(codec: s.codec, size: canvas, frameRate: FrameRate(fps: fps),
                              bitrateBps: bitrate,
                              keyframeIntervalSeconds: s.keyframeIntervalSeconds,
                              allowFrameReordering: false,   // 同上：录屏不开 B 帧
                              inputFormat: kCVPixelFormatType_32BGRA),
                outputHandler: { [weak self] sb, _ in
                    let box = SendableBox(sb)
                    self?.routeQueue.async { dest.enqueueVideo(box.value) }
                })
            enc.onError = { [weak self] msg in self?.emitStatus("⚠ 合并编码器异常：\(msg)") }
            mEncoder = enc
            comp = MetalCompositor(layout: layout)
        }

        for p in pipelines { p.start() }

        // -- 磁盘写入速度探测（方案第四节：高码率多路写机械盘必掉帧 → 启动前实测并告警，非致命）--
        if aggregateBps > 0 {
            let probeDir = outDir
            let bps = aggregateBps
            let measured = await Task.detached(priority: .utility) {
                DiskProbe.measureWriteSpeedMBs(in: probeDir, totalBytes: 32 * 1024 * 1024)
            }.value
            if let m = measured, let warn = DiskProbe.warningIfNeeded(aggregateBitrateBps: bps, measuredMBs: m) {
                DKLog.capture.error("磁盘探测：实测 \(m, privacy: .public)MB/s 低于需求")
                onStatus?("⚠ " + (warn.errorDescription ?? "磁盘写入偏慢"))
            } else if let m = measured {
                DKLog.capture.info("磁盘探测通过：实测 \(m, privacy: .public)MB/s")
            }
        }

        // -- 捕获 --
        let coord = CaptureCoordinator()
        systemAudioOwner = params.displays.first?.id
        if needsMerge { frameBuffers.removeAll(); composeFrameIndex = 0; startTime = nil }
        self.coordinator = coord
        self.displayEncoders = encoders
        self.pipelines = pipelines
        self.compositor = comp
        self.mergedEncoder = mEncoder

        // -- 缺帧续帧定时器（独立文件模式）：必须在采集启动/磁盘探测/麦克风之前拉起 --
        // 旧实现放在 start() 最后一行：前面任何一步抛异常（如麦克风启动失败）就静默不启动，
        // 表现为「成片只剩开头几秒、后面黑屏」；定时器本身对空状态安全（无 lastFrame 即跳过）。
        if needsSeparate { startPacer() }

        let onVideo: @Sendable (UInt32, CMSampleBuffer) -> Void = { [weak self] id, sb in
            let box = SendableBox(sb)
            self?.routeQueue.async { self?.route(.video(displayID: id, sampleBuffer: box.value)) }
        }
        var onAudio: (@Sendable (UInt32, CMSampleBuffer) -> Void)?
        if sysAudio {
            onAudio = { [weak self] id, sb in
                let box = SendableBox(sb)
                self?.routeQueue.async { self?.route(.audio(displayID: id, sampleBuffer: box.value)) }
            }
        }
        try await coord.start(
            displays: params.displays,
            settingsFor: { [settings = params.settings] id in settings.effective(for: id) },
            systemAudio: sysAudio,
            videoPixelFormat: captureFormat,
            excludedWindowIDs: params.excludedWindowIDs,
            onVideoFrame: onVideo,
            onAudioFrame: onAudio
        )

        // -- 麦克风（失败不毁掉整场录制：视频与系统声照常，仅提示）--
        if micAudio {
            let m = MicCapturer { [weak self] sb in
                let box = SendableBox(sb)
                self?.routeQueue.async { [weak self] in
                    guard let self else { return }
                    for p in self.pipelines { p.enqueueAudio(box.value, track: .microphone) }
                }
            }
            do {
                try m.start()
                mic = m
            } catch {
                DKLog.audio.error("麦克风启动失败（继续仅录系统声）: \(error.localizedDescription, privacy: .public)")
                onStatus?("⚠ 麦克风启动失败：\(error.localizedDescription)（已继续录制）")
            }
        }

        // -- 合成定时器（合并模式）：在 routeQueue 串行域内按目标帧率取各屏最新帧 --
        if needsMerge { startComposeTimer(on: routeQueue, fps: mergedFPS) }

        startedAt = Date()
        onStatus?("录制中：\(params.displays.count) 屏，模式 \(mode.rawValue)")
    }

    // MARK: - 帧路由（routeQueue 串行）

    private func route(_ event: Route) {
        switch event {
        case .video(let displayID, let sb):
            if let enc = displayEncoders[displayID] {
                // 走本路 FrameClock：静屏缺帧时由 pacer 按同一时钟续帧（PTS 单调）
                if var st = feedStates[displayID] {
                    let pts = st.clock.next(source: CMSampleBufferGetPresentationTimeStamp(sb))
                    enc.encode(sb, ptsOverride: pts)
                    // 只把「真带画面」的样本存为续帧源：空壳样本入库会让 pacer 补帧全被拒（上次黑屏的真凶）
                    if CMSampleBufferGetImageBuffer(sb) != nil {
                        st.lastFrame = sb
                        st.lastEmitAt = Date()
                    }
                    feedStates[displayID] = st
                } else {
                    enc.encode(sb)
                }
            }
            guard mergedEncoder != nil,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            // 只存最新帧；合成由定时器驱动（避免静屏时新帧饥饿 → 成片只有一帧）
            if startTime == nil { startTime = CMSampleBufferGetPresentationTimeStamp(sb) }
            frameBuffers[displayID] = pb

        case .audio(let displayID, let sb):
            // 系统声全局同源：独立文件各轨都写；合并文件只取首屏，避免重复叠加
            guard displayID == systemAudioOwner else { return }
            for p in pipelines { p.enqueueAudio(sb, track: .system) }
        }
    }

    // MARK: - 缺帧续帧定时器（routeQueue 串行域）

    /// 独立文件路径的保活节拍：派发到 routeQueue 串行域后创建定时器
    /// （帧回调已在同一串行域改 feedStates，故定时器创建也必须排入该域，避免并发读写）
    private func startPacer() {
        routeQueue.async { [weak self] in
            guard let self, self.pacerTimer == nil else { return }
            guard let tick = self.feedStates.values.map(\.intervalSeconds).min() else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.routeQueue)
            timer.schedule(deadline: .now() + tick, repeating: max(tick, 0.005))
            timer.setEventHandler { [weak self] in self?.pacerTick() }
            self.pacerTimer = timer
            timer.resume()
        }
    }

    /// 续一拍：用最近一帧画面重新编码（新 PTS）。
    /// 意义：屏幕静止 / SCK 不投递新帧时，视频轨仍按目标帧率增长 → 不会再出现
    /// 「只有第一帧图片、后面黑屏」（旧实现视频轨停在 1 帧，播放器放完即黑）。
    private func pacerTick() {
        let now = Date()
        for (id, var st) in feedStates {
            guard let last = st.lastFrame, CMSampleBufferGetImageBuffer(last) != nil,
                  let enc = displayEncoders[id] else { continue }
            let behind = now.timeIntervalSince(st.lastEmitAt)
            guard behind > st.intervalSeconds * Self.pacerSlack else { continue }
            let pts = st.clock.next(source: nil)
            if enc.encode(last, ptsOverride: pts) { st.synthetic += 1 }
            st.lastEmitAt = st.lastEmitAt.addingTimeInterval(st.intervalSeconds)
            feedStates[id] = st
        }
    }

    private func emitStatus(_ text: String) {
        routeQueue.async { [weak self] in self?.onStatus?(text) }
    }

    // MARK: - 合并合成定时器（routeQueue 串行域）

    private func startComposeTimer(on queue: DispatchQueue, fps: Double) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1.0 / fps, 0.001)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.composeTick() }
        composeTimer = timer
        timer.resume()
    }

    /// 定时合成一帧：用各屏最新帧（尚无帧的屏留黑）；PTS = 起始 + 帧序号/fps，单调不重复。
    private func composeTick() {
        guard mergedEncoder != nil, let compositor, !frameBuffers.isEmpty else { return }
        let pts = composePTS(index: composeFrameIndex)
        composeFrameIndex += 1
        guard let outPB = compositor.compose(frameBuffers),
              let merged = mergedSampleBuffer(from: outPB, pts: pts) else { return }
        mergedEncoder?.encode(merged)
    }

    private func composePTS(index: Int) -> CMTime {
        let ts: CMTimeScale = 600
        let ticks = (Double(index) * Double(ts) / max(mergedFPS, 1)).rounded()
        // 基准 = 首帧宿主 PTS，与同一管线内的音频样本同时间基（both 模式共用 muxer）
        return CMTimeAdd(startTime ?? .zero, CMTime(value: CMTimeValue(ticks), timescale: ts))
    }

    private func noteEncoded(_ displayID: UInt32) {
        Task { await coordinator?.noteEncoded(displayID: displayID) }
    }

    /// 合成器输出 PB 包成 CMSampleBuffer 供 VideoToolbox 编码
    private func mergedSampleBuffer(from pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb,
            formatDescriptionOut: &fd) == noErr, let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    // MARK: - 停止

    func stop() async -> Summary {
        let coord = coordinator
        await coord?.stop()

        // 先停两个定时器（与 routeQueue 串行域同步），再 flush 编码器
        // （同步产出剩余帧 → routeQueue 闭包已入队）
        routeQueue.sync {
            composeTimer?.cancel()
            composeTimer = nil
            pacerTimer?.cancel()
            pacerTimer = nil
            for (_, enc) in displayEncoders { enc.flush() }
            mergedEncoder?.flush()
        }
        // 编码器失败摘要（在 invalidate 前取，保留完整计数）
        var diagnostics: [String] = []
        for (id, enc) in displayEncoders.sorted(by: { $0.key < $1.key }) {
            let f = enc.failureSummary()
            if !f.isEmpty { diagnostics.append("屏\(id) 编码失败：\(f)") }
        }
        displayEncoders.values.forEach { $0.invalidate() }
        mergedEncoder?.invalidate()
        mic?.stop()

        var outputs: [URL] = []
        var pipelineErrors: [String] = []
        for p in pipelines {
            outputs.append(p.muxer.outputURL)
            await p.finish()
            if let e = p.error { pipelineErrors.append("\(p.muxer.outputURL.lastPathComponent)：\(e.localizedDescription)") }
            let drops = p.muxer.videoDroppedFrameCount
            let fails = p.videoAppendFailureCount
            if drops > 0 || fails > 0 {
                diagnostics.append("\(p.muxer.outputURL.lastPathComponent)：背压丢帧 \(drops)、append 失败 \(fails)")
            }
        }
        let merged = mergedEncoder?.failureSummary() ?? ""
        if !merged.isEmpty { diagnostics.append("合并编码失败：\(merged)") }

        var stats: [UInt32: CaptureStats] = [:]
        if let coord { stats = await coord.allStats() }
        let synthetic = takeDownState()
        onStatus?("录制已停止")
        return Summary(outputs: outputs, stats: stats, synthetic: synthetic,
                       pipelineErrors: pipelineErrors, diagnostics: diagnostics)
    }

    /// 停录后重置引擎状态，返回各路续帧计数（同步方法内加锁，避免在 async 上下文直接用 NSLock）
    private func takeDownState() -> [UInt32: Int] {
        stateLock.lock(); defer { stateLock.unlock() }
        let synthetic = feedStates.mapValues { $0.synthetic }
        coordinator = nil
        displayEncoders.removeAll()
        pipelines.removeAll()
        compositor = nil
        mergedEncoder = nil
        frameBuffers.removeAll()
        feedStates.removeAll()
        composeFrameIndex = 0
        mic = nil
        startedAt = nil
        return synthetic
    }

    func elapsedSeconds() -> Double {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// 当前各路已入帧总数（无画面看门狗用：启动后一段时间仍为 0 通常为屏幕录制权限失效）。
    func liveFramesIn() async -> Int {
        let coord = coordinator
        let stats = await coord?.allStats() ?? [:]
        return stats.values.reduce(0) { $0 + $1.framesIn }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// macOS 文件名安全化：替换 APFS 禁止的 / 和 :，去首尾空格，限长 40 字符。
    static func fileSafeName(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespaces)
        return String(s.prefix(40))
    }

    /// 根据用户自定义格式解析文件名。支持变量：{date} {time} {datetime} {display} {index}
    /// 如果格式串不含任何变量（纯常量）或为空，自动追加 -{datetime}-{display}。
    static func resolveFilename(format: String, display: String, index: Int, date: Date = Date()) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date), mo = cal.component(.month, from: date), d = cal.component(.day, from: date)
        let hh = cal.component(.hour, from: date), mm = cal.component(.minute, from: date), ss = cal.component(.second, from: date)
        let dateStr = String(format: "%04d-%02d-%02d", y, mo, d)
        let timeStr = String(format: "%02d%02d%02d", hh, mm, ss)
        let dtStr = "\(dateStr)-\(timeStr)"
        let safeDisplay = fileSafeName(display)

        var tmpl = format.trimmingCharacters(in: .whitespaces)
        // 检查是否含变量
        let hasVar = tmpl.contains("{")
        if tmpl.isEmpty || !hasVar {
            // 纯常量或空：追加默认后缀
            let prefix = tmpl.isEmpty ? "Disynk" : fileSafeName(tmpl)
            tmpl = "\(prefix)-{datetime}-{display}"
        }
        let result = tmpl
            .replacingOccurrences(of: "{datetime}", with: dtStr)
            .replacingOccurrences(of: "{date}", with: dateStr)
            .replacingOccurrences(of: "{time}", with: timeStr)
            .replacingOccurrences(of: "{display}", with: safeDisplay)
            .replacingOccurrences(of: "{index}", with: "\(index)")
        return fileSafeName(result)
    }
}

// MARK: - 封装目的 FIFO 管线

/// 单个输出文件的目的管线：压缩帧/音频帧事件 FIFO → muxer 顺序 append
private final class DestPipeline: @unchecked Sendable {
    let muxer: any RecordingMuxer
    private let displayID: UInt32?

    init(muxer: any RecordingMuxer, displayID: UInt32?) {
        self.muxer = muxer
        self.displayID = displayID
    }

    func isFor(displayID: UInt32) -> Bool { self.displayID == displayID }
    var isMerged: Bool { displayID == nil }

    enum Event: @unchecked Sendable {
        case video(CMSampleBuffer)
        case audio(CMSampleBuffer, AudioTrackKind)
        case finish
    }

    private var cont: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?
    private let errLock = NSLock()
    private var firstError: Error?
    /// append 失败计数（不闩锁：旧实现一失败就永久跳过后续所有帧，时间轴直接冻结在失败点）
    private var appendFailures = 0
    var videoAppendFailureCount: Int {
        errLock.lock(); defer { errLock.unlock() }
        return appendFailures
    }

    func start() {
        let (stream, c) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        cont = c
        task = Task {
            for await ev in stream {
                switch ev {
                case .video(let sb):
                    do { try await self.muxer.appendVideo(sb) }
                    catch { self.noteFailure(error) }
                case .audio(let sb, let kind):
                    do { try await self.muxer.appendAudio(sb, track: kind) }
                    catch { self.noteFailure(error) }
                case .finish:
                    do { try await self.muxer.finish() } catch { self.noteFailure(error) }
                }
            }
        }
    }

    func enqueueVideo(_ sb: CMSampleBuffer) { cont?.yield(.video(sb)) }
    func enqueueAudio(_ sb: CMSampleBuffer, track: AudioTrackKind) { cont?.yield(.audio(sb, track)) }

    func finish() async {
        cont?.yield(.finish)
        cont?.finish()
        await task?.value
        if let error { DKLog.mux.error("目的 \(self.muxer.outputURL.lastPathComponent) 管线错误: \(error.localizedDescription, privacy: .public)") }
    }

    /// 记录首个错误（供报告）但继续下一帧：单帧失败不应杀掉整轨
    private func noteFailure(_ e: Error) {
        errLock.lock(); defer { errLock.unlock() }
        appendFailures += 1
        if firstError == nil { firstError = e }
    }

    var error: Error? {
        errLock.lock(); defer { errLock.unlock() }
        return firstError
    }
}
