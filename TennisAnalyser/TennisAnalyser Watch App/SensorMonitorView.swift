//
//  SensorMonitorView.swift
//  TennisAnalyser Watch App
//
//  Presentation View — センサー値のリアルタイム時系列表示（F-W9 デモ）

import SwiftUI

/// 加速度3軸・角速度3軸を軸ごとの波形として実時間で表示するデモ画面
///
/// 画面を開いている間だけサンプリングし、保存も転送も行わない。
struct SensorMonitorView: View {

    @StateObject private var viewModel: SensorMonitorViewModel
    @State private var isAlertPresented = false
    @State private var accelerationScaleIndex = SensorChartScale.defaultAccelerationIndex
    @State private var rotationScaleIndex = SensorChartScale.defaultRotationIndex

    /// - Parameter viewModel: プレビューやテストで差し替える場合に指定する
    ///
    /// Why not 既定値に `SensorMonitorViewModel()` を直接書く: デフォルト引数は
    /// 呼び出し側の nonisolated な文脈で評価されるため、MainActor 隔離された
    /// イニシャライザを呼べずビルドが通らない。
    init(viewModel: SensorMonitorViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SensorMonitorViewModel())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                traceSection(
                    title: "加速度",
                    unit: "g",
                    trace: viewModel.accelerationTrace,
                    scale: SensorChartScale.acceleration[accelerationScaleIndex],
                    scaleLabel: SensorChartScale.accelerationLabel(accelerationScaleIndex),
                    format: "%+.2f",
                    values: (viewModel.latest?.accX, viewModel.latest?.accY, viewModel.latest?.accZ)
                ) {
                    accelerationScaleIndex =
                        (accelerationScaleIndex + 1) % SensorChartScale.acceleration.count
                }

                traceSection(
                    title: "角速度",
                    unit: "°/s",
                    trace: viewModel.rotationTrace,
                    scale: SensorChartScale.rotation[rotationScaleIndex],
                    scaleLabel: SensorChartScale.rotationLabel(rotationScaleIndex),
                    format: "%+.0f",
                    values: (viewModel.latest?.gyroX, viewModel.latest?.gyroY, viewModel.latest?.gyroZ)
                ) {
                    rotationScaleIndex =
                        (rotationScaleIndex + 1) % SensorChartScale.rotation.count
                }

                footer
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("センサー")
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

    // MARK: - 波形1組（3軸を重ねた1枚 + 現在値）

    private func traceSection(
        title: String,
        unit: String,
        trace: AxisTrace,
        scale: Double,
        scaleLabel: String,
        format: String,
        values: (Double?, Double?, Double?),
        onCycleScale: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                Spacer()
                // 実機で見ながら合わせられるよう、タップでスケールを循環させる
                Button(action: onCycleScale) {
                    Text(scaleLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            AxisTraceChart(trace: trace, scale: scale, capacity: viewModel.traceCapacity)
                .frame(height: 58)

            HStack(spacing: 0) {
                AxisValue(label: "X", value: values.0, format: format, color: SensorAxisColor.x)
                AxisValue(label: "Y", value: values.1, format: format, color: SensorAxisColor.y)
                AxisValue(label: "Z", value: values.2, format: format, color: SensorAxisColor.z)
            }
        }
    }

    // MARK: - 状態と操作

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? .green : .gray)
                    .frame(width: 6, height: 6)
                Text(viewModel.isRunning ? "計測中" : "停止中")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                Spacer()
                Text(viewModel.measuredHz > 0 ? String(format: "%.0f Hz", viewModel.measuredHz) : "--- Hz")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .monospacedDigit()
            }

            Button {
                if viewModel.isRunning {
                    viewModel.stop()
                } else {
                    viewModel.start()
                }
            } label: {
                Label(
                    viewModel.isRunning ? "一時停止" : "再開",
                    systemImage: viewModel.isRunning ? "pause.circle" : "play.circle"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(viewModel.isRunning ? Color.orange : Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 縦軸スケール

/// 波形の縦軸スケール
///
/// **調整するのはここ。** 既定値は 2026-07-21 の実測分布に合わせている
/// （合成加速度の中央値 7g・p90 22g。軸ごとに分けると通常の素振りは ±8g に収まる）。
/// 画面上のラベルをタップすると候補を循環するので、実機で見ながら選べる。
enum SensorChartScale {
    /// 加速度の縦軸候補 (±g)
    static let acceleration: [Double] = [4, 8, 16]
    /// 角速度の縦軸候補 (±°/s)
    static let rotation: [Double] = [500, 1000, 2000]

    static let defaultAccelerationIndex = 1
    static let defaultRotationIndex = 1

    static func accelerationLabel(_ index: Int) -> String {
        String(format: "±%.0fg", acceleration[index])
    }

    static func rotationLabel(_ index: Int) -> String {
        String(format: "±%.0f", rotation[index])
    }
}

/// 軸の色。X/Y/Z を通して同じ対応にする
enum SensorAxisColor {
    static let x = Color.red
    static let y = Color.green
    static let z = Color.cyan
}

// MARK: - AxisTraceChart

/// 3軸を1枚に重ねた波形
///
/// 最新が右端。点数が `capacity` に満たない開始直後は左側が空く
/// （時間軸の目盛りを一定に保つため、幅いっぱいへ引き伸ばさない）。
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
            context.stroke(baseline, with: .color(.white.opacity(0.18)), lineWidth: 1)

            guard capacity > 1, !trace.isEmpty else { return }

            let step = size.width / Double(capacity - 1)
            let count = trace.x.count

            func path(for values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    // 右端を最新にするため、末尾からの距離で位置を決める
                    let x = size.width - Double(count - 1 - index) * step
                    let clamped = max(min(value / scale, 1.0), -1.0)
                    let y = midY - clamped * (size.height / 2 - 1)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                return path
            }

            let style = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            context.stroke(path(for: trace.z), with: .color(SensorAxisColor.z), style: style)
            context.stroke(path(for: trace.y), with: .color(SensorAxisColor.y), style: style)
            context.stroke(path(for: trace.x), with: .color(SensorAxisColor.x), style: style)
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(value.map { String(format: format, $0) } ?? "---")
                .font(.system(size: 11, design: .monospaced))
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
    return VStack {
        AxisTraceChart(trace: trace, scale: 8, capacity: capacity)
            .frame(height: 58)
        AxisTraceChart(trace: trace, scale: 4, capacity: capacity)
            .frame(height: 58)
    }
    .padding(6)
}
