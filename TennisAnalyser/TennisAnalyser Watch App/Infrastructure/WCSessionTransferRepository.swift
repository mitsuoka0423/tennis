//
//  WCSessionTransferRepository.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — WCSession.transferFile によるスイング逐次転送（F-W5）

import Foundation
import WatchConnectivity
import os

/// `WCSession.transferFile` によるスイングファイル転送の実装
///
/// - スイング保存のたびに `enqueue` で転送キューへ追加（バックグラウンド転送）
/// - 転送完了コールバックでローカル CSV を削除（F-W5 + ストレージ保護）
/// - 未転送分は `retryPending` で再送（アクティベート完了時・ワークアウト終了時）
/// - 連続センサー記録のチャンクは `retryPending` でのみ送る（W6-T14）。
///   1時間で約46MB になり、セッション中に送るとスイング転送と帯域を奪い合うため
/// - WCSession の転送キューはプロセス再起動を跨いで永続化されるため、
///   `outstandingFileTransfers` と突き合わせて二重エンキューを防ぐ
///
/// 注意: delegate コールバックは WCSession 内部スレッドから呼ばれる。
/// Phase 1 の教訓に従い actor 隔離はせず、UI 通知のみ main queue へディスパッチする。
final class WCSessionTransferRepository: NSObject, SwingTransferRepository {

    // MARK: - Constants

    /// 転送 metadata の種別。iPhone 側（`PhoneSessionManager`）が取り込み先を振り分ける
    static let metadataTypeSwing = "swing"
    static let metadataTypeContinuousChunk = "continuousChunk"

    /// 連続センサー記録の保存ディレクトリ名（転送完了時の削除先の判別に使う）
    static let continuousDirectoryName = "continuous"

    // MARK: - Dependencies

    private let swingRepo: any SwingRepository
    private let continuousRepo: (any ContinuousSensorRepository)?

    // MARK: - State

    var onStatusChanged: ((_ transferred: Int, _ pending: Int) -> Void)?
    var onReachabilityChanged: ((_ reachable: Bool, _ lastContactAt: Date?) -> Void)?
    private var transferredCount = 0
    /// 最後に iPhone への到達を確認できた時刻（F-I9-6）
    private var lastContactAt: Date?

    private var session: WCSession { WCSession.default }

    // MARK: - Init

    init(
        swingRepo: any SwingRepository,
        continuousRepo: (any ContinuousSensorRepository)? = nil
    ) {
        self.swingRepo = swingRepo
        self.continuousRepo = continuousRepo
        super.init()
    }

    // MARK: - SwingTransferRepository

    func activate() {
        guard WCSession.isSupported() else {
            AppLog.transfer.error("WCSession not supported on this device")
            return
        }
        session.delegate = self
        session.activate()
    }

    func enqueue(fileURL: URL, swing: Swing) {
        let metadata: [String: Any] = [
            "type": Self.metadataTypeSwing,
            "swingId": swing.id,
            "sessionId": swing.sessionId,
            "sequence": swing.sequence,
            // 小数秒つき（F-I9-9）。CSV ヘッダーの DetectedAt と同じ形式に揃える
            "detectedAt": SwingRepositoryImpl.iso8601.string(from: swing.detectedAt),
            "peakAcceleration": swing.peakAcceleration,
        ]
        session.transferFile(fileURL, metadata: metadata)
        AppLog.transfer.info("enqueued swing #\(swing.sequence, privacy: .public) (\(fileURL.lastPathComponent, privacy: .public))")
        notifyStatus()
    }

