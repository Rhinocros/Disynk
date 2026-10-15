import AppKit
import DKCore
import SwiftUI

// MARK: - 关于：版本信息与协议文本

/// 版本/版权等信息全部取自 bundle（Info.plist 是版本事实源），协议文本内置。
enum AboutInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "开发构建"
    }
    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.disynk.app" }
    static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var copyright: String { "版权所有 © Disynk · 本程序以 GPL-3.0-or-later 发布（含第七条署名附加条款）" }
    /// 项目源地址：再分发与修改版都必须保留它，界面里的可点击链接也指向这里。
    static let projectURL = URL(string: "https://github.com/Rhinocros/Disynk")!
    static var tagline: String { "多屏录制 · 截图 · 本地 OCR" }

    /// 「复制版本信息」用的纯文本（反馈问题时一次性贴全）。
    static func summaryText() -> String {
        """
        Disynk \(version) (\(build))
        Bundle ID：\(bundleID)
        系统版本：\(systemVersion)
        源码与许可：\(AboutInfo.projectURL.absoluteString)
        """
    }
}

/// 协议种类（关于页分段切换）。
enum AgreementKind: String, CaseIterable, Identifiable {
    case eula = "开源许可与署名"
    case privacy = "隐私政策"
    case thirdParty = "第三方与开源"

    var id: String { rawValue }

    var text: String {
        switch self {
        case .eula:
            return """
            Disynk 开源许可与署名要求

            1. 许可基座
            本程序是自由软件：你可以在 GNU 通用公共许可证第 3 版（GPL-3.0）或其后任一版本
            的条款下再分发和/或修改它。完整条款见随包的 LICENSE 文件。

            2. 再分发与修改版必须保留的标注
            • 项目源地址 \(AboutInfo.projectURL.absoluteString) 与来源标注（说明该版本源自 Disynk 项目）；
            • 应用界面中一处可点击的项目链接（本「关于」页即是，不得移除也不得降级为不可点击文本）；
            • LICENSE（GPL-3.0 原文）、ADDITIONAL-TERMS.md（第七条附加条款）与 THIRD-PARTY-NOTICES.md 的完整文本。
            以上属 GPL-3.0 第七条(b)(c) 允许附加的合理条款（详见 ADDITIONAL-TERMS.md），随修改版一并传递。

            3. 修改版不可闭源
            你对外提供的衍生版本必须整体沿用 GPL-3.0-or-later，并随二进制提供完整对应源码；
            不得闭源分发，不得去除许可文本、署名或链接。把修改版部署到服务器上供他人使用，
            同样要按这一条款公开对应源码。

            4. 免责声明
            软件按「现状」提供，不作任何明示或默示保证，包括适销性、特定用途适用性与不侵权。
            不对因系统更新、私有 API 变更（虚拟屏依赖 macOS 未公开接口，大版本更新后可能失效）、
            权限撤销或存储介质故障导致的录制内容丢失承担责任。请在重要录制前先用短片测试。

            本页面文本为产品内置摘要，与随包 LICENSE 不一致时以 LICENSE 为准。
            """

        case .privacy:
            return """
            Disynk 隐私政策

            1. 本地处理
            屏幕内容、麦克风录音、摄像头画面与 OCR 识别全部在本机完成；文字识别使用 macOS
            内置 Vision 框架，不调用任何在线识别服务。录制与截图产物只写入你选择的输出目录。

            2. 收集的信息
            软件本身不联网：不收集使用数据、不投放广告、不含任何第三方统计或埋点 SDK，
            也不生成或上传设备标识。录制、截图与 OCR 全程离线完成。

            3. 权限用途
            屏幕录制=采集画面；麦克风=录制语音解说；辅助功能=点击/快捷键覆盖层与全局快捷键；
            自动化=窗口布局整理。任一权限缺失只影响对应功能，不会退化采集其它数据。

            4. 日志
            诊断日志写入系统「控制台」的应用日志，仅含功能状态与错误描述，不含屏幕像素内容；
            你可以在反馈时自行决定是否附上。

            5. 变更
            政策更新会在新版本的本页面的「关于 → 隐私政策」中体现，重大变更会另行公告。
            """
        case .thirdParty:
            return """
            第三方组件与开源许可

            • libvpx（BSD-3-Clause）——可选装配，用于 WebM/VP8·VP9 编码；未装配时 WebM 产出不可用。
            • Apple Vision / CoreImage / Metal / VideoToolbox / AVFoundation——随 macOS 提供，
              受 macOS 系统软件许可条款约束。
            • SF Symbols——Apple 提供，按 Apple 使用条款用于界面图标。

            Disynk 自身代码以 GPL-3.0-or-later 发布（附加上述署名条款）。
            上述组件的完整许可文本随其源码分发，可在对应项目仓库查阅。
            """
        }
    }
}

// MARK: - 关于页（主窗口「关于」分区；菜单栏「关于 Disynk…」直达）

struct AboutTab: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: AgreementKind = .eula
    @State private var copied = false

    var body: some View {
        EPGridCardStack {
            header
            agreement
            footnotes
        }
    }

    // 品牌区：图标 + 名称 + 版本；源码与许可单独一张卡（界面里的可点击链接即附加条款要求的那一处）
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: AboutInfo.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Disynk").font(.system(size: 26, weight: .semibold))
                    Text(AboutInfo.tagline).font(.callout).foregroundStyle(.secondary)
                    Text("版本 \(AboutInfo.version)（构建 \(AboutInfo.build)）")
                        .font(.system(.body, design: .monospaced))
                    Text(AboutInfo.copyright).font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button(copied ? "已复制" : "复制版本信息") { copySummary() }
                            .epButton(small: true)
                        Button("打开输出目录") { model.openOutputDirectory() }
                            .epButton(small: true)
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .card("关于")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Link(AboutInfo.projectURL.absoluteString, destination: AboutInfo.projectURL)
                        .font(.callout)
                    Spacer()
                }
                Text("本程序以 GPL-3.0-or-later 发布；再分发或修改须保留上面这个源地址、本界面的可点击链接与许可文本。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("系统版本：\(AboutInfo.systemVersion)　·　Bundle ID：\(AboutInfo.bundleID)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card("源码与许可")
        }
    }

    // 协议区：分段切换 + 可滚动正文
    private var agreement: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("协议", selection: $kind) {
                ForEach(AgreementKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            ScrollView {
                Text(kind.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
        }
        .card("软件协议", subtitle: "许可 / 隐私 / 第三方组件；正文可选中复制")
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("虚拟屏功能依赖 macOS 未公开接口（CGVirtualDisplay），系统大版本更新后可能失效，届时将降级提示。",
                  systemImage: "exclamationmark.triangle")
            Label("直发版本每次重编译会改变代码签名身份，屏幕录制等权限需重新勾选（见「权限」页指引）。",
                  systemImage: "lock.shield")
            Label("本版无自动更新检查；升级由下载页替换 dmg 完成。",
                  systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .card("说明")
    }

    private func copySummary() {
        let s = AboutInfo.summaryText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copied = true
        model.statusLine = "版本信息已复制到剪贴板"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

extension AboutInfo {
    /// 关于页展示的应用图标：优先 bundle 里的 AppIcon.icns（与 Dock 同一份），
    /// 取不到时回退系统对当前应用的图标记录。
    static var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
