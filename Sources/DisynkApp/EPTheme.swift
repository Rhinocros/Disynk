import AppKit
import SwiftUI

/// Element Plus 设计令牌层：官方浅色 css-var + dark 变量集，经动态 NSColor 随系统外观自动切换。
/// 全 App 颜色只从这里取语义令牌（primary/success/warning/danger、三级文字、三档边框…），
/// 不在页面里散落硬编码 RGB。组件样式原语（按钮/输入框/Tag/Alert）也收口在本文件。

// MARK: - 颜色工具

enum EP {
    /// 0xRRGGBB → sRGB NSColor。
    static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// 颜色混合：t=0 得 a，t=1 得 b（用于推算 light-x / dark-x 衍生色）。
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                       alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t)
    }

    /// 动态色：随所在视图 appearance 在浅/深两套间自动切换。
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static func color(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: dyn(light, dark)) }

    // MARK: - 主题色（明暗同值，衍生态按官方 light-x/dark-x 规则）

    static let primary = Color(nsColor: rgb(0x409EFF))
    static let primaryHover = Color(nsColor: rgb(0x66B1FF))   // light-3
    static let primaryActive = Color(nsColor: rgb(0x337ECC))  // dark-2
    static let success = Color(nsColor: rgb(0x67C23A))
    static let successHover = Color(nsColor: rgb(0x95D475))
    static let successActive = Color(nsColor: rgb(0x529B2E))
    static let warning = Color(nsColor: rgb(0xE6A23C))
    static let warningHover = Color(nsColor: rgb(0xEEBE77))
    static let warningActive = Color(nsColor: rgb(0xB88230))
    static let danger = Color(nsColor: rgb(0xF56C6C))
    static let dangerHover = Color(nsColor: rgb(0xF89898))
    static let dangerActive = Color(nsColor: rgb(0xC45656))
    static let info = Color(nsColor: rgb(0x909399))
    static let infoHover = Color(nsColor: rgb(0xA6A9AD))
    static let infoActive = Color(nsColor: rgb(0x74767A))

    // MARK: - 文字（--el-text-color-*）：n 前缀为 NSColor 形态（供 AppKit 绘制/验证），无 n 为 SwiftUI 形态

    static let nTextPrimary = dyn(rgb(0x303133), rgb(0xE5EAF3))
    static let nTextRegular = dyn(rgb(0x606266), rgb(0xCFD3DC))
    static let nTextSecondary = dyn(rgb(0x909399), rgb(0xA3A6A8))
    static let nTextPlaceholder = dyn(rgb(0xA8ABB2), rgb(0x8D9298))
    static let nTextDisabled = dyn(rgb(0xC0C4CC), rgb(0x5A5C60))
    static let textPrimary = Color(nsColor: nTextPrimary)
    static let textRegular = Color(nsColor: nTextRegular)
    static let textSecondary = Color(nsColor: nTextSecondary)
    static let textPlaceholder = Color(nsColor: nTextPlaceholder)
    static let textDisabled = Color(nsColor: nTextDisabled)

    // MARK: - 边框（--el-border-color-*）

    static let nBorderBase = dyn(rgb(0xDCDFE6), rgb(0x4C4D4F))
    static let nBorderLight = dyn(rgb(0xE4E7ED), rgb(0x414243))
    static let nBorderLighter = dyn(rgb(0xEBEEF5), rgb(0x363636))
    static let borderBase = Color(nsColor: nBorderBase)
    static let borderLight = Color(nsColor: nBorderLight)
    static let borderLighter = Color(nsColor: nBorderLighter)

    // MARK: - 背景/填充（--el-bg-color* / --el-fill-color*）

    static let nBgPage = dyn(rgb(0xF2F3F5), rgb(0x141414))
    static let nBgCard = dyn(rgb(0xFFFFFF), rgb(0x1D1E1F))
    static let nBgOverlay = dyn(rgb(0xFFFFFF), rgb(0x1D1E1F))
    static let nFillLight = dyn(rgb(0xF5F7FA), rgb(0x262626))
    static let nFillLighter = dyn(rgb(0xFAFAFA), rgb(0x202121))
    static let bgPage = Color(nsColor: nBgPage)
    static let bgCard = Color(nsColor: nBgCard)
    static let bgOverlay = Color(nsColor: nBgOverlay)
    static let fillLight = Color(nsColor: nFillLight)
    static let fillLighter = Color(nsColor: nFillLighter)

    /// 卡片轻阴影（对应 box-shadow-light 的桌面化收敛）。
    static let cardShadow = Color.black.opacity(0.08)

    // MARK: - 语义浅底（light-9 混合规则：浅=白色掺 10%，深=卡底掺 16%）

    /// `soft(base, role, t)` 的快捷产出：primary/success/warning/danger/info 浅底与浅描边。
    static func nSoft(_ role: NSColor) -> NSColor {
        dyn(mix(.white, role, 0.10), mix(rgb(0x1D1E1F), role, 0.16))
    }
    static func nSoftBorder(_ role: NSColor) -> NSColor {
        dyn(mix(.white, role, 0.30), mix(rgb(0x1D1E1F), role, 0.36))
    }
    static func soft(_ role: NSColor) -> Color { Color(nsColor: nSoft(role)) }
    static func softBorder(_ role: NSColor) -> Color { Color(nsColor: nSoftBorder(role)) }
    /// 主色浅底（选中菜单项、primary plain tag 等）。
    static let nPrimarySoft = nSoft(rgb(0x409EFF))
    static let primarySoft = Color(nsColor: nPrimarySoft)
    /// 主色浅描边。
    static let primarySoftBorder = softBorder(rgb(0x409EFF))

    // MARK: - 按键覆盖层预览令牌（MainWindow 拖拽预览框）
    // 画布与胶囊模拟「录进视频后的画面」：视频内容不随系统外观变化，故取固定值；
    // 胶囊底色与 DKOverlay 按键横幅（black 60% 底 + 白字）保持一致，预览框描边走窗口 chrome 边框令牌。

    static let previewScreen = NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1)
    static let previewPill = NSColor(white: 0, alpha: 0.70)
    static let previewBorder = nBorderBase

    // MARK: - 排版 / 圆角 / 间距

    static let fontCaption: CGFloat = 12
    static let fontBody: CGFloat = 14
    static let fontTitle: CGFloat = 16
    static let radius: CGFloat = 4        // --el-border-radius-base
    static let radiusPanel: CGFloat = 10  // 浮层窗体（EP dialog 观感的桌面放大版）
    static let cardPadding: CGFloat = 20  // --el-card-padding

    // MARK: - 角色色查询（Tag/Alert 共用）

    enum Role {
        case primary, success, warning, danger, info

        var base: NSColor {
            switch self {
            case .primary: return rgb(0x409EFF)
            case .success: return rgb(0x67C23A)
            case .warning: return rgb(0xE6A23C)
            case .danger: return rgb(0xF56C6C)
            case .info: return rgb(0x909399)
            }
        }
        var color: Color { Color(nsColor: base) }
        var soft: Color { EP.soft(base) }
        var softBorder: Color { EP.softBorder(base) }
    }
}

