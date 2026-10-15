// Disynk 图标生成器（方案 Cv6_SymSlant「对称斜切」）
//
// 设计要点（几何/配色与 logo/build_icons.py 一一对应，此处用 CoreGraphics 原生重绘）：
//   主元素 = 一块切角实体被一条负形斜切通道一分为二，左右各留一块点对称的负形「屏」孔洞。
//   彩色 App 图标：近黑平涂 squircle 底板 #10161D + 待录屏侧反白 #EEF3F6、录制侧湖蓝 #1FC8E8。
//   ≤64px 换用小尺寸档（通道加宽到 64、孔洞收小），避免斜缝在低分辨率被吃掉。
//   菜单栏图标不再自绘：直接从 logo/menubar 拷贝纯黑+alpha template 位图（单一事实源在 logo）。
//
// 产物：
//   Resources/AppIcon.iconset/*.png（多尺寸彩色图标，交给 make_icon.sh 合成 .icns）
//   Resources/MenuBarIcon.png / MenuBarIcon@2x.png（从 logo/menubar 拷入）
//
// 用法：由 Scripts/make_icon.sh 以修补后的 resource-dir 编译并运行本脚本。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 品牌色（对齐 build_icons.py）

let TILE_COLOR   = CGColor(srgbRed: 0x10 / 255, green: 0x16 / 255, blue: 0x1D / 255, alpha: 1) // 底板
let ACCENT_COLOR = CGColor(srgbRed: 0x1F / 255, green: 0xC8 / 255, blue: 0xE8 / 255, alpha: 1) // 录制侧 湖蓝
let INK_COLOR    = CGColor(srgbRed: 0xEE / 255, green: 0xF3 / 255, blue: 0xF6 / 255, alpha: 1) // 待录屏侧 反白

// MARK: - 几何基元（SVG 512 视框坐标，y 向下；绘制时由外层翻转 CTM 处理）

/// 45° 切角矩形（锋利，不用圆角）→ 多边形路径。
func chamferPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, c: CGFloat) -> CGPath {
    let pts: [CGPoint] = [
        CGPoint(x: x + c, y: y),
        CGPoint(x: x + w - c, y: y),
        CGPoint(x: x + w, y: y + c),
        CGPoint(x: x + w, y: y + h - c),
        CGPoint(x: x + w - c, y: y + h),
        CGPoint(x: x + c, y: y + h),
        CGPoint(x: x, y: y + h - c),
        CGPoint(x: x, y: y + c),
    ]
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

/// 超椭圆 squircle（近似 Apple 连续圆角），中心 (cx, cy)，半轴 a。参数对齐 build_icons.py。
func squirclePath(cx: CGFloat, cy: CGFloat, side: CGFloat, n: CGFloat = 4.7, steps: Int = 180) -> CGPath {
    let a = side / 2
    let p = 2 / n
    var pts: [CGPoint] = []
    pts.reserveCapacity(steps)
    for i in 0..<steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps) - CGFloat.pi
        let ct = cos(t), st = sin(t)
        let ox = a * copysign(pow(abs(ct), p), ct)
        let oy = a * copysign(pow(abs(st), p), st)
        pts.append(CGPoint(x: cx + ox, y: cy + oy))
    }
    let path = CGMutablePath()
    path.addLines(between: pts)
    path.closeSubpath()
    return path
}

// Cv6_SymSlant 参数（见 build_icons.py mark()）
let SEAM: CGFloat = 256              // 通道中心线（负形缝落在 x≈256）
let SLANT: CGFloat = -16             // 斜切角（SVG rotate 度数）
let APP_SCALE: CGFloat = 1.4286      // 标志宽 ≈ squircle 的 76%

// 负形屏：标准档 vs 小尺寸档（App 图标 ≤64px 用小尺寸档，通道加宽）
let HOLES_FULL  = [chamferPath(x: 100, y: 206, w: 100, h: 100, c: 18),
                   chamferPath(x: 312, y: 206, w: 100, h: 100, c: 18)]
let HOLES_SMALL = [chamferPath(x: 92, y: 212, w: 88, h: 88, c: 16),
                   chamferPath(x: 332, y: 212, w: 88, h: 88, c: 16)]

