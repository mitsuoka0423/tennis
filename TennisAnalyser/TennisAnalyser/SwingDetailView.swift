//
//  SwingDetailView.swift
//  TennisAnalyser
//
//  Presentation — スイング波形の詳細表示（F-I2, Swift Charts）

import SwiftUI
import Charts
import RealityKit

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
///
/// - 3D モデル（RealityKit）をドラッグで回転して、どの装着向きでも軸を確認できる
/// - 軸は Watch 画面基準のため、リューズの左右・腕の向きに依らず不変であることを明記
struct AxisGuideView: View {

    @Environment(\.dismiss) private var dismiss
    /// 装着スタイル（ユーザーは右腕・リューズ左が既定）
    @State private var crownOnLeft = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("装着スタイル", selection: $crownOnLeft) {
                        Text("リューズ左（右腕）").tag(true)
                        Text("リューズ右（左腕）").tag(false)
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 6) {
                        Watch3DAxisView(crownOnLeft: crownOnLeft)
                            .frame(height: 300)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Label("ドラッグで回転できます", systemImage: "rotate.3d")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        axisRow(
                            color: AxisPalette.x,
                            title: "X 軸",
                            detail: "画面を正面から見て右の方向が +X"
                        )
                        axisRow(
                            color: AxisPalette.y,
                            title: "Y 軸",
                            detail: "画面の上（12時）方向が +Y"
                        )
                        axisRow(
                            color: AxisPalette.z,
                            title: "Z 軸",
                            detail: "画面から顔側へ垂直に出る方向が +Z"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("チャートの読み方")
                            .font(.subheadline.bold())
                        Text("""
                        ・軸は Watch の画面基準です。リューズが左右どちらの装着でも軸の向きは変わりません。
                        ・加速度: 各軸方向への並進運動 (g)。重力は除去済みです。
                        ・角速度: 各軸まわりの回転 (°/s)。軸の正方向に右ねじが進む回転が正です。
                        ・腕の向きが変わると、世界座標（コート基準）に対する軸の向きは変わります。
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

// MARK: - Watch3DAxisView

/// Apple Watch 本体と座標軸の 3D モデル（RealityKit）
///
/// ドラッグで自由に回転でき、どの装着向きでも軸の対応を立体的に確認できる。
/// ライティングに依存しない UnlitMaterial を使用（配色は AxisPalette と同一）。
private struct Watch3DAxisView: View {

    let crownOnLeft: Bool

    var body: some View {
        RealityView { content in
            content.add(Self.makeRoot(crownOnLeft: crownOnLeft))
        } update: { content in
            // 装着スタイル切替時にモデルを再構築
            content.entities.removeAll()
            content.add(Self.makeRoot(crownOnLeft: crownOnLeft))
        }
        .realityViewCameraControls(.orbit)
        .accessibilityLabel("Apple Watch の3Dモデル: X は画面右方向、Y は画面上方向、Z は画面から手前方向")
    }

    // MARK: - Scene Construction

    private static func makeRoot(crownOnLeft: Bool) -> Entity {
        let root = Entity()

        let bodyMaterial = UnlitMaterial(color: UIColor(white: 0.55, alpha: 1.0))
        let screenMaterial = UnlitMaterial(color: UIColor(white: 0.12, alpha: 1.0))
        let bandMaterial = UnlitMaterial(color: UIColor(white: 0.35, alpha: 1.0))

        // 本体
        let body = ModelEntity(
            mesh: .generateBox(width: 1.1, height: 1.3, depth: 0.3, cornerRadius: 0.12),
            materials: [bodyMaterial]
        )
        root.addChild(body)

        // 画面（本体前面 = +Z 側）
        let screen = ModelEntity(
            mesh: .generateBox(width: 0.92, height: 1.08, depth: 0.04, cornerRadius: 0.08),
            materials: [screenMaterial]
        )
        screen.position = [0, 0, 0.15]
        root.addChild(screen)

        // バンド（上下）
        for yPos in [Float(1.0), Float(-1.0)] {
            let band = ModelEntity(
                mesh: .generateBox(width: 0.6, height: 0.75, depth: 0.24, cornerRadius: 0.1),
                materials: [bandMaterial]
            )
            band.position = [0, yPos, 0]
            root.addChild(band)
        }

        // リューズ（装着スタイルに応じて左右）
        let crown = ModelEntity(
            mesh: .generateCylinder(height: 0.14, radius: 0.09),
            materials: [bandMaterial]
        )
        crown.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])  // Y軸円柱 → X方向へ
        crown.position = [crownOnLeft ? -0.62 : 0.62, 0.2, 0]
        root.addChild(crown)

        // 座標軸（画面基準・リューズ位置に依らず固定）
        root.addChild(axisArrow(direction: [1, 0, 0], colorHex: (0x42, 0x69, 0xD0), label: "+X"))
        root.addChild(axisArrow(direction: [0, 1, 0], colorHex: (0xB4, 0x53, 0x09), label: "+Y"))
        root.addChild(axisArrow(direction: [0, 0, 1], colorHex: (0x3C, 0xA9, 0x51), label: "+Z"))

        return root
    }

    /// 原点から direction 方向への矢印（軸線 + 円錐の矢じり + ラベル）
    private static func axisArrow(
        direction: SIMD3<Float>,
        colorHex: (Int, Int, Int),
        label: String
    ) -> Entity {
        let color = UIColor(
            red: CGFloat(colorHex.0) / 255.0,
            green: CGFloat(colorHex.1) / 255.0,
            blue: CGFloat(colorHex.2) / 255.0,
            alpha: 1.0
        )
        let material = UnlitMaterial(color: color)
        let arrow = Entity()

        // 円柱・円錐はデフォルトで +Y 方向 → direction へ回転
        let rotation = simd_quatf(from: [0, 1, 0], to: direction)

        let shaftLength: Float = 1.5
        let shaft = ModelEntity(
            mesh: .generateCylinder(height: shaftLength, radius: 0.03),
            materials: [material]
        )
        shaft.orientation = rotation
        shaft.position = direction * (shaftLength / 2)
        arrow.addChild(shaft)

        let head = ModelEntity(
            mesh: .generateCone(height: 0.22, radius: 0.09),
            materials: [material]
        )
        head.orientation = rotation
        head.position = direction * (shaftLength + 0.11)
        arrow.addChild(head)

        // ラベル（常にカメラを向く）
        let textMesh = MeshResource.generateText(
            label,
            extrusionDepth: 0.02,
            font: .boldSystemFont(ofSize: 0.24),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        let text = ModelEntity(mesh: textMesh, materials: [material])
        let bounds = textMesh.bounds
        text.position = direction * (shaftLength + 0.4)
            - [bounds.extents.x / 2, bounds.extents.y / 2, 0]
        text.components.set(BillboardComponent())
        arrow.addChild(text)

        return arrow
    }
}

// MARK: - Preview

#Preview {
    AxisGuideView()
}
