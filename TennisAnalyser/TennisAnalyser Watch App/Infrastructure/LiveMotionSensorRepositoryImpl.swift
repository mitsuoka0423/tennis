//
//  LiveMotionSensorRepositoryImpl.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — CMMotionManager を使った低遅延センサーデータ取得実装（センサーデモ用）

import Foundation
import CoreMotion
import os

/// 1サンプルずつ即時配信する `MotionSensorRepository` 実装
///
/// - Why not `MotionSensorRepositoryImpl`（`CMBatchedSensorManager`）を使う:
///   バッチAPIは約1秒分（200サンプル）をまとめて配信するため、画面表示は
///   常に最大1秒遅れのバースト更新になる。Apple の位置づけも
///   「動作の**後で**解析する」用途であり、リアルタイム表示には向かない。
///   デモの要件は即応性であって分解能ではないため、更新のたびに
///   コールバックが来る `CMMotionManager` を使う。
/// - Why not ワークアウトセッションを開始する: `CMBatchedSensorManager` と異なり
///   `CMMotionManager` はワークアウト中でなくても動作するため、
///   デモのためにヘルスケアの認可を求める必要がない。
///   画面を見ている間だけ動けばよく、バックグラウンド継続も不要。
/// - @MainActor を持たない: コールバックは専用の `OperationQueue` 上で呼ばれる。
final class LiveMotionSensorRepositoryImpl: MotionSensorRepository {

    /// センサー更新の配信先。MainActor を経由しないことで画面更新の負荷と分離する
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LiveMotionSensorRepository"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private let manager = CMMotionManager()

    // MARK: - MotionSensorRepository

    func startSampling(targetHz: Int) -> AsyncThrowingStream<[MotionSample], Error> {
        AsyncThrowingStream { [manager, queue] continuation in
            guard manager.isDeviceMotionAvailable else {
                continuation.finish(throwing: MotionSensorError.notSupported)
                return
            }

            manager.deviceMotionUpdateInterval = 1.0 / Double(max(1, targetHz))
            AppLog.motion.info("live deviceMotion started at \(targetHz, privacy: .public)Hz")

            manager.startDeviceMotionUpdates(to: queue) { motion, error in
                if let error {
                    AppLog.motion.error("live deviceMotion error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                    return
                }
                guard let motion else { return }
                continuation.yield([Self.makeSample(from: motion)])
            }

            continuation.onTermination = { _ in
                manager.stopDeviceMotionUpdates()
                AppLog.motion.info("live deviceMotion stopped")
            }
        }
    }

    func stopSampling() {
        manager.stopDeviceMotionUpdates()
    }

    // MARK: - Private

    /// `CMDeviceMotion` から `MotionSample` を生成する
    ///
    /// 単位系は `MotionSensorRepositoryImpl` と揃える（加速度は重力除去済みの g、角速度は °/s）。
    nonisolated private static func makeSample(from motion: CMDeviceMotion) -> MotionSample {
        MotionSample(
            timestampMs: Int64(motion.timestamp * 1000),
            accX:  motion.userAcceleration.x,
            accY:  motion.userAcceleration.y,
            accZ:  motion.userAcceleration.z,
            gyroX: motion.rotationRate.x * (180.0 / .pi),
            gyroY: motion.rotationRate.y * (180.0 / .pi),
            gyroZ: motion.rotationRate.z * (180.0 / .pi),
            shotClass: nil
        )
    }
}
