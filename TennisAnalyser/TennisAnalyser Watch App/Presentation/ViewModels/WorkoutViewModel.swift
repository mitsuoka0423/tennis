//
//  WorkoutViewModel.swift
//  TennisAnalyser Watch App
//
//  Presentation ViewModel — View と Use Case / Infrastructure を接続する

import Foundation
import Combine
import SwiftUI

/// Watch UIとユースケース・インフラ層を接続するViewModel
///
/// 責務:
/// - WorkoutSessionManager（HealthKit）と RecordSessionUseCase（センサー収集）を協調して動作させる
/// - View に表示する状態（録音中/停止中、サンプル数、経過時間、実測Hz、ロス率、エラー）を提供する
/// - `useMock: true` でシミュレータ用 MockMotionSensorRepository に切り替えられる
@MainActor
final class WorkoutViewModel: ObservableObject {

    // MARK: - Dependencies

    private let workoutSessionManager: WorkoutSessionManager
    private let recordSessionUseCase: RecordSessionUseCase

    // MARK: - Published State

    @Published private(set) var isRecording: Bool = false
    /// ボタンタップ〜HealthKit認可・セッション開始完了までの待機中フラグ
    @Published private(set) var isStarting: Bool = false
    /// 検知済みスイング数
    @Published private(set) var swingCount: Int = 0
    /// 直近3分を15秒ごとに区切ったスイング数。右端が現在の窓、`nil` は計測開始前の窓
    @Published private(set) var swingBuckets: [Int?] =
        Array(repeating: nil, count: WorkoutViewModel.swingBucketCount)
    /// iPhone へ転送完了したスイング数
    @Published private(set) var transferredCount: Int = 0
    /// 未転送（キュー内 + ローカル残存）のスイング数
    @Published private(set) var pendingTransferCount: Int = 0
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var elapsedSeconds: Int = 0
    /// 計測中にリアルタイム更新される実測サンプリングレート (Hz)
    @Published private(set) var measuredHz: Double = 0.0
    /// ロス率 = 1 - (実測Hz / targetHz)。0〜1 の値。計測中のみ有効
    @Published private(set) var lossRate: Double = 0.0
    @Published private(set) var errorMessage: String?

    /// iPhone といま通信できるか（F-I9-6）
    @Published private(set) var isPhoneReachable: Bool = false
    /// 最後に iPhone と通信できた時刻。nil = 一度も通信できていない
    @Published private(set) var lastPhoneContactAt: Date?

    // MARK: - Configuration

    /// true にするとシミュレータ用モックリポジトリを使用する
    let useMock: Bool

    /// スイング数を数える窓の長さ (秒)
    ///
    /// 素振りの間隔（数秒）より長く、調子の変化が見える程度に短い刻み。
    static let swingBucketSeconds = 15
    /// 画面へ残す窓の数（15秒 × 12 = 3分）
    static let swingBucketCount = 12

    // MARK: - Private

    private let transferRepo: any SwingTransferRepository
    private var timerTask: Task<Void, Never>?
    private var startDate: Date?

    /// 計測開始からの全窓のスイング数。末尾が進行中の窓
    private var elapsedBuckets: [Int] = []

    // MARK: - Init

    /// - Parameters:
    ///   - useMock: シミュレータやプレビューで疑似データを使う場合は `true`
    ///   - workoutSessionManager: カスタム HealthKit マネージャー（省略時は自動生成）
    ///   - recordSessionUseCase: カスタム UseCase（省略時は `useMock` に応じて自動生成）
    init(
        useMock: Bool = false,
        workoutSessionManager: WorkoutSessionManager? = nil,
        recordSessionUseCase: RecordSessionUseCase? = nil
    ) {
        self.useMock = useMock
        self.workoutSessionManager = workoutSessionManager ?? WorkoutSessionManager()

        let swingRepo = SwingRepositoryImpl()
        // W6-T14: スイング単位保存と併存させる。次回の実機検証1回で両方式のデータを
        // 同時に採り、比較してから移行を判断する（後戻りの経路を残すため）
        let continuousRepo = ContinuousSensorRepositoryImpl()
        if let useCase = recordSessionUseCase {
            self.recordSessionUseCase = useCase
        } else {
            let motionRepo: any MotionSensorRepository = useMock
                ? MockMotionSensorRepository()
                : MotionSensorRepositoryImpl()
            self.recordSessionUseCase = RecordSessionUseCase(
                motionRepo: motionRepo,
                swingRepo: swingRepo,
                continuousRepo: continuousRepo
            )
        }
        // F-W5: 保存済みスイングを WCSession で iPhone へ逐次転送
        self.transferRepo = WCSessionTransferRepository(
            swingRepo: swingRepo, continuousRepo: continuousRepo
        )

        observeUseCase()
        wireTransfer()
    }

    // MARK: - Public API

    /// エラーメッセージをクリアする（アラート OK 後に呼ぶ）
    func clearError() {
        errorMessage = nil
    }

