//
//  ISO8601DateCoding.swift
//  TennisAnalyser (iOS)
//
//  Domain — 小数秒を保持する ISO8601 の読み書き（F-I9-9）
//
//  Why not JSONCoder の `.iso8601`: RFC 3339 の秒精度で符号化し、**小数秒を捨てる**。
//  動画と波形の同期は「壁時計 → セグメント内オフセット」の変換で成り立っており、
//  基準になる `RecordingSegment.startedAt` が秒に丸まると、そのセグメント全体で
//  最大1秒ずれる。2026-08-09 のセッションはこれで同期が合わなかった。
//
//  Why not 書き込み側だけ直す: 既存のファイルは秒精度で書かれている。
//  読み取りは小数秒あり・なしの双方を受け付ける必要がある。

import Foundation

/// 小数秒つき ISO8601 の整形と解釈
enum ISO8601DateCoding {

    /// 書き出しに使う形式（小数秒つき）
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 既存ファイル用（小数秒なし）
    nonisolated(unsafe) private static let secondsOnly = ISO8601DateFormatter()

    nonisolated static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    /// 小数秒あり・なしの双方を受け付ける
    nonisolated static func date(from text: String) -> Date? {
        fractional.date(from: text) ?? secondsOnly.date(from: text)
    }

    // MARK: - JSONCoder 用

    static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "ISO8601 として解釈できません: \(text)"
                )
            }
            return date
        }
    }
}
