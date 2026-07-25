//
//  AppLog.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — 構造化ログの入口（F-I7-6）
//
//  Why not print: `print` の出力は Xcode をアタッチしている間しか stdout に現れない。
//  2026-07-21 の実機検証（テニス実練習57分）ではログが1行も残らず、
//  録画が停止していた原因をファイル配置からの逆算でしか追えなかった。
//  `os.Logger` なら未接続でも記録され、後から Console.app・sysdiagnose で追跡できる。
//
//  Why not 同一ファイルを両ターゲットで共有: 本プロジェクトは Xcode の
//  同期グループ（PBXFileSystemSynchronizedRootGroup）で構成されており、
//  ターゲットごとにフォルダが対応する。共有フォルダを追加すると project.pbxproj の
//  手編集が必要になるためリスクが見合わない。Watch 側に同名の定義を置いている。

import os

/// アプリ全体の構造化ログ
///
/// サブシステムは Bundle Identifier に合わせる。Console.app では
/// `subsystem:com.spleeing.TennisAnalyser` で絞り込める。
enum AppLog {

    private static let subsystem = "com.spleeing.TennisAnalyser"

    /// カメラ録画の開始・停止・中断・復帰
    static let recording = Logger(subsystem: subsystem, category: "recording")
    /// スイング単位クリップの切り出し
    static let clip = Logger(subsystem: subsystem, category: "clip")
    /// Watch からのファイル受信・セッション通知
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    /// 受信済みスイングの永続化
    static let store = Logger(subsystem: subsystem, category: "store")
    /// セッション診断
    static let session = Logger(subsystem: subsystem, category: "session")
}
