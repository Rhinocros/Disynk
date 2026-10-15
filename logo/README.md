# Disynk 图标资产

结构：**Cv6_SymSlant**（对称斜切）· 强调色：湖蓝 `#1FC8E8` · 主色：近黑 `#0A0E13`

## 目录

| 路径 | 内容 | 用途 |
|---|---|---|
| `svg/` | 全部矢量源（14 个） | 唯一事实源，改稿从这里出发 |
| `AppIcon.iconset/` | 16–1024px 共 10 张 PNG | macOS 程序图标标准集 |
| `AppIcon.icns` | 多尺寸封装 | 直接替换 `Resources/AppIcon.icns` |
| `PNG/AppIcon_1024.png` | 单张大图 | 通用展示 |
| `dock/` | 1024 / 512 / 256 | Dock 展示（macOS 实际复用 icns） |
| `switcher/` | 128 / 256 / 512 | ⌘Tab 切换程序展示（实际复用 icns） |
| `menubar/` | `MenuBarIcon.png` + `@2x` + `@3x`，及 `*_Full` 备选 | 顶部菜单栏 template 图标 |
| `web/` | favicon / og-image / logo 系列 | 网站引用 |

## 菜单栏图标（只保留标志中间部分）

`MenuBarIcon.png`（1x 22×16）取标志 x 80–432 这一段：完整保留两块负形屏与
中间斜切通道，砍掉左右两头没有信息的实心端。纯黑 + alpha，接入时置
`NSImage.isTemplate = true` 让系统自动做明暗适配。

```swift
let icon = NSImage(named: "MenuBarIcon")
icon?.isTemplate = true
statusItem.button?.image = icon
```

`MenuBarIcon_Full.png`（1x 28×16）是完整标志版，供对比挑选。

## 尺寸策略

- **≥128px**：标准档（斜切通道 32 单位、负形屏 100×100）
- **≤64px**：小尺寸档（通道加宽到 64、负形屏收小），避免斜缝在低分辨率被吃掉
- 菜单栏 16px 级：中间段裁切 + 标准孔洞

## 重新生成

```bash
python build_icons.py        # 1) 产出 svg/
node build_icons.js          # 2) 栅格化 + 封装 icns/ico（依赖 sharp）
```

改色只改 `build_icons.py` 里的 `ACCENT`；几何参数不要动。
回退基线：Cv6 结构 + 荧光青 `#00EFC8`（见项目 `.workbuddy/memory/MEMORY.md`）。

## 上线前注意

- `svg/Disynk_Lockup*.svg` 与 og 图里的 "Disynk" 是系统字体回退，正式物料请转曲
  （Illustrator / Inkscape `Text → Path`）。
- `.icns` 由 PNG 条目直接封装（icp4/icp5/icp6/ic07–ic10/ic11–ic14），
  如需 `iconutil` 重合成：`iconutil -c icns AppIcon.iconset -o AppIcon.icns`。
