//
//  SwingDetector.swift
//  TennisAnalyser Watch App
//
//  Domain Service — スイング検知とウィンドウ切り出し（F-W3）
//  純粋ロジック・フレームワーク非依存・actor隔離なし
//  （Phase 1 の教訓: センサーストリーム経路に @MainActor を混ぜない）

import Foundation

/// センサーサンプル列からスイング（インパクト前後のウィンドウ）を切り出す検知器
///
/// アルゴリズム（docs/plans/PHASE2_PLAN.md 設計判断）:
/// - リングバッファに直近 `preSeconds` 分のサンプルをタイムスタンプ基準で保持
/// - 加速度ベクトル ≥ `threshold` でインパクト検知
/// - インパクト後 `postSeconds` 分のサンプルが揃った時点でウィンドウ確定・emit
/// - ウィンドウ収集中および確定済みウィンドウ内の再インパクトは無視
///   （次のインパクト判定はウィンドウ終端以降のサンプルから再開）
final class SwingDetector {

    // MARK: - Configuration

    /// インパクト前の切り出し秒数
    let preSeconds: Double
    /// インパクト後の切り出し秒数
    let postSeconds: Double
    /// インパクト判定の加速度閾値 (g)
    let threshold: Double

    // MARK: - State

    private let sessionId: String
    private var nextSequence: Int = 1
    /// 直近サンプルのバッファ（タイムスタンプ昇順を前提）
    private var buffer: [MotionSample] = []
    /// 収集中ウィンドウのインパクト時刻（nil = 待機中）
    private var activeImpactTs: Int64?
    /// この時刻以前のサンプルはインパクト判定の対象外（確定済みウィンドウとの重複防止）
    private var rearmAfterTs: Int64 = .min

    private var preMs: Int64 { Int64(preSeconds * 1000) }
    private var postMs: Int64 { Int64(postSeconds * 1000) }

    // MARK: - Init

    init(
        sessionId: String,
        preSeconds: Double = 2.0,
        postSeconds: Double = 2.0,
        threshold: Double = 3.0
    ) {
        self.sessionId = sessionId
        self.preSeconds = preSeconds
        self.postSeconds = postSeconds
        self.threshold = threshold
    }

    // MARK: - Public API

    /// サンプルバッチを投入し、確定したスイングを返す（0個以上）
    ///
    /// - Parameters:
    ///   - batch: タイムスタンプ昇順のサンプル列
    ///   - now: 現在の壁時計時刻（テスト時に注入可能）。`detectedAt` の算出に使用
    func feed(_ batch: [MotionSample], now: Date = Date()) -> [Swing] {
        guard !batch.isEmpty else { return [] }
        buffer.append(contentsOf: batch)

        var swings: [Swing] = []

        while true {
            // 1. インパクト探索（待機中のみ）
            if activeImpactTs == nil {
                activeImpactTs = buffer.first {
                    $0.timestampMs > rearmAfterTs && $0.accelerationMagnitude >= threshold
                }?.timestampMs
            }
            guard let impactTs = activeImpactTs, let lastTs = buffer.last?.timestampMs else { break }

            // 2. post窓が満ちるまで待機（次バッチ以降で確定）
            let windowEnd = impactTs + postMs
            guard lastTs >= windowEnd else { break }

            // 3. ウィンドウ確定・切り出し
            let windowStart = impactTs - preMs
            let windowSamples = buffer.filter {
                $0.timestampMs >= windowStart && $0.timestampMs <= windowEnd
            }
            // detectedAt: 最新サンプルとインパクトの時差から壁時計のインパクト時刻を逆算
            let latencySec = Double(lastTs - impactTs) / 1000.0
            swings.append(Swing(
                id: UUID().uuidString,
                sessionId: sessionId,
                sequence: nextSequence,
                impactTimestampMs: impactTs,
                detectedAt: now.addingTimeInterval(-latencySec),
                samples: windowSamples
            ))
            nextSequence += 1
            rearmAfterTs = windowEnd
            activeImpactTs = nil
        }

        trimBuffer()
        return swings
    }

    // MARK: - Private

    /// pre窓に必要な範囲より古いサンプルを破棄する
    private func trimBuffer() {
        let keepFrom: Int64
        if let impactTs = activeImpactTs {
            keepFrom = impactTs - preMs
        } else if let lastTs = buffer.last?.timestampMs {
            keepFrom = lastTs - preMs
        } else {
            return
        }
        if let firstKeep = buffer.firstIndex(where: { $0.timestampMs >= keepFrom }), firstKeep > 0 {
            buffer.removeFirst(firstKeep)
        }
    }
}
