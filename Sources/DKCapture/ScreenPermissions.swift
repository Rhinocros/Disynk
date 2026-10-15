import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import DKCore

/// TCC 权限检查与引导（屏幕录制 / 麦克风 / 辅助功能）
public enum ScreenPermissions {
    /// 屏幕录制权限（macOS 11+ 提供 preflight API）
    public static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 弹窗请求；已决定过不会重复弹，未授权时引导去系统设置
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func hasMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 覆盖层 CGEventTap 需要辅助功能权限
    public static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    public static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// 系统设置直达 URL（配合「引导重新授权」流程，方案 M7 路径 A）
    public static func openPrivacyPane(_ pane: Pane) {
        let map: [Pane: String] = [
            .screenRecording: "Privacy_ScreenCapture",
            .microphone: "Privacy_Microphone",
            .accessibility: "Privacy_Accessibility",
        ]
        let url = "x-apple.systempreferences:com.apple.preference.security?\(map[pane]!)"
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    public enum Pane: Sendable { case screenRecording, microphone, accessibility }

    /// 授予状态查询（供 UI 展示，不弹系统框）。
    public static func isGranted(_ pane: Pane) -> Bool {
        switch pane {
        case .screenRecording: return hasScreenRecording()
        case .microphone:      return hasMicrophone()
        case .accessibility:   return hasAccessibility()
        }
    }

    /// 权限对应的 `tccutil` 服务标识（Apple 规范 token）。纯映射，可离线单测。
    public static func tccutilService(for pane: Pane) -> String {
        switch pane {
        case .screenRecording: return "ScreenCapture"
        case .microphone:      return "Microphone"
        case .accessibility:   return "Accessibility"
        }
    }

    /// 「引导重新授权」命令提示（方案 M7 路径 A）。
    /// ad-hoc/自签每次重编译 cdhash 变化，TCC 按代码身份记忆的授权失效，
    /// 需 `tccutil reset <service> <bundleID>` 后重新勾选。`bundleID` 为空时省略
    /// （全量重置该服务），避免把非法空参数拼进命令。纯字符串逻辑，可离线单测。
    public struct ReauthHint: Sendable, Equatable {
        public let serviceToken: String
        public let command: String
        public let pane: Pane
        public init(serviceToken: String, command: String, pane: Pane) {
            self.serviceToken = serviceToken; self.command = command; self.pane = pane
        }
    }

    public static func reauthorizationHint(bundleID: String, pane: Pane) -> ReauthHint {
        let svc = tccutilService(for: pane)
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = trimmed.isEmpty ? "tccutil reset \(svc)" : "tccutil reset \(svc) \(trimmed)"
        return ReauthHint(serviceToken: svc, command: cmd, pane: pane)
    }

    /// 当前 App bundle 标识（命令行/测试环境可能为 nil → 返回空串，命令回退为全量重置）。
    public static func currentBundleID() -> String {
        Bundle.main.bundleIdentifier ?? ""
    }
}
