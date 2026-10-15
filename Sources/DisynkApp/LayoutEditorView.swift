import DKCompose
import DKCore
import SwiftUI

/// 可视化拖拽布局编辑器（方案 M2.5）：
/// 每个色块代表一路屏，拖动摆放位置、滑杆调整尺寸比例（归一化画布坐标）。
/// 块按屏幕**真实像素 1:1** 摆放；舞台比内容大（便于自由拖拽），录制时裁到内容包围盒。
struct LayoutEditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedID: UInt32?
    /// 拖起瞬间的块左上角归一化坐标（用 translation 增量计算，避免块跳到指针中心）
    @State private var dragOrigin: (id: UInt32, x: Double, y: Double)?

    var body: some View {
        VStack(spacing: 8) {
            canvas
            if let layout, let selectedID,
               let p = layout.placements.first(where: { $0.displayID == selectedID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选中：\(displayName(p.displayID))").font(.caption)
                    HStack {
                        Text("宽").font(.caption)
                        Slider(value: widthBinding(p.displayID), in: 0.05...1.0)
                        Text("高").font(.caption)
                        Slider(value: heightBinding(p.displayID), in: 0.05...1.0)
                    }
                }
            }
            Text("拖动色块自由摆放（可拖出舞台，松手后自动扩大并裁到内容范围，不留黑边）")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var layout: ComposeLayout? { model.layout }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let layout {
                    let side = fittedSize(in: geo.size, canvas: layout.canvas)
                    ZStack(alignment: .topLeading) {
                        EP.bgCard
                        ForEach(layout.placements, id: \.displayID) { p in
                            tile(p, canvasPx: layout.canvas, viewSize: side)
                        }
                    }
                    .frame(width: side.width, height: side.height)
                    .border(EP.borderBase)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    // 拖拽必须按舞台坐标系取位移：旧版用块自身局部坐标，指针永远落在块内，
                    // 换算出的归一化位置几乎不变 → “拖不动、摆不成上下排列”。
                    .coordinateSpace(name: Self.stageSpace)
                } else {
                    Text("勾选 ≥2 块屏后自动生成布局")
                        .font(.caption).foregroundStyle(.secondary)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EP.bgPage)
        .overlay(RoundedRectangle(cornerRadius: EP.radius).stroke(EP.borderBase))
    }

    private static let stageSpace = "layoutStage"

    private func fittedSize(in area: CGSize, canvas: PixelSize) -> CGSize {
        let scale = min(area.width / CGFloat(canvas.width),
                        area.height / CGFloat(canvas.height),
                        area.width > 0 && area.height > 0 ? 1000 : 1)
        return CGSize(width: CGFloat(canvas.width) * scale,
                      height: CGFloat(canvas.height) * scale)
    }

    @ViewBuilder
    private func tile(_ p: ComposeLayout.Placement, canvasPx: PixelSize, viewSize: CGSize) -> some View {
        let w = max(20, p.w * viewSize.width)
        let h = max(20, p.h * viewSize.height)
        let x = p.x * viewSize.width + w / 2
        let y = p.y * viewSize.height + h / 2
        let src = p.pixelSize(canvas: canvasPx)
        VStack(spacing: 2) {
            Image(systemName: "display")
                .font(.title3)
            Text(shortName(p.displayID))
                .font(.caption2).lineLimit(1)
            // 真实像素分辨率（旧版显示的是 p.w × 画布宽，2K 屏被预设缩成 1920×1080）
            Text("\(src.width)×\(src.height)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: w, height: h)
        .background(selectedID == p.displayID
                    ? EP.primary.opacity(0.30)
                    : EP.fillLight)
        .overlay(
            RoundedRectangle(cornerRadius: EP.radius)
                .stroke(selectedID == p.displayID ? EP.primary : EP.borderBase,
                        lineWidth: selectedID == p.displayID ? 2.5 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: EP.radius))
        .position(x: x, y: y)
        .onTapGesture { selectedID = p.displayID }
        .gesture(
            DragGesture(coordinateSpace: .named(Self.stageSpace))
                .onChanged { value in
                    guard var layout = model.layout, viewSize.width > 0, viewSize.height > 0 else { return }
                    if dragOrigin?.id != p.displayID { dragOrigin = (p.displayID, p.x, p.y) }
                    let o = dragOrigin ?? (p.displayID, p.x, p.y)
                    selectedID = p.displayID
                    // 拖拽起点 + 指针位移（归一化）。中途不扩舞台，否则画布一变就会让
                    // 已拖出的块跳回舞台内（表现为一到边界就抽跳）。
                    layout.setDragPosition(displayID: p.displayID,
                                           x: o.x + value.translation.width / viewSize.width,
                                           y: o.y + value.translation.height / viewSize.height)
                    model.layout = layout
                }
                .onEnded { _ in
                    dragOrigin = nil
                    guard var layout = model.layout else { return }   // 松手：舞台自动罩住摆好的块
                    layout.commitDrag()
                    model.layout = layout
                }
        )
    }

    private func widthBinding(_ id: UInt32) -> Binding<Double> {
        Binding(get: { model.layout?.placements.first { $0.displayID == id }?.w ?? 0.5 },
                set: { nw in
                    guard var layout = model.layout else { return }
                    layout.resize(displayID: id, w: nw,
                                  h: layout.placements.first { $0.displayID == id }?.h ?? nw)
                    model.layout = layout
                })
    }

    private func heightBinding(_ id: UInt32) -> Binding<Double> {
        Binding(get: { model.layout?.placements.first { $0.displayID == id }?.h ?? 0.5 },
                set: { nh in
                    guard var layout = model.layout else { return }
                    layout.resize(displayID: id,
                                  w: layout.placements.first { $0.displayID == id }?.w ?? nh, h: nh)
                    model.layout = layout
                })
    }

    private func displayName(_ id: UInt32) -> String {
        model.displays.first { $0.id == id }?.name ?? "屏 #\(id)"
    }
    private func shortName(_ id: UInt32) -> String {
        let n = displayName(id)
        return n.count > 14 ? String(n.prefix(14)) + "…" : n
    }
}
