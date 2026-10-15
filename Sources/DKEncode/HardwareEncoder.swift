import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import DKCore

/// VideoToolbox 硬件编码器封装。
/// 输入：SCK 产出的 CMSampleBuffer（NV12 或 BGRA）；输出：压缩帧回调（编码内部队列）。
/// 线程模型：encode/flush 需串行调用（内部有锁兜底），回调在 outputQueue 执行。
public final class HardwareEncoder: @unchecked Sendable {
    public struct Config: Sendable {
        public var codec: VideoCodec
        public var size: PixelSize
        public var frameRate: FrameRate
        public var bitrateBps: Int
        public var keyframeIntervalSeconds: Int
        public var allowFrameReordering: Bool   // MKV 简单块不支持 B 帧参考，见 DKMux
        /// 期望输入像素格式（合并模式输入为合成器 BGRA 帧）；nil = NV12 优先链
        public var inputFormat: OSType?
        /// 实时编码（true）或离线画质优先（false）。屏幕/窗口流为实时源，默认 true：
        /// 实时态下 VideoToolbox 会自行控制在途帧数，避免高码率原生分辨率时会话长时间缓存帧。
        public var live: Bool

        public init(codec: VideoCodec, size: PixelSize, frameRate: FrameRate,
                    bitrateBps: Int, keyframeIntervalSeconds: Int = 2,
                    allowFrameReordering: Bool = true, inputFormat: OSType? = nil,
                    live: Bool = true) {
            self.codec = codec
            self.size = size
            self.frameRate = frameRate
            self.bitrateBps = bitrateBps
            self.keyframeIntervalSeconds = keyframeIntervalSeconds
            self.allowFrameReordering = allowFrameReordering
            self.inputFormat = inputFormat
            self.live = live
        }

    }

    public typealias OutputHandler = @Sendable (_ sampleBuffer: CMSampleBuffer, _ isKeyframe: Bool) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private let outputQueue = DispatchQueue(label: "com.disynk.encode", qos: .userInteractive)
    private let outputHandler: OutputHandler
    private let config: Config
    /// invalidate 后不再接单（停止流程尾部，不计入错误上报）
    private var stopped = false
    /// 编码失败上报通道（每种文案首次触发一次；不阻断后续帧）
    public var onError: (@Sendable (String) -> Void)?
    /// 累计被拒/失败的帧数（诊断用，lock 保护）
    private var rejected = 0
    /// 已上报过的错误文案（去重：同文案只回调一次，但计数继续累加）
    private var reportedMessages: Set<String> = []
    /// 各文案重复次数（用于周期日志，避免旧「一次性上报」把上万次失败藏成一行的教训）
    private var repeatCounts: [String: Int] = [:]

    public init(config: Config, outputHandler: @escaping OutputHandler) throws {
        self.config = config
        self.outputHandler = outputHandler
        try setup()
    }