    func retryPending() {
        guard session.activationState == .activated else { return }
        // WCSession キューに載っていないローカル残存ファイルを再エンキュー
        let outstanding = Set(session.outstandingFileTransfers.map { $0.file.fileURL.path })

        let localFiles = (try? swingRepo.listFiles()) ?? []
        for url in localFiles where !outstanding.contains(url.path) {
            // メタデータはパスから復元（CSV ヘッダーにも全メタ情報あり = 冗長設計）
            let metadata: [String: Any] = [
                "type": Self.metadataTypeSwing,
                "sessionId": url.deletingLastPathComponent().lastPathComponent,
                "sequence": Int(url.deletingPathExtension().lastPathComponent) ?? 0,
            ]
            session.transferFile(url, metadata: metadata)
            AppLog.transfer.info("re-enqueued \(url.lastPathComponent, privacy: .public)")
        }

        // W6-T14: 連続センサー記録のチャンク（書き込み中のチャンクは listFiles に現れない）
        let chunks = continuousRepo.flatMap { try? $0.listFiles() } ?? []
        for url in chunks where !outstanding.contains(url.path) {
            let metadata: [String: Any] = [
                "type": Self.metadataTypeContinuousChunk,
                "sessionId": url.deletingLastPathComponent().lastPathComponent,
                "chunkIndex": Int(url.deletingPathExtension().lastPathComponent) ?? 0,
            ]
            session.transferFile(url, metadata: metadata)
            AppLog.transfer.info("enqueued chunk \(url.lastPathComponent, privacy: .public)")
        }

        notifyStatus()
    }

    /// F-I6: セッション開始を iPhone へ通知する（applicationContext は「最新状態のみ」を
    /// 保持し、iPhone がバックグラウンドでも到達するため、この用途に適している）
    func notifySessionStarted(sessionId: String) {
        sendSessionStatus(sessionId: sessionId, status: "started")
    }

    func notifySessionEnded(sessionId: String) {
        sendSessionStatus(sessionId: sessionId, status: "ended")
    }

    // MARK: - Private

    private func sendSessionStatus(sessionId: String, status: String) {
        guard session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext([
                "type": "sessionStatus",
                "sessionId": sessionId,
                "status": status,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ])
            AppLog.transfer.info("session \(status, privacy: .public): \(sessionId, privacy: .public)")
        } catch {
            AppLog.transfer.error("updateApplicationContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iPhone への到達性を通知する（F-I9-6）
    ///
    /// Why not 到達性の変化通知だけで更新する: `sessionReachabilityDidChange` は
    /// 圏外へ出た瞬間には必ずしも飛ばない。転送の完了は到達できたことの実証なので、
    /// そちらでも時刻を進める。
    private func notifyReachability() {
        let reachable = session.activationState == .activated && session.isReachable
        if reachable { lastContactAt = Date() }
        let contact = lastContactAt
        DispatchQueue.main.async { [weak self] in
            self?.onReachabilityChanged?(reachable, contact)
        }
    }

    /// 転送状態を通知する
    /// - Parameter finished: 完了直後の転送。`didFinish` 時点では
    ///   `outstandingFileTransfers` にまだ含まれていることがあるため除外する（W-2）
    private func notifyStatus(excluding finished: WCSessionFileTransfer? = nil) {
        var outstanding = session.outstandingFileTransfers
        if let finished {
            outstanding.removeAll { $0 === finished }
        }
        let pending = outstanding.count
        let transferred = transferredCount
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(transferred, pending)
        }
    }
}

// MARK: - WCSessionDelegate

extension WCSessionTransferRepository: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            AppLog.transfer.error("activation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        AppLog.transfer.info("activated: state=\(activationState.rawValue, privacy: .public)")
        notifyReachability()
        // アクティベート完了時に未転送分を再送（前回セッションの残り）
        retryPending()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        AppLog.transfer.info("reachability changed: \(session.isReachable, privacy: .public)")
        notifyReachability()
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        if let error {
            // 失敗分はローカルに残し、次回 retryPending で再送する
            AppLog.transfer.error("transfer failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            transferredCount += 1
            AppLog.transfer.info("transfer finished \(url.lastPathComponent, privacy: .public)")
            // 転送が完了したこと自体が到達の実証（F-I9-6）
            notifyReachability()
            // 転送完了後にローカルキャッシュを削除（F-W5 / ストレージ保護）
            // 削除先の振り分けは metadata ではなく保存先パスで行う。metadata は
            // 転送キューの永続化を跨いで古い形式（type 無し）が残り得るため
            let isChunk = url.pathComponents.contains(Self.continuousDirectoryName)
            do {
                if isChunk {
                    try continuousRepo?.deleteFile(at: url)
                } else {
                    try swingRepo.deleteFile(at: url)
                }
            } catch {
                AppLog.transfer.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        notifyStatus(excluding: fileTransfer)
    }
}
