//
//  RecordingCameraView.swift
//  TennisAnalyser
//
//  Presentation — 練習セッションの連続動画録画（F-I6）
//  三脚固定した iPhone でこの画面を開いたまま練習し、開始/停止のみ操作する想定。

import SwiftUI
import AVFoundation

struct RecordingCameraView: View {

    /// videoStore と同一インスタンスを共有するため App 側で生成したものを注入する
    @EnvironmentObject private var recorder: PracticeVideoRecorder
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?

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
        .onAppear { recorder.prepare() }
        .alert("エラー", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(recorder.errorMessageText)
        }
    }

    // MARK: - Camera

    private var cameraContent: some View {
        ZStack {
            CameraPreviewView(session: recorder.session)
                .ignoresSafeArea()

            VStack {
                if recorder.isRecording {
                    recordingBadge
                        .padding(.top, 12)
                }
                Spacer()
                recordButton
                    .padding(.bottom, 32)
            }
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(elapsedTimeString)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording()
                stopTimer()
            } else {
                recorder.startRecording()
                startTimer()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle().fill(.red).frame(width: 62, height: 62)
                }
            }
        }
        .accessibilityLabel(recorder.isRecording ? "録画停止" : "録画開始")
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
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

#Preview {
    let videoStore = VideoStore()
    RecordingCameraView()
        .environmentObject(PracticeVideoRecorder(videoStore: videoStore))
}
