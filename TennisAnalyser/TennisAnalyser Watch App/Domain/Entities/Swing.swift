//
//  Swing.swift
//  TennisAnalyser Watch App
//
//  Domain Entity — 外部フレームワーク依存なし

import Foundation

/// 1回のスイング（インパクト前後のウィンドウで切り出されたサンプル列）
///
/// F-W3: インパクト（加速度閾値超え）の前後を切り出した波形データ。
/// 1スイング = 1 CSV ファイルとして永続化・転送される（F-W4/F-W5）。
struct Swing: Equatable, Sendable {
    /// スイングの一意ID（UUID文字列）
    let id: String
    /// 所属セッションのID
    let sessionId: String
    /// セッション内の連番（1始まり）
    let sequence: Int
    /// インパクト時刻（センサータイムスタンプ, ms。起動からの経過時間）
    let impactTimestampMs: Int64
    /// インパクトの壁時計時刻（一覧表示・ファイル名用）
    let detectedAt: Date
    /// ウィンドウ内のサンプル列（インパクト前 preSeconds 〜 後 postSeconds）
    let samples: [MotionSample]

    /// ウィンドウ内のピーク加速度 (g)
    var peakAcceleration: Double {
        samples.map(\.accelerationMagnitude).max() ?? 0.0
    }
}
