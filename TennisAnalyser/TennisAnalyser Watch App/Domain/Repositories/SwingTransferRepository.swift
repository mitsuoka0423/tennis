//
//  SwingTransferRepository.swift
//  TennisAnalyser Watch App
//
//  Domain Repository Protocol — 外部フレームワーク依存なし

import Foundation

/// スイングファイルの iPhone への転送インターフェース（F-W5）
///
/// 実装は Infrastructure 層（WCSession 実装、またはテスト用モック）が提供する。
protocol SwingTransferRepository: AnyObject {
    /// 転送状態の変化通知（メインスレッドで呼ばれる）
    /// - transferred: このセッションで転送完了した累計件数
    /// - pending: 未転送（キュー内 + ローカル残存）件数
    var onStatusChanged: ((_ transferred: Int, _ pending: Int) -> Void)? { get set }

    /// iPhone への到達性の変化通知（メインスレッドで呼ばれる。F-I9-6）
    ///
    /// コート反対側では 20〜30m 離れ、Bluetooth が届かない。
    /// 「転送が滞っている」のか「そもそも圏外なのか」を区別する材料になる。
    /// - reachable: いま到達できるか
    /// - lastContactAt: 最後に到達を確認できた時刻（一度も無ければ nil）
    var onReachabilityChanged: ((_ reachable: Bool, _ lastContactAt: Date?) -> Void)? { get set }

    /// 転送セッションを有効化する（アプリ起動時に1回）
    func activate()

    /// スイングファイルを転送キューに追加する（保存のたびに呼ぶ）
    func enqueue(fileURL: URL, swing: Swing)

    /// 未転送分を再送する（ワークアウト終了時・アクティベート完了時）
    func retryPending()

    /// セッション開始を iPhone へ通知する（F-I6: 自動録画のトリガー）
    func notifySessionStarted(sessionId: String)

    /// セッション終了を iPhone へ通知する（F-I6: 自動録画停止のトリガー）
    func notifySessionEnded(sessionId: String)
}
