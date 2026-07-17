//
//  SwingSession.swift
//  TennisAnalyser Watch App
//
//  Domain Entity — 外部フレームワーク依存なし

import Foundation

/// 1回のワークアウトセッション
struct SwingSession: Equatable, Sendable {
    /// セッションの一意ID（UUID文字列）
    let id: String
    /// セッション開始時刻
    let startedAt: Date
    /// セッション終了時刻（nil = 進行中）
    let endedAt: Date?
    /// 収集済みサンプル
    let samples: [MotionSample]

    /// セッションが進行中かどうか
    var isActive: Bool { endedAt == nil }

    /// サンプリングレート（実測値, Hz）
    var measuredSamplingRate: Double? {
        guard samples.count >= 2 else { return nil }
        let durationMs = Double(samples.last!.timestampMs - samples.first!.timestampMs)
        guard durationMs > 0 else { return nil }
        return Double(samples.count - 1) / (durationMs / 1000.0)
    }

    // MARK: - Factory

    static func start(id: String = UUID().uuidString, at date: Date = Date()) -> SwingSession {
        SwingSession(id: id, startedAt: date, endedAt: nil, samples: [])
    }

    func appending(samples newSamples: [MotionSample]) -> SwingSession {
        SwingSession(id: id, startedAt: startedAt, endedAt: endedAt, samples: samples + newSamples)
    }

    func ended(at date: Date = Date()) -> SwingSession {
        SwingSession(id: id, startedAt: startedAt, endedAt: date, samples: samples)
    }
}
