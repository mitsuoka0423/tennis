//
//  SensorMonitorView.swift
//  TennisAnalyser Watch App
//
//  Presentation View — センサー値のリアルタイム時系列表示（F-W9 デモ）

import SwiftUI

/// 加速度3軸・角速度3軸を軸ごとの波形として実時間で表示するデモ画面
///
/// 画面を開いている間だけサンプリングし、保存も転送も行わない。
///
/// **1画面1グラフ。** 波形を画面いっぱいに敷き、加速度と角速度は左右の
/// スワイプで入れ替える。2枚を縦に並べていたときは1枚あたりの高さが
/// 66pt しか取れず、振り切れているのか小さく振れているのかが読めなかった。
struct SensorMonitorView: View {

    @StateObject private var viewModel: SensorMonitorViewModel
    @State private var page: MonitorPage = .acceleration
    @State private var isAlertPresented = false

    /// - Parameter viewModel: プレビューやテストで差し替える場合に指定する
    ///
    /// Why not 既定値に `SensorMonitorViewModel()` を直接書く: デフォルト引数は
    /// 呼び出し側の nonisolated な文脈で評価されるため、MainActor 隔離された
    /// イニシャライザを呼べずビルドが通らない。
    init(viewModel: SensorMonitorViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SensorMonitorViewModel())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $page) {
                ForEach(MonitorPage.allCases) { item in
                    chart(for: item)
                        .tag(item)
                }
            }
            // ページ表示は下端の状態行に自前で置くため、標準のドットは出さない
            .tabViewStyle(.page(indexDisplayMode: .never))
            // 波形はナビゲーションバーの下も含めて画面いっぱいに敷く
            .ignoresSafeArea()

            // Why not 下端の情報もページの中へ入れる: ページを跨いで動かない
            // 位置に置くため。スワイプで入れ替わるのは波形だけにする
            footer(page)
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("エラー", isPresented: $isAlertPresented) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            isAlertPresented = newValue != nil
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - 1ページ（波形1枚）

    private func chart(for item: MonitorPage) -> some View {
        AxisTraceChart(
            trace: trace(for: item),
            scale: scale(for: item),
            capacity: viewModel.traceCapacity
        )
    }

    /// 下端の情報。波形と重なるため、黒へ落ちる幕を敷いて文字を載せる
    private func footer(_ item: MonitorPage) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                let values = latestValues(for: item)
                AxisValue(label: "X", value: values.0, format: item.format, color: SensorAxisColor.x)
                AxisValue(label: "Y", value: values.1, format: item.format, color: SensorAxisColor.y)
                AxisValue(label: "Z", value: values.2, format: item.format, color: SensorAxisColor.z)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.isRunning ? GlassPalette.accent : GlassPalette.label)
                    .frame(width: 6, height: 6)
                // 「計測中」ではなく「取得中」。計測画面（F-W1〜W6）と紛らわしいため
                Text(viewModel.isRunning ? "取得中" : "停止中")
                    .font(.system(size: 11))
                    .foregroundStyle(GlassPalette.label)

                Spacer(minLength: 0)

                Text(item.unit)
                    .font(.system(size: 10))
                    .foregroundStyle(GlassPalette.label)
                // 目盛りが動くため、いま何倍で見ているかを常に添える
                Text(scaleLabel(for: item))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GlassPalette.info)
                    .animation(.default, value: scaleLabel(for: item))

                PageDots(selected: item)
                    .padding(.leading, 4)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background {
            // 幕は画面の下端まで伸ばす。安全領域で止めると、その下に残る
            // 波形だけが素のまま明るく見える
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.85), location: 0.55),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - ページごとの値

    private func trace(for item: MonitorPage) -> AxisTrace {
        switch item {
        case .acceleration: viewModel.accelerationTrace
        case .rotation: viewModel.rotationTrace
        }
    }

    private func scale(for item: MonitorPage) -> Double {
        switch item {
        case .acceleration: viewModel.accelerationScale
        case .rotation: viewModel.rotationScale
        }
    }

    private func scaleLabel(for item: MonitorPage) -> String {
        switch item {
        case .acceleration: SensorChartScale.accelerationLabel(viewModel.accelerationScale)
        case .rotation: SensorChartScale.rotationLabel(viewModel.rotationScale)
        }
    }

    private func latestValues(for item: MonitorPage) -> (Double?, Double?, Double?) {
        switch item {
        case .acceleration:
            (viewModel.latest?.accX, viewModel.latest?.accY, viewModel.latest?.accZ)
        case .rotation:
            (viewModel.latest?.gyroX, viewModel.latest?.gyroY, viewModel.latest?.gyroZ)
        }
    }
}

// MARK: - MonitorPage

/// モニターのページ。1ページ＝1グラフ
enum MonitorPage: Int, CaseIterable, Identifiable {
    case acceleration
    case rotation

    var id: Int { rawValue }

