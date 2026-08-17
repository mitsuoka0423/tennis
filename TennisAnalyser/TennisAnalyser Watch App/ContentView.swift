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
            GlassBarButton(
                title: "計測開始", glyph: .record, kind: .prominent, tint: GlassPalette.accent
            ) {
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
/// 要点であるスイング数を先に置き、その内訳を時系列の棒で下に添える
/// （HIG Charts）。動いている間に読むのは「録れているか」と「振れているか」の
/// 2つだけなので、経過時間とレートは状態行へ退ける。
private struct RecordingView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        RecordingLayout(
            elapsedText: viewModel.elapsedTimeString,
            swingCount: viewModel.swingCount,
            pendingTransferCount: viewModel.pendingTransferCount,
            measuredHz: viewModel.measuredHz,
            lossRate: viewModel.lossRate,
            buckets: viewModel.swingBuckets,
            onStop: { viewModel.stop() }
        )
    }
}

/// 計測中の表示そのもの
///
/// Why not `RecordingView` に直接書く: 計測中の値は `WorkoutViewModel` の
/// 外から入れられず、プレビューでこの画面を出すには実際にセンサーを回して
/// 待つしかなかった。値を引数で受け、見た目だけを単体で確認できるようにする。
private struct RecordingLayout: View {
    let elapsedText: String
    let swingCount: Int
    let pendingTransferCount: Int
    let measuredHz: Double
    let lossRate: Double
    let buckets: [Int?]
    let onStop: () -> Void

    @State private var isBlinkOn = false

    var body: some View {
        MeasureScreen {
            VStack(alignment: .leading, spacing: 0) {
                statusRow

                Text("スイング")
                    .font(.system(size: 11))
                    .foregroundStyle(GlassPalette.secondaryText)
                    .padding(.top, 10)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(swingCount)")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("回")
                        .font(.system(size: 12))
                        .foregroundStyle(GlassPalette.secondaryText)
                    Spacer(minLength: 0)
                    Text("直近15秒 \(latestBucket)")
                        .font(.system(size: 11))
                        .foregroundStyle(GlassPalette.secondaryText)
                }

                SwingBarChart(buckets: buckets)
                    .padding(.top, 8)

                axisRow

                Spacer(minLength: 0)
            }
        } action: {
            GlassBarButton(
                title: "停止・保存", glyph: .stop, kind: .tinted, tint: GlassPalette.danger
            ) {
                onStop()
            }
        }
    }

    /// 録れているかを示す行。点滅する点・経過時間・実測レート
    private var statusRow: some View {
        HStack(spacing: 5) {
            // リングを廃したため、記録が続いていることを示すのはこの点だけになる
            Circle()
                .fill(GlassPalette.danger)
                .frame(width: 7, height: 7)
                .opacity(isBlinkOn ? 1 : 0.25)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: isBlinkOn)
                .onAppear { isBlinkOn = true }

            Text(elapsedText)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(GlassPalette.text.opacity(0.7))

            Spacer(minLength: 0)

            // W-3: 転送の滞りは残件数で示す。転送前後で表記を変えない
            Text("残 \(pendingTransferCount)")
                .font(.system(size: 11))
                .foregroundStyle(GlassPalette.tertiaryText)

            Text(rateText)
                .font(.system(size: 11))
                .foregroundStyle(rateColor)
        }
    }

    /// 直近の窓のスイング数。最新の棒がどれかを色だけに頼らず示す
    private var latestBucket: Int {
        buckets.compactMap { $0 }.last ?? 0
    }

    /// 棒グラフの時間軸。両端と、破線が指す平均だけを添える
    private var axisRow: some View {
        HStack {
            Text("-3分")
            Spacer(minLength: 0)
            Text(String(format: "平均 %.1f", averageSwings))
            Spacer(minLength: 0)
            Text("現在")
        }
        .font(.system(size: 9))
        .foregroundStyle(GlassPalette.tertiaryText)
        .padding(.top, 3)
    }

    private var averageSwings: Double {
        let values = buckets.compactMap { $0 }
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private var rateText: String {
        guard measuredHz > 0 else { return "--- Hz" }
        return String(format: "%.0f Hz", measuredHz)
    }

    /// ロス率に応じた色: 1%未満=緑、5%未満=黄、それ以上=赤
    ///
    /// Why not レートを常に同じ濃度の白で出す: ロス率の数値を置く場所が
    /// 無くなったため、健全かどうかはこの色でしか分からない。
    private var rateColor: Color {
        guard measuredHz > 0 else { return GlassPalette.tertiaryText }
        if lossRate < 0.01 { return GlassPalette.text.opacity(0.5) }
        if lossRate < 0.05 { return GlassPalette.warning }
        return GlassPalette.danger
    }
}

// MARK: - SwingBarChart

/// 15秒ごとのスイング数を並べた棒グラフ
///
/// 最新の窓だけを濃い緑にし、残りは 45% へ落とす。色だけに頼らず
/// 「直近15秒」の数値も添えるため、どれが最新かは両方から読める。
///
/// Why not `Chart`（Swift Charts）を使う: 目盛りも凡例も出さない 12 本の棒に
/// 対して、軸の描画を止める指定のほうが記述量が多くなる。
private struct SwingBarChart: View {
    /// 右端が現在の窓。`nil` は計測開始前で、記録が無いこと自体を薄い棒で示す
    let buckets: [Int?]

    private var values: [Int] { buckets.compactMap { $0 } }

    /// 縦軸の上限。1窓 12回（4秒に1回）を下限に、超えたら実測へ合わせる
    private var upperBound: Double { Double(max(12, values.max() ?? 0)) }

    private var average: Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    /// 最新の窓の位置。ここだけ濃く塗る
    private var latestIndex: Int? {
        buckets.lastIndex { $0 != nil }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(index: index, value: value))
                            .frame(maxWidth: .infinity)
                            .frame(height: height(of: value, in: geometry.size.height))
                    }
                }

                if !values.isEmpty {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                    }
                    .stroke(
                        GlassPalette.text.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
                    .frame(height: 1)
                    .offset(y: -average / upperBound * geometry.size.height)
                }
            }
        }
        .frame(height: 54)
    }

    private func height(of value: Int?, in available: CGFloat) -> CGFloat {
        guard let value else { return 2 }
        return max(2, Double(value) / upperBound * available)
    }

    private func color(index: Int, value: Int?) -> Color {
        guard value != nil else { return .white.opacity(0.06) }
        return index == latestIndex ? GlassPalette.accent : GlassPalette.accent.opacity(0.45)
    }
}

// MARK: - Preview

#Preview("待機") {
    // 実際の呼び出し元（RootView）と同じ NavigationStack の下で確認する
    NavigationStack {
        ContentView()
    }
}

#Preview("計測中の表示") {
    // 見た目の確認用。センサーの到着を待たずに、値が揃った状態を出す
    RecordingLayout(
        elapsedText: "03:07",
        swingCount: 96,
        pendingTransferCount: 2,
        measuredHz: 198,
        lossRate: 0.008,
        buckets: [nil, nil, nil, 4, 9, 7, 12, 6, 0, 8, 11, 5],
        onStop: {}
    )
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