    private func setup() throws {
        // 像素格式回退链：优先调用方指定输入格式 → NV12 全范围（SCK 实况交付格式）
        // → NV12 视频范围 → BGRA。旧链首选 VideoRange，与 SCK 的 FullRange 交付不符，
        // 会迫使会话插入色彩转换（多余且有拒帧风险）。
        let preferred = config.inputFormat ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let formats: [OSType] = [preferred, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 kCVPixelFormatType_32BGRA]
        var lastError: OSStatus = noErr
        for format in formats {
            var sess: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(config.size.width),
                height: Int32(config.size.height),
                codecType: Self.codecType(for: config.codec),
                encoderSpecification: nil,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: format)
                ] as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: { refCon, _, status, _, sampleBuffer in
                    // 注：回调第 1 参 = outputCallbackRefCon（本会话 refcon），第 2 参 = sourceFrameRefCon
                    guard let refCon else { return }
                    let enc = Unmanaged<HardwareEncoder>.fromOpaque(refCon).takeUnretainedValue()
                    if status != noErr {
                        // 诊断：非 noErr 不得静默吞掉（不置 failed：单帧失败不应杀掉整路）
                        DKLog.encode.error("输出回调 status=\(status, privacy: .public)")
                        enc.report("编码器输出回调失败（status=\(status)）")
                        return
                    }
                    guard let sampleBuffer else { return }   // flush 尾帧（空）忽略
                    enc.handleOutput(sampleBuffer)
                },
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &sess
            )
            if status == noErr, let sess {
                self.session = sess
                applyProperties(sess)
                DKLog.encode.info("encoder up format ok")
                return
            }
            lastError = status
        }
        throw DKError.encoderSetup("VTCompressionSessionCreate 失败: \(lastError)")
    }

    private func applyProperties(_ sess: VTCompressionSession) {
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime,
                             value: config.live ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: config.bitrateBps))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: Int(Double(config.keyframeIntervalSeconds) * config.frameRate.fps)))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: config.frameRate.fps))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: config.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse)
        if config.codec == .h264 {
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
        } else if config.codec == .hevc {
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        // 保留时间戳，供封装层做音画同步
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    public static func codecType(for codec: VideoCodec) -> CMVideoCodecType {
        switch codec {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        case .proRes422: return kCMVideoCodecType_AppleProRes422
        }
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        let isKey: Bool
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let first = attachmentsArray.first {
            isKey = (first[kCMSampleAttachmentKey_NotSync as String] as? Bool).map { !$0 } ?? true
        } else {
            isKey = true
        }
        outputHandler(sampleBuffer, isKey)
    }

    /// 送入一帧源画面。
    /// - Parameters:
    ///   - ptsOverride: 覆盖时间戳（缺帧续帧/合成帧由上层 FrameClock 给出单调 PTS）；nil = 用源 PTS
    ///   - 返回 false 仅代表本帧被拒（不进入永久错误态，后续帧照接）
    @discardableResult
    public func encode(_ sampleBuffer: CMSampleBuffer, ptsOverride: CMTime? = nil) -> Bool {
        let failure = encodeLocked(sampleBuffer, ptsOverride: ptsOverride)
        if let failure { report(failure); return false }
        return true
    }

    /// 临界区：在会话上入帧。返回 nil 表示成功，否则为可读错误描述。
    private func encodeLocked(_ sampleBuffer: CMSampleBuffer, ptsOverride: CMTime?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let session, !stopped else { return nil }
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return "输入样本无像素缓冲" }
        let pts = ptsOverride ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let srcDur = CMSampleBufferGetDuration(sampleBuffer)
        let duration = CMTimeGetSeconds(srcDur) > 0 ? srcDur : Self.nominalDuration(frameRate: config.frameRate)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: image,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            DKLog.encode.error("EncodeFrame status=\(status, privacy: .public) pts=\(CMTimeGetSeconds(pts), format: .fixed(precision: 3))")
            return "EncodeFrame status=\(status)"
        }
        return nil
    }

    /// 无源时长时的标称帧时长（供封装层算连续时长）
    private static func nominalDuration(frameRate: FrameRate) -> CMTime {
        let f = UInt32(max(1, frameRate.fps.rounded()))
        return CMTime(value: 1, timescale: CMTimeScale(f))
    }

    /// 被拒帧累计数（诊断）
    public func rejectedFrameCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return rejected
    }

    /// 停录自检用：失败文案与次数摘要（空串 = 全程无失败）
    public func failureSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !repeatCounts.isEmpty else { return "" }
        return repeatCounts.sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: "、")
    }

    /// 去重上报：同文案只回调一次（UI 不被刷屏），但日志按累计次数周期性重提，
    /// 绝不回到「一次性上报 = 把 2 万次失败藏成 1 行」的老路。
    private func report(_ message: String) {
        lock.lock()
        rejected += 1
        let n = (repeatCounts[message] ?? 0) + 1
        repeatCounts[message] = n
        let first = !reportedMessages.contains(message)
        if first { reportedMessages.insert(message) }
        let cb = onError
        lock.unlock()
        // 首次、以及每 300 次（≈10 秒@30fps）写一次日志
        if first || n % 300 == 0 {
            DKLog.encode.error("编码失败上报(第\(n, privacy: .public)次): \(message, privacy: .public)")
        }
        if first { cb?(message) }
    }

    public func flush() {
        lock.lock()
        let sess = session
        lock.unlock()
        if let sess { VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid) }
    }

    public func invalidate() {
        lock.lock()
        stopped = true
        defer { lock.unlock() }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
}

/// 从压缩帧格式描述中提取 H.264/HEVC 参数集（MKV CodecPrivate 组装用）
public enum ParameterSets {
    /// HEVC 额外提供 VPS；H.264 下 vps 为空。三元组命名固定，方便下游拼装 hvcC/avcC。
    public struct Sets: Sendable {
        public var sps: [Data]
        public var pps: [Data]
        public var vps: [Data]
        public init(sps: [Data], pps: [Data], vps: [Data] = []) {
            self.sps = sps; self.pps = pps; self.vps = vps
        }
    }

    /// 返回 (sps[], pps[], vps[])（旧 API，保留兼容）
    public static func extract(from formatDescription: CMFormatDescription, codec: VideoCodec)
        -> Sets? {
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        switch (codec, subType) {
        case (.h264, kCMVideoCodecType_H264):
            var count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr
            else { return nil }
            var sps: [Data] = [], pps: [Data] = []
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let ptr
                else { continue }
                let data = Data(bytes: ptr, count: size)
                // NAL type：7=SPS、8=PPS（mask 0x1F）
                if let first = data.first, first & 0x1F == 7 { sps.append(data) }
                else if let first = data.first, first & 0x1F == 8 { pps.append(data) }
                else { sps.append(data) }
            }
            return Sets(sps: sps, pps: pps, vps: [])
        case (.hevc, kCMVideoCodecType_HEVC):
            var count = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr
            else { return nil }
            var sps: [Data] = [], pps: [Data] = [], vps: [Data] = []
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let ptr
                else { continue }
                let data = Data(bytes: ptr, count: size)
                // HEVC NAL type: 32=VPS, 33=SPS, 34=PPS（(byte>>1)&0x3F）
                let nalType = (data.first ?? 0) >> 1 & 0x3F
                switch nalType {
                case 32: vps.append(data)
                case 33: sps.append(data)
                case 34: pps.append(data)
                default: sps.append(data) // SEI/其他归入头参数
                }
            }
            return Sets(sps: sps, pps: pps, vps: vps)
        default:
            return nil
        }
    }
}
