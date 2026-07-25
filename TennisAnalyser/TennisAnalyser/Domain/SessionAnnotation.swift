//
//  SessionAnnotation.swift
//  TennisAnalyser (iOS)
//
//  Domain — 連続記録に対するアノテーション（F-I8 / W6-T16a）

import Foundation

/// 選別の状態
enum AnnotationStatus: String, Equatable, Sendable, Codable {
    /// 検知器が提示した未レビュー
    case proposed
    /// ユーザーが承認した（`shotClass` を伴う）
    case confirmed
    /// ユーザーが「スイングではない」と判断した
    case rejected
}

/// イベントの由来
enum EventOrigin: String, Equatable, Sendable, Codable {
    /// オフライン検知器が提示した
    case detector
    /// ユーザーが波形上で追加した（F-I8-5）
    case manual
}

/// アノテーション1件
struct AnnotatedEvent: Identifiable, Equatable, Sendable, Codable {
    let id: String
    /// インパクトの壁時計時刻。動画・センサー双方への対応付けの基準
    var impactAt: Date
    /// 球種（nil = 未分類）
    var shotClass: ShotClass?
    var status: AnnotationStatus
    var origin: EventOrigin
    /// 検知器由来の参考値 (g)
    var detectorPeak: Double?

    init(
        id: String = UUID().uuidString,
        impactAt: Date,
        shotClass: ShotClass? = nil,
        status: AnnotationStatus = .proposed,
        origin: EventOrigin = .detector,
        detectorPeak: Double? = nil
    ) {
        self.id = id
        self.impactAt = impactAt
        self.shotClass = shotClass
        self.status = status
        self.origin = origin
        self.detectorPeak = detectorPeak
    }

    /// レビュー済みか（承認または却下）
    var isReviewed: Bool { status != .proposed }
}

/// 1セッション分のアノテーション
///
/// センサー記録・動画とは独立した薄い層として持つ。切り出しは書き出し時に行うため、
/// 窓長やラベルを何度でも変更できる（F-I8-9）。
struct SessionAnnotation: Equatable, Sendable, Codable {

    let sessionId: String
    /// `impactAt` の昇順で保持する
    var events: [AnnotatedEvent]
    /// 動画とセンサーの時刻オフセット補正（F-I8-7）。全イベントへ一律に適用する
    var timeOffsetSeconds: Double
    var updatedAt: Date

    init(
        sessionId: String,
        events: [AnnotatedEvent] = [],
        timeOffsetSeconds: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.events = events.sorted { $0.impactAt < $1.impactAt }
        self.timeOffsetSeconds = timeOffsetSeconds
        self.updatedAt = updatedAt
    }

    // MARK: - 進捗（F-I8-1）

    var reviewedCount: Int { events.filter(\.isReviewed).count }
    var confirmedCount: Int { events.filter { $0.status == .confirmed }.count }
    var rejectedCount: Int { events.filter { $0.status == .rejected }.count }
    var remainingCount: Int { events.count - reviewedCount }

    /// 再開位置（F-I8-8）。未レビューの先頭イベント
    var firstUnreviewedIndex: Int? {
        events.firstIndex { !$0.isReviewed }
    }

    /// 書き出し対象（F-I8-9）。時刻オフセット補正を適用した `confirmed` のみ
    var confirmedEventsForExport: [AnnotatedEvent] {
        events
            .filter { $0.status == .confirmed }
            .map { corrected($0) }
    }

    /// 負例として書き出す対象（F-I8-10）
    var rejectedEventsForExport: [AnnotatedEvent] {
        events
            .filter { $0.status == .rejected }
            .map { corrected($0) }
    }

    // MARK: - 選別（F-I8-2）

    /// 承認と球種指定を1操作で行う
    mutating func confirm(id: String, shotClass: ShotClass, now: Date = Date()) {
        update(id: id, now: now) { event in
            event.shotClass = shotClass
            event.status = .confirmed
        }
    }

    /// 複数イベントへ同一の球種を一括付与する（F-I8-3）
    mutating func confirm(ids: [String], shotClass: ShotClass, now: Date = Date()) {
        for id in ids {
            confirm(id: id, shotClass: shotClass, now: now)
        }
    }

