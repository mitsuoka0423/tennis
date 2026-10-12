import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { sha256, WISE_PDF_SHA256, wiseTournaments } from "../src/sites/wise.ts";

describe("wiseTournaments", () => {
  const list = wiseTournaments();

  it("書き写した日程の基準にした PDF と、保存した PDF が同じであること", () => {
    const pdf = readFileSync(new URL("./fixtures/wise-sundaynight.pdf", import.meta.url));
    expect(sha256(pdf.buffer.slice(pdf.byteOffset, pdf.byteOffset + pdf.byteLength))).toBe(WISE_PDF_SHA256);
  });

  it("開催日はすべて日曜日であること", () => {
    for (const t of list) expect(new Date(`${t.date}T00:00:00Z`).getUTCDay()).toBe(0);
  });

  it("男子シングルスは2026年に39回あること", () => {
    // 第1・第2・第4日曜が各11〜12回、第5日曜が4回
    expect(list.filter((t) => t.event === "男子シングルス")).toHaveLength(11 + 12 + 12 + 4);
  });

  it("2026年10月以降の男子シングルスの日程が PDF と一致すること", () => {
    const dates = list
      .filter((t) => t.event === "男子シングルス" && t.date >= "2026-10-01")
      .map((t) => t.date)
      .sort();
    expect(dates).toEqual([
      "2026-10-04", "2026-10-11", "2026-10-18",
      "2026-11-01", "2026-11-08", "2026-11-22", "2026-11-29",
      "2026-12-06", "2026-12-13", "2026-12-20",
    ]);
  });

  it("大会ごとに一意な id を持つこと", () => {
    expect(new Set(list.map((t) => t.id)).size).toBe(list.length);
  });
});
