//
//  SwingRecord.swift
//  TennisAnalyser (iOS)
//
//  Domain — 受信済みスイングのモデルと CSV パーサ
//  注: Watch 側 Domain とはターゲットが別のため独立定義（将来は共有パッケージ化を検討）

import Foundation

/// ショット種別（6分類、F-I3 アノテーション用）
///
/// Watch 側 `MotionSample.ShotClass`（TennisAnalyser Watch App/Domain/Entities/MotionSample.swift）
/// と rawValue を一致させること。ターゲットが別のため独立定義（CSV の文字列経由で往復する）。
enum ShotClass: String, Equatable, Sendable, CaseIterable, Identifiable {
    case strokeForehand = "STROKE_FOREHAND"
    case strokeBackhand = "STROKE_BACKHAND"
    case volleyForehand = "VOLLEY_FOREHAND"
    case volleyBackhand = "VOLLEY_BACKHAND"
    case serve          = "SERVE"
    case other           = "OTHER"

    var id: String { rawValue }

    /// 一覧・詳細画面での表示名
    var displayName: String {
        switch self {
        case .strokeForehand: return "ストローク(フォア)"
        case .strokeBackhand: return "ストローク(バック)"
        case .volleyForehand: return "ボレー(フォア)"
        case .volleyBackhand: return "ボレー(バック)"
        case .serve: return "サーブ"
        case .other: return "その他"
        }
    }
}

/// 1サンプル分のセンサーデータ（波形表示用）
struct SwingSamplePoint: Identifiable {
    let id = UUID()
    let timestampMs: Int64
    let accX: Double
    let accY: Double
    let accZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double

    var accelerationMagnitude: Double {
        (accX * accX + accY * accY + accZ * accZ).squareRoot()
    }
}

/// 受信済みスイング（一覧表示用のメタ情報 + 遅延ロードされる波形）
struct SwingRecord: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let sequence: Int
    let detectedAt: Date?
    let impactTimestampMs: Int64?
    let peakAcceleration: Double?
    /// F-I3: 手動タグ付けされたショット種別（未設定は nil）
    let shotClass: ShotClass?
    let fileURL: URL

    static func == (lhs: SwingRecord, rhs: SwingRecord) -> Bool { lhs.id == rhs.id }
}

// MARK: - Date Formatting

/// 日付表示は yyyy-MM-dd 形式（I-2）
extension Date {
    private static let ymdhmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let ymdhmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// `yyyy-MM-dd HH:mm`
    var ymdhmString: String { Self.ymdhmFormatter.string(from: self) }
    /// `yyyy-MM-dd HH:mm:ss`
    var ymdhmsString: String { Self.ymdhmsFormatter.string(from: self) }
}

// MARK: - CSV Parser

enum SwingCSVParser {

    // 注: プロジェクトは SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor のため、
    // 純関数のパーサは nonisolated を明示してバックグラウンドから呼べるようにする

    /// メタ情報のみをパースする（一覧表示用・先頭行のみ読む軽量処理）
    nonisolated static func parseMetadata(fileURL: URL) -> SwingRecord? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var meta: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("# ") else { break }  // メタ情報はファイル先頭に連続
            let body = line.dropFirst(2)
            guard let sep = body.range(of: ": ") else { continue }
            meta[String(body[..<sep.lowerBound])] = String(body[sep.upperBound...])
        }

        // フォールバック: メタ欠損時はパス（swings/{sessionId}/{seq}.csv）から復元
        let sessionId = meta["SessionID"] ?? fileURL.deletingLastPathComponent().lastPathComponent
        let sequence = meta["Sequence"].flatMap(Int.init)
            ?? Int(fileURL.deletingPathExtension().lastPathComponent) ?? 0

        return SwingRecord(
            id: meta["SwingID"] ?? "\(sessionId)-\(sequence)",
            sessionId: sessionId,
            sequence: sequence,
            detectedAt: meta["DetectedAt"].flatMap { ISO8601DateFormatter().date(from: $0) },
            impactTimestampMs: meta["ImpactTimestampMs"].flatMap(Int64.init),
            peakAcceleration: meta["PeakAcceleration"].flatMap(Double.init),
            shotClass: meta["ShotClass"].flatMap(ShotClass.init(rawValue:)),
            fileURL: fileURL
        )
    }

    /// スイングにショット種別を書き込む（F-I3 アノテーションの永続化）
    ///
    /// メタ情報ヘッダー（`# ShotClass: X`）と全データ行の ShotClass 列の両方に書き込む。
    /// データ行にも書くのは Create ML の入力形式が「各サンプル行にラベルを持つ」のが
    /// 一般的なため（Wave 2 の学習データエクスポートでそのまま使える形にしておく）。
    nonisolated static func writeShotClass(fileURL: URL, shotClass: ShotClass) throws {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var otherMetaLines: [String] = []
        var headerLine: String?
        var dataLines: [String] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                continue
            } else if line.hasPrefix("# ShotClass:") {
                continue  // 既存の ShotClass 行は破棄し、末尾で新しい値を挿入する
            } else if line.hasPrefix("#") {
                otherMetaLines.append(String(line))
            } else if line.hasPrefix("Timestamp") {
                headerLine = String(line)
            } else {
                // データ行: 末尾の ShotClass 列を置き換える
                var cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                if !cols.isEmpty { cols[cols.count - 1] = shotClass.rawValue }
                dataLines.append(cols.joined(separator: ","))
            }
        }

        // 順序: その他メタ行 → ShotClass 行 → ヘッダー行 → データ行
        var lines = otherMetaLines
        lines.append("# ShotClass: \(shotClass.rawValue)")
        if let headerLine { lines.append(headerLine) }
        lines.append(contentsOf: dataLines)

        let newContent = lines.joined(separator: "\n") + "\n"
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 波形サンプルをパースする（詳細表示用）
    nonisolated static func parseSamples(fileURL: URL) -> [SwingSamplePoint] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line -> SwingSamplePoint? in
            guard !line.hasPrefix("#"), !line.hasPrefix("Timestamp") else { return nil }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 7,
                  let ts = Int64(cols[0]),
                  let ax = Double(cols[1]), let ay = Double(cols[2]), let az = Double(cols[3]),
                  let gx = Double(cols[4]), let gy = Double(cols[5]), let gz = Double(cols[6])
            else { return nil }
            return SwingSamplePoint(
                timestampMs: ts,
                accX: ax, accY: ay, accZ: az,
                gyroX: gx, gyroY: gy, gyroZ: gz
            )
        }
    }
}
