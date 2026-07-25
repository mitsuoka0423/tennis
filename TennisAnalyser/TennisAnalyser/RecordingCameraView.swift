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
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(recorder.isRecording ? .red : .gray)
                .frame(width: 10, height: 10)
            Text(recorder.isRecording ? "自動録画中 \(elapsedTimeString)" : "待機中（Watchで計測を開始すると自動的に録画します）")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
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
