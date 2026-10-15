import DKCore
import Foundation
import ScreenCaptureKit

/// 可录制窗口枚举（窗口录制下拉列表）：SCShareableContent 普通层窗口，排除桌面与本进程窗口。
public enum WindowEnumerator {
    public static func available(excludingProcessID pid: pid_t = getpid()) async throws -> [WindowSnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DKLog.capture.error("SCShareableContent(窗口) 获取失败: \(error.localizedDescription, privacy: .public)")
            throw DKError.captureStream("无法获取可录制窗口：\(error.localizedDescription)")
        }
        var result: [WindowSnapshot] = []
        for w in content.windows {
            guard w.windowLayer == 0,                          // 普通层（跳过菜单/提示/桌面控件）
                  w.frame.width >= 20, w.frame.height >= 20,
                  Int(w.owningApplication?.processID ?? -1) != Int(pid),
                  let app = w.owningApplication else { continue }
            // applicationName 桥接为 IUO：先收成 String? 再取默认值，避免隐式强解包崩溃
            let rawName: String? = app.applicationName
            result.append(WindowSnapshot(
                id: w.windowID,
                title: w.title ?? "",
                appName: rawName ?? "?",
                size: PixelSize(width: Int(w.frame.width), height: Int(w.frame.height))))
        }
        // 应用名 + 标题排序，列表稳定可读
        result.sort { ($0.appName, $0.title) < ($1.appName, $1.title) }
        return result
    }
}
