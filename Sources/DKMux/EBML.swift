import Foundation

/// EBML（Matroska 底层二进制标记语言）原语
/// 只实现写侧最小子集：元素 ID + 宽度前缀（VINT size）+ 载荷
/// （public 以供 DKExport 的 WebM 封装复用，WebM 与 MKV 同为 Matroska 家族）
public enum EBML {
    /// 编码元素长度为最小 VINT（1~8 字节）
    public static func encodedSize(_ length: Int) -> Data {
        let value = UInt64(length)
        var bytesRequired = 1
        while bytesRequired < 8 {
            let maxRepresentable = (1 << (7 * bytesRequired)) - 1
            if value < UInt64(maxRepresentable) { break }
            bytesRequired += 1
        }
        var out = Data(capacity: bytesRequired)
        let firstByteMarker = UInt8(0x80 >> (bytesRequired - 1))
        var bytes: [UInt8] = []
        for i in 0..<bytesRequired {
            bytes.append(UInt8((value >> (UInt64(8 * (bytesRequired - 1 - i)))) & 0xFF))
        }
        bytes[0] |= firstByteMarker
        out.append(contentsOf: bytes)
        return out
    }

    /// Segment 用未知长度 VINT（0x01FFFFFFFFFFFFFF）
    public static let unknownSize = Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

    public static func element(id: [UInt8], _ payload: Data) -> Data {
        var out = Data(id)
        out.append(encodedSize(payload.count))
        out.append(payload)
        return out
    }

    public static func uint(id: [UInt8], _ value: UInt64, byteWidth: Int = 0) -> Data {
        var width = byteWidth
        if width == 0 {
            width = 1
            var v = value
            while v > 0xFF && width < 8 { v >>= 8; width += 1 }
        }
        var payload = Data(capacity: width)
        for i in 0..<width {
            payload.append(UInt8((value >> UInt64(8 * (width - 1 - i))) & 0xFF))
        }
        return element(id: id, payload)
    }

    public static func float64(id: [UInt8], _ value: Double) -> Data {
        var bits = value.bitPattern
        var payload = Data(capacity: 8)
        for _ in 0..<8 {
            payload.append(UInt8(bits & 0xFF))
            bits >>= 8
        }
        payload.reverse()
        return element(id: id, payload)
    }

    public static func string(id: [UInt8], _ value: String) -> Data {
        element(id: id, Data(value.utf8))
    }

    public static func binary(id: [UInt8], _ value: Data) -> Data {
        element(id: id, value)
    }

    /// 拼接多个子元素为主元素载荷
    public static func master(id: [UInt8], _ children: Data) -> Data {
        element(id: id, children)
    }
}

/// Matroska 元素 ID 常量（public 供 DKExport WebM 封装复用）
public enum MkID {
    public static let ebml: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
    public static let ebmlVersion: [UInt8] = [0x42, 0x86]
    public static let ebmlReadVersion: [UInt8] = [0x42, 0xF7]
    public static let ebmlMaxIDLength: [UInt8] = [0x42, 0xF2]
    public static let ebmlMaxSizeLength: [UInt8] = [0x42, 0xF3]
    public static let docType: [UInt8] = [0x42, 0x82]
    public static let docTypeVersion: [UInt8] = [0x42, 0x87]
    public static let docTypeReadVersion: [UInt8] = [0x42, 0x85]

    public static let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67]
    public static let info: [UInt8] = [0x15, 0x49, 0xA9, 0x66]
    public static let segmentUID: [UInt8] = [0x73, 0xA4]
    public static let timecodeScale: [UInt8] = [0x2A, 0xD7, 0xB1]
    public static let muxingApp: [UInt8] = [0x4D, 0x80]
    public static let writingApp: [UInt8] = [0x57, 0x41]
    public static let duration: [UInt8] = [0x44, 0x89]

    public static let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B]
    public static let trackEntry: [UInt8] = [0xAE]
    public static let trackNumber: [UInt8] = [0xD7]
    public static let trackUID: [UInt8] = [0x73, 0xC5]
    public static let trackType: [UInt8] = [0x83]
    public static let flagLacing: [UInt8] = [0x9C]
    public static let language: [UInt8] = [0x22, 0xB5, 0x9C]
    public static let codecID: [UInt8] = [0x86]
    // Matroska 规范 §10.x：CodecPrivate = 0x63A2（不是 0x2586E8——那是 CodecDelay）
    public static let codecPrivate: [UInt8] = [0x63, 0xA2]
    public static let defaultDuration: [UInt8] = [0x23, 0xE3, 0x83]
    public static let video: [UInt8] = [0xE0]        // Matroska spec：Video = 0xE0
    public static let pixelWidth: [UInt8] = [0xB0]
    public static let pixelHeight: [UInt8] = [0xBA]
    public static let displayWidth: [UInt8] = [0x54, 0xB0]   // spec：DisplayWidth = 0x54B0
    public static let displayHeight: [UInt8] = [0x54, 0xBA]  // spec：DisplayHeight = 0x54BA
    public static let audio: [UInt8] = [0xE1]       // Matroska spec：Audio = 0xE1
    public static let samplingFrequency: [UInt8] = [0xB5]
    public static let channels: [UInt8] = [0x9F]
    public static let bitDepth: [UInt8] = [0x62, 0x64]

    public static let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    public static let timecode: [UInt8] = [0xE7]
    public static let simpleBlock: [UInt8] = [0xA3]
    // WebM 视频块必须置于 BlockGroup（禁 SimpleBlock），Block = 0xA1
    public static let blockGroup: [UInt8] = [0xA0]
    public static let block: [UInt8] = [0xA1]

    public static let cues: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    public static let cuePoint: [UInt8] = [0xBB]
    public static let cueTime: [UInt8] = [0xB3]
    public static let cueTrackPositions: [UInt8] = [0xB7]
    public static let cueTrack: [UInt8] = [0xF7]
    public static let cueClusterPosition: [UInt8] = [0xF1]
}
