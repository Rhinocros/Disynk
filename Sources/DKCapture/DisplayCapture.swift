import AVFoundation
import CoreMedia
import DKCore
import DKSettings
import Foundation
import ScreenCaptureKit

/// 单块显示器的 SCStream 捕获封装（每屏一路，多屏并发为方案核心能力）
/// 视频帧 = NV12 CMSampleBuffer 直入 VideoToolbox（零拷贝，见方案第四节内存对策）
public final class DisplayCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    public typealias VideoHandler = @Sendable (CMSampleBuffer) -> Void
    public typealias AudioHandler = @Sendable (CMSampleBuffer) -> Void

    public let displayID: UInt32

    private let display: SCDisplay
    private let settings: RecordingSettings
    private let sourceSize: PixelSize
    private let refreshRateHz: Double
    /// 采集像素格式：录编码链路用 NV12（零拷贝）；合并模式需 BGRA 供 Metal 合成
    public var videoPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// 需从录制画面排除的窗口（覆盖层「不入画」模式：仅本机可见，不进流）
    public var excludingWindows: [SCWindow] = []

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.disynk.capture.sample", qos: .userInteractive)
    private let onVideo: VideoHandler
    private let onAudio: AudioHandler?

    // 统计与错误经锁跨线程访问（SCK 回调在内部队列）
    private let statsLock = NSLock()
    private var _stats = CaptureStats()
    public var stats: CaptureStats {
        statsLock.lock(); defer { statsLock.unlock() }
        return _stats
    }

    public init(display: SCDisplay, displayID: UInt32, settings: RecordingSettings,
                sourceSize: PixelSize, refreshRateHz: Double,
                onVideo: @escaping VideoHandler, onAudio: AudioHandler? = nil) {
        self.display = display
        self.displayID = displayID
        self.settings = settings
        self.sourceSize = sourceSize
        self.refreshRateHz = refreshRateHz
        self.onVideo = onVideo
        self.onAudio = onAudio
        super.init()
    }

    public func start() async throws {
        guard stream == nil else { return }
        // 帧率不得超过源屏刷新率（方案第四节：SCK 输出帧率上限约束）
        let fps = Self.clampedFPS(requested: settings.frameRate.fps, refreshHz: refreshRateHz)
        let out = settings.resolution.resolve(source: sourceSize)

        let config = SCStreamConfiguration()
        config.width = out.width
        config.height = out.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        config.pixelFormat = videoPixelFormat
        config.queueDepth = 3                       // 方案：限制 queueDepth≤3 控内存
        config.showsCursor = settings.captureCursor
        config.scalesToFit = false                 // 已按长宽比取整尺寸，禁二次缩放

        if settings.captureSystemAudio, onAudio != nil {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if settings.captureSystemAudio, onAudio != nil {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await s.startCapture()
        self.stream = s
        DKLog.capture.info("屏 \(self.displayID) 捕获启动 \(out.width)x\(out.height)@\(fps, format: .fixed(precision: 1))fps")
    }

    /// 纯函数：请求帧率按源屏刷新率钳制（方案第四节「SCK 输出帧率不超过源屏刷新率」）。
    /// 上限为 `刷新率 - 0.5` 且不低于 1fps，再与用户请求值取小；与 SCStream 解耦，可离线单测。
    public static func clampedFPS(requested: Double, refreshHz: Double) -> Double {
        min(requested, max(refreshHz - 0.5, 1))
    }

    /// 纯函数：决定覆盖层「不入画」时需从 SCK 录制画面排除的窗口 ID 集合。
    /// `included=true`（覆盖层录入画面）→ 不排除；`included=false` 且面板窗口 ID 有效(>0)
    /// → 排除该窗口（仅本机可见、不进流）；面板尚未创建(≤0) 时无可排除。与 SCStream/真机
    /// 解耦、可离线单测（对齐 §三「入画/不入画独立开关」、§七「覆盖层关闭时不入画」）。
    public static func overlayExcludedWindowIDs(included: Bool, panelWindowID: Int) -> Set<UInt32> {
        if included { return [] }
        return panelWindowID > 0 ? [UInt32(panelWindowID)] : []
    }

    /// 纯函数：该帧状态是否无可用画面（应丢弃）。
    /// `.blank` 屏已熄灭、`.suspended` 更新被暂停、`.stopped` 流结束——三者都没有可编码内容。
    public static func discards(_ status: SCFrameStatus) -> Bool {
        status == .blank || status == .suspended || status == .stopped
    }

    /// 纯函数：该样本是否携带可编码的「画面」。
    ///
    /// SDK 头文件原文：`SCFrameStatusIdle = new frame was not generated because the display
    /// did not change` —— 即画面**未生成**，样本只是个时间戳信号、**不带像素缓冲**。
    /// 旧实现误读为「idle 仍带上一帧完整画面」而放行，结果：
    /// ① 空壳样本入编码器报「输入样本无像素缓冲」（且一次性上报把失败藏了）；
    /// ② 更致命的是它被当作「最近一帧」存下，续帧定时器拿这个空壳反复补帧 → 全部被拒
    ///   → 静屏期间视频轨零增长 → 成片仍只有开头几秒。
    /// 因此唯一判据改为「确实带像素缓冲」，状态位只做辅助。
    public static func deliversPicture(status: SCFrameStatus?, hasPixelBuffer: Bool) -> Bool {
        guard hasPixelBuffer else { return false }
        if let status, discards(status) { return false }
        return true
    }

    public func stop() async {
        guard let s = stream else { return }
        stream = nil
        do {
            try await s.stopCapture()
        } catch {
            DKLog.capture.error("屏 \(self.displayID) 停止异常: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // 帧取舍（「成片只有一帧后黑屏」的真修正）：
            // 以「是否带像素缓冲」为唯一真相；idle 等空壳样本单独计数、不入帧、不入编码器。
            // 时间轴连续不靠它们，而靠上层续帧定时器用最近一帧真画面补帧。
            let attachments = CMCopyDictionaryOfAttachments(
                allocator: nil, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            let dict = attachments as? [String: Any]
            let status = (dict?[SCStreamFrameInfo.status.rawValue] as? NSNumber)
                .flatMap { SCFrameStatus(rawValue: $0.intValue) }
            let hasPicture = CMSampleBufferGetImageBuffer(sampleBuffer) != nil
            guard Self.deliversPicture(status: status, hasPixelBuffer: hasPicture) else {
                bump { s in if hasPicture { s.framesDropped += 1 } else { s.framesIdle += 1 } }
                return
            }
            bump { $0.framesIn += 1 }
            onVideo(sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DKLog.capture.error("屏 \(self.displayID) 流中断: \(error.localizedDescription, privacy: .public)")
        bump { $0.framesDropped += 1 }
    }

    /// 供上层在编码完成后累计 framesEncoded
    public func noteEncoded() { bump { $0.framesEncoded += 1 } }

    private func bump(_ block: (inout CaptureStats) -> Void) {
        statsLock.lock(); defer { statsLock.unlock() }
        block(&_stats)
    }
}
