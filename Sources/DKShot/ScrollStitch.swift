import CoreGraphics
import Foundation

/// 滚动长截图拼接。
/// 三个关键步骤（缺一就是用户看到的“每帧都带标题栏/地址栏、重叠内容很多”）：
///  1) 固定 UI 裁剪：各帧静止的首/尾连续行 = 不随滚动移动的部分（窗口标题栏、
///     浏览器地址栏、页脚、粘性头部），拼接前统一裁掉（判定用中位数距离，抗光标闪烁）；
///  2) 重叠去重：先试精确行哈希，再退到行剖面容差比对 —— 滚动后应用会重新栅格化文字，
///     行哈希会变但像素只差一两个梯度，只靠精确匹配会整片重叠都没去掉；
///  3) 位移兜底：固定 UI 没裁净时「后缀=前缀」必然对不上（next 开头被工具栏占住），
///     改用通用纵向位移搜索（比较内部行），仍能把重复内容去掉。
/// 纯算法部分（行签名/剖面/重叠/位移/固定带）与真机解耦，可离线单测；像素合成用 CGContext。
public enum ScrollStitch {
    /// 一帧的行特征：逐行精确签名 + 逐行降采样灰度剖面（容差比较用）。
    public struct RowData {
        public let sigs: [UInt64]
        public let profiles: [UInt8]      // 行优先，每行 profileWidth 个采样
        public let profileWidth: Int

        public var count: Int { sigs.count }

        public func profile(_ row: Int) -> ArraySlice<UInt8> {
            let s = row * profileWidth
            guard s + profileWidth <= profiles.count else { return [] }
            return profiles[s..<(s + profileWidth)]
        }

        /// 裁掉首 top 行、尾 bottom 行（行特征直接切片，不重新取像素）。
        public func sliced(top: Int, bottom: Int) -> RowData {
            let end = max(0, min(count, count - bottom))
            let lo = min(top, end) * profileWidth
            let hi = end * profileWidth
            guard hi <= profiles.count, lo <= hi else { return self }
            return RowData(sigs: Array(sigs[lo / profileWidth..<end]),
                           profiles: Array(profiles[lo..<hi]),
                           profileWidth: profileWidth)
        }
    }

    /// 逐行图像签名（每行一个 UInt64 指纹）：按 RGBA8 渲染后对每行采样列做 FNV-1a 哈希。
    /// 采样列自适应宽度（≤ 64 列），兼顾速度与稳定（整行等色时任意列一致）。
    public static func rowSignatures(of image: CGImage) -> [UInt64] {
        analyze(of: image).sigs
    }

    /// 一次像素读取同时得到行签名与行剖面（避免两次渲染整帧）。
    public static func analyze(of image: CGImage, profileWidth: Int = 32) -> RowData {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return RowData(sigs: [], profiles: [], profileWidth: profileWidth) }
        let emptyProfiles = [UInt8](repeating: 0, count: h * profileWidth)
        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else {
            return RowData(sigs: Array(repeating: 0, count: h), profiles: emptyProfiles,
                           profileWidth: profileWidth)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let strideRow = w * 4
        let samples = max(1, min(64, w / 4))
        let colStep = max(1, w / samples)
        let pStep = max(1, w / profileWidth)
        var sigs = [UInt64]()
        sigs.reserveCapacity(h)
        var profiles = [UInt8]()
        profiles.reserveCapacity(h * profileWidth)
        // 实测：CGImage 经 ctx.draw 写入位图上下文后，内存缓冲区首行（偏移 0）即图像「视觉顶行」
        // （非底行）；故按视觉行序（顶→底）直接读取 yPix = row，供自上而下的重叠/堆叠计算。
        for row in 0..<h {
            let yPix = row
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for c in stride(from: 0, to: w, by: colStep) {
                let base = yPix * strideRow + c * 4
                for k in 0..<4 {
                    hash = (hash ^ UInt64(buf[base + k])) &* 0x0000_0100_0000_01b3
                }
            }
            sigs.append(hash)
            for p in 0..<profileWidth {
                let c = min(w - 1, p * pStep)
                let base = yPix * strideRow + c * 4
                profiles.append(UInt8((Int(buf[base]) + Int(buf[base + 1]) + Int(buf[base + 2])) / 3))
            }
        }
        return RowData(sigs: sigs, profiles: profiles, profileWidth: profileWidth)
    }

