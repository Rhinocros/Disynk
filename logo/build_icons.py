#!/usr/bin/env python3
"""Disynk 图标矢量源生成器 —— Cv6_SymSlant 结构 + 湖蓝 #1FC8E8。

只产 SVG；位图由 build_icons.js（sharp）栅格化并封装成 .icns / .ico。
改色只动 ACCENT，几何参数不要动（见 .workbuddy/memory/MEMORY.md 回退约定）。
结构与强调色已于 2026-10-08 由用户确认。
"""

import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SVG = ROOT / "svg"
SVG.mkdir(parents=True, exist_ok=True)

# ── 品牌色 ────────────────────────────────────────────────
INK = "#0A0E13"        # 主色 近黑
ACCENT = "#1FC8E8"     # 强调色 湖蓝（只允许出现在「正在录制」的那一块屏上）
LIGHT = "#EEF3F6"      # 反白
WHITE = "#FFFFFF"
TILE = "#10161D"       # App 图标底板（平涂，不用渐变）
OG_BG = "#0B0F14"

FONT = "Inter, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif"


# ── 几何基元 ──────────────────────────────────────────────
def chamfer(x, y, w, h, c):
    """45° 切角矩形（锋利化：不用圆角）。"""
    return (f"M{x + c} {y} H{x + w - c} L{x + w} {y + c} V{y + h - c} "
            f"L{x + w - c} {y + h} H{x + c} L{x} {y + h - c} V{y + c} Z")


def mark(ink, rec, gap=32, angle=-16, c=56, seam=256, holes=(), uid="ds"):
    """Cv6_SymSlant：一条负形通道斜切整块实体，左右各一块点对称负形屏。

    ink = 待录屏（实体侧）颜色；rec = 正在录制侧颜色（强调色专用位）。
    """
    left_w = seam - gap / 2 + 500
    right_x = seam + gap / 2
    box = chamfer(32, 128, 448, 256, c)

    defs = f'<defs><clipPath id="{uid}c"><path d="{box}"/></clipPath>'
    attr = ""
    if holes:
        m = '<rect x="0" y="0" width="512" height="512" fill="#fff"/>'
        for hp in holes:
            m += f'<path d="{chamfer(*hp)}" fill="#000"/>'
        defs += f'<mask id="{uid}m">{m}</mask>'
        attr = f' mask="url(#{uid}m)"'
    defs += "</defs>"

    body = (f'<g clip-path="url(#{uid}c)"{attr}>'
            f'<g transform="rotate({angle} 256 256)">'
            f'<rect x="-500" y="-500" width="{left_w:.1f}" height="1600" fill="{rec}"/>'
            f'<rect x="{right_x:.1f}" y="-500" width="900" height="1600" fill="{ink}"/>'
            f'</g></g>')
    return defs + body


# 负形屏：两块 100×100 切角方孔，关于画布中心 (256,256) 点对称
HOLES_FULL = ((100, 206, 100, 100, 18), (312, 206, 100, 100, 18))
# 小尺寸：通道加宽到 96，孔洞收小
HOLES_SMALL = ((86, 214, 76, 84, 14), (350, 214, 76, 84, 14))
# App 图标 64px 以下：中间档
HOLES_APPSM = ((92, 212, 88, 88, 16), (332, 212, 88, 88, 16))


def wrap(vb, body, title):
    """vb = 正方形边长，或 (宽, 高)。"""
    w, h = (vb, vb) if isinstance(vb, int) else vb
    return wrap_vb(f"0 0 {w} {h}", w, h, body, title)


def wrap_vb(viewbox, w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="{viewbox}" fill="none">'
            f'<title>{title}</title>\n{body}\n</svg>\n')


def emit(name, vb, body, title):
    (SVG / name).write_text(wrap(vb, body, title), encoding="utf-8")


def placed(inner, tx, ty, s):
    return f'<g transform="translate({tx:.4g} {ty:.4g}) scale({s:.4g})">{inner}</g>'


def squircle(side, n=4.7, steps=180):
    """超椭圆采样的连续圆角方形（近似 Apple squircle），接缝落在左侧平直段。"""
    a = side / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps - math.pi
        ct, st_ = math.cos(t), math.sin(t)
        p = 2.0 / n
        x = a * math.copysign(abs(ct) ** p, ct)
        y = a * math.copysign(abs(st_) ** p, st_)
        pts.append((a + x, a + y))
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"


# ── 1. 标志本体 ──────────────────────────────────────────
emit("Disynk_Mark.svg", 512,
     mark(INK, ACCENT, holes=HOLES_FULL), "Disynk")
emit("Disynk_Mark_Dark.svg", 512,
     mark(LIGHT, ACCENT, holes=HOLES_FULL), "Disynk on dark")
emit("Disynk_Mark_Mono.svg", 512,
     mark("currentColor", "currentColor", holes=HOLES_FULL, uid="dsm"),
     "Disynk monochrome")
emit("Disynk_Mark_White.svg", 512,
     mark(WHITE, WHITE, holes=HOLES_FULL, uid="dsw"), "Disynk white")
