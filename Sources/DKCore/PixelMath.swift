import CoreGraphics
import Foundation

/// 像素几何纯函数（供截图/录制尺寸计算复用，可离线单测）。
public enum PixelMath {
    /// 归一化到编码器友好的偶数尺寸（H.264/HEVC 要求宽高为偶；下限 2，上限 8192）。
    public static func evenSize(_ w: Int, _ h: Int) -> PixelSize {
        func even(_ v: Int) -> Int { min(8192, max(2, v & ~1)) }
        return PixelSize(width: even(w), height: even(h))
    }

    /// 点矩形 × 像素倍率 → 目标像素尺寸（偶数对齐；倍率下限 1、非有限回退 1）。
    public static func regionPixels(rect: CGRect, scale: Double) -> PixelSize {
        let s = scale.isFinite ? max(1.0, scale) : 1.0
        return evenSize(Int((rect.width * s).rounded()), Int((rect.height * s).rounded()))
    }
}
