//
//  ISO8601DateCodingTests.swift
//  TennisAnalyserTests
//
//  ISO8601DateCoding（F-I9-9: 小数秒を保持した時刻の読み書き）のユニットテスト

import Testing
import Foundation
@testable import TennisAnalyser

struct ISO8601DateCodingTests {

    /// 小数秒を持つ時刻（.250 秒）
    private let date = Date(timeIntervalSince1970: 1_780_000_000.25)

    @Test("書き出した文字列を読み戻すとミリ秒まで一致する")
    func roundTripKeepsSubSecond() {
        let text = ISO8601DateCoding.string(from: date)
        let parsed = try! #require(ISO8601DateCoding.date(from: text))

        #expect(text.contains(".250"))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
    }

    @Test("小数秒の無い既存の文字列も読める")
    func acceptsSecondsOnlyText() {
        let parsed = try! #require(ISO8601DateCoding.date(from: "2026-06-08T09:46:40Z"))

        #expect(abs(parsed.timeIntervalSince1970 - 1_780_000_000) < 0.001)
    }

    @Test("ISO8601 として解釈できない文字列は nil を返す")
    func rejectsGarbage() {
        #expect(ISO8601DateCoding.date(from: "not a date") == nil)
    }

    // MARK: - JSONCoder（manifest.json・診断記録が通る経路）

    private struct Box: Codable, Equatable {
        let at: Date
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601DateCoding.encodingStrategy
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601DateCoding.decodingStrategy
        return decoder
    }

    @Test("JSON へ符号化して復号してもミリ秒が失われない")
    func jsonRoundTripKeepsSubSecond() throws {
        let data = try encoder().encode(Box(at: date))
        let decoded = try decoder().decode(Box.self, from: data)

        // 既定の .iso8601 はここで 0.25 秒を捨てるため、同期が最大1秒ずれていた
        #expect(abs(decoded.at.timeIntervalSince(date)) < 0.001)
    }

    @Test("秒精度で書かれた既存の manifest も復号できる")
    func jsonDecodesLegacySecondsOnly() throws {
        let json = Data(#"{"at":"2026-06-08T09:46:40Z"}"#.utf8)
        let decoded = try decoder().decode(Box.self, from: json)

        #expect(abs(decoded.at.timeIntervalSince1970 - 1_780_000_000) < 0.001)
    }

    @Test("復号できない値は DecodingError になる")
    func jsonRejectsGarbage() {
        let json = Data(#"{"at":"not a date"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try decoder().decode(Box.self, from: json)
        }
    }
}