    mutating func reject(id: String, now: Date = Date()) {
        update(id: id, now: now) { event in
            event.status = .rejected
        }
    }

    /// 判断を未レビューへ戻す（保留・取り消し）
    ///
    /// 球種も落とす。`proposed` かつ球種を持つ状態を作ると、承認済みか未判断かを
    /// 状態だけで判別できなくなる。
    mutating func unreview(id: String, now: Date = Date()) {
        update(id: id, now: now) { event in
            event.status = .proposed
            event.shotClass = nil
        }
    }

    // MARK: - 見落としの補完（F-I8-5）

    /// 波形上の任意位置へイベントを追加する
    @discardableResult
    mutating func addManualEvent(impactAt: Date, now: Date = Date()) -> AnnotatedEvent {
        let event = AnnotatedEvent(impactAt: impactAt, origin: .manual)
        events.append(event)
        events.sort { $0.impactAt < $1.impactAt }
        updatedAt = now
        return event
    }

    mutating func remove(id: String, now: Date = Date()) {
        events.removeAll { $0.id == id }
        updatedAt = now
    }

    // MARK: - 位置と時刻の調整（F-I8-6/7）

    /// インパクト位置を前後にずらす
    mutating func adjustImpact(id: String, bySeconds seconds: Double, now: Date = Date()) {
        update(id: id, now: now) { event in
            event.impactAt = event.impactAt.addingTimeInterval(seconds)
        }
        events.sort { $0.impactAt < $1.impactAt }
    }

    /// セッション全体の時刻オフセットを設定する
    ///
    /// Why not 各イベントの `impactAt` を書き換える: 補正値を持たせておけば
    /// 何度でも調整し直せる。書き換えてしまうと元の検知位置が失われ、
    /// 補正を戻したり別の値で試すことができない。
    mutating func setTimeOffset(_ seconds: Double, now: Date = Date()) {
        timeOffsetSeconds = seconds
        updatedAt = now
    }

    // MARK: - 検知結果の取り込み

    /// 検知器の結果を取り込む（再実行しても人の判断を失わない）
    ///
    /// - Parameter tolerance: 既存イベントと同一とみなす時間差（秒）
    ///
    /// Why not 全て入れ替える: パラメータを変えて検知し直すたびに承認済みの球種と
    /// 却下の記録が消える。却下は検知器改善のための負例であり（F-I8-10）、
    /// 失うと同じ誤検知を何度も却下し直すことになる。
    mutating func merge(detected: [DetectedImpact], tolerance: Double = 0.25, now: Date = Date()) {
        var survivors: [AnnotatedEvent] = []
        var unmatched = events

        for impact in detected.sorted(by: { $0.impactAt < $1.impactAt }) {
            let nearest = unmatched.enumerated().min { lhs, rhs in
                abs(lhs.element.impactAt.timeIntervalSince(impact.impactAt))
                    < abs(rhs.element.impactAt.timeIntervalSince(impact.impactAt))
            }
            if let nearest,
               abs(nearest.element.impactAt.timeIntervalSince(impact.impactAt)) <= tolerance {
                // 既存の判断・調整済みの位置を残し、参考値だけ更新する
                var event = unmatched.remove(at: nearest.offset)
                event.detectorPeak = impact.peakAcceleration
                survivors.append(event)
            } else {
                survivors.append(AnnotatedEvent(
                    impactAt: impact.impactAt,
                    origin: .detector,
                    detectorPeak: impact.peakAcceleration
                ))
            }
        }

        // 検知されなくなった候補のうち、人が触っていないものだけを捨てる
        survivors.append(contentsOf: unmatched.filter { $0.isReviewed || $0.origin == .manual })

        events = survivors.sorted { $0.impactAt < $1.impactAt }
        updatedAt = now
    }

    // MARK: - Private

    private mutating func update(
        id: String, now: Date, _ transform: (inout AnnotatedEvent) -> Void
    ) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        transform(&events[index])
        updatedAt = now
    }

    /// 時刻オフセット補正を適用した複製を返す
    private func corrected(_ event: AnnotatedEvent) -> AnnotatedEvent {
        guard timeOffsetSeconds != 0 else { return event }
        var corrected = event
        corrected.impactAt = event.impactAt.addingTimeInterval(timeOffsetSeconds)
        return corrected
    }
}
