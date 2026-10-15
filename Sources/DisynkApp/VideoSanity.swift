import AVFoundation
import DKCore
import Foundation

/// 停录后成片体检（针对「录制只有第一帧图片、后面黑屏」这类症状的自检）。
/// 读取每个成片的视频轨时长与标称帧率：若视频轨时长远短于实际录制时长，
/// 说明时间轴断裂（缺帧未续上），立刻在状态行给出可读告警并写日志。
enum VideoSanity {
    struct Report: Sendable {
        var name: String
        var videoSeconds: Double
        var nominalFPS: Double
        var hasVideo: Bool
    }

    /// 检查产物；返回告警文本（空数组 = 正常）
    static func warnings(for urls: [URL], expectedSeconds: Double) async -> [String] {
        guard expectedSeconds > 1 else { return [] }   // 极短录制不做判定
        var out: [String] = []
        for url in urls {
            let r = await report(for: url)
            if !r.hasVideo {
                out.append("\(r.name)：无视频轨")
                continue
            }
            if r.videoSeconds < max(1.0, expectedSeconds * 0.5) {
                out.append(String(format: "%@：视频轨仅 %.1fs（录了 %.1fs）、标称 %.1ffps → 时间轴断裂",
                                  r.name, r.videoSeconds, expectedSeconds, r.nominalFPS))
            }
            let line = String(format: "体检 %@ 视频轨 %.2fs nominalFPS %.2f",
                              r.name, r.videoSeconds, r.nominalFPS)
            DKLog.export.info("\(line, privacy: .public)")
        }
        return out
    }

    private static func report(for url: URL) async -> Report {
        let asset = AVURLAsset(url: url)
        let name = url.lastPathComponent
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else {
            return Report(name: name, videoSeconds: 0, nominalFPS: 0, hasVideo: false)
        }
        var seconds = 0.0
        if let tr = try? await track.load(.timeRange) { seconds = tr.duration.seconds }
        let fps = (try? await track.load(.nominalFrameRate)) ?? 0
        return Report(name: name, videoSeconds: seconds, nominalFPS: Double(fps), hasVideo: true)
    }
}
