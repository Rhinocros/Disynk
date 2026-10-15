/**
 * Disynk 图标位图生成器 —— 把 svg/ 下的矢量源栅格化并封装为 .icns / .ico。
 *
 * 依赖：sharp（node 工作区已装）
 * 运行：node build_icons.js
 *
 * 几何与配色全部来自 build_icons.py；本文件只负责尺寸与容器，不做任何造型改动。
 */

const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const SVG = path.join(ROOT, 'svg');
const SRC = {
  appIcon: path.join(SVG, 'Disynk_AppIcon.svg'),          // 1024 标准档
  appIconSm: path.join(SVG, 'Disynk_AppIcon_Small.svg'),  // 1024 小尺寸档（通道更宽）
  favicon: path.join(SVG, 'Disynk_Favicon.svg'),
  menuBar: path.join(SVG, 'Disynk_MenuBar.svg'),          // 336×256 中间段
  menuBarFull: path.join(SVG, 'Disynk_MenuBar_Full.svg'), // 512×512 完整标志
  og: path.join(SVG, 'Disynk_OG.svg'),                    // 1200×630
};

const dir = (p) => { fs.mkdirSync(p, { recursive: true }); return p; };
const out = (p, buf) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, buf); return p; };

/** 矢量 → PNG。density 按目标宽度放大 2 倍超采样后降采样，保证小尺寸边缘干净。 */
async function raster(svgFile, svgW, w, h = w) {
  const density = Math.min(2880, (72 * w / svgW) * 2);
  return sharp(svgFile, { density })
    .resize(w, h, { fit: 'contain', kernel: 'lanczos3' })
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
}

// ── ICNS ────────────────────────────────────────────────
function buildICNS(entries) {
  const parts = [];
  let total = 8;
  for (const { type, buf } of entries) {
    const len = 8 + buf.length;
    const head = Buffer.alloc(8);
    head.write(type, 0, 4, 'ascii');
    head.writeUInt32BE(len, 4);
    parts.push(head, buf);
    total += len;
  }
  const head = Buffer.alloc(8);
  head.write('icns', 0, 4, 'ascii');
  head.writeUInt32BE(total, 4);
  return Buffer.concat([head, ...parts]);
}

// ── ICO ─────────────────────────────────────────────────
function buildICO(entries) {
  const n = entries.length;
  const dir = Buffer.alloc(6);
  dir.writeUInt16LE(0, 0);
  dir.writeUInt16LE(1, 2);
  dir.writeUInt16LE(n, 4);
  let offset = 6 + 16 * n;
  const ents = [];
  for (const { size, buf } of entries) {
    const e = Buffer.alloc(16);
    e.writeUInt8(size >= 256 ? 0 : size, 0);
    e.writeUInt8(size >= 256 ? 0 : size, 1);
    e.writeUInt8(0, 2);
    e.writeUInt8(0, 3);
    e.writeUInt16LE(1, 4);
    e.writeUInt16LE(32, 6);
    e.writeUInt32LE(buf.length, 8);
    e.writeUInt32LE(offset, 12);
    ents.push(e);
    offset += buf.length;
  }
  return Buffer.concat([dir, ...ents, ...entries.map((x) => x.buf)]);
}

