import AVFoundation
import CoreMedia
import CoreVideo
import DKEncode
import DKCore

/// MP4 / MOV 封装后端（AVAssetWriter）
public final class AssetWriterMuxer: RecordingMuxer, @unchecked Sendable {
    public let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
    private let lock = NSLock()
    private var started = false
    private var hasError = false
    /// 等待就绪超时后被丢掉的视频帧数（诊断）
    private var droppedFrames = 0

    /// 未就绪丢帧累计数（停录后由上层读用）
    public var videoDroppedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedFrames
    }

    /// MP4/MOV 路径音轨由 AVAssetWriter 自行 AAC 编码（喂 PCM）；MKV 路径用 AACStreamEncoder
    private static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    init(url: URL, container: ContainerFormat,
         video: MuxerFactory.VideoDescriptor, audioTracks: [AudioTrackKind]) throws {
        self.outputURL = url
        let fileType: AVFileType = container == .mp4 ? .mp4 : .mov
        self.writer = try AVAssetWriter(url: url, fileType: fileType)

        // 压缩帧直通：outputSettings nil + sourceFormatHint（实测：无 hint 的 nil-settings
        // 输入 canAdd 永返 false）；格式细节由首帧样本携带
        var hint: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: HardwareEncoder.codecType(for: video.codec),
                                       width: Int32(video.pixelSize.width),
                                       height: Int32(video.pixelSize.height),
                                       extensions: nil, formatDescriptionOut: &hint)
        let input: AVAssetWriterInput
        if let hint {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        } else {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        }
        self.videoInput = input
        self.videoInput.expectsMediaDataInRealTime = true
        // 不设 mediaTimeScale：passthrough 保留样本自带时间刻度。若强制设为整数 fps，
        // 相邻两帧取整到同一 tick 会使 append 失败 → writer 进入错误态 → 成片只剩首帧后黑屏。
        guard writer.canAdd(videoInput) else { throw DKError.muxerFailure("无法添加视频轨") }
        writer.add(videoInput)

        for kind in audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInputs[kind] = input
            }
        }
    }

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) async throws {
        // 先确保会话已按本帧 PTS 启动，再等输入就绪（旧实现一遇 !isReady 就丢帧：
        // 高码率原生分辨率下 writer 短暂背压即成片掉帧 → 时间轴断裂/只剩首帧）
        try ensureWriting(firstVideoPTS: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        await waitUntilReady()
        try appendVideoSync(sampleBuffer)
    }

    /// 首帧启动写入会话（AVAssetWriter 必须先 startWriting/startSession 才能 append）
    private func ensureWriting(firstVideoPTS: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        guard !hasError else { throw DKError.muxerFailure("封装器已处于错误态") }
        writer.startWriting()
        writer.startSession(atSourceTime: firstVideoPTS)
        started = true
        DKLog.mux.info("会话启动 pts=\(CMTimeGetSeconds(firstVideoPTS), format: .fixed(precision: 3))")
    }

    /// 有界等待输入就绪（最多 ~1s，2ms 步进；不阻塞线程池）
    private func waitUntilReady() async {
        var waited: UInt64 = 0
        while !videoInput.isReadyForMoreMediaData && waited < 1_000_000_000 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            waited += 2_000_000
            if writer.status != .writing { return }
        }
    }

    /// 同步临界区（非 async 方法内加锁，避开 NSLock 在 async 上下文不可用的限制）
    private func appendVideoSync(_ sampleBuffer: CMSampleBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !hasError else { throw DKError.muxerFailure("封装器已处于错误态") }
        guard started else { throw DKError.muxerFailure("会话未启动") }
        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(sampleBuffer) {
                hasError = true
                let msg = writer.error?.localizedDescription ?? "append 视频帧失败"
                DKLog.mux.error("视频 append 失败: \(msg, privacy: .public)")
                throw DKError.muxerFailure(msg)
            }
        } else {
            droppedFrames += 1
            DKLog.mux.warning("AVAssetWriter 视频输入未就绪（已等待 1s），丢帧 #\(self.droppedFrames)")
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) async throws {
        appendAudioSync(sampleBuffer, track: track)
    }

    private func appendAudioSync(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) {
        lock.lock(); defer { lock.unlock() }
        guard started, let input = audioInputs[track], !hasError else { return }
        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                DKLog.mux.error("音频轨 append 失败: \(self.writer.error?.localizedDescription ?? "?", privacy: .public)")
            }
        }
    }

    public func finish() async throws {
        try markInputsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed, let err = writer.error {
            throw DKError.muxerFailure(err.localizedDescription)
        }
    }

    /// 未启动则删除半成品并返回 false；已启动则标记轨道结束
    private func markInputsFinished() throws {
        lock.lock(); defer { lock.unlock() }
        guard started else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
    }
}