    /// セッション開始（HealthKit + センサー収集）
    func start() {
        guard !isRecording, !isStarting else { return }
        errorMessage = nil
        isStarting = true

        // startWorkout は nonisolated: MainActor から切り離して実行しないと
        // delegate コールバックが MainActor キューで詰まりデッドロックになる
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                if await !self.useMock {
                    try await self.workoutSessionManager.startWorkout()
                }
                await self.recordSessionUseCase.startSession()
                await MainActor.run {
                    self.isStarting = false
                    self.isRecording = true
                    self.startDate = Date()
                    self.startTimer()
                    // F-I6: iPhone のカメラ自動録画を開始させる
                    if let sessionId = self.recordSessionUseCase.currentSessionId {
                        self.transferRepo.notifySessionStarted(sessionId: sessionId)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// セッション停止（HealthKit終了 + CSV保存）
    func stop() {
        guard isRecording else { return }
        let sessionId = recordSessionUseCase.currentSessionId

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                await self.recordSessionUseCase.stopSession()
                if await !self.useMock {
                    try await self.workoutSessionManager.stopWorkout()
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                self.isRecording = false
                self.stopTimer()
                self.updateStats()
                // ワークアウト終了時に未転送分を再送（F-W5）
                self.transferRepo.retryPending()
                // F-I6: iPhone のカメラ自動録画を停止させる
                if let sessionId {
                    self.transferRepo.notifySessionEnded(sessionId: sessionId)
                }
            }
        }
    }

    // MARK: - Private

    /// 転送層の配線: 保存完了 → エンキュー、状態変化 → Published 更新
    private func wireTransfer() {
        recordSessionUseCase.onSwingSaved = { [weak self] swing, url in
            self?.transferRepo.enqueue(fileURL: url, swing: swing)
        }
        transferRepo.onStatusChanged = { [weak self] transferred, pending in
            self?.transferredCount = transferred
            self?.pendingTransferCount = pending
        }
        transferRepo.onReachabilityChanged = { [weak self] reachable, lastContactAt in
            self?.isPhoneReachable = reachable
            self?.lastPhoneContactAt = lastContactAt
        }
        transferRepo.activate()
    }

    private func observeUseCase() {
        Task { @MainActor in
            for await count in recordSessionUseCase.$sampleCount.values {
                self.sampleCount = count
            }
        }
        Task { @MainActor in
            for await count in recordSessionUseCase.$swingCount.values {
                let added = count - self.swingCount
                self.swingCount = count
                // セッション開始時に 0 へ戻るため、増えたときだけ窓へ積む
                if added > 0 { self.addSwings(added) }
            }
        }
        Task { @MainActor in
            for await err in recordSessionUseCase.$error.values {
                if let err {
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func startTimer() {
        elapsedSeconds = 0
        measuredHz = 0.0
        lossRate = 0.0
        elapsedBuckets = []
        publishBuckets()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording else { break }
                self.elapsedSeconds += 1
                // 1秒ごとに実測Hz・ロス率をリアルタイム更新
                self.updateStats()
                // スイングが1本も出ない窓も時間の経過として送り出す
                self.openBucketsUpToNow()
                self.publishBuckets()
            }
        }
    }

    /// 検知されたスイングを進行中の窓へ積む
    private func addSwings(_ count: Int) {
        openBucketsUpToNow()
        elapsedBuckets[elapsedBuckets.count - 1] += count
        publishBuckets()
    }

    /// いまの経過時間に対応する窓まで配列を伸ばす
    private func openBucketsUpToNow() {
        let index = elapsedSeconds / Self.swingBucketSeconds
        while elapsedBuckets.count <= index {
            elapsedBuckets.append(0)
        }
    }

    /// 直近 `swingBucketCount` 個の窓を右詰めで公開する
    ///
    /// 窓が足りないうちは左を `nil` で埋める。時間軸の目盛り（-3分〜現在）を
    /// 一定に保ち、開始直後に棒が横へ引き伸ばされないようにするため。
    private func publishBuckets() {
        let tail = elapsedBuckets.suffix(Self.swingBucketCount).map { Optional($0) }
        let padding = Array<Int?>(
            repeating: nil, count: max(0, Self.swingBucketCount - tail.count)
        )
        swingBuckets = padding + tail
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// 実測Hz とロス率をフィルタ前の生サンプルから計算して更新する
    ///
    /// - フィルタ後（記録対象）のサンプルはスイング時のみ増えるため、
    ///   F-W2 のサンプリングレート検証にはフィルタ前の生サンプルを使う。
    /// - Hz はセンサータイムスタンプ間隔から計算（壁時計ジッタの影響を受けない）。
    private func updateStats() {
        let hz = recordSessionUseCase.measuredRawHz
        measuredHz = hz

        let targetHz = Double(recordSessionUseCase.targetHz)
        if targetHz > 0 && hz > 0 {
            // ロス率: 期待Hz に対して何割のサンプルが欠落しているか
            lossRate = max(0.0, min(1.0, 1.0 - hz / targetHz))
        } else {
            lossRate = 0.0
        }
    }

    /// 経過時間を `MM:SS` 形式で返す
    var elapsedTimeString: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// ロス率を `xx.x%` 形式で返す
    var lossRateString: String {
        String(format: "%.1f%%", lossRate * 100)
    }

    /// iPhone との通信状態の表示文字列（F-I9-6）
    ///
    /// 圏外のときは**経過時間**を出す。コート反対側へ行けば必ず切れるため、
    /// 切れていること自体は異常ではない。異常なのは「戻ったのに繋がらない」ことであり、
    /// それは経過時間でしか判断できない。
    ///
    /// 注: 計測中は1秒ごとの `elapsedSeconds` 更新で再描画されるため、
    /// この文字列も追従する（自前のタイマーは持たない）。
    var phoneContactString: String {
        if isPhoneReachable { return "接続中" }
        guard let lastPhoneContactAt else { return "未接続" }
        let seconds = Int(Date().timeIntervalSince(lastPhoneContactAt))
        if seconds < 60 { return "圏外 \(seconds)秒" }
        return "圏外 \(seconds / 60)分"
    }
}