    /// 两行剖面的平均绝对差（0…255）。
    public static func rowDistance(_ a: RowData, _ ra: Int, _ b: RowData, _ rb: Int) -> Int {
        guard a.profileWidth == b.profileWidth, ra >= 0, rb >= 0, ra < a.count, rb < b.count else { return 255 }
        let pa = a.profile(ra), pb = b.profile(rb)
        guard !pa.isEmpty, pa.count == pb.count else { return 255 }
        var sum = 0
        for (x, y) in zip(pa, pb) { sum += abs(Int(x) - Int(y)) }
        return sum / pa.count
    }

    /// 相邻两帧的最大纵向重叠行数（前帧的「末尾 o 行」== 后帧的「开头 o 行」）。
    /// 从大到小试探，命中即返回；低于 minRows 视为无重叠返回 0。纯逻辑，可离线单测。
    public static func overlap(prev: [UInt64], next: [UInt64], minRows: Int) -> Int {
        let maxO = min(prev.count, next.count)
        guard maxO >= minRows, minRows >= 1 else { return 0 }
        for o in stride(from: maxO, through: minRows, by: -1) {
            if matchesSuffixPrefix(prev, next, o) { return o }
        }
        return 0
    }

    /// 容差版重叠检测（精确匹配失败时用）：按行剖面比对，采样命中率 ≥ hitRatio 即成立。
    public static func tolerantOverlap(prev: RowData, next: RowData, minRows: Int,
                                       hitRatio: Double = 0.85, tol: Int = 6) -> Int {
        let maxO = min(prev.count, next.count)
        guard maxO >= minRows, minRows >= 1 else { return 0 }
        for o in stride(from: maxO, through: minRows, by: -1) {
            let probes = min(o, 24)
            let step = max(1, o / probes)
            var hits = 0, tried = 0
            var i = 0
            while i < o {
                tried += 1
                if rowDistance(prev, prev.count - o + i, next, i) <= tol { hits += 1 }
                i += step
            }
            if tried > 0, Double(hits) / Double(tried) >= hitRatio { return o }
        }
        return 0
    }

    /// 两帧同址就相等的首/尾连续行数 = 这对帧的固定 UI（不随滚动移动）。
    /// 只需一对帧就能判（只有两帧的会话也能用），带内同样允许 ≤maxGap 行闪烁。
    public static func pairStaticBands(prev: RowData, next: RowData, maxFraction: Double = 0.35,
                                       tol: Int = 6, maxGap: Int = 4) -> (top: Int, bottom: Int) {
        let h = min(prev.count, next.count)
        guard h > 0 else { return (0, 0) }
        let cap = Int(Double(h) * maxFraction)
        func same(_ r: Int) -> Bool { rowDistance(prev, r, next, r) <= tol }
        func band(anchor: Int, step: Int) -> Int {
            var seen = anchor, last = -1, length = 0, walked = 0
            while seen >= 0, seen < h, walked < cap {
                if same(seen) {
                    if last < 0 || abs(seen - last) <= maxGap + 1 { length = walked + 1 }
                    last = seen
                } else {
                    if last < 0 { break }
                    if abs(seen - last) > maxGap { break }
                }
                seen += step
                walked += 1
            }
            return length
        }
        let top = band(anchor: 0, step: 1)
        var bottom = band(anchor: h - 1, step: -1)
        if top + bottom > h / 2 { bottom = max(0, h / 2 - top) }
        return (top, bottom)
    }

