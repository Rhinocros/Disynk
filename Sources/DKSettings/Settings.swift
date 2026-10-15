import Foundation
import DKCore

/// 录制产出格式（开始录制时直接选择，不再离线导出）：
/// - video：现有 编码器→封装 管线直出容器文件
/// - webm / gif：内部仍录 mp4 中间产物，停止后自动转码并删除中间文件
public enum RecordOutputFormat: String, Sendable, CaseIterable, Codable, Identifiable {
    case video
    case webm
    case gif

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .video: return "视频"
        case .webm: return "WebM"
        case .gif: return "GIF"
        }
    }
}

/// 窗口录制的背景（仅对窗口来源生效）：
/// - transparent：保留 alpha（BGRA 采集），录出可透背景（GIF/WebM 真保留；MP4 容器会把 alpha 压平为黑底）。
/// - customImage(path)：把窗口帧合成到指定壁纸图之上再编码（CoreGraphics 逐帧合成）。
public enum WindowBackground: Sendable, Hashable, Codable {
    case transparent
    case customImage(String)

    public var displayName: String {
        switch self {
        case .transparent: return "透明"
        case .customImage: return "自定义壁纸"
        }
    }
}

/// 一个快捷键组合：物理 keyCode + NSEvent.ModifierFlags.rawValue（存 UInt 避免依赖 AppKit）。
public struct KeyCombo: Sendable, Hashable, Codable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 按键覆盖层显示模式
public enum KeyDisplayMode: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case allKeys       // 显示所有按键
    case shortcutsOnly // 仅显示含修饰键的快捷键（如 ⌘⇧3）

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .allKeys: return "所有按键"
        case .shortcutsOnly: return "仅快捷键"
        }
    }
}

/// 截图保存格式。png/jpeg/heic 走系统 ImageIO；webp 走 libvpx VP8 软编单帧封装
///（仅 DISYNK_WITH_LIBVPX=1 装配构建可用，否则保存时报错并回退 PNG）。
/// 放弃 AVIF：macOS 15 ImageIO 无 AVIF 编码（实测 CGImageDestination 失败），需另 vendor libavif+aom，性价比低。
public enum ShotFormat: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case png, jpeg, heic, webp

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .png: return "PNG（无损）"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        }
    }
    /// 文件扩展名
    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }
    /// ImageIO 目的地类型（webp 不走 ImageIO，返回 nil）
    public var imageIOType: String? {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .webp: return nil
        }
    }
    /// 有损格式（需指定质量；JPEG 不支持透明需压平白底）
    public var isLossy: Bool { self != .png }
}

/// 可绑定全局快捷键的核心操作。
public enum ShortcutAction: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case openShotPanel
    case openRecordPanel
    case record
    case recordVideo
    case recordGIF
    case recordWebM
    case shotFull
    case shotRegion
    case shotWindow
    case toggleDesktopIcons

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .openShotPanel: return "打开 / 关闭截图面板"
        case .openRecordPanel: return "打开 / 关闭录屏面板"
        case .record: return "开始 / 停止录制"
        case .recordVideo: return "录制视频"
        case .recordGIF: return "录制 GIF"
        case .recordWebM: return "录制 WebM"
        case .shotFull: return "全屏截图"
        case .shotRegion: return "区域截图"
        case .shotWindow: return "窗口截图"
        case .toggleDesktopIcons: return "隐藏 / 显示桌面图标"
        }
    }
}

/// 一次录制的完整参数（默认值 + 每屏覆盖）
public struct RecordingSettings: Sendable, Hashable, Codable {
    public var codec: VideoCodec = .hevc
    public var container: ContainerFormat = .mp4
    public var quality: QualityTier = .high
    public var resolution: ResolutionMode = .native
    public var frameRate: FrameRate = .p60
    public var keyframeIntervalSeconds: Int = 2
    public var outputMode: OutputMode = .separateFiles
    /// 录制产出格式（视频/WebM/GIF）
    public var outputFormat: RecordOutputFormat = .video
    public var captureCursor: Bool = true
    public var captureSystemAudio: Bool = true
    public var captureMicrophone: Bool = false
    /// 点击效果覆盖层开关（方案 M4：独立开关）
    public var overlayClickEffects: Bool = true
    /// 快捷键显示覆盖层开关（默认开：录制时实时显示按下的快捷键）
    public var overlayShortcutDisplay: Bool = true
    /// 覆盖层是否录入画面（关闭=仅本机可见，需 SCK 排除窗口实现）
    public var overlayIncludedInRecording: Bool = true
    /// 延迟录制秒数（0=不延迟；>0 起录前倒计时）
    public var recordDelaySeconds: Int = 0
    /// 窗口录制的背景（透明 / 自定义壁纸）
    public var windowBackground: WindowBackground = .transparent
    /// 录屏时是否将本软件自身窗口排除在画面之外（true=排除，软件界面不出现在录制中）
    public var excludeOwnWindows: Bool = true
    /// 按键覆盖层显示模式：所有按键 / 仅快捷键
    public var overlayKeyMode: KeyDisplayMode = .shortcutsOnly
    /// 按键覆盖层水平位置（0=左，0.5=居中，1=右）
    public var overlayKeyPositionX: Double = 0.5
    /// 按键覆盖层垂直位置（0=底部，1=顶部）
    public var overlayKeyPositionY: Double = 0.08
    /// 自定义文件名格式（支持变量：{date} {time} {datetime} {display} {index}）
    /// 纯常量或留空时自动追加 -{datetime}-{display}
    public var filenameFormat: String = "Disynk-{datetime}-{display}"