// MARK: - 绘制

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// 在 1024 设计坐标（y 向下）里画一个 squircle 底板 + Cv6_SymSlant 标志。
/// small = 使用小尺寸档（通道更宽、孔洞收小）。画到尺寸 designPx 的上下文。
private func drawMarkDesign(into ctx: CGContext, designPx: Int, small: Bool) {
    let D = CGFloat(designPx)
    let k = D / 1024.0
    ctx.saveGState()
    ctx.translateBy(x: 0, y: D)   // 翻转成 SVG y 向下
    ctx.scaleBy(x: k, y: -k)      // 设计空间 = 1024

    // 底板：squircle 840，居中 (512,512)
    ctx.addPath(squirclePath(cx: 512, cy: 512, side: 840))
    ctx.setFillColor(TILE_COLOR)
    ctx.fillPath()

    // 标志：缩放 1.4286 居中（标志几何中心 256,256 → 画布 512,512）
    ctx.saveGState()
    let tx = 512 - 256 * APP_SCALE
    ctx.concatenate(CGAffineTransform(translationX: tx, y: tx))
    ctx.scaleBy(x: APP_SCALE, y: APP_SCALE)

    // 裁剪 = 切角实体挖掉两块负形屏（偶奇填充）
    let clip = CGMutablePath()
    clip.addPath(chamferPath(x: 32, y: 128, w: 448, h: 256, c: 56))
    for hole in (small ? HOLES_SMALL : HOLES_FULL) { clip.addPath(hole) }
    ctx.addPath(clip)
    ctx.clip(using: .evenOdd)

    // 斜切通道两侧色块：先旋转坐标系，再画两条覆盖左右的巨大矩形，缝隙留空即显底板
    let gap: CGFloat = small ? 64 : 32
    let leftW = SEAM - gap / 2 + 500
    let rightX = SEAM + gap / 2
    ctx.saveGState()
    ctx.translateBy(x: 256, y: 256)
    ctx.rotate(by: -SLANT * .pi / 180)   // 经 y 翻转后与 SVG rotate(-16) 视觉一致
    ctx.translateBy(x: -256, y: -256)
    ctx.setFillColor(ACCENT_COLOR)
    ctx.fill(CGRect(x: -500, y: -500, width: leftW, height: 1600))
    ctx.setFillColor(INK_COLOR)
    ctx.fill(CGRect(x: rightX, y: -500, width: 900, height: 1600))
    ctx.restoreGState()

    ctx.restoreGState()  // 标志缩放/平移
    ctx.restoreGState()  // 翻转
}

/// 高质量降采样：先按 supersample 倍超绘，再 .high 插值缩放到目标尺寸。
func drawColorIcon(size: Int, small: Bool) -> CGImage {
    let ss = max(1, 1024 / max(size, 1))   // 小尺寸超采样倍率（16px→64x，封顶避免过大）
    let supersample = min(ss, 64)
    let big = size * supersample
    let src = makeContext(big)
    drawMarkDesign(into: src, designPx: big, small: small)
    let bigImg = src.makeImage()!

    if supersample == 1 { return bigImg }

    let dst = makeContext(size)
    dst.interpolationQuality = .high
    dst.draw(bigImg, in: CGRect(x: 0, y: 0, width: size, height: size))
    return dst.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败: \(url.path)\n".data(using: .utf8)!); return
    }
    try? data.write(to: url)
}

// MARK: - 主流程

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let resDir = root.appendingPathComponent("Resources")
let setDir = resDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)

// 标准 iconset 尺寸（name -> px）；≤64px 用小尺寸档，与 logo/build_icons.js 策略一致
let iconSpecs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in iconSpecs {
    writePNG(drawColorIcon(size: px, small: px <= 64), to: setDir.appendingPathComponent(name))
}

// 菜单栏 template 图标：拷贝 logo/menubar 的完整版 MenuBarIcon_Full（纯黑+alpha，含左右实心端），
// 落地为 Resources 的 MenuBarIcon.png/@2x（App 代码按此名加载，单一事实源在 logo 资产链）。
let menubarDir = root.appendingPathComponent("logo/menubar")
let menubarCopies: [(src: String, dst: String)] = [
    ("MenuBarIcon_Full.png", "MenuBarIcon.png"),
    ("MenuBarIcon_Full@2x.png", "MenuBarIcon@2x.png"),
]
for pair in menubarCopies {
    let src = menubarDir.appendingPathComponent(pair.src)
    let dst = resDir.appendingPathComponent(pair.dst)
    if FileManager.default.fileExists(atPath: src.path) {
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    } else {
        FileHandle.standardError.write("⚠ 缺少 \(src.path)，未更新菜单栏图标\n".data(using: .utf8)!)
    }
}

print("✔ 图标已生成于 \(resDir.path)")