    /// 在内容窗口 [skip.top, h-skip.bottom) 内搜位移 Δ：prev[skip.top+Δ+t] ≈ next[skip.top+t]。
    /// 因为只比内容区，两帧共用的标题栏/地址栏既不会拖低命中率、也不会被当成新内容。
    /// 计分前先剔除「同址静止行」（两帧同一地址行剖面已相等 = 不随滚动移动的残留固定 UI，
    /// 如视口裁剪失败残留的侧栏、页面中部的 sticky 筛选条）：这类行在任何 Δ 下都“命中”，
    /// 会稀释真实 Δ 的命中率致漏判（→整屏重复堆叠），也会虚增错误 Δ 的命中率致误判。
    /// 优先取**最小**的近似完全命中（≥0.98）Δ = 真实滚动步长（宁可留一点重叠也不跳内容）；
    /// 没有完全命中时退到首个 ≥0.90 的 Δ。返回 Δ（= 本帧新增的内容行数），无可靠位移返回 nil。
    public static func bestShift(prev: RowData, next: RowData, skip: (top: Int, bottom: Int),
                                 minAligned: Int, tol: Int = 6) -> Int? {
        let h = min(prev.count, next.count)
        let c = max(0, min(skip.top, h)), b = max(0, min(skip.bottom, h - c))
        let contentH = h - c - b
        guard contentH - minAligned >= 1 else { return nil }
        var isStatic = [Bool](repeating: false, count: h)
        for r in 0..<h { isStatic[r] = rowDistance(prev, r, next, r) <= tol }
        var loose: Int?
        for d in 1...(contentH - minAligned) {
            let aligned = contentH - d
            let probes = min(aligned, 24)
            let step = max(1, aligned / probes)
            var hits = 0, tried = 0
            var t = 0
            while t < aligned {
                let ra = c + d + t, rb = c + t
                if !isStatic[ra], !isStatic[rb] {          // 同址静止行不参与计分
                    tried += 1
                    if rowDistance(prev, ra, next, rb) <= tol { hits += 1 }
                }
                t += step
            }
            guard tried >= 3 else { continue }             // 可判行太少 → 结果不可信
            let ratio = Double(hits) / Double(tried)
            if ratio >= 0.98 { return d }
            if ratio >= 0.90, loose == nil { loose = d }
        }
        return loose
    }

    /// 各帧静止的首/尾连续行数 = 不随滚动移动的固定 UI。
    /// 两点关键（都是真实场景踩过的坑）：
    ///  • 判定用「与其余各帧行剖面距离的**中位数**」而非精确相等：地址栏光标闪烁、
    ///    favicon 动画只会让个别帧的个别行变化；
    ///  • 带内允许极少量“闪烁行”（连续不超过 maxGap 行）：旧版一行不同就截断识别，
    ///    导致工具栏只裁掉上半截 → 剩下半截逐屏重复。
    /// maxFraction 限制单侧最多裁掉多大比例，避免把正文空白误裁。
    public static func staticBands(_ frames: [RowData], maxFraction: Double = 0.35,
                                   tol: Int = 6, maxGap: Int = 2) -> (top: Int, bottom: Int) {
        guard frames.count >= 2 else { return (0, 0) }
        let h = frames.map(\.count).min() ?? 0
        guard h > 0 else { return (0, 0) }
        let cap = Int(Double(h) * maxFraction)
        func staticRow(_ r: Int) -> Bool {
            guard r >= 0, r < h else { return false }
            var ds: [Int] = []
            ds.reserveCapacity(frames.count - 1)
            for f in frames[1...] { ds.append(rowDistance(frames[0], r, f, r)) }
            guard !ds.isEmpty else { return true }
            ds.sort()
            return ds[ds.count / 2] <= tol
        }
        /// 从 anchor 沿 step 量固定带长度：允许带内少量闪烁行，连续超过 maxGap 行不静止才算结束。
        func band(anchor: Int, step: Int) -> Int {
            var seen = anchor, last = -1, length = 0, walked = 0
            while seen >= 0, seen < h, walked < cap {
                if staticRow(seen) {
                    if last < 0 || abs(seen - last) <= maxGap + 1 { length = walked + 1 }
                    last = seen
                } else {
                    if last < 0 { break }                        // 首行就不静止 → 没有固定带
                    if abs(seen - last) > maxGap { break }        // 静止带里断开太多行
                }
                seen += step
                walked += 1
            }
            return length
        }
        let top = band(anchor: 0, step: 1)
        var bottom = band(anchor: h - 1, step: -1)
        // 别把整帧裁没（纯色页面常见）
        if top + bottom > h / 2 { bottom = max(0, h / 2 - top) }
        return (top, bottom)
    }

    private static func matchesSuffixPrefix(_ a: [UInt64], _ b: [UInt64], _ o: Int) -> Bool {
        let offA = a.count - o
        for i in 0..<o where a[offA + i] != b[i] { return false }
        return true
    }

