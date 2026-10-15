import AVFoundation
import CoreMedia
import DKCore
import QuartzCore

/// 麦克风采集（方案 M3）：AVAudioEngine inputNode tap → 48k Float32 PCM CMSampleBuffer
public final class MicCapturer: @unchecked Sendable {
    public typealias Handler = @Sendable (CMSampleBuffer) -> Void

    private let engine = AVAudioEngine()
    private let handler: Handler
    private let sampleRate: Double
    private var format: AVAudioFormat?
    private var running = false

    public init(sampleRate: Double = 48_000, handler: @escaping Handler) {
        self.sampleRate = sampleRate
        self.handler = handler
    }

    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DKError.permissionDenied("麦克风")
        }
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: max(1, min(2, inFmt.channelCount)),
                                   interleaved: true)
        guard let target else { throw DKError.other("无法构建目标音频格式") }
        format = target

        if inFmt.sampleRate != sampleRate || inFmt.channelCount != target.channelCount {
            guard let converter = AVAudioConverter(from: inFmt, to: target) else {
                throw DKError.other("麦克风采样率转换器创建失败")
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, when in
                guard let self else { return }
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buf.frameLength + 512)!
                var error: NSError?
                var fed = false
                converter.convert(to: out, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                if error == nil, out.frameLength > 0 { self.emit(out, when: when) }
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 4096, format: target) { [weak self] buf, when in
                self?.emit(buf, when: when)
            }
        }
        engine.prepare()
        try engine.start()
        running = true
        DKLog.audio.info("麦克风采集启动 \(inFmt.sampleRate)→\(self.sampleRate)Hz")
    }

    public func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func emit(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let sb = Self.sampleBuffer(from: buf, when: when) else { return }
        handler(sb)
    }

    /// AVAudioPCMBuffer → CMSampleBuffer（PCM Float32 交织，PTS 取自 host time）
    static func sampleBuffer(from buf: AVAudioPCMBuffer, when: AVAudioTime) -> CMSampleBuffer? {
        guard buf.frameLength > 0,
              let src = buf.audioBufferList.pointee.mBuffers.mData else { return nil }
        var asbd = buf.format.streamDescription.pointee
        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &fmtDesc) == noErr,
            let fmtDesc
        else { return nil }

        let bytes = Int(buf.frameLength) * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block
        else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: src, blockBuffer: block,
                                            offsetIntoDestination: 0, dataLength: bytes) == noErr else { return nil }

        let scale = CMTimeScale(1_000_000_000)
        let pts = when.sampleTime >= 0
            ? CMTime(seconds: Double(when.sampleTime) / max(when.sampleRate, 1), preferredTimescale: scale)
            : CMTime(seconds: CACurrentMediaTime(), preferredTimescale: scale)
        let dur = CMTime(value: CMTimeValue(buf.frameLength), timescale: CMTimeScale(buf.format.sampleRate))
        var timing = CMSampleTimingInfo(duration: dur,
                                         presentationTimeStamp: pts,
                                         decodeTimeStamp: .invalid)
        var sampleSize = bytes
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: fmtDesc, sampleCount: CMItemIndex(buf.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sb) == noErr, let sb
        else { return nil }
        return sb
    }
}
