import AVFoundation
import CoreMedia
import DKCore
import DKSettings
import Foundation
import ScreenCaptureKit

/// 多屏捕获协调器：N 路 DisplayCapture 生命周期管理（方案核心卖点：多屏并发）
public actor CaptureCoordinator {
    private var captures: [UInt32: DisplayCapture] = [:]
    public private(set) var isRunning = false

    public init() {}

    /// 启动指定屏集合的捕获；每屏独立参数（settingsFor），帧统一回调
    /// excludedWindowIDs：需从录制画面排除的窗口 ID（覆盖层「不入画」模式）
    public func start(displays: [DisplaySnapshot],
                      settingsFor: @Sendable (UInt32) -> RecordingSettings,
                      systemAudio: Bool,
                      videoPixelFormat: OSType? = nil,
                      excludedWindowIDs: Set<UInt32> = [],
                      onVideoFrame: @escaping @Sendable (UInt32, CMSampleBuffer) -> Void,
                      onAudioFrame: (@Sendable (UInt32, CMSampleBuffer) -> Void)? = nil) async throws {
        guard captures.isEmpty else { throw DKError.captureStream("捕获已在运行") }
        guard ScreenPermissions.hasScreenRecording() else {
            throw DKError.permissionDenied("屏幕录制")
        }

        // SCShareableContent 是 SCDisplay 的权威来源
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var displayByID: [UInt32: SCDisplay] = [:]
        for d in content.displays { displayByID[d.displayID] = d }
        // 将待排除窗口 ID 解析为 SCWindow 对象（覆盖层面板存在才排除；未找到则无操作）
        let excludeWindows: [SCWindow] = excludedWindowIDs.isEmpty ? [] :
            content.windows.filter { excludedWindowIDs.contains($0.windowID) }

        for snap in displays {
            guard let sc = displayByID[snap.id] else { throw DKError.displayNotFound(id: snap.id) }
            var settings = settingsFor(snap.id)
            if !systemAudio { settings.captureSystemAudio = false }

            // 闭包显式标为 VideoHandler/AudioHandler（@Sendable），避免隐式非 Sendable 闭包转换告警
            let vHandler: DisplayCapture.VideoHandler = { buf in onVideoFrame(snap.id, buf) }
            let aHandler: DisplayCapture.AudioHandler? = onAudioFrame.map { cb in
                let inner: DisplayCapture.AudioHandler = { buf in cb(snap.id, buf) }
                return inner
            }
            let capture = DisplayCapture(
                display: sc, displayID: snap.id, settings: settings,
                sourceSize: snap.sourceSize, refreshRateHz: snap.refreshRateHz,
                onVideo: vHandler,
                onAudio: aHandler
            )
            if let pf = videoPixelFormat { capture.videoPixelFormat = pf }
            capture.excludingWindows = excludeWindows
            try await capture.start()
            captures[snap.id] = capture
        }
        isRunning = true
        DKLog.capture.info("协调器启动 \(self.captures.count) 路捕获，排除窗口 \(excludeWindows.count) 个")
    }

    public func stop() async {
        await withTaskGroup(of: Void.self) { group in
            for (_, capture) in captures {
                group.addTask { await capture.stop() }
            }
        }
        captures.removeAll()
        isRunning = false
    }

    /// 各屏统计快照（UI 容量/掉帧告警用）
    public func allStats() -> [UInt32: CaptureStats] {
        var out: [UInt32: CaptureStats] = [:]
        for (id, capture) in captures { out[id] = capture.stats }
        return out
    }

    /// 编码完成回计数（计算真实掉帧率）
    public func noteEncoded(displayID: UInt32) {
        captures[displayID]?.noteEncoded()
    }

    public func runningDisplayIDs() -> [UInt32] { Array(captures.keys) }
}
