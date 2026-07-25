//
//  MotionSensorRepositoryImpl.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — CMBatchedSensorManager を使ったセンサーデータ取得実装

import Foundation
import CoreMotion
import os

/// `CMBatchedSensorManager` を使った高頻度センサーデータ取得の実装
///
/// - watchOS 10以降で利用可能な `CMBatchedSensorManager` を使用する。
/// - @MainActor を持たない: for await でバッチを受け取る際に MainActor 上で待機すると
///   MainActor キューが詰まりデータが届かなくなるため。
/// - deviceMotionUpdates() のみ使用: CMDeviceMotion には加速度・角速度の両方が含まれるため
///   accelerometerUpdates() と組み合わせるペアリング処理が不要で実装がシンプルになる。
/// - 配信レートは deviceMotion の仕様上限 200Hz（accelerometerUpdates() は加速度のみ 800Hz）。
///   実機検証（2026-07-17）の結果、同期済み・重力除去済みの 200Hz を採用した。
final class MotionSensorRepositoryImpl: MotionSensorRepository {

    private var samplingTask: Task<Void, Never>?

    // MARK: - MotionSensorRepository

    func startSampling(targetHz: Int) -> AsyncThrowingStream<[MotionSample], Error> {
        AsyncThrowingStream { continuation in
            guard CMBatchedSensorManager.isDeviceMotionSupported else {
                continuation.finish(throwing: MotionSensorError.notSupported)
                return
            }

            let manager = CMBatchedSensorManager()

            samplingTask = Task {
                do {
                    AppLog.motion.info("deviceMotionUpdates started")
                    var batchCount = 0
                    for try await batch in manager.deviceMotionUpdates() {
                        guard !Task.isCancelled else {
                            AppLog.motion.info("stream task cancelled")
                            break
                        }
                        batchCount += 1
                        if batchCount <= 3 {
                            AppLog.motion.debug("batch #\(batchCount, privacy: .public): \(batch.count, privacy: .public) samples")
                        }
                        let samples = batch.map { Self.makeSample(from: $0) }
                        if !samples.isEmpty {
                            continuation.yield(samples)
                        }
                    }
                    AppLog.motion.info("stream ended normally")
                    continuation.finish()
                } catch {
                    AppLog.motion.error("stream error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.samplingTask?.cancel()
                self?.samplingTask = nil
            }
        }
    }

    func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: - Private

    /// CMDeviceMotion から MotionSample を生成する
    private static func makeSample(from motion: CMDeviceMotion) -> MotionSample {
        MotionSample(
            timestampMs: Int64(motion.timestamp * 1000),
            accX:  motion.userAcceleration.x,
            accY:  motion.userAcceleration.y,
            accZ:  motion.userAcceleration.z,
            gyroX: motion.rotationRate.x * (180.0 / .pi),  // rad/s → °/s
            gyroY: motion.rotationRate.y * (180.0 / .pi),
            gyroZ: motion.rotationRate.z * (180.0 / .pi),
            shotClass: nil
        )
    }
}

// MARK: - Errors

enum MotionSensorError: LocalizedError {
    case notSupported
    case managerUnavailable

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "このデバイスは高頻度センサーAPIをサポートしていません。"
        case .managerUnavailable:
            return "センサーマネージャーが利用できません。"
        }
    }
}
