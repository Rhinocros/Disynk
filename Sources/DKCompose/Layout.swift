import DKCore
import Foundation

/// 合并录制的布局模型（方案 M2.5：横/竖/混合预设 + 拖拽自由摆放）
/// 坐标系：画布归一化 [0,1]×[0,1]，编辑器 UI 与合成器共用同一模型
public struct ComposeLayout: Sendable, Hashable, Codable {
    public struct Placement: Sendable, Hashable, Codable {
        public var displayID: UInt32
        /// 画布内归一化矩形（origin 左上）
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        /// 该路屏真实像素尺寸（0 = 未知）。布局块按 1:1 像素摆放，编辑器据此显示
        /// 真实分辨率（旧版把单元定死 1920x1080，2K 屏在布局里被显示成 1080p）。
        public var sourceWidth: Int
        public var sourceHeight: Int

        public init(displayID: UInt32, x: Double, y: Double, w: Double, h: Double,
                    sourceWidth: Int = 0, sourceHeight: Int = 0) {
            self.displayID = displayID
            self.x = x; self.y = y; self.w = w; self.h = h
            self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        }

        /// 真实像素尺寸（未知时按当前画布反推）
        public func pixelSize(canvas: PixelSize) -> PixelSize {
            sourceWidth > 0 && sourceHeight > 0
                ? PixelSize(width: sourceWidth, height: sourceHeight)
                : PixelSize(width: max(1, Int((w * Double(canvas.width)).rounded())),
                            height: max(1, Int((h * Double(canvas.height)).rounded())))
        }

        /// 像素矩形（画布尺寸给定，偶数对齐）
        public func pixelRect(canvas: PixelSize) -> (x: Int, y: Int, w: Int, h: Int) {
            (x: Int((x * Double(canvas.width)).rounded()),
             y: Int((y * Double(canvas.height)).rounded()),
             w: Int((w * Double(canvas.width)).rounded()),
             h: Int((h * Double(canvas.height)).rounded()))
        }
    }

    public var canvasWidth: Int
    public var canvasHeight: Int
    public var placements: [Placement]

    public var canvas: PixelSize { PixelSize(width: canvasWidth, height: canvasHeight) }

