//
//  RecordingCameraView.swift
//  TennisAnalyser
//
//  Presentation — 練習セッションの連続動画録画（F-I6）
//  三脚固定した iPhone でこの画面を開いたままにしておくだけでよい。
//  Watch の計測開始/停止に連動して自動的に録画される（手動の開始/停止ボタンは無い）。

import SwiftUI
import AVFoundation

struct RecordingCameraView: View {

    /// videoStore と同一インスタンスを共有するため App 側で生成したものを注入する
    @EnvironmentObject private var recorder: PracticeVideoRecorder
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?
    /// 空き容量（W6-T17）。nil = 未取得
    @State private var capacity: StorageCapacity?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch recorder.permissionState {
            case .granted:
                cameraContent
            case .denied:
                permissionDeniedView
            case .notDetermined:
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            recorder.prepare()
            capacity = StorageCapacity.current()
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording { startTimer() } else { stopTimer() }
        }
        .alert("エラー", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(recorder.errorMessageText)
        }
    }

    // MARK: - Camera

    private var cameraContent: some View {
        ZStack {
            CameraPreviewView(recorder: recorder)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                statusBadge
                    .padding(.top, 12)
                // 操作方法は待機中にだけ出す。録画中・復旧中に読む必要は無く、
                // 状態表示を大きくした意味が薄れる
                if !recorder.isSessionActive && !recorder.isRecording {
                    Text("Apple Watch で計測を開始すると自動的に録画します")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let capacity, capacity.isLow {
                    capacityWarning(capacity)
                }
                Spacer()
            }
        }
    }

    /// 空き容量の警告（W6-T17）
    ///
    /// 削除の提案はしない。中間データは学習データの素材であり、自動削除も
    /// 期限削除も行わない方針のため（F-I7-4）。判断はユーザーに委ねる。
    private func capacityWarning(_ capacity: StorageCapacity) -> some View {
        VStack(spacing: 2) {
            Label(
                "空き容量 \(capacity.availableDescription)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            Text(String(format: "録画できる見込みは約 %.1f 時間です", capacity.estimatedRecordableHours))
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 自動録画の状態表示（手動ボタンは無い。Watch の計測開始/停止に連動する）
    ///
    /// F-I9-6: 三脚から離れて練習するため、状態を読めるのは戻ってきた一瞬だけになる。
    /// 近寄らずに読めるよう大きく出し、**3つの状態を色で区別する**。
    /// 2026-08-09 は「セッションは続いているのに録画が止まっている」状態で
    /// 5分19秒を取りこぼしたが、当時の表示ではそれが「待機中」と同じ見た目だった。
    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
            Text(statusText)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(statusColor.opacity(recorder.isRecording ? 0.0 : 0.35))
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusColor: Color {
        if recorder.isRecording { return .red }
        // セッションは続いているのに録画していない＝復旧待ち。最も見逃したくない状態
        if recorder.isSessionActive { return .orange }
        return .gray
    }

    private var statusText: String {
        if recorder.isRecording { return "録画中 \(elapsedTimeString)" }
        if recorder.isSessionActive { return "録画が停止しています（復旧中）" }
        return "待機中"
    }

    private var elapsedTimeString: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    private func startTimer() {
        elapsedSeconds = 0
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(.white)
            Text("カメラへのアクセスが許可されていません")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding()
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { recorder.errorMessage != nil }, set: { _ in })
    }
}

private extension PracticeVideoRecorder {
    var errorMessageText: String { errorMessage ?? "" }
}

// MARK: - CameraPreviewView

/// `AVCaptureVideoPreviewLayer` を表示する UIViewRepresentable
///
/// プレビューレイヤーを recorder に渡すことで、端末回転に追従した向き制御を委ねる（F-I6）
private struct CameraPreviewView: UIViewRepresentable {
    let recorder: PracticeVideoRecorder

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.videoGravity = .resizeAspectFill
        recorder.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

#Preview {
    let diagnostics = DiagnosticsStore()
    let videoStore = VideoStore(diagnostics: diagnostics)
    RecordingCameraView()
        .environmentObject(PracticeVideoRecorder(videoStore: videoStore, diagnostics: diagnostics))
}