    /// 各帧自上而下的落位顶部偏移（像素）。首帧在 0；其余 = 已堆叠高度 − 与前一帧的重叠。
    /// 纯逻辑：给定各帧高度与相邻重叠序列（overlaps[i] = 帧 i 与 i-1 的重叠行数）。
    public static func topOffsets(heights: [Int], overlaps: [Int]) -> [Int] {
        guard let first = heights.first else { return [] }
        var offsets = [0]
        var total = first
        for i in 1..<heights.count {
            let ov = i - 1 < overlaps.count ? max(0, overlaps[i - 1]) : 0
            let clampedOv = min(ov, heights[i - 1], heights[i])
            offsets.append(total - clampedOv)
            total += heights[i] - clampedOv
        }
        return offsets
    }

    /// 合成选项。includeTitlebar=false 时，拼接前从每帧裁掉顶部标题栏，并对左右
    /// 「逐帧列哈希全同」的原生固定栏（如浏览器竖排标签栏）做严格裁剪（见 staticColumns）。
    public struct Options {
        public var includeTitlebar: Bool
        public init(includeTitlebar: Bool = true) { self.includeTitlebar = includeTitlebar }
        public static let `default` = Options(includeTitlebar: true)
    }

    /// 合成结果与诊断信息（供上层把“裁了多少固定 UI / 重叠是否去成”说给用户）。
    public struct StitchReport {
        public let image: CGImage
        public let trimmedTop: Int        // 裁掉的顶部固定 UI 行数
        public let trimmedBottom: Int     // 裁掉的底部固定 UI 行数
        public let trimmedLeft: Int       // 裁掉的左侧固定栏列数（仅 includeTitlebar=false 时 >0）
        public let trimmedRight: Int      // 裁掉的右侧固定栏列数
        public let frameCount: Int
        public let zeroOverlapPairs: Int  // 没检测到重叠的相邻对数（>0 则可能仍有重复内容）
        public let shiftRescuedPairs: Int // 全局裁剪后仍残留固定 UI、靠逐对位移跳过对数
        public let stepRescuedPairs: Int  // 重叠完全漏判、按其余帧滚动步长中位数兜底估算的对数

        public init(image: CGImage, trimmedTop: Int, trimmedBottom: Int, frameCount: Int,
                    zeroOverlapPairs: Int, shiftRescuedPairs: Int = 0,
                    trimmedLeft: Int = 0, trimmedRight: Int = 0, stepRescuedPairs: Int = 0) {
            self.image = image
            self.trimmedTop = trimmedTop
            self.trimmedBottom = trimmedBottom
            self.trimmedLeft = trimmedLeft
            self.trimmedRight = trimmedRight
            self.frameCount = frameCount
            self.zeroOverlapPairs = zeroOverlapPairs
            self.shiftRescuedPairs = shiftRescuedPairs
            self.stepRescuedPairs = stepRescuedPairs
        }
    }

    /// 合成最终高图（只拿图像）。详见 stitchDetailed。
    public static func stitch(_ images: [CGImage], minRows: Int = 6) -> CGImage? {
        stitchDetailed(images, minRows: minRows)?.image
    }

