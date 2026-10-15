import Foundation
import ServiceManagement
import DKCore

/// 桌面图标显隐：写 Finder 偏好 `CreateDesktop` 并重启 Finder 生效。
/// CreateDesktop = true（默认）显示桌面图标；false 隐藏。
/// 非沙盒 ad-hoc 构建下 `/usr/bin/defaults` + `killall Finder` 可行。
@MainActor
enum DesktopIcons {
    /// 当前是否已隐藏桌面图标（读失败按「未隐藏」处理）。
    static func isHidden() -> Bool {
        let out = run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `defaults read` 对 bool 输出 "0" / "1"
        return out == "0"
    }

    static func setHidden(_ hidden: Bool) {
        _ = run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop",
                                      "-bool", hidden ? "false" : "true"])
        _ = run("/usr/bin/killall", ["Finder"])
    }

    /// 读→切换→返回切换后的新状态（true = 已隐藏）。
    @discardableResult
    static func toggle() -> Bool {
        let nowHidden = isHidden()
        setHidden(!nowHidden)
        return !nowHidden
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 开机自启（macOS 13+ 的 SMAppService.mainApp）。
@MainActor
enum LaunchAtLogin {
    static var isAvailable: Bool { true }   // 目标 macOS 14，恒可用

    /// 是否已登记为登录项。
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 设置开关；返回是否成功。失败时调用方提示去「系统设置 → 通用 → 登录项」。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