    public init() {}

    // 宽容解码：新增字段（如 outputFormat）在旧版持久化 JSON 中缺失时取默认值，
    // 避免设置整体回退重置。
    private enum CodingKeys: String, CodingKey {
        case codec, container, quality, resolution, frameRate, keyframeIntervalSeconds
        case outputMode, outputFormat, captureCursor, captureSystemAudio, captureMicrophone
        case overlayClickEffects, overlayShortcutDisplay, overlayIncludedInRecording
        case recordDelaySeconds, windowBackground, excludeOwnWindows
        case overlayKeyMode, overlayKeyPositionX, overlayKeyPositionY, filenameFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        container = try c.decodeIfPresent(ContainerFormat.self, forKey: .container) ?? d.container
        quality = try c.decodeIfPresent(QualityTier.self, forKey: .quality) ?? d.quality
        resolution = try c.decodeIfPresent(ResolutionMode.self, forKey: .resolution) ?? d.resolution
        frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate) ?? d.frameRate
        keyframeIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .keyframeIntervalSeconds) ?? d.keyframeIntervalSeconds
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? d.outputMode
        outputFormat = try c.decodeIfPresent(RecordOutputFormat.self, forKey: .outputFormat) ?? d.outputFormat
        captureCursor = try c.decodeIfPresent(Bool.self, forKey: .captureCursor) ?? d.captureCursor
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? d.captureSystemAudio
        captureMicrophone = try c.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? d.captureMicrophone
        overlayClickEffects = try c.decodeIfPresent(Bool.self, forKey: .overlayClickEffects) ?? d.overlayClickEffects
        overlayShortcutDisplay = try c.decodeIfPresent(Bool.self, forKey: .overlayShortcutDisplay) ?? d.overlayShortcutDisplay
        overlayIncludedInRecording = try c.decodeIfPresent(Bool.self, forKey: .overlayIncludedInRecording) ?? d.overlayIncludedInRecording
        recordDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .recordDelaySeconds) ?? d.recordDelaySeconds
        windowBackground = try c.decodeIfPresent(WindowBackground.self, forKey: .windowBackground) ?? d.windowBackground
        excludeOwnWindows = try c.decodeIfPresent(Bool.self, forKey: .excludeOwnWindows) ?? d.excludeOwnWindows
        overlayKeyMode = try c.decodeIfPresent(KeyDisplayMode.self, forKey: .overlayKeyMode) ?? d.overlayKeyMode
        overlayKeyPositionX = try c.decodeIfPresent(Double.self, forKey: .overlayKeyPositionX) ?? d.overlayKeyPositionX
        overlayKeyPositionY = try c.decodeIfPresent(Double.self, forKey: .overlayKeyPositionY) ?? d.overlayKeyPositionY
        let decodedName = try c.decodeIfPresent(String.self, forKey: .filenameFormat) ?? d.filenameFormat
        // 旧版本可能持久化过空串：回填默认模板，避免用户看到空白输入框
        filenameFormat = decodedName.isEmpty ? d.filenameFormat : decodedName
    }
}

/// 单屏覆盖参数（方案：每屏独立分辨率/帧率/指针）
public struct DisplayOverride: Sendable, Hashable, Codable {
    public var resolution: ResolutionMode?
    public var frameRate: FrameRate?
    /// nil=继承全局值；true=此屏指针入画；false=此屏不录指针
    public var captureCursor: Bool?

    public init(resolution: ResolutionMode? = nil, frameRate: FrameRate? = nil, captureCursor: Bool? = nil) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.captureCursor = captureCursor
    }

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, captureCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayOverride()
        resolution = try c.decodeIfPresent(ResolutionMode.self, forKey: .resolution) ?? d.resolution
        frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate) ?? d.frameRate
        captureCursor = try c.decodeIfPresent(Bool.self, forKey: .captureCursor)
    }
}

