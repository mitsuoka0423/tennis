import * as cheerio from "cheerio";
import type { Status, Tournament } from "../types.ts";
import { normalizeEvent } from "../normalize/event.ts";
import { normalizeLevel } from "../normalize/level.ts";
import { hhmm, isoDate, squash } from "../normalize/text.ts";

export const INSPIRITS_ORIGIN = "https://reserve.inspirits-tennis-club.com";

const SURFACE = /(\S*(?:人工芝|ハード|クレー|オムニ|カーペット)\S*?コート)(\((?:アウトドア|インドア)\))?/;

export const parseSurface = (text: string): string | null => {
  const m = text.match(SURFACE);
  return m ? `${m[1]}${m[2] ?? ""}` : null;
};

const toStatus = (statusClass: string): Status => {
  if (statusClass.includes("stock_many")) return "受付中";
  if (statusClass.includes("stock_few")) return "空き少";
  if (statusClass.includes("out_of_stock")) return "満員";
  return "不明";
};

export const parseInspirits = (html: string): Tournament[] => {
  const $ = cheerio.load(html);
  return $("li.list_body_line_wrap")
    .toArray()
    .flatMap((el) => {
      const row = $(el);
      const btn = row.find(".statusBtn").first();
      const eventId = btn.attr("data-event-id");
      const stamp = btn.attr("data-usage-timestamp") ?? "";
      const d = squash(row.find(".b-day").text()).match(/(\d{4})\/(\d{1,2})\/(\d{1,2})/);
      if (!eventId || !d) return [];
      const venue = squash(row.find(".name-label").text()).replace(/^\[|\]$/g, "");
      const detail = squash(row.find(".name-detail").text());
      // 種目の前後に年齢制限やコート種別の注記が入るため、種目の直後の語だけをレベルとみなす
      const levelRaw = detail.match(/(?:シングルス|ダブルス|団体戦)\s+(\S+)/)?.[1] ?? "";
      const date = isoDate(d[1]!, d[2]!, d[3]!);
      const startTime = hhmm(stamp) ?? hhmm(row.find(".b-time").text());
      return [
        {
          // 同じ event_id が日時違いで繰り返し出るため、日時まで含めて一意にする
          id: `inspirits:${eventId}@${date}T${startTime ?? ""}`,
          site: "inspirits",
          name: `${venue} ${detail}`,
          date,
          startTime,
          venue,
          event: normalizeEvent(detail),
          level: normalizeLevel(levelRaw),
          levelRaw,
          status: toStatus(row.find(".b-status dd").attr("class") ?? ""),
          surface: parseSurface(detail),
          url: new URL(btn.attr("data-url") ?? "/reservations/calendar", INSPIRITS_ORIGIN).href,
        } satisfies Tournament,
      ];
    });
};

export const lastPage = (html: string): number => {
  const $ = cheerio.load(html);
  const pages = $(".js_paginator_page")
    .toArray()
    .map((el) => Number($(el).attr("data-url")?.match(/page=(\d+)/)?.[1] ?? 1));
  return Math.max(1, ...pages);
};
