//
//  RecordSessionUseCase.swift
//  TennisAnalyser Watch App
//
//  Use Case — Domain依存のみ、フレームワーク非依存

import Foundation
import Combine

/// ワークアウトセッションを通じてセンサーデータを収集・保存するユースケース
///
/// 責務:
/// - セッション開始/終了のライフサイクル管理
/// - MotionSensorRepository からサンプルを受け取り、セッションに蓄積
/// - 1次フィルタ（加速度閾値による省電力フィルタリング）
/// - セッション終了時に SessionRepository へ保存
@MainActor
final class RecordSessionUseCase: ObservableObject {

    // MARK: - Dependencies

    private let motionRepo: any MotionSensorRepository
    private let sessionRepo: any SessionRepository

    // MARK: - State

    @Published private(set) var currentSession: SwingSession?
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var sampleCount: Int = 0
    /// フィルタ前の生サンプル総数。実測Hz・ロス率の計測（F-W2）に使用する
    @Published private(set) var rawSampleCount: Int = 0
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
    @Published private(set) var error: Error?

    // MARK: - Configuration

    /// 目標サンプリングレート (Hz)
    ///
    /// `CMBatchedSensorManager.deviceMotionUpdates()` の仕様上限は 200Hz。
    /// 実機検証（2026-07-17, Series 9）にて実測 ~197Hz（ロス率 ~1.5%）を確認し、
    /// deviceMotion 200Hz を採用（加速度・角速度が同期済み・重力除去済みのため）。
    var targetHz: Int = 200
    /// 1次フィルタ: 加速度ベクトル閾値 (g)。これを超えたサンプルのみ記録対象とする
    var accelerationThreshold: Double = 3.0
    /// 閾値フィルタを無効化（デバッグ・全量取得用）
    var disableFilter: Bool = false

    // MARK: - Private

    private var samplingTask: Task<Void, Never>?

    // MARK: - Init

    init(motionRepo: any MotionSensorRepository, sessionRepo: any SessionRepository) {
        self.motionRepo = motionRepo
        self.sessionRepo = sessionRepo
    }

    // MARK: - Public API

    /// セッションを開始してセンサーサンプリングを開始する
    func startSession() {
        guard !isRecording else { return }

        let session = SwingSession.start()
        currentSession = session
        isRecording = true
        sampleCount = 0
        rawSampleCount = 0
        firstRawTimestampMs = nil
        lastRawTimestampMs = nil
        error = nil

        samplingTask = Task.detached { [weak self] in
            guard let self else { return }
            let stream = await self.motionRepo.startSampling(targetHz: await self.targetHz)
            print("[UseCase] sampling stream started")
            do {
                for try await batch in stream {
                    print("[UseCase] received batch: \(batch.count) samples")
                    await self.processBatch(batch)
                }
            } catch {
                print("[UseCase] stream error: \(error)")
                await MainActor.run {
                    self.error = error
                    self.isRecording = false
                }
            }
        }
    }

    /// セッションを停止してCSVに保存する
    func stopSession() async {
        guard isRecording, var session = currentSession else { return }

        isRecording = false
        motionRepo.stopSampling()
        samplingTask?.cancel()
        samplingTask = nil

        session = session.ended()
        currentSession = session

        do {
            try await sessionRepo.save(session: session)
        } catch {
            self.error = error
        }
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

        let filtered = disableFilter
            ? batch
            : batch.filter { $0.accelerationMagnitude >= accelerationThreshold }

        guard !filtered.isEmpty else { return }

        currentSession = currentSession?.appending(samples: filtered)
        sampleCount += filtered.count
    }
}
