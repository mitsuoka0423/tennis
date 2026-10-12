import type { Tournament } from "../src/types.ts";

export const tournament = (over: Partial<Tournament> = {}): Tournament => ({
  id: "clover:c1",
  site: "clover",
  name: "テスト大会",
  // 2026-10-17 は土曜日
  date: "2026-10-17",
  startTime: "09:00",
  venue: "テストコート",
  event: "男子シングルス",
  level: "中級",
  levelRaw: "中級",
  status: "受付中",
  surface: "オムニコート",
  url: "https://example.com/1",
  ...over,
});
