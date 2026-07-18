//
//  PracticeVideo.swift
//  TennisAnalyser (iOS)
//
//  Domain — 練習セッション中に連続録画したスロー動画（F-I6）

import Foundation

/// 練習セッション中に連続録画した動画1本
///
/// 1スイングごとではなく、録画開始〜停止までの1本を保持する。
/// スイングとの対応付けは `startedAt`/`endedAt`（壁時計）と
/// `SwingRecord.detectedAt` を突き合わせて行う（Why not: Watch と iPhone は
/// 別デバイスでセッションIDを共有できないため、時刻マッチングが唯一の手段）。
struct PracticeVideo: Identifiable, Equatable, Codable {
    let id: String
    let startedAt: Date
    /// 録画中は nil。停止時に確定する
    var endedAt: Date?
    /// 動画ファイル名（保存ディレクトリ内の相対名。絶対パスは環境で変わるため保持しない）
    let fileName: String

    /// このスイングの `detectedAt` が動画の録画範囲内にあるか
    func contains(_ date: Date) -> Bool {
        guard let endedAt else { return false }
        return date >= startedAt && date <= endedAt
    }

    /// `date` に対応する動画内の再生位置（秒）。範囲外なら nil
    func offsetSeconds(for date: Date) -> Double? {
        guard contains(date) else { return nil }
        return date.timeIntervalSince(startedAt)
    }
}
