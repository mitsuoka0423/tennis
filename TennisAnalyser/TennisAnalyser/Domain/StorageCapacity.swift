//
//  StorageCapacity.swift
//  TennisAnalyser (iOS)
//
//  Domain — 空き容量の逼迫判定（F-I7-4 / W6-T17）

import Foundation

/// 空き容量の状態
///
/// 1080p の録画は1時間あたり 4〜6GB、センサーの連続記録は 46MB/時を要する。
/// 中間データは自動削除しない方針のため（F-I7-4）、逼迫は警告で知らせる。
struct StorageCapacity: Equatable {

    /// 残り時間の見積りに用いる消費量（1時間あたりのバイト数）
    ///
    /// 2026-07-21 の実測（1080p・57分）に基づく上限側の値を採る。
    /// 少なく見積もると「まだ録れる」と表示して途中で書けなくなるため。
    nonisolated static let bytesPerHour: Int64 = 6 * 1024 * 1024 * 1024

    /// これを下回ったら警告する（1時間の練習を録りきれない）
    nonisolated static let warningThreshold: Int64 = bytesPerHour

    /// これを下回ったら録画を止める（F-I9-2）
    ///
    /// Why not 警告と同じ閾値で止める: 警告は「1時間録りきれない」の目安であり、
    /// その時点で止めると録れるはずの練習を途中で切ることになる。
    /// 停止はディスクを使い切って書き込みが失敗し、セグメントが壊れるのを防ぐためのものなので、
    /// 実際に危ない水準まで下げる（約20分ぶん）。
    nonisolated static let criticalThreshold: Int64 = 2 * 1024 * 1024 * 1024

    let availableBytes: Int64

    /// 現在の空き容量で録画できる見込み時間
    nonisolated var estimatedRecordableHours: Double {
        Double(availableBytes) / Double(Self.bytesPerHour)
    }

    /// 1時間の練習を録りきれない見込みか
    nonisolated var isLow: Bool {
        availableBytes < Self.warningThreshold
    }

    /// 録画を続けると書き込みに失敗しうる水準か（F-I9-2）
    nonisolated var isCritical: Bool {
        availableBytes < Self.criticalThreshold
    }

    /// Documents を含むボリュームの空き容量を読む
    ///
    /// Why not `volumeAvailableCapacity`: 同キーはシステムの都合で回収可能な領域を
    /// 含まないため実際に書ける量より小さく出る。書き込み可否の判断には
    /// `forImportantUsage`（重要データ向けに確保できる量）が適している。
    nonisolated static func current() -> StorageCapacity? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        guard let values = try? docs.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return StorageCapacity(availableBytes: available)
    }

    /// 「12.3 GB」形式の表示文字列
    nonisolated var availableDescription: String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }
}
