import AVFoundation
import CoreMedia
import DKCore

/// 录制封装器统一协议。视频输入均为 VideoToolbox 压缩帧；
/// 音频输入为未压缩 PCM 48kHz 立体声 Float32（MP4/MOV 由 AVAssetWriter 转 AAC；MKV 由内置 AACStreamEncoder 转 AAC）。
/// 帧参数为 CMSampleBuffer（非 Sendable）：各封装实现靠自身串行域 + 调用方 FIFO 保序，
/// actor 后端（MKVMuxer）以 @preconcurrency conformance 声明这一移交语义。
public protocol RecordingMuxer: Sendable {
    var outputURL: URL { get }
    func appendVideo(_ sampleBuffer: CMSampleBuffer) async throws
    func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) async throws
    func finish() async throws
    /// 因输入未就绪（背压超时）而丢弃的视频帧数；停录自检报告用
    var videoDroppedFrameCount: Int { get }
}

public extension RecordingMuxer {
    /// 默认 0：仅 AVAssetWriter 路径有背压丢帧语义，其它后端不必实现
    var videoDroppedFrameCount: Int { 0 }
}

public enum AudioTrackKind: UInt8, Sendable {
    case system = 1
    case microphone = 2
}

/// 按容器格式创建封装器
public enum MuxerFactory {
    public struct VideoDescriptor: Sendable {
        public var codec: VideoCodec
        public var pixelSize: PixelSize
        public var displaySize: PixelSize   // 显示宽高（非方形像素/缩放时用）
        public var fps: Double

        public init(codec: VideoCodec, pixelSize: PixelSize, displaySize: PixelSize, fps: Double) {
            self.codec = codec
            self.pixelSize = pixelSize
            self.displaySize = displaySize
            self.fps = fps
        }
    }

    public static func make(container: ContainerFormat, video: VideoDescriptor,
                            audioTracks: [AudioTrackKind], outputURL: URL) throws -> any RecordingMuxer {
        switch container {
        case .mp4, .mov:
            return try AssetWriterMuxer(url: outputURL, container: container,
                                        video: video, audioTracks: audioTracks)
        case .mkv:
            guard video.codec != .proRes422 else {
                throw DKError.muxerFailure("MKV 暂不支持 ProRes，请改用 MP4/MOV 容器")
            }
            return MKVMuxer(url: outputURL, video: video, audioTracks: audioTracks)
        }
    }
}
