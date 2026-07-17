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
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var elapsedSeconds: Int = 0
    /// 計測中にリアルタイム更新される実測サンプリングレート (Hz)
    @Published private(set) var measuredHz: Double = 0.0
    /// ロス率 = 1 - (実測Hz / targetHz)。0〜1 の値。計測中のみ有効
    @Published private(set) var lossRate: Double = 0.0
    @Published private(set) var errorMessage: String?

    // MARK: - Configuration

    /// true にするとシミュレータ用モックリポジトリを使用する
    let useMock: Bool

    // MARK: - Private

    private var timerTask: Task<Void, Never>?
    private var startDate: Date?

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

        if let useCase = recordSessionUseCase {
            self.recordSessionUseCase = useCase
        } else {
            let motionRepo: any MotionSensorRepository = useMock
                ? MockMotionSensorRepository()
                : MotionSensorRepositoryImpl()
            self.recordSessionUseCase = RecordSessionUseCase(
                motionRepo: motionRepo,
                sessionRepo: SessionRepositoryImpl()
            )
        }

        observeUseCase()
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
            }
        }
    }

    // MARK: - Private

    private func observeUseCase() {
        Task { @MainActor in
            for await count in recordSessionUseCase.$sampleCount.values {
                self.sampleCount = count
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

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording else { break }
                self.elapsedSeconds += 1
                // 1秒ごとに実測Hz・ロス率をリアルタイム更新
                self.updateStats()
            }
        }
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
}
