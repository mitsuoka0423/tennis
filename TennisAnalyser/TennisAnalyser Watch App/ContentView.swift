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

    /// - Parameters:
    ///   - workoutSessionManager: HealthKit マネージャー。省略時はシミュレータ向けにモックを使う
    ///   - viewModel: プレビューで計測中の表示を確認する場合に指定する
    init(
        workoutSessionManager: WorkoutSessionManager? = nil,
        viewModel: WorkoutViewModel? = nil
    ) {
        let useMock = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        _viewModel = StateObject(wrappedValue: viewModel ?? WorkoutViewModel(
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
        .navigationTitle("計測")
        .navigationBarTitleDisplayMode(.inline)
        // 計測中はナビゲーションバーごと隠す
        //
        // 1. 離脱の禁止: 他画面のセンサー取得と並走すると 200Hz の計測レートへ影響しうる
        // 2. 画面の高さの確保: 計測中の表示は停止ボタンが見切れない高さに詰めてあり
        //    （W-1）、バーのぶん縮むと再び見切れる
        .toolbar(isMeasuring ? .hidden : .visible, for: .navigationBar)
        .navigationBarBackButtonHidden(isMeasuring)
        .alert("エラー", isPresented: $isAlertPresented) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            isAlertPresented = newValue != nil
        }
    }

    /// 計測が動いている（開始処理中を含む）
    private var isMeasuring: Bool {
        viewModel.isRecording || viewModel.isStarting
    }
}

// MARK: - StartingView

/// 計測開始処理中（HealthKit 認可待ち・セッション確立中）の画面
private struct StartingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(GlassPalette.accent)
                .frame(width: 56, height: 56)
                .glassSurface(cornerRadius: 28)

            Text("準備中...")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Text("ヘルスケアの許可が\n求められる場合があります")
                .font(.system(size: 11))
                .foregroundStyle(GlassPalette.label)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - StandbyView

/// 待機中の画面（開始ボタン）
///
/// W-4: ボタンは RecordingView と同じ `measureScreen` に載せ、
/// 大きさ・位置を完全に揃える（画面切替時にボタンがずれない）
private struct StandbyView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        MeasureScreen {
            VStack(spacing: 8) {
                Image(systemName: "figure.tennis")
                    .font(.system(size: 24))
                    .foregroundStyle(GlassPalette.accent)
                    .frame(width: 56, height: 56)
                    .glassSurface(cornerRadius: 28)

                Text("スイングを記録します")
                    .font(.system(size: 12))
                    .foregroundStyle(GlassPalette.label)
            }
        } action: {
            GlassBarButton(title: "計測開始", glyph: .record, tint: GlassPalette.accent) {
                viewModel.start()
            }
        }
    }
}

// MARK: - MeasureScreen

/// 計測画面の共通の骨組み
///
/// **操作は必ず画面の下端に固定し、残りの高さへ内容を収める。**
/// 待機と計測中でボタンの位置が動かないのは、両方がこの器に載っているため（W-4）。
///
/// Why not それぞれの画面で `VStack` + `Spacer` を組む: `Spacer` は親から
/// 提案された高さが内容より小さいと縮まず、内容がはみ出したぶんだけ
/// ボタンが安全領域の外へ押し出される。実機で停止ボタンが見切れた原因がこれ（W-1）。
private struct MeasureScreen<Content: View, Action: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - RecordingView

/// 計測中の画面（リアルタイム表示 + 停止ボタン）
///
/// 経過時間を中心に置き、レートの健全性はリングの弧で示す（カタログ 1g）。
/// 動いている間に読むのは「まだ録れているか」だけなので、数値の一覧より
/// 一目で欠けが分かる形を採る。
private struct RecordingView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        MeasureScreen {
            VStack(spacing: 6) {
                // W-1: 高さが足りない機種・文字サイズではリングを一段小さくする。
                // 縮むのはリングだけで、ボタンの位置は動かない
                ViewThatFits(in: .vertical) {
                    ring(diameter: 118, timeSize: 30)
                    ring(diameter: 100, timeSize: 26)
                    ring(diameter: 84, timeSize: 22)
                }

                Text(rateText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(viewModel.measuredHz > 0 ? rateColor : GlassPalette.label)
            }
        } action: {
            GlassBarButton(title: "停止・保存", glyph: .stop, tint: GlassPalette.danger) {
                viewModel.stop()
            }
        }
    }

    /// 経過時間を囲むリング。弧の長さがレートの健全性を表す
    private func ring(diameter: CGFloat, timeSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 6)

            Circle()
                .trim(from: 0, to: rateHealth)
                .stroke(rateColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: rateColor.opacity(0.55), radius: 4)

            VStack(spacing: 0) {
                Text(viewModel.elapsedTimeString)
                    .font(.system(size: timeSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("スイング \(swingStatValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(GlassPalette.label)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// スイング数と転送状況の表示
    /// W-3: 転送前後で表記を変えず常に "n (残m)" 形式で統一
    private var swingStatValue: String {
        "\(viewModel.swingCount) (残\(viewModel.pendingTransferCount))"
    }

    private var rateText: String {
        guard viewModel.measuredHz > 0 else { return "レート測定中" }
        return String(format: "%.0f Hz ・ ロス %@", viewModel.measuredHz, viewModel.lossRateString)
    }

    /// リングの弧が示すレートの健全性（0…1）
    ///
    /// ロス率 0% で全周、5% 以上で消える。5% は赤の境界であり、
    /// そこまで来たら弧の長さより色で気づく。
    private var rateHealth: Double {
        guard viewModel.measuredHz > 0 else { return 0 }
        return 1 - min(viewModel.lossRate / 0.05, 1)
    }

    /// ロス率に応じた色: 1%未満=緑、5%未満=黄、それ以上=赤
    private var rateColor: Color {
        guard viewModel.measuredHz > 0 else { return GlassPalette.label }
        if viewModel.lossRate < 0.01 { return GlassPalette.accent }
        if viewModel.lossRate < 0.05 { return GlassPalette.warning }
        return GlassPalette.danger
    }
}

// MARK: - Preview

#Preview("待機") {
    // 実際の呼び出し元（RootView）と同じ NavigationStack の下で確認する
    NavigationStack {
        ContentView()
    }
}

#Preview("計測中") {
    RecordingStatePreview()
}

/// 計測中の表示を確認するためのプレビュー用ラッパー
///
/// 計測中は停止ボタンが見切れやすいため（W-1）、この状態を単体で見られるようにする。
/// `useMock: true` なら HealthKit を経ずに計測状態へ入る。
///
/// Why not `#Preview` の中で直接 `start()` を呼ぶ: プレビューのコード変換
/// （`__designTimeSelection`）が文と `return` の混在で解決に失敗し、
/// ファイル全体のプレビューがビルドできなくなる。
private struct RecordingStatePreview: View {
    @StateObject private var viewModel = WorkoutViewModel(useMock: true)

    var body: some View {
        NavigationStack {
            ContentView(viewModel: viewModel)
        }
        .task { viewModel.start() }
    }
}
