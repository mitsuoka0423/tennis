import { createHash } from "node:crypto";
import type { Event, Tournament } from "../types.ts";

export const WISE_PDF_URL = "http://www.teamwise.jp/26sundaynight.pdf";

/**
 * 日程を PDF から読み取らず、PDF の日程表を書き写して持つ。
 * PDF の日程は表の画像に近い組みかたで、テキストにすると日付が月・種目と対応しない順に並ぶ。
 * 年1回の公開で中身はほぼ変わらないため、書き写したうえで PDF の更新だけを検知する。
 */
export const WISE_PDF_SHA256 = "5851c4631f7c05565989a4373459f0fc813ec8e81466c327260ec097d1492731";

const YEAR = 2026;
const NAME = "'26 WISE サンデーナイトセッション";
const VENUE = "東宝調布スポーツパーク";
export const WISE_VENUE_ADDRESS = "東京都調布市多摩川2-29-1";

/** PDF「日程」の表。行ごとに同じ日に開催する2種目と、月→日 */
const SCHEDULE: ReadonlyArray<{ events: readonly Event[]; days: Readonly<Record<number, number>> }> = [
  {
    events: ["男子シングルス", "男子ダブルス"],
    days: { 1: 4, 2: 1, 3: 1, 5: 3, 6: 7, 7: 5, 8: 2, 9: 6, 10: 4, 11: 1, 12: 6 },
  },
  {
    events: ["男子シングルス", "女子シングルス"],
    days: { 1: 11, 2: 8, 3: 8, 4: 12, 5: 10, 6: 14, 7: 12, 8: 9, 9: 13, 10: 11, 11: 8, 12: 13 },
  },
  {
    events: ["男子シングルス", "ミックスダブルス"],
    days: { 1: 25, 2: 22, 3: 22, 4: 26, 5: 24, 6: 28, 7: 26, 8: 23, 9: 27, 10: 18, 11: 22, 12: 20 },
  },
  // 第5日曜の「add男子シングルス」も男子シングルスとして扱う
  { events: ["男子シングルス", "女子ダブルス"], days: { 3: 29, 5: 31, 8: 30, 11: 29 } },
];

export const wiseTournaments = (): Tournament[] =>
  SCHEDULE.flatMap(({ events, days }) =>
    Object.entries(days).flatMap(([month, day]) =>
      events.map((event): Tournament => {
        const date = `${YEAR}-${month.padStart(2, "0")}-${String(day).padStart(2, "0")}`;
        return {
          id: `wise:${date}:${event}`,
          site: "wise",
          name: `${NAME} ${event}`,
          date,
          startTime: "17:00",
          venue: VENUE,
          event,
          // 参加資格は「アドバンスビギナー（中級者クラスまでの方）」。上限が中級なので中級に寄せる
          level: "中級",
          levelRaw: "アドバンスビギナー（中級者クラスまで）",
          // PDF には空き状況が無い
          status: "不明",
          surface: "オムニコート",
          url: WISE_PDF_URL,
        };
      }),
    ),
  );

export const sha256 = (data: ArrayBuffer): string => createHash("sha256").update(Buffer.from(data)).digest("hex");
