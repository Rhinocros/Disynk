import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import DKCapture
import DKCore
import DKEncode
import DKMux
import DKSettings
import Foundation
import ScreenCaptureKit

/// 单目标录制（方案第三节：窗口录制 / 范围录制的补充路径）。
/// 与多屏 RecordingEngine 解耦：一路 SCStream（某窗口，或某屏的选区）→ 单 HardwareEncoder → 单 Muxer。
/// 遵守「SCK 回调线程不做重活」：压缩帧经串行 FIFO 管线保序后再 append（对齐 RecordingEngine）。
/// 线程模型同 DisplayCapture：非 @MainActor，start/stop 由上层在 MainActor 的 Task 内 await。
final class SingleTargetRecorder: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {

    /// 录制目标：窗口（按 CGWindowID）或某屏内的矩形选区（点坐标，左上原点）。
    enum Target: Sendable {
        case window(windowID: UInt32)
        case region(displayID: UInt32, rect: CGRect)
    }

    struct Params: @unchecked Sendable {
        var target: Target
        var settings: RecordingSettings
        var outputURL: URL
        /// 需从录制画面排除的窗口 ID（覆盖层「不入画」/ 本软件窗口排除）
        var excludedWindowIDs: Set<UInt32> = []
    }

    struct Summary: Sendable {
        var output: URL
        var framesIn: Int
        var framesDropped: Int
        /// 缺帧续帧（静屏时按帧间隔补的画面帧）数
        var synthetic: Int
        /// 「未生成新帧」投递数（idle 空壳样本，不带像素缓冲）
        var framesIdle: Int
        /// 编码器失败摘要（空串 = 无失败）
        var encodeFailures: String
    }

    // MARK: 状态

    private let sampleQueue = DispatchQueue(label: "com.disynk.strecord.sample", qos: .userInteractive)
    private let routeQueue = DispatchQueue(label: "com.disynk.strecord.route", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var encoder: HardwareEncoder?
    private var muxer: (any RecordingMuxer)?
    private var currentOutput: URL?
    private var _startedAt: Date?
    private var stats = Stats()
    var onStatus: (@Sendable (String) -> Void)?

    // 出帧节拍（routeQueue 串行域访问）：与 RecordingEngine 同样的「缺帧续帧」兼底
    private var clock: FrameClock?
    private var intervalSeconds = 1.0 / 30
    private var lastFrame: CMSampleBuffer?
    private var lastEmitAt = Date()
    private var pacerTimer: DispatchSourceTimer?
    private var syntheticCount = 0
    private static let pacerSlack = 1.6
    /// 窗口自定义壁纸合成器（仅窗口录制且选择自定义壁纸时非 nil；routeQueue 串行域访问）
    private var windowCompositor: WindowBGCompositor?

    private final class Stats { var framesIn = 0; var framesDropped = 0; var framesIdle = 0 }

    /// 封装 FIFO 事件（保序 append）。
    private enum MuxEvent: @unchecked Sendable {
        case video(CMSampleBuffer)
        case audio(CMSampleBuffer)
        case finish
    }
    private var muxCont: AsyncStream<MuxEvent>.Continuation?
    private var muxTask: Task<Void, Never>?
    private let muxErrLock = NSLock()
    private var muxError: Error?

    override init() { super.init() }

    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stream != nil }

