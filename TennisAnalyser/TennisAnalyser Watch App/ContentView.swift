//
//  ContentView.swift
//  TennisAnalyser Watch App
//
//  Presentation View — セッション開始/停止 + リアルタイム状態表示

import SwiftUI

struct ContentView: View {

    /// App から注入される WorkoutSessionManager（HealthKit 認可済み）
    /// 省略時はシミュレータ向けにモックを使用する
    @StateObject private var viewModel: WorkoutViewModel
    @State private var isAlertPresented = false

    init(workoutSessionManager: WorkoutSessionManager? = nil) {
        let useMock = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            useMock: useMock,
            workoutSessionManager: workoutSessionManager
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isRecording {
                RecordingView(viewModel: viewModel)
            } else if viewModel.isStarting {
                StartingView()
            } else {
                StandbyView(viewModel: viewModel)
            }
        }
        .alert("エラー", isPresented: $isAlertPresented) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            isAlertPresented = newValue != nil
        }
    }
}

// MARK: - StartingView

/// 計測開始処理中（HealthKit 認可待ち・セッション確立中）の画面
private struct StartingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.green)
                .scaleEffect(1.4)

            Text("準備中...")
                .font(.headline)
                .foregroundStyle(.white)

            Text("ヘルスケアの許可が\n求められる場合があります")
                .font(.caption2)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - StandbyView

/// 待機中の画面（開始ボタン）
private struct StandbyView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.tennis")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Tennis Analyser")
                .font(.headline)
                .foregroundStyle(.white)

            Button {
                viewModel.start()
            } label: {
                Label("計測開始", systemImage: "record.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

// MARK: - RecordingView

/// 計測中の画面（リアルタイム表示 + 停止ボタン）
private struct RecordingView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        VStack(spacing: 8) {
            // 録音中インジケーター
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.3)
                Text("計測中")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 経過時間
            Text(viewModel.elapsedTimeString)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            // サンプル数 / 実測Hz / ロス率
            VStack(spacing: 2) {
                StatRow(label: "サンプル数", value: "\(viewModel.sampleCount.formatted())")
                StatRow(
                    label: "実測Hz",
                    value: viewModel.measuredHz > 0
                        ? String(format: "%.0f Hz", viewModel.measuredHz)
                        : "---"
                )
                StatRow(
                    label: "ロス率",
                    value: viewModel.measuredHz > 0
                        ? viewModel.lossRateString
                        : "---",
                    valueColor: lossRateColor(viewModel.lossRate)
                )
            }
            .padding(.vertical, 4)

            Spacer()

            Button {
                viewModel.stop()
            } label: {
                Label("停止・保存", systemImage: "stop.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    /// ロス率に応じた色: 1%未満=緑、5%未満=黄、それ以上=赤
    private func lossRateColor(_ rate: Double) -> Color {
        if rate < 0.01 { return .green }
        if rate < 0.05 { return .yellow }
        return .red
    }
}

// MARK: - StatRow

private struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.gray)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
