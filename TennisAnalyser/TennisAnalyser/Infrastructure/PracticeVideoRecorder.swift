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

    /// 物理状態: いま実際に録画しているか
    @Published private(set) var isRecording = false

    /// 論理状態: Watch のセッションが継続中か（F-I7-2）
    ///
    /// Why not isRecording だけで判断: 中断中は「録画していない」が「セッションは続いている」。
    /// この2つを同一視していたため、2026-07-21 は中断後に再開すべきかどうかを
    /// 判断する材料が無く、57分間停止したままになった。
    @Published private(set) var isSessionActive = false
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
    /// セッションが継続中の間だけ保持する sessionId（中断復帰時の再開先）
    private var activeSessionId: String?

    /// 1セグメントの最大長（F-I7-3）。到達したら次のセグメントへ切り替える
    ///
    /// Why not 無制限: 1時間の 1080p は 5〜7GB に達し、1ファイルの破損が全損に直結する。
    /// セグメントは一次データであり、失うと1時間の実練習をやり直すことになる。
    private static let maxSegmentDuration = CMTime(seconds: 600, preferredTimescale: 600)

    /// 停止を要求した側が設定する終了理由。`didFinishRecordingTo` は
    /// 停止が「セッション終了によるもの」か「中断によるもの」かを判別できないため、
    /// 停止要求の時点で理由を預かる。
    private var pendingEndReason: SegmentEndReason = .sessionEnded

    /// 録画中のセグメント番号（F-I7-3）
    private var currentSegmentIndex = 0

    // MARK: - 復旧監視（F-I9-1）と上限（F-I9-2）

    /// 復旧監視の間隔。「継続中なのに録画していない」状態をこの周期で拾う
    private static let supervisorInterval: TimeInterval = 5

    /// セッションの最大長（F-I9-2）
    ///
    /// Why not 上限なし: 終了通知が届かないまま持ち帰ると録画が回り続ける。
    /// 1080p は 5〜7GB/時であり、空き 90GB を半日で埋める。
    private static let maxSessionDuration: TimeInterval = 3 * 60 * 60

    /// 空き容量を読む間隔。5秒ごとに読むほど速く減る値ではない
    private static let capacityCheckInterval: TimeInterval = 60

    private var supervisorTask: Task<Void, Never>?
    /// セッション開始時刻（最大長の判定に使う）
    private var sessionStartedAt: Date?
    private var lastCapacityCheckAt: Date?
    /// 中断で止まったまま、まだ録画が再開していない
    private var isAwaitingRecovery = false

    init(videoStore: VideoStore, diagnostics: DiagnosticsStore) {
        self.videoStore = videoStore
        self.diagnostics = diagnostics
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        // 中断からの復帰経路（F-I7-2）。中断の入口は複数あるため、
        // 復帰契機も「アプリが前面に戻った」「キャプチャの中断が明けた」の両方を購読する
        center.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleSessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted, object: session
        )
        center.addObserver(
            self, selector: #selector(handleSessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded, object: session
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
            self.movieOutput.maxRecordedDuration = Self.maxSegmentDuration
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

    /// Watch のセッション開始通知を受けて録画を始める（F-I7-2）
    func beginSession(sessionId: String) {
        isSessionActive = true
        activeSessionId = sessionId
        sessionStartedAt = Date()
        lastCapacityCheckAt = nil
        isAwaitingRecovery = false
        startSupervisor()
        startNextSegment()
    }

    /// Watch のセッション終了通知を受けて録画を終える
    func endSession() {
        clearSessionState()
        stopRecording(reason: .sessionEnded)
    }

    private func clearSessionState() {
        supervisorTask?.cancel()
        supervisorTask = nil
        isSessionActive = false
        activeSessionId = nil
        sessionStartedAt = nil
        lastCapacityCheckAt = nil
        isAwaitingRecovery = false
    }

    /// 次のセグメントの録画を開始する
    ///
    /// 中断復帰・最大長到達・セッション開始のいずれからも呼ばれる。
    /// `.mov` へ追記する API が無いため、再開は常に新しいセグメントになる。
    private func startNextSegment() {
        guard let sessionId = activeSessionId else { return }
        guard !isRecording, permissionState == .granted else { return }
        let index = videoStore.nextSegmentIndex(sessionId: sessionId)
        guard let url = try? videoStore.newSegmentURL(sessionId: sessionId, index: index) else {
            errorMessage = "保存先を作成できませんでした。"
            return
        }
        pendingSessionId = sessionId
        currentSegmentIndex = index
        setIdleTimerDisabled(true)
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

    // MARK: - 中断と復帰（F-I7-2）

    @objc private func handleWillResignActive() {
        // Why not 停止しない: バックグラウンドでは AVCaptureSession が OS により
        // 必ず停止される。停止を待つと書き込み途中のファイルが壊れるため、先に閉じる。
        guard isRecording else { return }
        recordInterruption("willResignActive")
        stopRecording(reason: .interrupted)
    }

    @objc private func handleDidBecomeActive() {
        attemptRecovery(trigger: "didBecomeActive")
    }

    @objc private func handleSessionWasInterrupted(_ note: Notification) {
        let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map(String.init) ?? "unknown"
        recordInterruption("captureInterrupted(reason=\(reason))")
        if isRecording { stopRecording(reason: .interrupted) }
    }

    @objc private func handleSessionInterruptionEnded() {
        attemptRecovery(trigger: "captureInterruptionEnded")
    }

    /// セッションが継続中なのに録画が止まっていれば再開を試みる（F-I9-1）
    ///
    /// 「論理状態が有効かつ物理状態が停止」という**状態だけ**で判断する。
    /// どの経路から呼ばれても同じ結果になり、二重に開始することもない。
    ///
    /// Why not 記録するのが `interruptionEnded` ではなく `recoveryAttempted` なのか:
    /// ここは「試みた」時点であり、実際に録画が始まるとは限らない。
    /// 復帰したことは `didStartRecordingTo` 側で記録する。両者を混ぜると、
    /// 「中断したまま戻れていない」ことを数えられなくなる。
    private func attemptRecovery(trigger: String) {
        guard isSessionActive, !isRecording, let sessionId = activeSessionId else { return }
        guard permissionState == .granted else {
            AppLog.recording.error("recovery blocked: camera permission not granted")
            return
        }
        AppLog.recording.info("recovery attempt: trigger=\(trigger, privacy: .public)")
        diagnostics.record(.recoveryAttempted(at: Date(), trigger: trigger), for: sessionId)
        // 中断中は AVCaptureSession 自体も停止しているため、走らせ直してから録画する
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        startNextSegment()
    }

    // MARK: - 復旧監視（F-I9-1）と上限（F-I9-2）

    /// セッションが続く限り、状態を見て復旧を試み続ける
    ///
    /// Why not 停止契機ごとに通知を購読する（F-I7-2 の設計）: 通知2本
    /// （`didBecomeActive` / `AVCaptureSessionInterruptionEnded`）では
    /// `.error` でのセグメント終了・保存先作成の失敗・中断終了の通知が来ない中断を拾えず、
    /// 一度当たるとセッションの残り全部が空白になる。停止の原因を列挙する設計は、
    /// 列挙漏れの分だけそのまま欠陥になる。
    ///
    /// Why not バックグラウンドでも動かす: iOS はバックグラウンドで
    /// `AVCaptureSession` を動かさない。App が suspend されればこの Task も止まり、
    /// 前面へ戻ったときに `didBecomeActive` と本監視の両方が復旧を試みる。
    private func startSupervisor() {
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.supervisorInterval))
                guard !Task.isCancelled, let self else { return }
                self.superviseTick()
            }
        }
    }

    private func superviseTick() {
        guard isSessionActive, let sessionId = activeSessionId else { return }

        if let reason = exceededLimitReason() {
            AppLog.recording.info("session limit reached: \(reason, privacy: .public)")
            diagnostics.record(.sessionLimitReached(at: Date(), reason: reason), for: sessionId)
            errorMessage = "上限に達したため録画を終了しました（\(reason)）。"
            clearSessionState()
            stopRecording(reason: .limitReached)
            return
        }

        guard !isRecording else { return }
        attemptRecovery(trigger: "supervisor")
    }

    /// 上限に達していればその理由を返す（F-I9-2）
    private func exceededLimitReason() -> String? {
        if let sessionStartedAt,
           Date().timeIntervalSince(sessionStartedAt) >= Self.maxSessionDuration {
            return "maxSessionDuration(\(Int(Self.maxSessionDuration / 3600))h)"
        }

        let now = Date()
        if let lastCapacityCheckAt,
           now.timeIntervalSince(lastCapacityCheckAt) < Self.capacityCheckInterval {
            return nil
        }
        lastCapacityCheckAt = now
        if let capacity = StorageCapacity.current(), capacity.isCritical {
            return "storageCritical(\(capacity.availableDescription))"
        }
        return nil
    }

    private func recordInterruption(_ reason: String) {
        guard let sessionId = activeSessionId else { return }
        AppLog.recording.info("interrupted: \(reason, privacy: .public)")
        diagnostics.record(.interrupted(at: Date(), reason: reason), for: sessionId)
    }

    // MARK: - 自動ロックの抑止（F-I7-T3）

    /// 画面の自動ロックを抑止する
    ///
    /// 2026-07-21 の実機検証では、三脚固定で操作しないため自動ロックが発火し、
    /// `willResignActive` 経由で録画が停止していた。録画中だけ抑止する。
    ///
    /// Why not 常時抑止: 画面が点きっぱなしになりバッテリーを消費する。
    /// 録画していない間まで抑止する理由が無い。
    private func setIdleTimerDisabled(_ disabled: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
        AppLog.recording.info("idle timer disabled: \(disabled, privacy: .public)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Why not setIdleTimerDisabled(false): deinit は nonisolated であり
        // @MainActor のメソッドを呼べない。UIApplication へは MainActor 上で触る必要がある。
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
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
                let index = self.currentSegmentIndex
                self.videoStore.registerSegmentStart(sessionId: sessionId, index: index, startedAt: startedAt)
                self.diagnostics.record(.segmentStarted(index: index, at: startedAt), for: sessionId)
                // 中断で止まっていたぶんが実際に戻った時点を記録する（F-I9-1）。
                // 試行（recoveryAttempted）と分けているのは、試みたが開始できていない
                // 状態を数えられるようにするため
                if self.isAwaitingRecovery {
                    self.isAwaitingRecovery = false
                    self.diagnostics.record(.interruptionEnded(at: startedAt), for: sessionId)
                }
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
            // 録画していない間まで画面を点けておく理由が無いため、確実に戻す。
            // guard の前に置くのは、以降の早期 return でも抑止が残らないようにするため
            self.setIdleTimerDisabled(false)
            guard let sessionId = self.pendingSessionId, let startedAt = self.recordingStartedAt else { return }
            self.pendingSessionId = nil
            self.recordingStartedAt = nil
            var reason = self.pendingEndReason
            let index = self.currentSegmentIndex
            var reachedMaxDuration = false
            self.pendingEndReason = .sessionEnded

            if let error {
                // AVFoundation は正常停止時にも「非ゼロ」エラーを返すことがあるため、
                // ファイルが実際に存在するかで成否を判断する
                let nsError = error as NSError
                let recordedSuccessfully = nsError
                    .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                // 最大長到達は正常終了として扱う。ファイルは有効であり、次のセグメントへ継ぐ
                if nsError.code == AVError.maximumDurationReached.rawValue {
                    reachedMaxDuration = true
                }
                if !recordedSuccessfully && !reachedMaxDuration {
                    AppLog.recording.error(
                        "segment failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.videoStore.registerSegmentEnd(
                        sessionId: sessionId, index: index, endedAt: endedAt, reason: .error
                    )
                    self.diagnostics.record(
                        .segmentEnded(index: index, at: endedAt, reason: .error), for: sessionId
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
            if reachedMaxDuration { reason = .maxDuration }

            // セッションが続いているのに中断で止まった＝復旧待ち（F-I9-1）
            if reason == .interrupted, self.isSessionActive {
                self.isAwaitingRecovery = true
            }

            self.videoStore.registerSegmentEnd(
                sessionId: sessionId, index: index, endedAt: endedAt, reason: reason
            )
            self.diagnostics.record(
                .segmentEnded(index: index, at: endedAt, reason: reason), for: sessionId
            )

            // 最大長で切れた場合は、間を空けずに次のセグメントを開始する（F-I7-3）。
            // 継ぎ目の欠落は避けられないが、診断記録の segmentEnded/segmentStarted の
            // 時刻差として残るため、後から欠落区間を特定できる
            if reachedMaxDuration, self.isSessionActive {
                self.startNextSegment()
            }
        }
    }
}
