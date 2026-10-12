import * as cheerio from "cheerio";
import type { Tournament } from "../types.ts";
import { normalizeEvent } from "../normalize/event.ts";
import { normalizeLevel } from "../normalize/level.ts";
import { hhmm, isoDate, squash } from "../normalize/text.ts";

export const LEONE_URL = "https://leone-tokyo2022.com/mens-singles/";

export const parseLeone = (html: string): Tournament[] => {
  const $ = cheerio.load(html);
  return $("table.tablepress tbody tr")
    .toArray()
    .flatMap((el) => {
      const cells = $(el).children("td");
      // 月見出しの行（colspan）は5列にならない
      if (cells.length !== 5) return [];
      const text = (i: number) => squash(cells.eq(i).text());
      const when = text(0);
      const d = when.match(/(\d{4})年\s*(\d{1,2})月(\d{1,2})日/);
      const url = cells.eq(4).find("a").attr("href") ?? "";
      const key = url.match(/tId=(\d+)/)?.[1];
      if (!d || !key) return [];
      const name = text(1);
      const levelRaw = text(2);
      return [
        {
          id: `leone:${key}`,
          site: "leone",
          name,
          date: isoDate(d[1]!, d[2]!, d[3]!),
          startTime: hhmm(when),
          venue: text(3),
          event: normalizeEvent(name),
          level: normalizeLevel(levelRaw),
          levelRaw,
          // 一覧ページに空き状況が無い。詳細ページは別ドメインの SPA で、取得コストに見合わないため見送る
          status: "不明",
          url,
        } satisfies Tournament,
      ];
    });
};
