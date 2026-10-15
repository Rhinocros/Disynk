import AudioToolbox
import CoreAudio
import CoreMedia
import DKCore

/// PCM(Float32 interleaved) → AAC 裸帧的流式编码器（MKV 音轨用）。
/// 非线程安全，由 MKVMuxer actor 串行调用。
final class AACStreamEncoder {
    struct Packet {
        var data: Data
        var seconds: Double   // 呈现时间（秒，相对 session 起点）
    }

    private var converter: AudioConverterRef?
    let sampleRate: Double
    let channels: Int
    static let framesPerPacket = 1024

    /// ring 首帧的全局帧号；consumedFrames = 下一待编码帧的全局帧号
    private var ring = Data()
    private var ringStartFrame = 0
    private var consumedFrames = 0
    private var timeMarks: [(frame: Int, seconds: Double)] = []

    fileprivate var callbackInput = Data()
    fileprivate var bytesPerFrame: Int { channels * 4 }

    init(sampleRate: Double = 48_000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        setup()
    }

    var available: Bool { converter != nil }

    /// AAC AudioSpecificConfig（作 MKV CodecPrivate）。
    /// 优先取 AudioConverter 的 magic cookie；但新建编码会话在首次转换前常返回空，
    /// 故回退为按采样率/声道合成的确定性 AAC-LC ASC（与编码器目标格式一致）。
    var magicCookie: Data? {
        guard let converter else { return nil }
        var size = UInt32(0)
        var probe: UInt8 = 0
        if AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie,
                                     &size, &probe) == noErr, size > 0 {
            var data = Data(count: Int(size))
            let status = data.withUnsafeMutableBytes { ptr in
                AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie,
                                          &size, ptr.baseAddress!)
            }
            if status == noErr, !data.isEmpty { return data }
        }
        return Self.audioSpecificConfig(sampleRate: sampleRate, channels: channels)
    }

    /// 确定性 AAC-LC AudioSpecificConfig（2 字节）：objectType(5)|freqIdx(4)|chanCfg(4)|...
    static func audioSpecificConfig(sampleRate: Double, channels: Int) -> Data {
        let freqIdx: Int
        switch Int(sampleRate.rounded()) {
        case 96_000: freqIdx = 0
        case 88_200: freqIdx = 1
        case 64_000: freqIdx = 2
        case 48_000: freqIdx = 3
        case 44_100: freqIdx = 4
        case 32_000: freqIdx = 5
        case 24_000: freqIdx = 6
        case 22_050: freqIdx = 7
        case 16_000: freqIdx = 8
        case 12_000: freqIdx = 9
        case 11_025: freqIdx = 10
        case 8_000: freqIdx = 11
        case 7_350: freqIdx = 12
        default: freqIdx = 3
        }
        let objectType = 2 // AAC-LC
        let b0 = UInt8((objectType << 3) | (freqIdx >> 1))
        let b1 = UInt8((freqIdx & 0x01) << 7 | (channels & 0x0F) << 3)
        return Data([b0, b1])
    }

    private func setup() {
        var src = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var dst = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        var conv: AudioConverterRef?
        let status = AudioConverterNew(&src, &dst, &conv)
        guard status == noErr, let conv else {
            DKLog.mux.error("AAC 编码器创建失败 status=\(status)")
            return
        }
        var bitrate = UInt32(192_000)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)
        self.converter = conv
    }

    /// 送入一段 PCM；startSeconds 为该段第一帧的呈现时间
    func append(pcm: Data, startSeconds: Double) {
        let tailFrame = ringStartFrame + ring.count / bytesPerFrame
        ring.append(pcm)
        timeMarks.append((frame: tailFrame, seconds: startSeconds))
        while timeMarks.count > 4, timeMarks[1].frame <= consumedFrames {
            timeMarks.removeFirst()
        }
    }

    /// 尽可能多地产出 AAC 包
    func drain() -> [Packet] {
        guard let converter else { return [] }
        var out: [Packet] = []
        let packetBytes = Self.framesPerPacket * bytesPerFrame

        while true {
            let readOffset = (consumedFrames - ringStartFrame) * bytesPerFrame
            guard ring.count - readOffset >= packetBytes else { break }

            callbackInput = ring.subdata(in: readOffset..<(readOffset + packetBytes))

            var packetCount = UInt32(1)
            let capacity = 2048
            var outStorage = [UInt8](repeating: 0, count: capacity)
            let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
            let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 8)
            defer { ablRaw.deallocate() }
            let abl = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
            abl.pointee.mNumberBuffers = 1
            outStorage.withUnsafeMutableBytes { bufPtr in
                abl.pointee.mBuffers.mData = bufPtr.baseAddress
                abl.pointee.mBuffers.mDataByteSize = UInt32(capacity)
                abl.pointee.mBuffers.mNumberChannels = UInt32(channels)
            }

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioConverterFillComplexBuffer(converter, aacInputCallback, selfPtr,
                                                         &packetCount, abl, nil)
            guard status == noErr, packetCount > 0 else {
                if status != noErr { DKLog.mux.error("AAC 编码失败 status=\(status)") }
                break
            }
            let size = Int(abl.pointee.mBuffers.mDataByteSize)
            out.append(Packet(data: Data(bytes: outStorage, count: size),
                              seconds: seconds(forFrame: consumedFrames)))
            consumedFrames += Self.framesPerPacket
            advanceRing()
        }
        return out
    }

    private func advanceRing() {
        let dropFrames = consumedFrames - ringStartFrame
        guard dropFrames > Self.framesPerPacket * 64 else { return }
        let aligned = dropFrames / Self.framesPerPacket * Self.framesPerPacket
        ring.removeFirst(aligned * bytesPerFrame)
        ringStartFrame += aligned
    }

    private func seconds(forFrame frame: Int) -> Double {
        guard let mark = timeMarks.last(where: { $0.frame <= frame }) else {
            return Double(frame) / sampleRate
        }
        return mark.seconds + Double(frame - mark.frame) / sampleRate
    }
}

/// AudioConverter 拉取 PCM 输入的 C 回调：mData 指向 encoder.callbackInput（调用期间存活）
private func aacInputCallback(
    _ inContext: AudioConverterRef,
    _ inNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutDataDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else { return 1 }
    let encoder = Unmanaged<AACStreamEncoder>.fromOpaque(inUserData).takeUnretainedValue()
    let slice = encoder.callbackInput
    guard !slice.isEmpty else {
        inNumberDataPackets.pointee = 0
        return 1 // kAudioConverterErr_BadPropertySpecifier 等 FourCC 常量未导入 Swift，非 0 即终止转换
    }
    ioData.pointee.mNumberBuffers = 1
    slice.withUnsafeBytes { src in
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: src.baseAddress!)
    }
    ioData.pointee.mBuffers.mDataByteSize = UInt32(slice.count)
    ioData.pointee.mBuffers.mNumberChannels = UInt32(encoder.channels)
    inNumberDataPackets.pointee = UInt32(slice.count / encoder.bytesPerFrame)
    return noErr
}