    /// ナビゲーションバーのタイトルを兼ねる
    var title: String {
        switch self {
        case .acceleration: "加速度"
        case .rotation: "角速度"
        }
    }

    var unit: String {
        switch self {
        case .acceleration: "g"
        case .rotation: "°/s"
        }
    }

    var format: String {
        switch self {
        case .acceleration: "%+.2f"
        case .rotation: "%+.0f"
        }
    }
}

// MARK: - PageDots

/// いま何ページ目かを示す点
///
/// Why not `TabView` 標準の点をそのまま使う: 標準の点は画面の下端中央に
/// 独立して置かれ、下端の情報と行が二段になる。状態・単位・目盛りと
/// 同じ行に収めるため自前で描く。
private struct PageDots: View {
    let selected: MonitorPage

    var body: some View {
        HStack(spacing: 5) {
            ForEach(MonitorPage.allCases) { item in
                Circle()
                    .fill(item == selected ? GlassPalette.accent : .white.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - 軸の色

/// 軸の色。X/Y/Z を通して同じ対応にする
enum SensorAxisColor {
    static let x = GlassPalette.danger
    static let y = GlassPalette.accent
    static let z = GlassPalette.info
}

// MARK: - AxisTraceChart

/// 3軸を1枚に重ねた波形
///
/// 最新が右端。点数が `capacity` に満たない開始直後は左側が空く
/// （時間軸の目盛りを一定に保つため、幅いっぱいへ引き伸ばさない）。
///
/// 線は自身の色で発光させる（カタログ 1i）。3本が重なる瞬間でも、
/// にじみの色で手前がどの軸か分かる。
private struct AxisTraceChart: View {
    let trace: AxisTrace
    let scale: Double
    let capacity: Int

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2

            // 0 の基準線
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.white.opacity(0.14)), lineWidth: 1)

            guard capacity > 1, !trace.isEmpty else { return }

            let step = size.width / Double(capacity - 1)
            let count = trace.x.count

            func path(for values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    // 右端を最新にするため、末尾からの距離で位置を決める
                    let x = size.width - Double(count - 1 - index) * step
                    let clamped = max(min(value / scale, 1.0), -1.0)
                    let y = midY - clamped * (size.height / 2 - 3)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                return path
            }

            // 奥から Z→Y→X。X（振りの主成分）を最前面に置く
            for (values, color, width) in [
                (trace.z, SensorAxisColor.z, 2.0),
                (trace.y, SensorAxisColor.y, 2.0),
                (trace.x, SensorAxisColor.x, 2.2)
            ] {
                let line = path(for: values)
                let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: color.opacity(0.6), radius: 4))
                    layer.stroke(line, with: .color(color), style: style)
                }
            }
        }
    }
}

// MARK: - AxisValue

/// 軸1つぶんの現在値
private struct AxisValue: View {
    let label: String
    let value: Double?
    let format: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(value.map { String(format: format, $0) } ?? "---")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("画面") {
    MockedSensorMonitorPreview()
}

/// 疑似データを流した状態のプレビュー
///
/// 実センサーはプレビューで動かないため `MockMotionSensorRepository` を使う。
/// 実際の呼び出し元（RootView）と同じ NavigationStack の下で確認する。
private struct MockedSensorMonitorPreview: View {
    @StateObject private var viewModel =
        SensorMonitorViewModel(repository: MockMotionSensorRepository())

    var body: some View {
        NavigationStack {
            SensorMonitorView(viewModel: viewModel)
        }
    }
}

#Preview("波形") {
    // 描画そのものの確認用。ライブのサンプル到着を待たずに形を見る
    let capacity = 150
    var trace = AxisTrace()
    for index in 0..<capacity {
        let t = Double(index) / Double(capacity)
        trace.append(
            x: 6 * sin(t * .pi * 6),
            y: 3 * cos(t * .pi * 4),
            z: -1 + 2 * sin(t * .pi * 10),
            capacity: capacity
        )
    }
    // 上は自動スケール適用後、下は下限のまま（振り切れた見え方の比較用）
    let fitted = SensorChartScale.fit(
        peak: trace.peakMagnitude, minimum: SensorChartScale.accelerationMinimum
    )
    // 画面いっぱいに敷いたときの線の太さと発光を、実寸で確認する
    return AxisTraceChart(trace: trace, scale: fitted, capacity: capacity)
        .ignoresSafeArea()
}

#Preview("波形（下限スケール）") {
    // 自動スケールを効かせず、振り切れた見え方と比較する
    let capacity = 150
    var trace = AxisTrace()
    for index in 0..<capacity {
        let t = Double(index) / Double(capacity)
        trace.append(
            x: 6 * sin(t * .pi * 6),
            y: 3 * cos(t * .pi * 4),
            z: -1 + 2 * sin(t * .pi * 10),
            capacity: capacity
        )
    }
    return AxisTraceChart(
        trace: trace, scale: SensorChartScale.accelerationMinimum, capacity: capacity
    )
    .ignoresSafeArea()
}
