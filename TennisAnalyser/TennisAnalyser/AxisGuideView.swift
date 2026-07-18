//
//  AxisGuideView.swift
//  TennisAnalyser
//
//  Presentation — Apple Watch の座標軸ガイド（I-1）
//  波形チャートの X/Y/Z がどの向きに対応するかを図解する。
//  画像アセットではなく SwiftUI 描画（ダークモード対応・チャートと同一配色）。

import SwiftUI

/// X/Y/Z 系列の共通配色（dataviz 検証済み: ライト/ダーク両モードで CVD ΔE 9.5）
enum AxisPalette {
    static let x = Color(red: 0x42 / 255.0, green: 0x69 / 255.0, blue: 0xD0 / 255.0)  // #4269D0
    static let y = Color(red: 0xB4 / 255.0, green: 0x53 / 255.0, blue: 0x09 / 255.0)  // #B45309
    static let z = Color(red: 0x3C / 255.0, green: 0xA9 / 255.0, blue: 0x51 / 255.0)  // #3CA951
}

/// Apple Watch の座標軸を図解するシート
struct AxisGuideView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    WatchAxisDiagram()
                        .frame(width: 240, height: 280)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        axisRow(
                            color: AxisPalette.x,
                            title: "X 軸",
                            detail: "画面の右方向（文字盤を正面に見てリューズ側）が +X"
                        )
                        axisRow(
                            color: AxisPalette.y,
                            title: "Y 軸",
                            detail: "画面の上方向（12時方向・バンド上側）が +Y"
                        )
                        axisRow(
                            color: AxisPalette.z,
                            title: "Z 軸",
                            detail: "画面から手前（顔側）に向かう方向が +Z"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("チャートの読み方")
                            .font(.subheadline.bold())
                        Text("""
                        ・加速度: 各軸方向への並進運動 (g)。重力は除去済みです。
                        ・角速度: 各軸まわりの回転 (°/s)。軸の正方向に右ねじが進む回転が正です。
                        ・軸は Watch 本体（画面）基準のため、腕の向きが変わると世界座標に対する向きも変わります。
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Watch の座標軸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func axisRow(color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - WatchAxisDiagram

/// Apple Watch 本体と軸矢印のベクター図
private struct WatchAxisDiagram: View {

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let bodyW: CGFloat = 110
            let bodyH: CGFloat = 130
            let stroke = Color.secondary

            // バンド（上下）
            let bandW: CGFloat = 64
            let bandRect1 = CGRect(x: cx - bandW / 2, y: cy - bodyH / 2 - 52, width: bandW, height: 48)
            let bandRect2 = CGRect(x: cx - bandW / 2, y: cy + bodyH / 2 + 4, width: bandW, height: 48)
            for rect in [bandRect1, bandRect2] {
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 10),
                    with: .color(stroke.opacity(0.6)),
                    lineWidth: 1.5
                )
            }

            // 本体
            let bodyRect = CGRect(x: cx - bodyW / 2, y: cy - bodyH / 2, width: bodyW, height: bodyH)
            context.stroke(
                Path(roundedRect: bodyRect, cornerRadius: 26),
                with: .color(stroke),
                lineWidth: 2.5
            )

            // リューズ（右側）
            let crownRect = CGRect(x: bodyRect.maxX + 2, y: cy - 26, width: 6, height: 22)
            context.fill(Path(roundedRect: crownRect, cornerRadius: 3), with: .color(stroke.opacity(0.7)))
            let buttonRect = CGRect(x: bodyRect.maxX + 2, y: cy + 4, width: 5, height: 26)
            context.fill(Path(roundedRect: buttonRect, cornerRadius: 2.5), with: .color(stroke.opacity(0.4)))

            // X 軸矢印（右方向）
            drawArrow(
                context: &context,
                from: CGPoint(x: cx, y: cy),
                to: CGPoint(x: cx + 92, y: cy),
                color: AxisPalette.x
            )
            context.draw(
                Text("+X").font(.footnote.bold()).foregroundStyle(AxisPalette.x),
                at: CGPoint(x: cx + 100, y: cy - 14)
            )

            // Y 軸矢印（上方向）
            drawArrow(
                context: &context,
                from: CGPoint(x: cx, y: cy),
                to: CGPoint(x: cx, y: cy - 108),
                color: AxisPalette.y
            )
            context.draw(
                Text("+Y").font(.footnote.bold()).foregroundStyle(AxisPalette.y),
                at: CGPoint(x: cx + 16, y: cy - 104)
            )

            // Z 軸（画面から手前 = ⊙ 記法: 円 + 中心点）
            let zRadius: CGFloat = 13
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - zRadius, y: cy - zRadius, width: zRadius * 2, height: zRadius * 2)),
                with: .color(AxisPalette.z),
                lineWidth: 2.5
            )
            context.fill(
                Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                with: .color(AxisPalette.z)
            )
            context.draw(
                Text("+Z (手前)").font(.footnote.bold()).foregroundStyle(AxisPalette.z),
                at: CGPoint(x: cx - 4, y: cy + 30)
            )
        }
        .accessibilityLabel("Apple Watch の座標軸: X は画面右方向、Y は画面上方向、Z は画面から手前方向")
    }

    /// 矢印（軸線 + 三角の矢じり）を描画する
    private func drawArrow(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        color: Color
    ) {
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(color), lineWidth: 2.5)

        // 矢じり
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength: CGFloat = 12
        let headAngle: CGFloat = .pi / 7
        var head = Path()
        head.move(to: to)
        head.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        ))
        head.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        ))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

// MARK: - Preview

#Preview {
    AxisGuideView()
}
