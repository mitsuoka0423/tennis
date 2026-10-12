import * as cheerio from "cheerio";
import type { Status, Tournament } from "../types.ts";
import { normalizeEvent } from "../normalize/event.ts";
import { normalizeLevel } from "../normalize/level.ts";
import { isoDate, squash } from "../normalize/text.ts";

export const CLOVER_URL = "https://tennis-net.jp/clover";

const toStatus = (entry: string): Status => {
  if (/中止/.test(entry)) return "中止";
  if (/申込み開始/.test(entry)) return "受付前";
  if (/満員|キャンセル待ち|締切/.test(entry)) return "満員";
  if (/申込みはこちら/.test(entry)) return "受付中";
  return "不明";
};

export const parseClover = (html: string): Tournament[] => {
  const $ = cheerio.load(html);
  return $("li.game-list-item")
    .toArray()
    .flatMap((el) => {
      const item = $(el);
      const field = (label: string) =>
        squash(item.find("dt").filter((_, dt) => $(dt).text().trim() === label).next("dd").text());
      const name = squash(item.find(".heading-game").text());
      const url = item.find("a.game-detail").attr("href") ?? "";
      const key = url.match(/\/clover\/([^/?]+)/)?.[1];
      const d = field("開催日").match(/(\d{4})年(\d{1,2})月(\d{1,2})日/);
      if (!key || !d) return [];
      const levelRaw = field("グレード");
      return [
        {
          id: `clover:${key}`,
          site: "clover",
          name,
          date: isoDate(d[1]!, d[2]!, d[3]!),
          startTime: null,
          venue: field("会場"),
          event: normalizeEvent(name),
          level: normalizeLevel(levelRaw),
          levelRaw,
          status: toStatus(field("申込み")),
          // 一覧にも大会ページにもサーフェスが載っていない（2026-10-12 確認）
          surface: null,
          url: url.replace(/\?.*$/, ""),
        } satisfies Tournament,
      ];
    });
};
