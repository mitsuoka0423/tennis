//
//  PracticeVideoRecorder.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — AVFoundation によるセッション連続録画（F-I6）
//
//  Why not 高フレームレート撮影: 端末ごとに対応フォーマットが異なり実機無しでは
//  検証リスクが高い。まずは通常撮影＋再生速度変更（SwingDetailView 側）で
//  「スロー」を実現し、必要になれば高fpsフォーマットへ切り替える
//  （録画・同期の仕組みはそのまま流用できる設計にしている）。
//
//  Why not 手動の開始/停止ボタン: Watch のセッション開始/終了に連動して
//  自動的に録画する（V-T6/T7）。ユーザーが iPhone を三脚固定したあとに
//  操作するのはカメラ権限の許可のみで済む。

import AVFoundation
import Combine
import UIKit
import os

/// カメラ権限の状態
enum CameraPermissionState {
    case notDetermined
    case granted
    case denied
}

/// 練習セッション中の連続動画録画を管理する（Watch からの通知で自動的に開始/停止する）
///
/// - 音声トラックは録音しない（フォーム分析に不要）
/// - アプリがバックグラウンドへ遷移した場合は自動停止する（ファイル破損防止）
@MainActor
final class PracticeVideoRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var permissionState: CameraPermissionState = .notDetermined
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.spleeing.TennisAnalyser.cameraSession")
    private var isConfigured = false

    // 端末の物理的な向きを加速度センサーで追跡し、プレビュー・録画それぞれに
    // 水平基準の回転角度を提供する（F-I6 横向き対応）。
    // Why not UIDevice.orientation: 三脚固定では faceUp 等になり信頼できないため、
    // Apple 推奨の RotationCoordinator を使う。
    private var videoDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?

    private let videoStore: VideoStore
    private let diagnostics: DiagnosticsStore
    private var pendingSessionId: String?
    private var recordingStartedAt: Date?

    /// 停止を要求した側が設定する終了理由。`didFinishRecordingTo` は
    /// 停止が「セッション終了によるもの」か「中断によるもの」かを判別できないため、
    /// 停止要求の時点で理由を預かる。
    private var pendingEndReason: SegmentEndReason = .sessionEnded

    /// セグメント番号。W2（F-I7-3）で分割録画に対応するまでは 1本のみのため 0 固定
    private static let singleSegmentIndex = 0

    init(videoStore: VideoStore, diagnostics: DiagnosticsStore) {
        self.videoStore = videoStore
        self.diagnostics = diagnostics
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    // MARK: - Permission & Setup

    /// カメラ権限を確認・要求し、許可されたらセッションを構成する
    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.permissionState = granted ? .granted : .denied
                    if granted { self?.configureSessionIfNeeded() }
                }
            }
        default:
            permissionState = .denied
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            sessionQueue.async { [session] in session.startRunning() }
            return
        }
        isConfigured = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                Task { @MainActor in self.errorMessage = "カメラを初期化できませんでした。" }
                return
            }
            self.session.addInput(input)

            guard self.session.canAddOutput(self.movieOutput) else {
                self.session.commitConfiguration()
                Task { @MainActor in self.errorMessage = "動画出力を初期化できませんでした。" }
                return
            }
            self.session.addOutput(self.movieOutput)
            self.session.commitConfiguration()
            self.session.startRunning()

            Task { @MainActor in
                self.videoDevice = device
                self.setUpRotationCoordinator()
            }
        }
    }

    // MARK: - Orientation（F-I6 横向き対応）

    /// プレビューレイヤーを受け取り、回転追跡をセットアップする（View の生成時に呼ぶ）
    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        previewLayer = layer
        setUpRotationCoordinator()
    }

    /// デバイスとプレビューレイヤーが揃った時点で RotationCoordinator を構成する。
    /// 片方が未確定でも（プレビュー未表示など）デバイスさえあれば録画用の角度は得られる。
    @MainActor
    private func setUpRotationCoordinator() {
        guard let videoDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        // プレビューの向きは端末回転に追従してリアルタイム更新する
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyPreviewRotation(angle) }
        }
    }

    @MainActor
    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Recording（Watch からのセッション通知で呼ばれる。F-I6）

    func startRecording(sessionId: String) {
        guard !isRecording, permissionState == .granted else { return }
        guard let url = try? videoStore.newSourceRecordingURL(sessionId: sessionId) else {
            errorMessage = "保存先を作成できませんでした。"
            return
        }
        pendingSessionId = sessionId
        // 録画開始時点の向きをファイルに固定する（三脚固定で先に向きを決めてから
        // Watch で計測開始する運用のため、開始時の角度を採用すれば十分）
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async { [movieOutput] in
            if let captureAngle,
               let connection = movieOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(captureAngle) {
                connection.videoRotationAngle = captureAngle
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording(reason: SegmentEndReason = .sessionEnded) {
        guard isRecording else { return }
        pendingEndReason = reason
        sessionQueue.async { [movieOutput] in
            movieOutput.stopRecording()
        }
    }

    @objc private func handleWillResignActive() {
        if isRecording { stopRecording(reason: .interrupted) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension PracticeVideoRecorder: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // 実際に録画が始まった時刻を起点にする（通知〜開始のラグを除くため）
        let startedAt = Date()
        Task { @MainActor in
            self.recordingStartedAt = startedAt
            self.isRecording = true
            AppLog.recording.info("segment started: \(fileURL.lastPathComponent, privacy: .public)")
            if let sessionId = self.pendingSessionId {
                self.diagnostics.record(
                    .segmentStarted(index: Self.singleSegmentIndex, at: startedAt), for: sessionId
                )
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let endedAt = Date()
        Task { @MainActor in
            self.isRecording = false
            guard let sessionId = self.pendingSessionId, let startedAt = self.recordingStartedAt else { return }
            self.pendingSessionId = nil
            self.recordingStartedAt = nil
            let reason = self.pendingEndReason
            self.pendingEndReason = .sessionEnded

            if let error {
                // AVFoundation は正常停止時にも「非ゼロ」エラーを返すことがあるため、
                // ファイルが実際に存在するかで成否を判断する
                let recordedSuccessfully = (error as NSError)
                    .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                if !recordedSuccessfully {
                    AppLog.recording.error(
                        "segment failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.diagnostics.record(
                        .segmentEnded(index: Self.singleSegmentIndex, at: endedAt, reason: .error),
                        for: sessionId
                    )
                    self.errorMessage = "録画に失敗しました: \(error.localizedDescription)"
                    return
                }
            }

            AppLog.recording.info(
                """
                segment ended: reason=\(reason.rawValue, privacy: .public) \
                duration=\(endedAt.timeIntervalSince(startedAt), format: .fixed(precision: 1))s
                """
            )
            self.diagnostics.record(
                .segmentEnded(index: Self.singleSegmentIndex, at: endedAt, reason: reason),
                for: sessionId
            )

            let video = PracticeVideo(
                id: sessionId, startedAt: startedAt, endedAt: endedAt,
                fileName: outputFileURL.lastPathComponent
            )
            self.videoStore.saveSourceMetadata(video)
        }
    }
}
