//
//  SessionRepository.swift
//  TennisAnalyser Watch App
//
//  Domain Repository Protocol — 外部フレームワーク依存なし

import Foundation

/// セッションデータの永続化インターフェース
///
/// 実装は Infrastructure 層（CSV書き出し実装、またはテスト用モック）が提供する。
protocol SessionRepository: AnyObject {
    /// セッションをストレージに保存（CSV等）
    func save(session: SwingSession) async throws

    /// 保存済みセッションの一覧を返す
    func listSessions() async throws -> [SwingSession]

    /// 指定IDのセッションを削除（転送完了後のクリーンアップ用）
    func delete(sessionId: String) async throws

    /// セッションのファイルURLを返す（WCSession転送用）
    func fileURL(for sessionId: String) throws -> URL
}