    func startedSeconds() -> Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// 当前已入帧总数（无画面看门狗用；启动后仍为 0 多为权限失效导致黑屏/空流）。
    func liveFramesIn() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return stats.framesIn
    }

    // MARK: - 尺寸计算（委托 DKCore.PixelMath 纯函数，已离线单测）

    private static func regionPixels(rect: CGRect, scale: Double) -> PixelSize {
        PixelMath.regionPixels(rect: rect, scale: scale)
    }

    // MARK: - 启动

    func start(_ params: Params) async throws {
        guard ScreenPermissions.hasScreenRecording() else {
            throw DKError.permissionDenied("屏幕录制")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // 解析目标 → SCContentFilter + 基准像素尺寸 + fps 上限
        let filter: SCContentFilter
        let basePixels: PixelSize
        var fpsCap = params.settings.frameRate.fps
        let config = SCStreamConfiguration()
        var sourceRectForConfig: CGRect?

        switch params.target {
        case .window(let winID):
            guard let window = content.windows.first(where: { $0.windowID == winID }) else {
                throw DKError.other("窗口不存在或已关闭")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Self.windowScale(window.frame)
            basePixels = Self.regionPixels(rect: window.frame, scale: scale)
        case .region(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw DKError.displayNotFound(id: displayID)
            }
            // 解析需排除的窗口（「排除本软件窗口」保留覆盖层、「不入画」排除覆盖层）
            let excludeWindows: [SCWindow] = params.excludedWindowIDs.isEmpty ? [] :
                content.windows.filter { params.excludedWindowIDs.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
            sourceRectForConfig = rect
            let scale = Self.displayScale(displayID)
            basePixels = Self.regionPixels(rect: rect, scale: scale)
            let refresh = Self.refreshHz(displayID)
            fpsCap = DisplayCapture.clampedFPS(requested: params.settings.frameRate.fps, refreshHz: refresh)
        }

        let out = params.settings.resolution.resolve(source: basePixels)
        let fps = Double((fpsCap.rounded()).clamped(to: 1...240))
        let bitrate = Int(params.settings.quality.bitrateBps(size: out, fps: fps, codec: params.settings.codec))

        config.width = out.width
        config.height = out.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   // NV12 零拷贝直入 VideoToolbox
        config.queueDepth = 3
        config.showsCursor = params.settings.captureCursor
        config.scalesToFit = false
        if let rect = sourceRectForConfig { config.sourceRect = rect }

        // 窗口背景（仅窗口目标）：透明/自定义壁纸都需 BGRA 采集（桌面无关窗口滤器会外框透明）；
        // 自定义额外逐帧合成到壁纸上。BGRA 本身携带 alpha，无需额外开关。
        var encoderInputFormat: OSType? = nil
        if case .window = params.target {
            switch params.settings.windowBackground {
            case .transparent:
                config.pixelFormat = kCVPixelFormatType_32BGRA
                encoderInputFormat = kCVPixelFormatType_32BGRA
            case .customImage(let path):
                config.pixelFormat = kCVPixelFormatType_32BGRA
                if let comp = WindowBGCompositor(wallpaperPath: path, size: out) {
                    windowCompositor = comp
                    encoderInputFormat = kCVPixelFormatType_32BGRA
                } else {
                    onStatus?("⚠ 壁纸无法读取，窗口将按原样录制")
                }
            }
        }

        let wantSystemAudio = params.settings.captureSystemAudio
        if wantSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        var trackKinds: [AudioTrackKind] = []
        if wantSystemAudio { trackKinds.append(.system) }

        // 编码器：压缩帧 → 串行 FIFO → muxer（保序）
        let enc = try HardwareEncoder(
            config: .init(codec: params.settings.codec, size: out, frameRate: FrameRate(fps: fps),
                          bitrateBps: bitrate,
                          keyframeIntervalSeconds: params.settings.keyframeIntervalSeconds,
                          // 录屏不开 B 帧：避免输出样本按解码序到达（PTS 非单调、首帧 DTS 负偏）
                          // 与自驱帧时钟相互作乱，旧实测因此出现「视频轨只到开头几秒」
                          allowFrameReordering: false, inputFormat: encoderInputFormat),
            outputHandler: { [weak self] sb, _ in
                let box = SendableBox(sb)
                self?.routeQueue.async { self?.muxCont?.yield(.video(box.value)) }
            })
        enc.onError = { [weak self] msg in
            self?.routeQueue.async { self?.onStatus?("⚠ 编码器异常：\(msg)") }
        }
        let mux = try MuxerFactory.make(
            container: params.settings.container,
            video: .init(codec: params.settings.codec, pixelSize: out, displaySize: out, fps: fps),
            audioTracks: trackKinds, outputURL: params.outputURL)

        // 启动封装 FIFO 任务
        let (streamEvents, cont) = AsyncStream<MuxEvent>.makeStream(bufferingPolicy: .unbounded)
        muxCont = cont
        muxTask = Task { [weak self] in
            for await ev in streamEvents {
                switch ev {
                case .video(let sb):
                    do { try await mux.appendVideo(sb) } catch { self?.markMuxError(error) }
                case .audio(let sb):
                    do { try await mux.appendAudio(sb, track: .system) } catch { self?.markMuxError(error) }
                case .finish:
                    do { try await mux.finish() } catch { self?.markMuxError(error) }
                }
            }
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantSystemAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await s.startCapture()

        adoptRunningState(stream: s, encoder: enc, muxer: mux, output: params.outputURL)
        // 节拍状态在 routeQueue 串行域内初始化（避免与帧回调并发读写），顺带启动续帧定时器
        routeQueue.async { [weak self] in
            guard let self else { return }
            self.clock = FrameClock(fps: fps)
            self.intervalSeconds = 1.0 / max(fps, 1)
            self.lastFrame = nil
            self.lastEmitAt = Date()
            self.syntheticCount = 0
            self.startPacer()
        }

        DKLog.capture.info("单目标录制启动 \(out.width)x\(out.height)@\(fps, format: .fixed(precision: 1))fps → \(params.outputURL.lastPathComponent, privacy: .public)")
        onStatus?("录制中：\(out.width)×\(out.height)")
    }

    /// 归档本次运行句柄（同步方法内加锁，避开 async 上下文直接使 NSLock）
    private func adoptRunningState(stream s: SCStream, encoder enc: HardwareEncoder,
                                  muxer mux: any RecordingMuxer, output: URL) {
        stateLock.lock(); defer { stateLock.unlock() }
        encoder = enc
        muxer = mux
        stream = s
        currentOutput = output
        _startedAt = Date()
        stats = Stats()
    }

    // MARK: - 停止

    func stop() async -> Summary {
        let taken = detachState()
        let s = taken.stream
        let enc = taken.encoder
        let out = taken.output

        try? await s?.stopCapture()
        // 先停续帧定时器，再 flush 编码器：剩余压缩帧在 outputHandler 里入 FIFO；须在 finish 流前同步产出
        routeQueue.sync {
            pacerTimer?.cancel()
            pacerTimer = nil
            windowCompositor = nil
            enc?.flush()
        }
        enc?.invalidate()
        muxCont?.yield(.finish)
        muxCont?.finish()
        await muxTask?.value
        muxTask = nil

        if let err = muxError { DKLog.mux.error("单目标封装错误: \(err.localizedDescription, privacy: .public)") }
        let fin = taken.stats
        let synth = syntheticCount
        let encFails = enc?.failureSummary() ?? ""
        return Summary(output: out ?? URL(fileURLWithPath: NSTemporaryDirectory()),
                       framesIn: fin.framesIn, framesDropped: fin.framesDropped,
                       synthetic: synth, framesIdle: fin.framesIdle, encodeFailures: encFails)
    }

    /// 摘取并清空运行态（同步方法内加锁，避免在 async 上下文直接用 NSLock）
    private func detachState() -> (stream: SCStream?, encoder: HardwareEncoder?, output: URL?, stats: Stats) {
        stateLock.lock(); defer { stateLock.unlock() }
        let t = (stream, encoder, currentOutput, stats)
        stream = nil; encoder = nil; muxer = nil; currentOutput = nil; _startedAt = nil
        return t
    }

    private func markMuxError(_ e: Error) {
        muxErrLock.lock(); defer { muxErrLock.unlock() }
        if muxError == nil { muxError = e }
    }

    // MARK: - SCStreamOutput

    func stream(_ aStream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // 帧取舍：以「是否带像素缓冲」为唯一真相。
            // idle 样本是「画面未生成」的信号（SDK 头文件原文），并无像素：
            // 旧实现当它入队→编码器报「输入样本无像素缓冲」→ 续帧源被污染→静屏期间零输出。
            let attachments = CMCopyDictionaryOfAttachments(
                allocator: nil, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            let dict = attachments as? [String: Any]
            let status = (dict?[SCStreamFrameInfo.status.rawValue] as? NSNumber)
                .flatMap { SCFrameStatus(rawValue: $0.intValue) }
            let hasPicture = CMSampleBufferGetImageBuffer(sampleBuffer) != nil
            guard DisplayCapture.deliversPicture(status: status, hasPixelBuffer: hasPicture) else {
                stateLock.lock()
                if hasPicture { stats.framesDropped += 1 } else { stats.framesIdle += 1 }
                stateLock.unlock()
                return
            }
            stateLock.lock(); stats.framesIn += 1; stateLock.unlock()
            // 不在 SCK 回调线程做编码：排入 routeQueue 串行域（与帧时钟/续帧定时器同域）
            let box = SendableBox(sampleBuffer)
            routeQueue.async { [weak self] in self?.feedVideo(box.value) }
        case .audio:
            stateLock.lock(); let c = muxCont; stateLock.unlock()
            routeQueue.async { c?.yield(.audio(sampleBuffer)) }
        default:
            break
        }
    }

    // MARK: - 出帧与缺帧续帧（routeQueue 串行域）

    /// 真实帧：经帧时钟取单调 PTS 后入编码器，并留存画面供续帧使用。
    /// 若选了自定义壁纸（windowCompositor 非 nil）：先把窗口帧合成到壁纸上，再编码（并作为续帧源）。
    private func feedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let enc = currentEncoder() else { return }
        var clk = clock ?? FrameClock(fps: 1.0 / max(intervalSeconds, 0.001))
        let pts = clk.next(source: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        clock = clk
        let toEncode: CMSampleBuffer
        if let comp = windowCompositor,
           let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
           let out = comp.composite(pb),
           let wrapped = Self.sampleBuffer(from: out, pts: pts) {
            toEncode = wrapped
        } else {
            toEncode = sampleBuffer
        }
        enc.encode(toEncode, ptsOverride: pts)
        if CMSampleBufferGetImageBuffer(toEncode) != nil { lastFrame = toEncode }
        lastEmitAt = Date()
    }

    /// 将合成后的 BGRA 像素缓冲包成 CMSampleBuffer 供 VideoToolbox 编码。
    private static func sampleBuffer(from pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd) == noErr,
            let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// 当前编码器（加锁取；停止后为 nil）
    private func currentEncoder() -> HardwareEncoder? {
        stateLock.lock(); defer { stateLock.unlock() }
        return encoder
    }

    /// 启动续帧定时器（仅在 routeQueue 串行域内调用）
    private func startPacer() {
        pacerTimer?.cancel()
        let tick = max(intervalSeconds, 0.005)
        let timer = DispatchSource.makeTimerSource(queue: routeQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in self?.pacerTick() }
        pacerTimer = timer
        timer.resume()
    }

    /// 缺帧时补一拍（静屏 → 视频轨仍按目标帧率增长，避免「只有一帧后黑屏」）
    private func pacerTick() {
        guard let last = lastFrame, CMSampleBufferGetImageBuffer(last) != nil,
              let enc = currentEncoder(), var clk = clock else { return }
        let behind = Date().timeIntervalSince(lastEmitAt)
        guard behind > intervalSeconds * Self.pacerSlack else { return }
        let pts = clk.next(source: nil)
        clock = clk
        if enc.encode(last, ptsOverride: pts) { syntheticCount += 1 }
        lastEmitAt = lastEmitAt.addingTimeInterval(intervalSeconds)
    }

    func stream(_ aStream: SCStream, didStopWithError error: Error) {
        DKLog.capture.error("单目标流中断: \(error.localizedDescription, privacy: .public)")
        stateLock.lock(); stats.framesDropped += 1; stateLock.unlock()
    }

    // MARK: - 倍率/刷新探测（真机相关，最小实现）

    private static func displayScale(_ displayID: UInt32) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        let pointW = Int(CGDisplayBounds(displayID).width)
        guard pointW > 0 else { return 1 }
        return (Double(mode.pixelWidth) / Double(pointW) * 2).rounded() / 2
    }

    private static func refreshHz(_ displayID: UInt32) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 60 }
        let hz = mode.refreshRate
        return hz > 0 ? hz : 60
    }

    /// 窗口所在屏的像素倍率（按 frameRect 中心命中 NSScreen 的 backingScaleFactor）。
    private static func windowScale(_ frameRect: CGRect) -> Double {
        let center = CGPoint(x: frameRect.midX, y: frameRect.midY)
        for screen in NSScreen.screens where screen.frame.contains(center) {
            return Double(screen.backingScaleFactor)
        }
        return Double(NSScreen.main?.backingScaleFactor ?? 1)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