emit("Disynk_Mark_Small.svg", 512,
     mark("currentColor", "currentColor", gap=96, holes=HOLES_SMALL, uid="dss"),
     "Disynk monochrome small")

# ── 2. 横版字标 ──────────────────────────────────────────
def lockup(inner, fg, title):
    return wrap((600, 200),
                placed(inner, 40, 20, 0.3125)
                + f'<text x="240" y="133" font-family="{FONT}" font-size="96" '
                  f'font-weight="800" letter-spacing="-2" fill="{fg}">Disynk</text>',
                title)


(SVG / "Disynk_Lockup.svg").write_text(
    lockup(mark(INK, ACCENT, holes=HOLES_FULL, uid="dsl"), INK, "Disynk"), encoding="utf-8")
(SVG / "Disynk_Lockup_Dark.svg").write_text(
    lockup(mark(LIGHT, ACCENT, holes=HOLES_FULL, uid="dsld"), LIGHT, "Disynk on dark"),
    encoding="utf-8")
(SVG / "Disynk_Lockup_White.svg").write_text(
    lockup(mark(WHITE, WHITE, holes=HOLES_FULL, uid="dslw"), WHITE, "Disynk white"),
    encoding="utf-8")

# ── 3. App 图标（程序图标 / Dock / ⌘Tab 共用同一份几何） ────
# macOS 规范：squircle 约占画布 82%，四周留 ~9% 透明边距，否则在 Dock/⌘Tab
# 里会比系统其他图标明显偏大（仓库旧图标已踩过此坑）。
SQUIRCLE_SIDE = 840
SQUIRCLE = squircle(SQUIRCLE_SIDE)
SQ_OFF = (1024 - SQUIRCLE_SIDE) / 2


def appicon(inner, title):
    return wrap(1024,
                f'<g transform="translate({SQ_OFF:.4g} {SQ_OFF:.4g})">'
                f'<path d="{SQUIRCLE}" fill="{TILE}"/></g>\n' + inner, title)


def fit_mark(s, holes, gap, ink=LIGHT, uid="dsa"):
    """把 512 视框的标志等比放进 1024 画布并居中。"""
    tx = 512 - 256 * s          # 标志几何中心恰为 (256,256)
    ty = 512 - 256 * s
    return placed(mark(ink, ACCENT, gap=gap, holes=holes, uid=uid), tx, ty, s)


APP_SCALE = 1.4286           # 标志宽 640px，约为 squircle 宽的 76%
(SVG / "Disynk_AppIcon.svg").write_text(
    appicon(fit_mark(APP_SCALE, HOLES_FULL, 32), "Disynk app icon"), encoding="utf-8")
(SVG / "Disynk_AppIcon_Small.svg").write_text(
    appicon(fit_mark(APP_SCALE, HOLES_APPSM, 64, uid="dsas"), "Disynk app icon (small sizes)"),
    encoding="utf-8")

# ── 4. 菜单栏图标：只保留标志中间那一段 ────────────────────
# 实体块 x 32..480（切角 56），取 80..432 这段：完整保留两块负形屏
# 与中间斜切通道，只留 8 单位切角收边，砍掉左右两头没有信息的实心端。
(SVG / "Disynk_MenuBar.svg").write_text(
    wrap_vb("80 128 352 256", 352, 256,
            mark("#000000", "#000000", holes=HOLES_FULL, uid="dsmb"),
            "Disynk menu bar (centre crop)"), encoding="utf-8")
(SVG / "Disynk_MenuBar_Full.svg").write_text(
    wrap_vb("32 128 448 256", 448, 256,
            mark("#000000", "#000000", holes=HOLES_FULL, uid="dsmf"),
            "Disynk menu bar (full mark)"), encoding="utf-8")

# ── 5. 网站用 ────────────────────────────────────────────
(SVG / "Disynk_Favicon.svg").write_text(
    appicon(fit_mark(APP_SCALE, HOLES_APPSM, 64, uid="dsf"), "Disynk favicon"), encoding="utf-8")

s = 0.9
og = (f'<rect width="1200" height="630" fill="{OG_BG}"/>'
      + placed(mark(LIGHT, ACCENT, holes=HOLES_FULL, uid="dsog"),
               110 - 32 * s, (630 - 256 * s) / 2 - 128 * s, s)
      + f'<rect x="576" y="248" width="56" height="4" fill="{ACCENT}"/>'
      + f'<text x="576" y="330" font-family="{FONT}" font-size="92" font-weight="800" '
        f'letter-spacing="-3" fill="{WHITE}">Disynk</text>'
      + f'<text x="576" y="380" font-family="{FONT}" font-size="27" font-weight="500" '
        f'fill="#93A1B0">多屏并行录制 · 截图 · 滚动长截图 · 本地 OCR</text>'
      + f'<text x="576" y="418" font-family="{FONT}" font-size="23" font-weight="400" '
        f'fill="#5D6B7A">Multi-screen recording for macOS</text>')
(SVG / "Disynk_OG.svg").write_text(wrap((1200, 630), og, "Disynk"), encoding="utf-8")

print(f"SVG 源已生成：{SVG}")
for f in sorted(SVG.glob("*.svg")):
    print("  ", f.name)