    public init(canvasWidth: Int, canvasHeight: Int, placements: [Placement]) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.placements = placements
    }

    // MARK: - 预设（方案：横向、竖向、横竖混合网格）

    /// 每块屏按**真实像素 1:1** 摆进 cols×rows 网格；舞台至少留 2×2 个格子，
    /// 使“把两屏从横排拖成上下排”这类操作一开始就有落点（不够时 dragTile 自动扩舞台）。
    /// 旧版把单元格定死为 1920x1080 并把各屏缩放进去 → 2K 屏被降级显示/合成为 1080p。
    private static func tile(_ displays: [DisplaySnapshot], cols: Int, rows: Int) -> ComposeLayout {
        let cols = max(1, cols), rows = max(1, rows)
        let srcs = displays.map { d -> PixelSize in
            d.sourceSize.width > 0 && d.sourceSize.height > 0
                ? d.sourceSize : PixelSize(width: 1920, height: 1080)
        }
        let maxW = max(640, srcs.map(\.width).max() ?? 1920)
        let maxH = max(480, srcs.map(\.height).max() ?? 1080)
        var canvasW = maxW * max(2, cols)
        var canvasH = maxH * max(2, rows)
        canvasW -= canvasW % 2
        canvasH -= canvasH % 2
        let cellW = Double(canvasW) / Double(cols)
        let cellH = Double(canvasH) / Double(rows)
        var placements: [Placement] = []
        for (i, d) in displays.enumerated() {
            let col = i % cols, row = i / cols
            let src = i < srcs.count ? srcs[i] : PixelSize(width: maxW, height: maxH)
            let pw = Double(src.width) / Double(canvasW)
            let ph = Double(src.height) / Double(canvasH)
            // 块在其单元格内居中（保持真实像素尺寸，不缩放）
            let cx = (Double(col) + 0.5) * cellW
            let cy = (Double(row) + 0.5) * cellH
            placements.append(Placement(displayID: d.id,
                                        x: (cx - Double(src.width) / 2) / Double(canvasW),
                                        y: (cy - Double(src.height) / 2) / Double(canvasH),
                                        w: pw, h: ph,
                                        sourceWidth: src.width, sourceHeight: src.height))
        }
        return ComposeLayout(canvasWidth: canvasW, canvasHeight: canvasH, placements: placements)
    }

    public static func horizontal(_ displays: [DisplaySnapshot]) -> ComposeLayout {
        tile(displays, cols: max(displays.count, 1), rows: 1)
    }

    public static func vertical(_ displays: [DisplaySnapshot]) -> ComposeLayout {
        tile(displays, cols: 1, rows: max(displays.count, 1))
    }

    /// 横竖混合网格：近似正方形排布（2 屏横排、3~4 屏 2×2 …）
    public static func mixedGrid(_ displays: [DisplaySnapshot]) -> ComposeLayout {
        let cols = max(1, Int(ceil(sqrt(Double(displays.count)))))
        let rows = max(1, Int(ceil(Double(displays.count) / Double(cols))))
        return tile(displays, cols: cols, rows: rows)
    }

    // MARK: - 编辑器操作（拖拽摆放）

    /// 移动某屏摆放位置（归一化，越界钳制回画布）
    public mutating func move(displayID: UInt32, x: Double, y: Double) {
        guard let i = placements.firstIndex(where: { $0.displayID == displayID }) else { return }
        placements[i].x = min(max(0, x), max(0, 1 - placements[i].w))
        placements[i].y = min(max(0, y), max(0, 1 - placements[i].h))
    }

    /// 拖拽摆放（编辑器专用）：允许拖出舞台边界 —— 需要时自动扩大舞台（各块像素尺寸不变）。
    /// 旧版只能 move（钳回画布），而横排预设下块高 = 画布高 → y 永远只能为 0，
    /// 表现为“两个屏幕没能随意拖动摆放、摆不成上下排列”。
    public mutating func dragTile(displayID: UInt32, x: Double, y: Double) {
        setDragPosition(displayID: displayID, x: x, y: y)
        fitStage()
    }

    /// 拖拽中的即时位置：不钳制、不扩舞台（越界也允许），松手后由 commitDrag 收口。
    /// 若在 onChanged 里就 fitStage，画布会在一次拖动中途被放大并重映射归一化坐标，
    /// 与拖起瞬间快照的 dragOrigin 失配 → 块在边界处来回跳变。
    public mutating func setDragPosition(displayID: UInt32, x: Double, y: Double) {
        guard let i = placements.firstIndex(where: { $0.displayID == displayID }) else { return }
        placements[i].x = min(max(x, -2), 2)
        placements[i].y = min(max(y, -2), 2)
    }

    /// 松手：把舞台撑到罩住所有块。
    public mutating func commitDrag() { fitStage() }

    /// 把舞台撑到能罩住所有块（越界时扩大画布并重映射，块之间相对位置与像素尺寸不变）。
    private mutating func fitStage() {
        guard !placements.isEmpty, canvasWidth > 0, canvasHeight > 0 else { return }
        let W = Double(canvasWidth), H = Double(canvasHeight)
        var minX = 0.0, minY = 0.0, maxX = 1.0, maxY = 1.0
        for p in placements {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x + p.w); maxY = max(maxY, p.y + p.h)
        }
        guard minX < -1e-9 || minY < -1e-9 || maxX > 1 + 1e-9 || maxY > 1 + 1e-9 else { return }
        let spanW = (maxX - minX) * W, spanH = (maxY - minY) * H
        var newW = Int((spanW * 1.125).rounded())     // 四周再留 1/16 边距，便于继续拖
        var newH = Int((spanH * 1.125).rounded())
        newW = max(64, newW - newW % 2)
        newH = max(64, newH - newH % 2)
        let padW = (Double(newW) - spanW) / 2, padH = (Double(newH) - spanH) / 2
        for i in placements.indices {
            placements[i].x = (padW + (placements[i].x - minX) * W) / Double(newW)
            placements[i].y = (padH + (placements[i].y - minY) * H) / Double(newH)
            placements[i].w = placements[i].w * W / Double(newW)
            placements[i].h = placements[i].h * H / Double(newH)
        }
        canvasWidth = newW
        canvasHeight = newH
    }

    /// 输出画布 = 所有块的并集包围盒（去掉舞台空白边距）：怎么摆放就怎么合并，不留黑边。
    /// 各块像素尺寸不变（仅平移 + 归一化基准换为包围盒）。
    public func croppedToContent() -> ComposeLayout {
        guard !placements.isEmpty, canvasWidth > 0, canvasHeight > 0 else { return self }
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        for p in placements {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x + p.w); maxY = max(maxY, p.y + p.h)
        }
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX > 0, spanY > 0, spanX < 0.999 || spanY < 0.999 else { return self }
        var w = Int((spanX * Double(canvasWidth)).rounded())
        var h = Int((spanY * Double(canvasHeight)).rounded())
        w = max(64, w - w % 2)
        h = max(64, h - h % 2)
        var out = ComposeLayout(canvasWidth: w, canvasHeight: h, placements: [])
        out.placements = placements.map { p in
            Placement(displayID: p.displayID,
                      x: (p.x - minX) / spanX, y: (p.y - minY) / spanY,
                      w: p.w / spanX, h: p.h / spanY,
                      sourceWidth: p.sourceWidth, sourceHeight: p.sourceHeight)
        }
        return out
    }

    /// 缩放某屏（以左上为锚）
    public mutating func resize(displayID: UInt32, w: Double, h: Double) {
        guard let i = placements.firstIndex(where: { $0.displayID == displayID }) else { return }
        placements[i].w = min(max(0.05, w), max(0.05, 1 - placements[i].x))
        placements[i].h = min(max(0.05, h), max(0.05, 1 - placements[i].y))
    }

    // MARK: - 选中集变更同步（保留手动拖拽，不重置已有摆放）

    /// 依据新的选中屏集合增量同步 placement：移除已取消勾选的屏，为新增勾选的屏
    /// 按近似网格分配初始位（避开现有块），**不改动**已存在屏的 x/y/w/h。
    /// 与 SCStream/拖拽解耦，可离线单测（方案：拖拽为主、按钮为快捷预设）。
    public mutating func sync(to displays: [DisplaySnapshot]) {
        let ids = Set(displays.map { $0.id })
        placements.removeAll { !ids.contains($0.displayID) }
        // 刷新已知真实分辨率（不影响已有归一化摆放）
        for d in displays {
            guard d.sourceSize.width > 0, d.sourceSize.height > 0,
                  let i = placements.firstIndex(where: { $0.displayID == d.id }) else { continue }
            placements[i].sourceWidth = d.sourceSize.width
            placements[i].sourceHeight = d.sourceSize.height
        }
        let n = max(displays.count, 1)
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        for d in displays where !placements.contains(where: { $0.displayID == d.id }) {
            let src = d.sourceSize.width > 0 && d.sourceSize.height > 0
                ? d.sourceSize : PixelSize(width: 1920, height: 1080)
            // 新块按真实像素 1:1 进入（而不是旧版的 1/cols × 0.9 缩放块）
            let pw = min(0.9, Double(src.width) / Double(max(2, canvasWidth)))
            let ph = min(0.9, Double(src.height) / Double(max(2, canvasHeight)))
            let idx = placements.count
            let col = idx % cols, row = idx / cols
            placements.append(Placement(displayID: d.id,
                                        x: min(Double(col) / Double(cols), 1 - pw),
                                        y: min(Double(row) / Double(rows), 1 - ph),
                                        w: pw, h: ph,
                                        sourceWidth: src.width, sourceHeight: src.height))
        }
        fitStage()   // 新块比舞台大时自动扩舞台
    }

    /// 合并分辨率过大保护：画布宽 >8K 时整体降缩放比（方案第四节兜底对策）
    public func clamped(maxCanvasWidth: Int = 8192) -> ComposeLayout {
        guard canvasWidth > maxCanvasWidth else { return self }
        let s = Double(maxCanvasWidth) / Double(canvasWidth)
        var copy = self
        copy.canvasWidth = Int((Double(canvasWidth) * s).rounded())
        copy.canvasHeight = Int((Double(canvasHeight) * s).rounded())
        return copy // 归一化坐标不变，像素尺寸随画布缩放
    }

    /// 画布总像素（供编码器容量检查）
    public var totalPixels: Int { canvasWidth * canvasHeight }
}
