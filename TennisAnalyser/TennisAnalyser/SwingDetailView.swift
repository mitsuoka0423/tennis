//
//  SwingDetailView.swift
//  TennisAnalyser
//
//  Presentation — スイング波形の詳細表示（F-I2, Swift Charts）

import SwiftUI
import Charts

struct SwingDetailView: View {

    let record: SwingRecord

    @State private var samples: [SwingSamplePoint] = []
    @State private var isLoading = true
    @State private var showsAxisGuide = false

    /// X/Y/Z 軸の系列色（AxisPalette: 座標軸ガイドと同一配色・固定順で循環させない）
    private static let axisColors: KeyValuePairs<String, Color> = [
        "X": AxisPalette.x,
        "Y": AxisPalette.y,
        "Z": AxisPalette.z,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isLoading {
                    ProgressView("読み込み中...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if samples.isEmpty {
                    ContentUnavailableView(
                        "波形データを読み込めません",
                        systemImage: "waveform.slash"
                    )
                } else {
                    waveformChart(
                        title: "加速度 (g)",
                        points: accelerationPoints
                    )
                    waveformChart(
                        title: "角速度 (°/s)",
                        points: gyroPoints
                    )
                }
            }
            .padding()
        }
        .navigationTitle("スイング #\(record.sequence)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsAxisGuide = true
                } label: {
                    Image(systemName: "move.3d")
                }
                .accessibilityLabel("座標軸ガイド")
            }
        }
        .sheet(isPresented: $showsAxisGuide) {
            AxisGuideView()
        }
        .task {
            // 波形は詳細表示時に遅延ロード（一覧はメタ情報のみで軽量に保つ）
            let url = record.fileURL
            let loaded = await Task.detached(priority: .userInitiated) {
                SwingCSVParser.parseSamples(fileURL: url)
            }.value
            samples = loaded
            isLoading = false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = record.detectedAt {
                // I-2: 日付は yyyy-MM-dd 表記
                Text(date.ymdhmsString)
                    .font(.headline)
            }
            HStack(spacing: 16) {
                if let peak = record.peakAcceleration {
                    Label(String(format: "ピーク %.1f g", peak), systemImage: "bolt")
                }
                Label("\(samples.count) サンプル", systemImage: "waveform")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    private struct ChartPoint: Identifiable {
        let id = UUID()
        /// インパクトからの相対時間 (秒)
        let time: Double
        let value: Double
        let axis: String
    }

    /// インパクト時刻（相対時間の原点）。メタ欠損時は先頭サンプル
    private var impactMs: Int64 {
        record.impactTimestampMs ?? samples.first?.timestampMs ?? 0
    }

    private var accelerationPoints: [ChartPoint] {
        chartPoints { [("X", $0.accX), ("Y", $0.accY), ("Z", $0.accZ)] }
    }

    private var gyroPoints: [ChartPoint] {
        chartPoints { [("X", $0.gyroX), ("Y", $0.gyroY), ("Z", $0.gyroZ)] }
    }

    private func chartPoints(
        _ extract: (SwingSamplePoint) -> [(String, Double)]
    ) -> [ChartPoint] {
        samples.flatMap { sample in
            extract(sample).map { axis, value in
                ChartPoint(
                    time: Double(sample.timestampMs - impactMs) / 1000.0,
                    value: value,
                    axis: axis
                )
            }
        }
    }

    @ViewBuilder
    private func waveformChart(title: String, points: [ChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Chart {
                // インパクト時点の基準線（系列色ではなく無彩色）
                RuleMark(x: .value("インパクト", 0.0))
                    .foregroundStyle(.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(points) { point in
                    LineMark(
                        x: .value("時間 (秒)", point.time),
                        y: .value(title, point.value),
                        series: .value("軸", point.axis)
                    )
                    .foregroundStyle(by: .value("軸", point.axis))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartForegroundStyleScale(Self.axisColors)
            .chartXAxisLabel("インパクトからの時間 (秒)", alignment: .center)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 220)
        }
    }
}

// MARK: - 以下、旧 AxisGuideView.swift から統合
// （Xcode の同期グループが新規ファイルを認識しない問題の回避。内容は I-1 座標軸ガイド）

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