/// 全局设置聚合
public struct AppSettingsSnapshot: Sendable, Hashable, Codable {
    public var recording = RecordingSettings()
    public var perDisplay: [UInt32: DisplayOverride] = [:]
    public var outputDirectoryPath: String =
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Disynk").path
    /// 每个核心操作的自定义快捷键（缺失 = 未绑定）
    public var shortcuts: [ShortcutAction: KeyCombo] = [:]
    /// 截图后是否自动 OCR（关=仅存图不识别；开=截图同时识别文字）。截图面板与主窗口共享此开关。
    public var ocrEnabled: Bool = false
    /// 滚动长截图是否「包含标题栏」。
    /// false（默认）= 拼接前从每帧裁掉顶部标题栏/工具栏（不随滚动移动的顶行），
    ///   并按严格列检测（逐帧列哈希全同）裁掉左右原生固定栏（如浏览器竖排标签栏），缓解拼接重复；
    /// true = 保留顶部固定 UI，仅按重叠/位移去重。（视口裁剪生效时强制按 true 处理。）
    public var scrollCaptureIncludeTitlebar: Bool = false
    /// 截图保存格式（PNG/JPG/HEIC/WebP；默认 PNG 保持旧行为）
    public var screenshotFormat: ShotFormat = .png

    public init() {}

    // 宽容解码：旧 JSON 缺 shortcuts / ocrEnabled 时不报错（同 RecordingSettings）。
    private enum CodingKeys: String, CodingKey {
        case recording, perDisplay, outputDirectoryPath, shortcuts, ocrEnabled
        case scrollCaptureIncludeTitlebar, screenshotFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettingsSnapshot()
        recording = try c.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? d.recording
        perDisplay = try c.decodeIfPresent([UInt32: DisplayOverride].self, forKey: .perDisplay) ?? d.perDisplay
        outputDirectoryPath = try c.decodeIfPresent(String.self, forKey: .outputDirectoryPath) ?? d.outputDirectoryPath
        shortcuts = try c.decodeIfPresent([ShortcutAction: KeyCombo].self, forKey: .shortcuts) ?? d.shortcuts
        ocrEnabled = try c.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? d.ocrEnabled
        scrollCaptureIncludeTitlebar = try c.decodeIfPresent(Bool.self, forKey: .scrollCaptureIncludeTitlebar) ?? d.scrollCaptureIncludeTitlebar
        screenshotFormat = try c.decodeIfPresent(ShotFormat.self, forKey: .screenshotFormat) ?? d.screenshotFormat
    }

    public func effective(for displayID: UInt32) -> RecordingSettings {
        var s = recording
        if let o = perDisplay[displayID] {
            if let r = o.resolution { s.resolution = r }
            if let f = o.frameRate { s.frameRate = f }
            if let cur = o.captureCursor { s.captureCursor = cur }
        }
        return s
    }
}

/// 设置持久化（UserDefaults + JSON）。变更通过 AsyncStream 广播。
public actor SettingsStore {
    private static let defaultsKey = "disynk.settings.v1"

    private var snapshot: AppSettingsSnapshot
    private let defaults: UserDefaults
    private var continuations: [UUID: AsyncStream<AppSettingsSnapshot>.Continuation] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = AppSettingsSnapshot()
        }
        // 一次性迁移：旧版本「按键显示覆盖层」默认关且已被持久化为 false，
        // 新默认值对旧配置不生效 → 首次升级强制打开一次，之后尊重用户手动开关。
        var migrated = false
        let overlayKey = "disynk.migrate.overlayShortcutOn.v1"
        if !defaults.bool(forKey: overlayKey) {
            snapshot.recording.overlayShortcutDisplay = true
            defaults.set(true, forKey: overlayKey)
            migrated = true
        }
        // 一次性迁移：旧版录制面板宽高框定死 1920×1080，任何编辑都会持久化为
        // .custom(1920×1080) → 全屏录制永远 1080p；升级时改回跟随屏幕原生分辨率，
        // 之后尊重用户在设置窗口里手动选定的分辨率。
        let resKey = "disynk.migrate.nativeResolution.v1"
        if !defaults.bool(forKey: resKey) {
            if case .custom(let s) = snapshot.recording.resolution, s.width == 1920, s.height == 1080 {
                snapshot.recording.resolution = .native
            }
            defaults.set(true, forKey: resKey)
            migrated = true
        }
        if migrated {
            // init 处于 nonisolated 上下文，不能调 actor 隔离的 persist()，直接内联写入。
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    public func current() -> AppSettingsSnapshot { snapshot }

    public func updates() -> AsyncStream<AppSettingsSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            continuation.yield(snapshot)
        }
    }

    public func mutate(_ block: (inout AppSettingsSnapshot) -> Void) {
        block(&snapshot)
        persist()
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
