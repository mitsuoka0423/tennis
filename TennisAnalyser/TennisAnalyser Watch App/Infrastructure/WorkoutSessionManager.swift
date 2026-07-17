//
//  WorkoutSessionManager.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — HKWorkoutSession を管理してバックグラウンド動作を維持する

import Foundation
import HealthKit

/// `HKWorkoutSession` を使ってWatchアプリのバックグラウンド動作を維持するマネージャー
///
/// スイング計測中は画面が消灯してもプロセスが中断されないよう、
/// HKWorkoutSession をアクティブに保つ。
///
/// - ObservableObject / @MainActor を持たない純粋な非同期クラス:
///   @MainActor クラスの async メソッドで await すると、そのメソッドが MainActor キューを
///   占有し続け、delegate コールバック（Task { @MainActor in }）が積まれても
///   実行できずデッドロックになる。
///   状態の @Published 管理は呼び出し元の WorkoutViewModel に委譲する。
final class WorkoutSessionManager: NSObject {

    // MARK: - Private

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var stateContinuation: AsyncStream<Result<HKWorkoutSessionState, Error>>.Continuation?

    // MARK: - Public API

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutSessionError.healthKitUnavailable
        }
        let typesToShare: Set<HKSampleType> = [HKQuantityType.workoutType()]
        try await healthStore.requestAuthorization(toShare: typesToShare, read: [])
    }

    func startWorkout() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutSessionError.healthKitUnavailable
        }

        let workoutType = HKQuantityType.workoutType()
        if healthStore.authorizationStatus(for: workoutType) == .notDetermined {
            try await requestAuthorization()
        }
        guard healthStore.authorizationStatus(for: workoutType) != .sharingDenied else {
            throw WorkoutSessionError.notAuthorized
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .tennis
        config.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )
        session.delegate = self
        builder.delegate = self
        workoutSession = session
        workoutBuilder = builder

        // ストリーム作成 → startActivity の順で delegate のコールバックをとりこぼさない
        var localContinuation: AsyncStream<Result<HKWorkoutSessionState, Error>>.Continuation?
        let stateStream = AsyncStream<Result<HKWorkoutSessionState, Error>> { continuation in
            localContinuation = continuation
        }
        stateContinuation = localContinuation
        session.startActivity(with: Date())

        for await result in stateStream {
            switch result {
            case .success(.running):
                break
            case .success(let s) where s == .stopped || s == .notStarted:
                throw WorkoutSessionError.unexpectedStop
            case .failure(let error):
                throw error
            default:
                continue
            }
            break
        }

        try await builder.beginCollection(at: Date())
    }

    func stopWorkout() async throws {
        guard let session = workoutSession, let builder = workoutBuilder else { return }

        var localContinuation: AsyncStream<Result<HKWorkoutSessionState, Error>>.Continuation?
        let stateStream = AsyncStream<Result<HKWorkoutSessionState, Error>> { continuation in
            localContinuation = continuation
        }
        stateContinuation = localContinuation
        session.end()

        for await result in stateStream {
            switch result {
            case .success(.ended):
                break
            case .failure(let error):
                throw error
            default:
                continue
            }
            break
        }

        try await builder.endCollection(at: Date())
        try await builder.finishWorkout()
        workoutSession = nil
        workoutBuilder = nil
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutSessionManager: HKWorkoutSessionDelegate {

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        stateContinuation?.yield(.success(toState))
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        stateContinuation?.yield(.failure(error))
        stateContinuation?.finish()
        stateContinuation = nil
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutSessionManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Errors

enum WorkoutSessionError: LocalizedError {
    case healthKitUnavailable
    case notAuthorized
    case unexpectedStop

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "このデバイスでHealthKitは利用できません。"
        case .notAuthorized:
            return "HealthKitの利用が許可されていません。設定アプリからプライバシー設定を確認してください。"
        case .unexpectedStop:
            return "ワークアウトセッションが予期せず停止しました。"
        }
    }
}