// MARK: - 按钮样式（EP Button：primary/default/danger/success + small 尺寸）

struct EPButtonStyle: ButtonStyle {
    enum Role { case primary, plain, danger, success }
    var role: Role = .plain
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        EPButtonLabel(configuration: configuration, role: role, small: small)
    }
}

private struct EPButtonLabel: View {
    let configuration: EPButtonStyle.Configuration
    let role: EPButtonStyle.Role
    var small: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    /// 常态/悬停/按压三段底色与描边（default 走官方「描边变主色」规则）。
    private var palette: (bg: Color, fg: Color, stroke: Color) {
        let hover = hovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        switch role {
        case .primary, .danger, .success:
            let (base, hv, ac) = switch role {
            case .primary: (EP.primary, EP.primaryHover, EP.primaryActive)
            case .danger: (EP.danger, EP.dangerHover, EP.dangerActive)
            default: (EP.success, EP.successHover, EP.successActive)
            }
            let bg = pressed ? ac : (hover ? hv : (isEnabled ? base : EP.fillLight))
            return (bg, isEnabled ? .white : EP.textDisabled, bg)
        case .plain:
            let accent = pressed ? EP.primaryActive : (hover ? EP.primary : EP.textRegular)
            let stroke = hover ? (pressed ? EP.primaryActive : EP.primary) : EP.borderBase
            return (isEnabled ? EP.bgCard : EP.fillLight,
                    isEnabled ? accent : EP.textDisabled,
                    hover ? (pressed ? EP.primaryActive : EP.primarySoftBorder) : (isEnabled ? stroke : EP.borderLight))
        }
    }

    var body: some View {
        let p = palette
        configuration.label
            .font(.system(size: small ? EP.fontCaption : EP.fontBody))
            .foregroundStyle(p.fg)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? 24 : 32)
            .background(RoundedRectangle(cornerRadius: EP.radius).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: EP.radius).strokeBorder(p.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: EP.radius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    func epButton(_ role: EPButtonStyle.Role = .plain, small: Bool = false) -> some View {
        buttonStyle(EPButtonStyle(role: role, small: small))
    }
}

// MARK: - 输入框样式（EP Input：实底 + 1px 描边 + 4 圆角）

/// 先强制 `.plain` 去掉系统 bezel，再自绘单层描边，并禁用聚焦描边环，
/// 保证任何状态下都只有一层外框（修掉数字框/激活码框的“双层框”）。
struct EPFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: EP.fontBody))
            .foregroundStyle(EP.textRegular)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: EP.radius).fill(EP.bgCard))
            .overlay(RoundedRectangle(cornerRadius: EP.radius).strokeBorder(EP.borderBase, lineWidth: 1))
            .focusEffectDisabled()
    }
}

extension View {
    func epField() -> some View { modifier(EPFieldModifier()) }
}

// MARK: - 标签（EP Tag：语义浅底 + 同系描边）

struct EPTag: View {
    var text: String
    var role: EP.Role = .info
    var body: some View {
        Text(text)
            .font(.system(size: EP.fontCaption))
            .foregroundStyle(role.color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: EP.radius).fill(role.soft))
            .overlay(RoundedRectangle(cornerRadius: EP.radius).strokeBorder(role.softBorder, lineWidth: 1))
    }
}

// MARK: - 提示条（EP Alert：语义浅底 + 图标 + 13pt 文案）

struct EPAlert: View {
    enum Kind {
        case info, success, warning, error
        var role: EP.Role {
            switch self {
            case .info: return .info
            case .success: return .success
            case .warning: return .warning
            case .error: return .danger
            }
        }
        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
    var kind: Kind = .info
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(kind.role.color)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(EP.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: EP.radius).fill(kind.role.soft))
        .overlay(RoundedRectangle(cornerRadius: EP.radius).strokeBorder(kind.role.softBorder, lineWidth: 1))
    }
}