(async () => {
  const made = [];

  // 1) AppIcon.iconset —— macOS 程序图标 / Dock / ⌘Tab 的统一来源
  const iconSet = dir(path.join(ROOT, 'AppIcon.iconset'));
  const specs = [
    ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
    ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
    ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
    ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
    ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
  ];
  for (const [name, px] of specs) {
    // 64px 以下换用通道更宽的小尺寸档，避免斜切缝在低分辨率被吃掉
    const src = px <= 64 ? SRC.appIconSm : SRC.appIcon;
    const buf = await raster(src, 1024, px);
    fs.writeFileSync(path.join(iconSet, name), buf);
    made.push(`AppIcon.iconset/${name}`);
  }

  // 2) AppIcon.icns
  const png = async (px, small = false) => raster(small ? SRC.appIconSm : SRC.appIcon, 1024, px);
  const icnsEntries = [
    { type: 'icp4', buf: await png(16, true) },
    { type: 'icp5', buf: await png(32, true) },
    { type: 'icp6', buf: await png(64, true) },
    { type: 'ic07', buf: await png(128) },
    { type: 'ic08', buf: await png(256) },
    { type: 'ic09', buf: await png(512) },
    { type: 'ic10', buf: await png(1024) },
    { type: 'ic11', buf: await png(32, true) },
    { type: 'ic12', buf: await png(64, true) },
    { type: 'ic13', buf: await png(256) },
    { type: 'ic14', buf: await png(512) },
  ];
  out(path.join(ROOT, 'AppIcon.icns'), buildICNS(icnsEntries));
  made.push('AppIcon.icns');

  // 3) 单张大图 / Dock / 切换程序（⌘Tab）
  out(path.join(ROOT, 'PNG', 'AppIcon_1024.png'), await png(1024));
  made.push('PNG/AppIcon_1024.png');
  for (const px of [1024, 512, 256]) {
    out(path.join(ROOT, 'dock', `Dock_${px}.png`), await png(px));
    made.push(`dock/Dock_${px}.png`);
  }
  for (const px of [128, 256, 512]) {
    out(path.join(ROOT, 'switcher', `Switcher_${px}.png`), await png(px));
    made.push(`switcher/Switcher_${px}.png`);
  }

  // 4) 菜单栏图标（template：纯黑 + alpha，交给 NSImage.isTemplate 上色）
  //    中间段 352:256 = 1.375 → 1x 22×16
  for (const [name, k] of [['MenuBarIcon.png', 1], ['MenuBarIcon@2x.png', 2], ['MenuBarIcon@3x.png', 3]]) {
    out(path.join(ROOT, 'menubar', name), await raster(SRC.menuBar, 352, 22 * k, 16 * k));
    made.push(`menubar/${name}`);
  }
  //    完整标志 448:256 = 1.75 → 1x 28×16（备选）
  for (const [name, k] of [['MenuBarIcon_Full.png', 1], ['MenuBarIcon_Full@2x.png', 2], ['MenuBarIcon_Full@3x.png', 3]]) {
    out(path.join(ROOT, 'menubar', name), await raster(SRC.menuBarFull, 448, 28 * k, 16 * k));
    made.push(`menubar/${name}`);
  }

  // 5) 网站用
  const web = dir(path.join(ROOT, 'web'));
  const fav = async (px) => raster(SRC.favicon, 1024, px);
  out(path.join(web, 'favicon-16x16.png'), await fav(16));
  out(path.join(web, 'favicon-32x32.png'), await fav(32));
  out(path.join(web, 'favicon-48x48.png'), await fav(48));
  out(path.join(web, 'apple-touch-icon.png'), await fav(180));
  out(path.join(web, 'icon-192.png'), await fav(192));
  out(path.join(web, 'icon-512.png'), await fav(512));
  out(path.join(web, 'favicon.ico'), buildICO([
    { size: 16, buf: await fav(16) },
    { size: 32, buf: await fav(32) },
    { size: 48, buf: await fav(48) },
  ]));
  out(path.join(web, 'og-image.png'), await raster(SRC.og, 1200, 1200, 630));
  for (const n of ['favicon.svg', 'logo.svg', 'logo-dark.svg', 'logo-white.svg',
                   'logo-lockup.svg', 'logo-lockup-dark.svg']) made.push(`web/${n} (copy)`);
  const copy = {
    'Disynk_Favicon.svg': 'favicon.svg',
    'Disynk_Mark.svg': 'logo.svg',
    'Disynk_Mark_Dark.svg': 'logo-dark.svg',
    'Disynk_Mark_White.svg': 'logo-white.svg',
    'Disynk_Lockup.svg': 'logo-lockup.svg',
    'Disynk_Lockup_Dark.svg': 'logo-lockup-dark.svg',
  };
  for (const [s, d] of Object.entries(copy)) {
    fs.copyFileSync(path.join(SVG, s), path.join(web, d));
  }
  // web/ 里补一份小尺寸单色版，给页脚/深色区块用
  fs.copyFileSync(path.join(SVG, 'Disynk_Mark_Mono.svg'), path.join(web, 'logo-mono.svg'));

  made.push('web/*');
  console.log('图标生成完成：');
  for (const m of made) console.log('  ', m);
})().catch((e) => { console.error(e); process.exit(1); });
