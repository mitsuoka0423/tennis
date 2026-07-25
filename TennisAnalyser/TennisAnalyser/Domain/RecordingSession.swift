//
//  RecordingSession.swift
//  TennisAnalyser (iOS)
//
//  Domain — 1セッションの録画をセグメント列として表す（F-I7-3）
//
//  Why not PracticeVideo の拡張: `PracticeVideo` は startedAt/endedAt を1組しか持てず、
//  1セッション＝1ファイルを前提としている。中断復帰時に .mov へ追記する API は
//  AVCaptureMovieFileOutput に無く、再開は新規ファイルにならざるを得ないため、
//  1セッションが複数ファイルに分かれることを表現できる型が要る。
//
//  Why not セグメントを跨いだ通し時刻を保持: セグメントごとに startedAt を持たせ、
//  問い合わせ時に解決する。中断区間の長さは事前に決まらず、通し時刻を保持すると
//  中断のたびに全セグメントの再計算が必要になるため。

import Foundation

/// 連続録画1本（セグメント）
struct RecordingSegment: Identifiable, Equatable, Codable {

    let index: Int
    /// セッションディレクトリ内の相対名。絶対パスは環境で変わるため保持しない
    let fileName: String
    /// 実際に録画が始まった時刻（通知〜開始のラグを除いた値）
    let startedAt: Date
    /// 録画中は nil
    var endedAt: Date?
    /// 録画中は nil
    var endReason: SegmentEndReason?

    var id: Int { index }

    /// 標準のファイル名（スイングCSVと同じ4桁ゼロ埋め）
    static func fileName(for index: Int) -> String {
        String(format: "%04d.mov", index)
    }

    /// この時刻が録画済みの範囲に含まれるか
    ///
    /// 終了時刻が未確定（録画中・アプリが落ちた等）の場合は含まないと判定する。
    /// 範囲が定まらない以上、切り出し位置も定まらないため。
    func contains(_ date: Date) -> Bool {
        guard let endedAt else { return false }
        return date >= startedAt && date <= endedAt
    }

    /// 録画済みの長さ（秒）。終了時刻が未確定なら nil
    var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }
}

/// 1セッション分の録画
///
/// - 保存先: `Documents/video_sources/{sessionId}/manifest.json` + `{index}.mov`
/// - `id` は Watch と共有する sessionId
struct RecordingSession: Identifiable, Equatable, Codable {

    let id: String
    /// セッション開始通知の受信時刻
    let startedAt: Date
    /// セッション終了通知の受信時刻。進行中は nil
    var endedAt: Date?
    var segments: [RecordingSegment]

    init(id: String, startedAt: Date, endedAt: Date? = nil, segments: [RecordingSegment] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
    }

    // MARK: - 解決

    /// 指定時刻を含むセグメントと、そのセグメント内でのオフセット秒を解決する
    ///
    /// 中断区間（セグメントとセグメントの間）や録画範囲外の時刻は nil を返す。
    /// クリップ生成・タイムライン再生の双方がこの解決を用いる。
    func resolve(_ date: Date) -> (segment: RecordingSegment, offsetSeconds: Double)? {
        guard let segment = segments.first(where: { $0.contains(date) }) else { return nil }
        return (segment, date.timeIntervalSince(segment.startedAt))
    }

    /// 次に割り当てるセグメント番号
    ///
    /// 既存の最大値+1 とする。件数ではなく最大値を使うのは、
    /// 途中のセグメントが削除されても番号が衝突しないようにするため。
    var nextSegmentIndex: Int {
        (segments.map(\.index).max() ?? -1) + 1
    }

    /// 終了時刻が確定したセグメントの合計録画時間
    var recordedDuration: TimeInterval {
        segments.compactMap(\.duration).reduce(0, +)
    }

    /// セッション全体の長さ。終了通知が未受信なら nil
    var sessionDuration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// 録画がセッション全体のどれだけを覆えたか（0.0〜1.0）
    var coverageRatio: Double? {
        guard let sessionDuration, sessionDuration > 0 else { return nil }
        return recordedDuration / sessionDuration
    }
}