    /// 合成最终高图：先裁掉各帧共有的固定 UI（顶部/底部行带；不勾选「包含标题栏」时另裁左右
    /// 原生固定栏），再逐对检测重叠（位移→精确→容差）后堆叠。
    /// 宽度取首帧，帧宽不一致时按首帧宽拉伸放置。失败返回 nil。
    /// options.includeTitlebar=false 时：① 全局静止带漏判用首对帧兜底顶部；② 用严格列检测
    /// （逐帧列哈希全同，见 staticColumns）裁掉左右固定栏——浏览器竖排标签栏等原生 UI 逐帧
    /// 像素级一致会被裁，随页滚动的正文/分类菜单列哈希必变、不会被裁（v0.1.50 tol 剖面误判的教训）。
    public static func stitchDetailed(_ images: [CGImage], options: Options = Options(), minRows: Int = 6) -> StitchReport? {
        let usable0 = images.filter { $0.width > 0 && $0.height > 0 }
        guard let first0 = usable0.first else { return nil }
        var usable = usable0
        var trimmedLeft = 0, trimmedRight = 0
        // 不勾选「包含标题栏」：先裁掉左右逐帧全同的原生固定栏（浏览器竖排标签栏等），
        // 再进入行分析——固定左栏会稀释行剖面信号、拖累重叠检测（重复内容的成因之一）。
        if !options.includeTitlebar, usable.count >= 2 {
            let (l, r) = staticColumns(usable)
            if l + r > 0, first0.width > l + r + 16 {
                trimmedLeft = l; trimmedRight = r
                usable = usable.map {
                    $0.cropping(to: CGRect(x: l, y: 0, width: $0.width - l - r, height: $0.height)) ?? $0
                }
            }
        }
        guard let first = usable.first else { return nil }
        if usable.count == 1 {
            return StitchReport(image: first, trimmedTop: 0, trimmedBottom: 0,
                                frameCount: 1, zeroOverlapPairs: 0, shiftRescuedPairs: 0,
                                trimmedLeft: trimmedLeft, trimmedRight: trimmedRight)
        }

        let analyzed = usable.map { analyze(of: $0) }
        var bands = staticBands(analyzed)
        // 强制去标题栏时，若全局静止带漏判（如仅两帧会话 staticBands 需 ≥3 帧才可靠），用首对帧兜底顶部
        if !options.includeTitlebar, bands.top == 0, analyzed.count >= 2 {
            bands.top = pairStaticBands(prev: analyzed[0], next: analyzed[1]).top
        }
        let frames: [CGImage]
        let data: [RowData]
        if bands.top + bands.bottom > 0, first.height > (bands.top + bands.bottom) + 16 {
            frames = usable.map { crop($0, top: bands.top, bottom: bands.bottom) }
            data = analyzed.map { $0.sliced(top: bands.top, bottom: bands.bottom) }
        } else {
            frames = usable
            data = analyzed
        }
        guard frames.count >= 2, data.count >= 2 else { return nil }

        // 逐对：1) 同址静止带 = 这对帧的固定 UI；2) 只在内容窗口里搜位移 Δ（本帧新增行数）；
        // 3) 位移无果才退回「后缀=前缀」重叠检测。固定 UI 部分合成时直接不画 →
        // 从结构上杜绝“每一屏都带标题栏/地址栏”。
        // 4) 仍漏判（o=0，典型成因：懒加载图瞬间刷新/滚动动画模糊帧）时，用其余帧成功步长 Δ
        // 的中位数兜底估算重叠，避免整屏重复内容直接堆进长图。
        var overlaps: [Int] = []
        var drawSkip: [(top: Int, bottom: Int)] = [(0, 0)]
        var shiftPairs = 0
        var stepSamples: [Int] = []          // 各对 bestShift 成功的 Δ（滚动步长近乎恒定）
        var failed: [(index: Int, h: Int)] = []   // 所有方法都漏判的对（待中位数兜底）
        let heights = frames.map(\.height)
        for i in 1..<data.count {
            let h = min(data[i - 1].count, data[i].count)
            let pb = pairStaticBands(prev: data[i - 1], next: data[i])
            drawSkip.append(pb)
            if pb.top + pb.bottom > 0 { shiftPairs += 1 }   // 全局裁剪后仍残留固定 UI 的对数
            let contentH = max(0, h - pb.top - pb.bottom)
            let minAligned = max(minRows, contentH / 8)
            if let d = bestShift(prev: data[i - 1], next: data[i], skip: pb, minAligned: minAligned) {
                stepSamples.append(d)
                overlaps.append(max(0, h - d))
                continue
            }
            // 位移搜索无果：用重叠检测（首尾对齐），再不行先挂起（后面按步长中位数兜底）
            var o = overlap(prev: data[i - 1].sigs, next: data[i].sigs, minRows: minRows)
            if o == 0 {
                o = tolerantOverlap(prev: data[i - 1], next: data[i], minRows: minRows)
            }
            if o == 0 { failed.append((overlaps.count, h)) }
            overlaps.append(o)
        }
        var stepPairs = 0
        if !failed.isEmpty, stepSamples.count >= 2 {
            let sorted = stepSamples.sorted()
            let med = sorted[sorted.count / 2]
            for (idx, hh) in failed {
                let o = max(0, hh - med)
                if o > 0 {
                    overlaps[idx] = o
                    stepPairs += 1
                }
            }
        }
        let zeroPairs = failed.count - stepPairs
        let offsets = topOffsets(heights: heights, overlaps: overlaps)
        guard offsets.count == frames.count, let firstH = heights.first else { return nil }

        // 调整偏移量以消除 drawSkip 导致的白色间隙：
        // 确保每帧绘制内容的起始行不超过前一帧绘制内容的结束行
        var adjOffsets = offsets
        for i in 1..<frames.count {
            let prevTop = drawSkip[i - 1].top
            let prevBottom = drawSkip[i - 1].bottom
            let prevDrawnEnd = adjOffsets[i - 1] + prevTop + (heights[i - 1] - prevTop - prevBottom)
            let curDrawnStart = adjOffsets[i] + drawSkip[i].top
            if curDrawnStart > prevDrawnEnd {
                adjOffsets[i] -= (curDrawnStart - prevDrawnEnd)
            }
        }

        // 总高 = 各帧实际落位底边的最大值
        var totalH = firstH
        for i in frames.indices {
            let top = i == 0 ? 0 : drawSkip[i].top
            let bottom = i == 0 ? 0 : drawSkip[i].bottom
            let bottomEdge = adjOffsets[i] + top + (heights[i] - top - bottom)
            totalH = max(totalH, bottomEdge)
        }

        let W = first.width
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: totalH, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: totalH))
        for (i, img) in frames.enumerated() {
            // 后续帧只画内容区（固定 UI 不重复入画）；首帧整帧保留
            var top = 0, bottom = 0
            if i > 0 {
                top = max(0, min(drawSkip[i].top, img.height - 8))
                bottom = max(0, min(drawSkip[i].bottom, img.height - top - 8))
            }
            let sub = (top + bottom > 0)
                ? (img.cropping(to: CGRect(x: 0, y: top, width: img.width,
                                           height: img.height - top - bottom)) ?? img)
                : img
            // adjOffsets[i] + top 为该子图顶部在长图里的行号；CGContext 原点左下
            let y = CGFloat(totalH - (adjOffsets[i] + top) - sub.height)
            ctx.draw(sub, in: CGRect(x: 0, y: y, width: CGFloat(W), height: CGFloat(sub.height)))
        }
        guard let out = ctx.makeImage() else { return nil }
        return StitchReport(image: out, trimmedTop: bands.top, trimmedBottom: bands.bottom,
                            frameCount: frames.count, zeroOverlapPairs: zeroPairs,
                            shiftRescuedPairs: shiftPairs,
                            trimmedLeft: trimmedLeft, trimmedRight: trimmedRight,
                            stepRescuedPairs: stepPairs)
    }

    /// 裁掉图像顶部 top 行、底部 bottom 行（CGImage 坐标原点为图像左上）。
    private static func crop(_ img: CGImage, top: Int, bottom: Int) -> CGImage {
        guard top + bottom > 0, img.height > top + bottom + 8 else { return img }
        return img.cropping(to: CGRect(x: 0, y: top, width: img.width, height: img.height - top - bottom))
            ?? img
    }

    /// 各帧左右「固定侧栏」列宽（不勾选「包含标题栏」时由 stitchDetailed 接入）。
    /// 判定为严格版：某列在多数帧里**逐像素哈希全同** → 不随滚动移动 → 固定列。
    /// 为何用全同哈希而非旧版 tol 剖面距离：真实网页左侧多是随页滚动的正文/分类菜单，
    /// 容差判定会把它们误认成固定侧栏裁掉（v0.1.50 的教训）；而滚动内容的列哈希必变，
    /// 浏览器竖排标签栏等原生 UI 不参与页面重栅格化、逐帧像素级一致，只有它会通过全同判定。
    /// 与行版 staticBands 同理：带内允许 ≤maxGap 列闪烁（悬停高亮/动图图标）。
    /// 关键：只裁到带内**最后一个有纵向内容结构**（非平坦）的静止列——真正的固定侧栏（图标/文字/分隔线
    /// 在固定行）才会让各行签名趋同、拖低重叠匹配；而页面留白/纯色空白列是平坦的（纵向几乎不变），
    /// 对所有行贡献同一常量、并不造成重复，故不应被裁掉（否则会把正文左边的空白边距也裁了）。
    /// 单侧上限 maxFraction×宽，且左右合计不超过半宽。返回 (left, right) 列数。
    public static func staticColumns(_ images: [CGImage], profileHeight: Int = 40,
                                     maxFraction: Double = 0.25, maxGap: Int = 3,
                                     flatRange: Int = 20, hashRows: Int = 128) -> (left: Int, right: Int) {
        let usable = images.filter { $0.width > 0 && $0.height > 0 }
        guard usable.count >= 2 else { return (0, 0) }
        let w = usable.map(\.width).min() ?? 0
        guard w > 24 else { return (0, 0) }
        let hashes: [[UInt64]] = usable.map { columnHashes(of: $0, width: w, rows: hashRows) }
        let profs: [[UInt8]] = usable.map { columnProfiles(of: $0, width: w, samples: profileHeight) }
        func staticCol(_ x: Int) -> Bool {
            var same = 0, total = 0
            for f in hashes[1...] { total += 1; if f[x] == hashes[0][x] { same += 1 } }
            guard total > 0 else { return true }
            return same * 2 >= total          // 多数帧列哈希与首帧全同（抗偶发模糊/悬停帧）
        }
        // 平坦列 = 纵向灰度极差 ≤ flatRange（页面留白、纯色背景）；非平坦 = 有结构（图标/文字/线条）。
        func flatCol(_ x: Int) -> Bool {
            let p = profs[0]
            var lo = 255, hi = 0
            for k in 0..<profileHeight {
                let v = Int(p[x * profileHeight + k])
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            return hi - lo <= flatRange
        }
        let cap = Int(Double(w) * maxFraction)
        func band(anchor: Int, step: Int) -> Int {
            var seen = anchor, last = -1, walked = 0
            var structured = -1   // 带内最近一个「静止且非平坦」列的绝对列号
            while seen >= 0, seen < w, walked < cap {
                if staticCol(seen) {
                    if last < 0 || abs(seen - last) <= maxGap + 1, !flatCol(seen) {
                        structured = seen
                    }
                    last = seen
                } else {
                    if last < 0 { break }
                    if abs(seen - last) > maxGap { break }
                }
                seen += step
                walked += 1
            }
            guard structured >= 0 else { return 0 }   // 整条带都是留白/纯色 → 不裁
            return step > 0 ? structured + 1 : w - structured
        }
        let left = band(anchor: 0, step: 1)
        var right = band(anchor: w - 1, step: -1)
        if left + right > w / 2 { right = max(0, w / 2 - left) }
        return (left, right)
    }

    /// 逐列采样哈希：每列取 ≤rows 个像素行的 RGBA 做 FNV-1a，用于「逐帧全同」严格判定。
    private static func columnHashes(of image: CGImage, width: Int, rows: Int) -> [UInt64] {
        let iw = image.width, ih = image.height
        var out = [UInt64](repeating: 0, count: max(0, width))
        guard iw > 0, ih > 0, width > 0 else { return out }
        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: iw * ih * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: iw, height: ih, bitsPerComponent: 8,
                      bytesPerRow: iw * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return out }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        let stride = iw * 4
        let step = max(1, ih / max(1, rows))
        for x in 0..<width {
            let xx = min(iw - 1, x)
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var y = 0
            while y < ih {
                let base = y * stride + xx * 4
                for k in 0..<4 { hash = (hash ^ UInt64(buf[base + k])) &* 0x0000_0100_0000_01b3 }
                y += step
            }
            out[x] = hash
        }
        return out
    }

    /// 把图像渲染为「列主序」降采样灰度剖面：width 列 × samples 行，供列间距离比较。
    private static func columnProfiles(of image: CGImage, width: Int, samples: Int) -> [UInt8] {
        let iw = image.width, ih = image.height
        var out = [UInt8](repeating: 0, count: max(0, width * samples))
        guard iw > 0, ih > 0, width > 0, samples > 0 else { return out }
        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: iw * ih * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: iw, height: ih, bitsPerComponent: 8,
                      bytesPerRow: iw * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return out }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        let stride = iw * 4
        let step = max(1, ih / samples)
        for x in 0..<width {
            let xx = min(iw - 1, x)
            var s = 0, y = 0
            while y < ih, s < samples {
                let base = y * stride + xx * 4
                out[x * samples + s] = UInt8((Int(buf[base]) + Int(buf[base + 1]) + Int(buf[base + 2])) / 3)
                y += step
                s += 1
            }
            while s < samples { out[x * samples + s] = out[x * samples + (s - 1)]; s += 1 }   // 尾部补齐防越界
        }
        return out
    }
}
