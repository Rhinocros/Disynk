import AppKit
import SwiftUI

/// Element Plus 风格的界面基调：设计令牌见 EPTheme.swift，这里保留导航分区、卡片容器、
/// 浮层背板与面板标题行等交互骨架，视觉实现全部经 EP 令牌取色（深浅色自适应）。

// MARK: - 导航分区（左栏）

enum NavSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case record = "录制"
    case shot = "截图 / OCR"
    case shortcuts = "快捷键"
    case virtual = "虚拟屏"
    case permission = "权限"
    case about = "关于"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .record: return "record.circle"
        case .shot: return "text.viewfinder"
        case .shortcuts: return "keyboard"
        case .virtual: return "display.2"
        case .permission: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 主题

enum Theme {
    /// 页面画布背景（--el-bg-color-page）。
    static let canvas = EP.bgPage
    /// 卡片填充（--el-bg-color）。
    static let cardFill = EP.bgCard
    /// 品牌强调色：Element Plus 主色蓝。
    static let accent = EP.primary

    /// 大窗卡片圆角（--el-border-radius-base）。
    static let cornerRadius: CGFloat = EP.radius
    /// 浮层面板圆角。
    static let panelCornerRadius: CGFloat = EP.radiusPanel
    /// 卡片/面板描边（--el-border-color）。
    static let cardStroke = EP.borderBase
    /// 浮层阴影：透出桌面时阴影更明显以与背景拉开层次。
    static let panelShadowColor = Color.black.opacity(0.28)
    static let panelShadowRadius: CGFloat = 16
}

// MARK: - 浮层面板标题行

/// 面板自绘标题行：左标题 + 右关闭按钮。
/// 系统交通灯在 `fullSizeContentView + nonactivatingPanel + floating` 的浮层上反复出现
/// “看得见但点不着”（首击只用于激活窗口，且命中区域被内容视图抢走），
/// 因此面板统一隐藏标准按钮，改用一定可点的自绘 X。
struct PanelHeader: View {
    var title: String
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.09), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }
}

extension NSWindow {
    /// 隐藏标准交通灯（关闭/最小化/缩放）。浮层面板统一自绘关闭按钮，
    /// 避免“看得到交通灯但点不着”的歧义。
    func hideStandardWindowButtons() {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
    }
}

// MARK: - 透出桌面的 vibrancy 承载视图

/// 用 AppKit `NSVisualEffectView` 作 SwiftUI 背板，`behindWindow` 混合模式真实透出桌面；
/// `state = .active` 保证面板非 key 窗（浮层常不抢焦点）也持续呈现 vibrant 材质。
struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// 浮层面板背板：透出桌面 + 叠一层接近不透明的窗体色。
/// （早期额外叠的顶部 50pt 深色带会在标题上方露出一截“半透明条”，已按需求移除。）
struct PanelBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            VibrancyBackground(material: .hudWindow)
            Color(nsColor: EP.dyn(EP.rgb(0xFFFFFF, 0.94), EP.rgb(0x1D1E1F, 0.96)))
        }
    }
}

// MARK: - 卡片容器

/// EP 卡片：实底 --el-bg-color + 1px --el-border-color 描边 + 4pt 圆角 + 轻阴影；
/// 标题 16pt semibold、副标题 12pt，标题与内容间以 border-lighter 分隔（对齐 el-card header）。
struct CardModifier: ViewModifier {
    var title: String?
    var subtitle: String?
    /// 是否撑满所在网格行高（EPGridCardStack 同行卡片等高对齐）。
    /// 非网格场景（如录制页 HSplitView 里与自适应卡片同列）需传 false，避免与兄弟卡片抢高度。
    var fill: Bool = true

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: EP.fontTitle, weight: .semibold))
                        .foregroundStyle(EP.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: EP.fontCaption)).foregroundStyle(EP.textSecondary)
                    }
                }
                Rectangle().fill(EP.borderLighter).frame(height: 1)
                    .padding(.vertical, 12)
            }
            content
        }
        .padding(EP.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil,
               alignment: fill ? .topLeading : .leading)
        .background(
            RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .fill(EP.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EP.radius, style: .continuous)
                .strokeBorder(EP.borderBase, lineWidth: 1)
        )
        .shadow(color: EP.cardShadow, radius: 6, x: 0, y: 2)
    }
}

extension View {
    /// 包裹为卡片；可选标题/副标题。fill=false 时不撑满网格行高（仅录制页等非网格列使用）。
    func card(_ title: String? = nil, subtitle: String? = nil, fill: Bool = true) -> some View {
        modifier(CardModifier(title: title, subtitle: subtitle, fill: fill))
    }
}

/// 卡片列：纵向（或横向）堆叠多张卡片的页面根容器（带画布背景与 EP 正文前景色）。
struct CardStack<Content: View>: View {
    var horizontal: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if horizontal {
                HStack(alignment: .top, spacing: 20) { content }
            } else {
                VStack(alignment: .leading, spacing: 20) { content }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(EP.bgPage)
        .foregroundStyle(EP.textPrimary)
    }
}

/// 双列卡片网格：对齐 Element Plus overview 页的组件卡片排布；
/// 窄窗口自动降为单列，卡片内容照旧用 `.card(...)` 修饰。
struct EPGridCardStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 20)],
                      alignment: .leading, spacing: 20) {
                content
            }
            .padding(20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(EP.bgPage)
        .foregroundStyle(EP.textPrimary)
    }
}
