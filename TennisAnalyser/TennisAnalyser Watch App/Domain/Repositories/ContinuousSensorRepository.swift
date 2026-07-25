//
//  ContinuousSensorRepository.swift
//  TennisAnalyser Watch App
//
//  Domain Repository Protocol — 外部フレームワーク依存なし

import Foundation

/// センサーの全区間（連続）記録の永続化インターフェース（F-I8 / W6-T14）
///
/// スイング単位の `SwingRepository` と併存する。検知器がウィンドウ外を捨てるのに対し、
/// こちらは届いたサンプルを全て保存し、打点の切り出しは事後（iPhone 側）に行う。
///
/// 1セッションを複数のチャンクに分割して保存する。転送単位を小さく保つためであり、
/// 途中で失敗しても未転送のチャンクだけを再送できる。
protocol ContinuousSensorRepository: AnyObject {
    /// 記録を開始する（チャンク番号を 0 から振り直す）
    func beginSession(sessionId: String)

    /// サンプルバッチを追記する
    /// - Parameters:
    ///   - samples: センサータイムスタンプ昇順のサンプル列
    ///   - receivedAt: バッチを受け取った壁時計時刻。センサータイムスタンプ（起動からの
    ///     経過時間）を壁時計へ対応付ける基準として、チャンク先頭で記録する
    func append(_ samples: [MotionSample], receivedAt: Date)

    /// 記録を終了し、書き込み中のチャンクを閉じる
    ///
    /// 本メソッドの復帰後、書き出し済みの全チャンクが `listFiles()` に現れることを保証する
    func endSession()

    /// 転送対象のチャンク一覧を返す（書き込み中のチャンクは含まない）
    func listFiles() throws -> [URL]

    /// チャンクファイルを削除する（転送完了後のクリーンアップ用）
    func deleteFile(at url: URL) throws
}
