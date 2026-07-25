//
//  RecordSessionUseCase.swift
//  TennisAnalyser Watch App
//
//  Use Case — Domain依存のみ、フレームワーク非依存

import Foundation
import Combine
import os

/// ワークアウトセッションを通じてスイングを検知・保存するユースケース
///
/// 責務:
/// - セッション開始/終了のライフサイクル管理
/// - MotionSensorRepository のサンプルを SwingDetector に流し、スイングを切り出す（F-W3）
/// - 確定したスイングを SwingRepository へ逐次保存する（F-W4）
/// - 保存完了を `onSwingSaved` で通知する（F-W5 転送のフック）
@MainActor
final class RecordSessionUseCase: ObservableObject {

    // MARK: - Dependencies

    private let motionRepo: any MotionSensorRepository
    private let swingRepo: any SwingRepository

    // MARK: - State

    @Published private(set) var isRecording: Bool = false
    /// 検知済みスイング数
    @Published private(set) var swingCount: Int = 0
    /// 保存済みサンプル総数（スイングウィンドウ内のサンプル）
    @Published private(set) var sampleCount: Int = 0
    /// フィルタ前の生サンプル総数。実測Hz・ロス率の計測（F-W2）に使用する
    @Published private(set) var rawSampleCount: Int = 0
    @Published private(set) var error: Error?

    /// 現在のセッションID（nil = 未開始）
    private(set) var currentSessionId: String?

    /// スイング保存完了フック（F-W5: 転送層が購読する）
    var onSwingSaved: ((Swing, URL) -> Void)?

    // MARK: - Configuration（要求 2.2: 調整可能）

    /// 目標サンプリングレート (Hz)
    ///
    /// `CMBatchedSensorManager.deviceMotionUpdates()` の仕様上限は 200Hz。
    /// 実機検証（2026-07-17, Series 9）にて実測 200Hz・ロス率 0.2% を確認。
    var targetHz: Int = 200
    /// インパクト判定の加速度閾値 (g)
    var accelerationThreshold: Double = 3.0
    /// スイングウィンドウ: インパクト前の秒数
    var preSeconds: Double = 2.0
    /// スイングウィンドウ: インパクト後の秒数
    var postSeconds: Double = 2.0

    // MARK: - Private

    private var samplingTask: Task<Void, Never>?
    private var detector: SwingDetector?
    /// 生サンプルの最初・最後のセンサータイムスタンプ (ms)。実測Hz計算に使用
    private var firstRawTimestampMs: Int64?
    private var lastRawTimestampMs: Int64?

    /// センサータイムスタンプに基づく実測サンプリングレート (Hz)
    ///
    /// 壁時計（バッチ到着時刻）ではなくサンプル自身のタイムスタンプ間隔から
    /// 計算するため、バッチ到着ジッタや画面更新タイミングの影響を受けない。
    var measuredRawHz: Double {
        guard let first = firstRawTimestampMs,
              let last = lastRawTimestampMs,
              last > first, rawSampleCount > 1 else { return 0.0 }
        return Double(rawSampleCount - 1) / (Double(last - first) / 1000.0)
    }

    // MARK: - Init

    init(motionRepo: any MotionSensorRepository, swingRepo: any SwingRepository) {
        self.motionRepo = motionRepo
        self.swingRepo = swingRepo
    }

    // MARK: - Public API

    /// セッションを開始してセンサーサンプリング・スイング検知を開始する
    func startSession() {
        guard !isRecording else { return }

        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        detector = SwingDetector(
            sessionId: sessionId,
            preSeconds: preSeconds,
            postSeconds: postSeconds,
            threshold: accelerationThreshold
        )
        isRecording = true
        swingCount = 0
        sampleCount = 0
        rawSampleCount = 0
        firstRawTimestampMs = nil
        lastRawTimestampMs = nil
        error = nil

        samplingTask = Task.detached { [weak self] in
            guard let self else { return }
            let stream = await self.motionRepo.startSampling(targetHz: await self.targetHz)
            AppLog.swing.info("sampling stream started")
            do {
                for try await batch in stream {
                    await self.processBatch(batch)
                }
            } catch {
                AppLog.swing.error("stream error: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.error = error
                    self.isRecording = false
                }
            }
        }
    }

    /// セッションを停止する
    ///
    /// スイングは検知のたびに保存済みのため、停止時の一括保存は行わない。
    /// 収集途中の未確定ウィンドウは破棄する（インパクト後2秒未満で停止した場合のみ）。
    func stopSession() {
        guard isRecording else { return }

        isRecording = false
        motionRepo.stopSampling()
        samplingTask?.cancel()
        samplingTask = nil
        detector = nil
        currentSessionId = nil
    }

    // MARK: - Private

    private func processBatch(_ batch: [MotionSample]) {
        // フィルタ前の生サンプル数とタイムスタンプ範囲を記録（実測Hz・ロス率の計測用）
        if let firstSample = batch.first, let lastSample = batch.last {
            if firstRawTimestampMs == nil {
                firstRawTimestampMs = firstSample.timestampMs
            }
            lastRawTimestampMs = lastSample.timestampMs
        }
        rawSampleCount += batch.count

        // スイング検知・ウィンドウ切り出し（F-W3）
        guard let detector else { return }
        let swings = detector.feed(batch)
        for swing in swings {
            swingCount += 1
            sampleCount += swing.samples.count
            saveSwing(swing)
        }
    }

    /// スイングを保存し、完了時に onSwingSaved を通知する（F-W4 → F-W5）
    private func saveSwing(_ swing: Swing) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.swingRepo.save(swing: swing)
                AppLog.swing.info("swing #\(swing.sequence, privacy: .public) saved: \(url.lastPathComponent, privacy: .public) (\(swing.samples.count, privacy: .public) samples)")
                self.onSwingSaved?(swing, url)
            } catch {
                AppLog.swing.error("swing save failed: \(error.localizedDescription, privacy: .public)")
                self.error = error
            }
        }
    }
}
