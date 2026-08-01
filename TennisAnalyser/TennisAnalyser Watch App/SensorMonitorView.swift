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
            VStack(spacing: 10) {
                traceSection(
                    title: "加速度",
                    unit: "g",
                    trace: viewModel.accelerationTrace,
                    scale: viewModel.accelerationScale,
                    scaleLabel: SensorChartScale.accelerationLabel(viewModel.accelerationScale),
                    format: "%+.2f",
                    values: (viewModel.latest?.accX, viewModel.latest?.accY, viewModel.latest?.accZ)
                )

                traceSection(
                    title: "角速度",
                    unit: "°/s",
                    trace: viewModel.rotationTrace,
                    scale: viewModel.rotationScale,
                    scaleLabel: SensorChartScale.rotationLabel(viewModel.rotationScale),
                    format: "%+.0f",
                    values: (viewModel.latest?.gyroX, viewModel.latest?.gyroY, viewModel.latest?.gyroZ)
                )

                footer
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("モニター")
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
        values: (Double?, Double?, Double?)
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(GlassPalette.label)
                Spacer()
                // 目盛りが動くため、いま何倍で見ているかを常に添える
                Text(scaleLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GlassPalette.info)
                    .animation(.default, value: scaleLabel)
            }

            AxisTraceChart(trace: trace, scale: scale, capacity: viewModel.traceCapacity)
                .frame(height: 66)
                .padding(3)
                .glassSurface(cornerRadius: 12)

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
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isRunning ? GlassPalette.accent : GlassPalette.label)
                    .frame(width: 6, height: 6)
                // 「計測中」ではなく「取得中」。計測画面（F-W1〜W6）と紛らわしいため
                Text(viewModel.isRunning ? "取得中" : "停止中")
                    .font(.system(size: 11))
                    .foregroundStyle(GlassPalette.label)
                Spacer()
                Text(viewModel.measuredHz > 0 ? String(format: "%.0f Hz", viewModel.measuredHz) : "--- Hz")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GlassPalette.label)
            }

            GlassBarButton(
                title: viewModel.isRunning ? "一時停止" : "再開",
                tint: viewModel.isRunning ? GlassPalette.caution : GlassPalette.accent
            ) {
                if viewModel.isRunning {
                    viewModel.stop()
                } else {
                    viewModel.start()
                }
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
            context.stroke(baseline, with: .color(.white.opacity(0.16)), lineWidth: 1)

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

            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

            // 奥から Z→Y→X。X（振りの主成分）を最前面に置く
            for (values, color) in [
                (trace.z, SensorAxisColor.z),
                (trace.y, SensorAxisColor.y),
                (trace.x, SensorAxisColor.x)
            ] {
                let line = path(for: values)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: color.opacity(0.7), radius: 3))
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
        HStack(spacing: 2) {
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
    return VStack(spacing: 10) {
        AxisTraceChart(trace: trace, scale: fitted, capacity: capacity)
            .frame(height: 66)
            .padding(3)
            .glassSurface(cornerRadius: 12)
        AxisTraceChart(trace: trace, scale: SensorChartScale.accelerationMinimum, capacity: capacity)
            .frame(height: 66)
            .padding(3)
            .glassSurface(cornerRadius: 12)
    }
    .padding(8)
}
