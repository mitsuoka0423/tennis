//
//  SwingRepository.swift
//  TennisAnalyser Watch App
//
//  Domain Repository Protocol — 外部フレームワーク依存なし

import Foundation

/// スイング単位データの永続化インターフェース（F-W4）
///
/// 1スイング = 1ファイル（CSV）。実装は Infrastructure 層が提供する。
protocol SwingRepository: AnyObject {
    /// スイングを保存し、保存先ファイルの URL を返す（WCSession 転送用）
    @discardableResult
    func save(swing: Swing) async throws -> URL

    /// 保存済み（未転送含む）スイングファイルの一覧を返す
    func listFiles() throws -> [URL]

    /// スイングファイルを削除する（転送完了後のクリーンアップ用）
    func deleteFile(at url: URL) throws
}
