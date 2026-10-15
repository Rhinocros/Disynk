import AVFoundation
import CoreMedia
import DKCore
import DKEncode

/// Matroska(MKV) 封装后端：内置最小 EBML 写手（v1 支持 H.264/HEVC 视频 + AAC 音轨）。
/// Segment 使用未知长度，Duration 以占位写入并在 finish() 回写，Cues 收尾追加。
/// conformance 标 @preconcurrency：CMSampleBuffer 非 Sendable，帧 append 由调用方
/// 串行 FIFO 保序送达（actor 重入不会并发写文件），因此移交语义成立。
public actor MKVMuxer: @preconcurrency RecordingMuxer {
    public let outputURL: URL

    private let video: MuxerFactory.VideoDescriptor
    private let wantedAudio: [AudioTrackKind]
    private var file: FileHandle?
    private var offset: UInt64 = 0

    private var headerWritten = false
    private var baseSeconds: Double = 0
    private var nalLengthSize = 4

    // 当前 cluster 缓冲（10s 或首个非关键帧超时前 flush）
    private var clusterBlocks = Data()
    private var clusterStartMs: UInt64 = 0
    private var cueEntries: [(timecodeMs: UInt64, position: UInt64)] = []
    private var lastBlockEndMs: Double = 0
    private var durationValueFileOffset: UInt64?

    private var systemEncoder = AACStreamEncoder()
    private var micEncoder = AACStreamEncoder()

    private static let clusterIntervalMs: Double = 10_000

    init(url: URL, video: MuxerFactory.VideoDescriptor, audioTracks: [AudioTrackKind]) {
        self.outputURL = url
        self.video = video
        self.wantedAudio = audioTracks
    }

    // MARK: - 写入原语

    private func write(_ data: Data) throws {
        if file == nil {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: outputURL.path) else {
                throw DKError.muxerFailure("无法打开输出文件: \(outputURL.path)")
            }
            file = h
        }
        file?.write(data)
        offset += UInt64(data.count)
    }

    // MARK: - 视频

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) async throws {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if !headerWritten {
            baseSeconds = pts
            try writeHeader(sampleBuffer: sampleBuffer)
            headerWritten = true
        }
        let tsMs = UInt64(max(0, (pts - baseSeconds) * 1000).rounded())
        let isKey = isKeyframe(sampleBuffer)

        if !clusterBlocks.isEmpty,
           isKey,
           Double(tsMs - clusterStartMs) >= Self.clusterIntervalMs {
            try flushCluster()
        }
        if clusterBlocks.isEmpty {
            clusterStartMs = tsMs
        }

        guard let payload = rawSlice(from: sampleBuffer) else { return }
        let durationMs = CMSampleBufferGetDuration(sampleBuffer).seconds
        lastBlockEndMs = max(lastBlockEndMs, Double(tsMs) + (durationMs > 0 ? durationMs * 1000 : 16))

        clusterBlocks.append(Self.simpleBlock(track: 1, relativeMs: Int(tsMs - clusterStartMs),
                                              keyframe: isKey, payload: payload))
    }

    private func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]],
              let first = arr.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool).map { !$0 } ?? true
    }

    /// 取编码帧的裸字节（AVCC 长度前缀直通；长度前缀非 4 时转 AnnexB 起始码）
    private func rawSlice(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return nil }
        let raw = Data(bytes: dataPointer, count: length)
        if nalLengthSize == 4 { return raw }
        // 转 AnnexB：把每个 NAL 的 2 字节长度前缀换成 4 字节起始码
        var out = Data()
        var idx = 0
        while idx + nalLengthSize <= raw.count {
            let nalLen: Int
            if nalLengthSize == 4 {
                nalLen = Int(raw[idx]) << 24 | Int(raw[idx + 1]) << 16 | Int(raw[idx + 2]) << 8 | Int(raw[idx + 3])
            } else {
                nalLen = Int(raw[idx]) << 8 | Int(raw[idx + 1])
            }
            idx += nalLengthSize
            guard idx + nalLen <= raw.count else { break }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(raw.subdata(in: idx..<(idx + nalLen)))
            idx += nalLen
        }
        return out
    }

    /// SimpleBlock = 轨道VINT + 相对时间码(int16) + 标志 + 载荷
    static func simpleBlock(track: Int, relativeMs: Int, keyframe: Bool, payload: Data) -> Data {
        var block = Data()
        block.append(UInt8(0x80 | track)) // 单字节轨道 VINT（轨号 ≤127）
        let rel = Int16(max(-32768, min(32767, relativeMs)))
        block.append(UInt8((UInt16(bitPattern: rel)) >> 8))
        block.append(UInt8(UInt16(bitPattern: rel) & 0xFF))
        block.append(keyframe ? 0x80 : 0x00)
        block.append(payload)
        return EBML.element(id: MkID.simpleBlock, block)
    }

    private func flushCluster() throws {
        guard !clusterBlocks.isEmpty else { return }
        var payload = Data()
        // Timecode（u24）
        payload.append(EBML.uint(id: MkID.timecode, clusterStartMs, byteWidth: 3))
        payload.append(clusterBlocks)
        cueEntries.append((timecodeMs: clusterStartMs, position: offset))
        let cluster = EBML.element(id: MkID.cluster, payload)
        try write(cluster)
        clusterBlocks = Data()
    }

    // MARK: - 头部（EBML / Segment / Info / Tracks）

    private func writeHeader(sampleBuffer: CMSampleBuffer) throws {
        // EBML 头
        var header = Data()
        header.append(EBML.uint(id: MkID.ebmlVersion, 1))
        header.append(EBML.uint(id: MkID.ebmlReadVersion, 1))
        header.append(EBML.uint(id: MkID.ebmlMaxIDLength, 4))
        header.append(EBML.uint(id: MkID.ebmlMaxSizeLength, 8))
        header.append(EBML.string(id: MkID.docType, "matroska"))
        header.append(EBML.uint(id: MkID.docTypeVersion, 4))
        header.append(EBML.uint(id: MkID.docTypeReadVersion, 2))
        try write(EBML.master(id: MkID.ebml, header))

        // Segment（未知长度）
        try write(Data(MkID.segment) + EBML.unknownSize)

        // Info：Duration 占位 8 字节 float64，finish 时回写
        var info = Data()
        var uid = Data(count: 16)
        for i in 0..<16 { uid[i] = UInt8.random(in: 0...255) }
        info.append(EBML.binary(id: MkID.segmentUID, uid))
        info.append(EBML.uint(id: MkID.timecodeScale, 1_000_000)) // 1ms 刻度
        info.append(EBML.string(id: MkID.muxingApp, "Disynk"))
        info.append(EBML.string(id: MkID.writingApp, "Disynk"))
        let durationElem = EBML.float64(id: MkID.duration, 0)
        let durationValueOffsetInPayload = info.count + durationElem.count - 8
        info.append(durationElem)
        let infoPayloadSize = EBML.encodedSize(info.count)
        durationValueFileOffset = offset + UInt64(4 /*id*/ + infoPayloadSize.count)
            + UInt64(durationValueOffsetInPayload)
        try write(EBML.element(id: MkID.info, info))

        // Tracks
        var tracksPayload = Data()
        tracksPayload.append(try videoTrackEntry(sampleBuffer: sampleBuffer))
        for kind in wantedAudio {
            let encoder = kind == .system ? systemEncoder : micEncoder
            guard encoder.available, let asc = encoder.magicCookie else { continue }
            tracksPayload.append(audioTrackEntry(number: kind == .system ? 2 : 3, cookie: asc))
        }
        try write(EBML.master(id: MkID.tracks, tracksPayload))
    }

    private func videoTrackEntry(sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DKError.muxerFailure("缺少视频格式描述")
        }
        var track = Data()
        track.append(EBML.uint(id: MkID.trackNumber, 1))
        track.append(EBML.uint(id: MkID.trackUID, 0x1853_8067))
        track.append(EBML.uint(id: MkID.trackType, 1)) // video
        track.append(EBML.uint(id: MkID.flagLacing, 0))
        track.append(EBML.string(id: MkID.language, "und"))

        let codecID: String
        var codecPrivate = Data()
        switch video.codec {
        case .h264:
            codecID = "V_MPEG4/ISO/AVC"
            guard let sets = ParameterSets.extract(from: formatDesc, codec: .h264),
                  !sets.sps.isEmpty else {
                throw DKError.muxerFailure("无法提取 H.264 参数集")
            }
            var nalLen: Int32 = 4
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalLen)
            nalLengthSize = Int(nalLen)
            codecPrivate = Self.buildAVCC(sps: sets.sps, pps: sets.pps)
        case .hevc:
            codecID = "V_MPEGH/ISO/HEVC"
            guard let sets = ParameterSets.extract(from: formatDesc, codec: .hevc),
                  !sets.sps.isEmpty else {
                throw DKError.muxerFailure("无法提取 HEVC 参数集")
            }
            // 优先取系统组装好的 hvcC 配置记录（键即 CFString "HVCDecoderConfigurationRecord"，
            // CLT SDK 未导出对应常量符号，改用字面量）。CFTypeRef 到 Data 的自动桥接在部分
            // Swift 工具链下会失败，改用 CFGetTypeID 直接判定 CFData 后强转。
            let ext: CFTypeRef? = CMFormatDescriptionGetExtension(formatDesc,
                extensionKey: "HVCDecoderConfigurationRecord" as CFString)
            if let cfType = ext, CFGetTypeID(cfType) == CFDataGetTypeID() {
                codecPrivate = (cfType as! CFData) as Data
            } else {
                // VideoToolbox HEVC 实测不在 formatDescription 上提供 hvcC 扩展（本会话 probe 确认），
                // 因此从参数集自行拼装完整 hvcC（VPS/SPS/PPS 三 array + lengthSizeMinusOne=3）。
                codecPrivate = Self.buildHVC(sps: sets.sps, pps: sets.pps, vps: sets.vps)
            }
        case .proRes422:
            throw DKError.muxerFailure("MKV 不支持 ProRes")
        }
        track.append(EBML.string(id: MkID.codecID, codecID))
        if !codecPrivate.isEmpty {
            track.append(EBML.binary(id: MkID.codecPrivate, codecPrivate))
        }
        track.append(EBML.uint(id: MkID.defaultDuration,
                               UInt64((1_000_000_000 / video.fps).rounded())))

        var videoElem = Data()
        videoElem.append(EBML.uint(id: MkID.pixelWidth, UInt64(video.pixelSize.width)))
        videoElem.append(EBML.uint(id: MkID.pixelHeight, UInt64(video.pixelSize.height)))
        videoElem.append(EBML.uint(id: MkID.displayWidth, UInt64(video.displaySize.width)))
        videoElem.append(EBML.uint(id: MkID.displayHeight, UInt64(video.displaySize.height)))
        track.append(EBML.master(id: MkID.video, videoElem))

        return EBML.master(id: MkID.trackEntry, track)
    }

    private func audioTrackEntry(number: Int, cookie: Data) -> Data {
        var track = Data()
        track.append(EBML.uint(id: MkID.trackNumber, UInt64(number)))
        track.append(EBML.uint(id: MkID.trackUID, UInt64(0x2000 + number)))
        track.append(EBML.uint(id: MkID.trackType, 2)) // audio
        track.append(EBML.uint(id: MkID.flagLacing, 0))
        track.append(EBML.string(id: MkID.language, "und"))
        track.append(EBML.string(id: MkID.codecID, "A_AAC"))
        track.append(EBML.binary(id: MkID.codecPrivate, cookie))
        var audioElem = Data()
        audioElem.append(EBML.float64(id: MkID.samplingFrequency, 48_000))
        audioElem.append(EBML.uint(id: MkID.channels, 2))
        audioElem.append(EBML.uint(id: MkID.bitDepth, 16))
        track.append(EBML.master(id: MkID.audio, audioElem))
        return EBML.master(id: MkID.trackEntry, track)
    }

    /// AVCDecoderConfigurationRecord
    static func buildAVCC(sps: [Data], pps: [Data]) -> Data {
        var out = Data()
        let firstSPS = sps[0]
        out.append(1)                                  // configurationVersion
        out.append(firstSPS.count > 1 ? firstSPS[1] : 0x64) // profile_idc
        out.append(firstSPS.count > 2 ? firstSPS[2] : 0)    // profile_compatibility
        out.append(firstSPS.count > 3 ? firstSPS[3] : 40)   // level_idc
        out.append(0xFF)                               // 4 字节长度前缀
        out.append(0xE1 | UInt8(min(sps.count, 0x1F))) // 1110 0000 | numSPS
        for s in sps.prefix(31) {
            out.append(UInt8(s.count >> 8)); out.append(UInt8(s.count & 0xFF))
            out.append(s)
        }
        out.append(UInt8(min(pps.count, 0xFF)))
        for p in pps.prefix(255) {
            out.append(UInt8(p.count >> 8)); out.append(UInt8(p.count & 0xFF))
            out.append(p)
        }
        return out
    }

    /// HEVC 兜底：完整 hvcC 需系统配置记录，若不可得仅拼参数集（多数播放器仍可启动，
    /// 但规范场景下应依赖 kCMFormatDescriptionExtension_HVCDecoderConfigurationRecord）
    static func buildHVCCHDR(sps: [Data], pps: [Data]) -> Data {
        var out = Data()
        out.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 1, 32, 0, 0, 0, 0, 0, 0])
        out.append(0) // numOfArrays = 0：依赖 AnnexB 透传
        return out
    }

    /// 完整 hvcC（ISO/IEC 14496-15 §8.3.1.1），22B 头 + numOfArrays + VPS/SPS/PPS 三 array；
    /// VideoToolbox HEVC 不暴露 hvcC 扩展时作为主路径（本会话 probe 确认 ext=nil）。
    /// profile/level 取保守默认（Main / L3）；下游 FFmpeg 会从 in-band SPS 重新推导，不阻断初始化。
    static func buildHVC(sps: [Data], pps: [Data], vps: [Data]) -> Data {
        var out = Data(capacity: 128)
        out.append(0x01)                          // configurationVersion
        out.append(0x01)                          // space(2)=0 | tier(1)=0 | profile_idc(5)=1 (Main)
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // profile_compatibility 32-bit BE（bit0 = Main 兼容）
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // constraint_indicator 48-bit
        out.append(0x5A)                          // general_level_idc = 90 (v3.0)
        out.append(0xF0); out.append(0x00)        // 4-bit reserved '1111' | 12-bit min_spatial_segmentation_idc = 0
        out.append(0xFC)                          // 6-bit reserved | parallelismType = 0
        out.append(0xFD)                          // 6-bit reserved | chromaFormat = 1 (4:2:0)
        out.append(0xF8)                          // 5-bit reserved | bitDepthLuma = 0 (8bit)
        out.append(0xF8)                          // 5-bit reserved | bitDepthChroma = 0
        out.append(0x00); out.append(0x00)        // avgFrameRate 16-bit BE = 0 (VFR)
        out.append(0x0F)                          // constantFrameRate(2)=0 | numTemporalLayers(3)=1 | temporalIdNested(1)=1 | lengthSizeMinusOne(2)=3
        var arrays = 0
        if !vps.isEmpty { arrays += 1 }
        if !sps.isEmpty { arrays += 1 }
        if !pps.isEmpty { arrays += 1 }
        out.append(UInt8(arrays))                 // numOfArrays
        func put(_ type: UInt8, _ set: [Data]) {
            out.append(0x80 | type)               // array_completeness=1 | reserved=0 | nal_unit_type
            out.append(UInt8(set.count >> 8))
            out.append(UInt8(set.count & 0xFF))
            for d in set {
                out.append(UInt8(d.count >> 8))
                out.append(UInt8(d.count & 0xFF))
                out.append(d)
            }
        }
        if !vps.isEmpty { put(32, vps) }
        if !sps.isEmpty { put(33, sps) }
        if !pps.isEmpty { put(34, pps) }
        return out
    }

    // MARK: - 音频

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) async throws {
        guard headerWritten else { return } // 首视频帧前到达的少量音频丢弃
        let encoder = track == .system ? systemEncoder : micEncoder
        guard encoder.available else { return }
        guard let pcm = Self.floatPCM(from: sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) - baseSeconds
        encoder.append(pcm: pcm.data, startSeconds: pts)
        let trackNumber = track == .system ? 2 : 3
        for packet in encoder.drain() {
            let tsMs = UInt64(max(0, packet.seconds * 1000).rounded())
            if clusterBlocks.isEmpty { clusterStartMs = tsMs }
            lastBlockEndMs = max(lastBlockEndMs, Double(tsMs) + 21)
            let block = Self.simpleBlock(track: trackNumber,
                                         relativeMs: Int(tsMs - clusterStartMs),
                                         keyframe: true, payload: packet.data)
            clusterBlocks.append(block)
        }
    }

    static func floatPCM(from sampleBuffer: CMSampleBuffer) -> (data: Data, seconds: Double)? {
        // 两遍调用：先查所需大小，再取数据
        var needed = 0
        let probe = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil)
        guard needed > 0, probe != noErr || needed > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockRef: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl,
            bufferListSize: needed, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockRef)
        guard status == noErr else { return nil }

        var data = Data()
        let count = Int(abl.pointee.mNumberBuffers)
        withUnsafeMutableBytes(of: &abl.pointee.mBuffers) { slotBytes in
            for i in 0..<count {
                let base = slotBytes.baseAddress!.advanced(by: i * MemoryLayout<AudioBuffer>.stride)
                let buf = base.assumingMemoryBound(to: AudioBuffer.self).pointee
                if let md = buf.mData, buf.mDataByteSize > 0 {
                    data.append(Data(bytes: md, count: Int(buf.mDataByteSize)))
                }
            }
        }
        let seconds = Double(data.count / 8) / 48_000
        return (data, seconds)
    }

    // MARK: - 收尾

    public func finish() async throws {
        guard headerWritten, file != nil else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }
        try flushCluster()

        // Cues
        var cues = Data()
        for entry in cueEntries {
            var positions = Data()
            positions.append(EBML.uint(id: MkID.cueTrack, 1))
            positions.append(EBML.uint(id: MkID.cueClusterPosition, entry.position))
            var point = Data()
            point.append(EBML.uint(id: MkID.cueTime, entry.timecodeMs))
            point.append(EBML.master(id: MkID.cueTrackPositions, positions))
            cues.append(EBML.master(id: MkID.cuePoint, point))
        }
        if !cues.isEmpty {
            try write(EBML.master(id: MkID.cues, cues))
        }

        // 回写 Duration
        if let pos = durationValueFileOffset {
            var bits = lastBlockEndMs.bitPattern
            var be = Data(capacity: 8)
            for _ in 0..<8 { be.append(UInt8(bits & 0xFF)); bits >>= 8 }
            be.reverse()
            file?.seek(toFileOffset: pos)
            file?.write(be)
        }
        try? file?.close()
        file = nil
    }
}
