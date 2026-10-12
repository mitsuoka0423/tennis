import { describe, expect, it } from "vitest";
import { applyFilter, defaultFilter, matchesPreference, parseFilter } from "../src/filter.ts";
import { isDayOff, parseHolidaysCsv } from "../src/holidays.ts";
import { tournament } from "./helpers.ts";

const TODAY = "2026-10-12";
const holidays = new Set(["2026-10-12"]); // スポーツの日（月）

describe("isDayOff", () => {
  it("土日と祝日を休日、それ以外を平日と判定すること", () => {
    expect(isDayOff("2026-10-17", holidays)).toBe(true); // 土
    expect(isDayOff("2026-10-18", holidays)).toBe(true); // 日
    expect(isDayOff("2026-10-12", holidays)).toBe(true); // 祝
    expect(isDayOff("2026-10-13", holidays)).toBe(false); // 火
  });
});

describe("parseHolidaysCsv", () => {
  it("見出し行を飛ばし、日付を YYYY-MM-DD に揃えること", () => {
    expect(parseHolidaysCsv("国民の祝日・休日月日,国民の祝日・休日名称\r\n2027/1/1,元日\r\n")).toEqual([
      { date: "2027-01-01", name: "元日" },
    ]);
  });
});

describe("parseFilter", () => {
  it("クエリが無いときは参加条件を既定値にすること", () => {
    expect(parseFilter(new URLSearchParams(), TODAY)).toEqual({
      from: "2026-10-12",
      to: "2026-12-11",
      days: ["休日"],
      events: ["男子シングルス"],
      levels: ["中級", "中上級"],
      sites: ["clover", "leone", "inspirits"],
      hideFull: true,
    });
  });

  it("送信済みのフォームでチェックが無い項目は空として扱うこと", () => {
    const f = parseFilter(new URLSearchParams("q=1&level=オープン"), TODAY);
    expect(f.levels).toEqual(["オープン"]);
    expect(f.days).toEqual([]);
    expect(f.hideFull).toBe(false);
  });

  it("想定外の値を捨てること", () => {
    const f = parseFilter(new URLSearchParams("q=1&from=abc&event=テニス&event=男子ダブルス"), TODAY);
    expect(f.from).toBe(TODAY);
    expect(f.events).toEqual(["男子ダブルス"]);
  });
});

describe("applyFilter", () => {
  const f = defaultFilter(TODAY);

  it("参加条件に合う大会だけを残すこと", () => {
    const list = [
      tournament({ id: "ok" }),
      tournament({ id: "weekday", date: "2026-10-13" }),
      tournament({ id: "doubles", event: "男子ダブルス" }),
      tournament({ id: "open", level: "オープン" }),
      tournament({ id: "full", status: "満員" }),
      tournament({ id: "cancel", status: "中止" }),
      tournament({ id: "far", date: "2027-01-09" }),
    ];
    expect(applyFilter(list, f, holidays).map((t) => t.id)).toEqual(["ok"]);
  });

  it("状態が不明の大会は隠さないこと", () => {
    expect(applyFilter([tournament({ status: "不明" })], f, holidays)).toHaveLength(1);
  });
});

describe("matchesPreference", () => {
  it("期間と満員を問わず参加条件だけで判定すること", () => {
    expect(matchesPreference(tournament({ date: "2027-05-01", status: "満員" }), holidays)).toBe(true);
    expect(matchesPreference(tournament({ level: "初級" }), holidays)).toBe(false);
  });
});
