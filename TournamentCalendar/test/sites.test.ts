import { describe, expect, it } from "vitest";
import { parseClover } from "../src/sites/clover.ts";
import { parseLeone } from "../src/sites/leone.ts";
import { lastPage, parseInspirits } from "../src/sites/inspirits.ts";
import { fixture } from "./fixture.ts";

describe("parseClover", () => {
  const list = parseClover(fixture("clover.html"));

  it("一覧の大会をすべて取り出すこと", () => {
    expect(list).toHaveLength(10);
  });

  it("大会の各項目を取り出すこと", () => {
    expect(list[0]).toEqual({
      id: "clover:c56411",
      site: "clover",
      name: "第363回 MTSテニスアリーナ三鷹 ナイターミックスダブルス 中級以下",
      date: "2026-10-18",
      startTime: null,
      venue: "MTS三鷹",
      event: "ミックスダブルス",
      level: "中級",
      levelRaw: "中級以下",
      status: "受付中",
      url: "https://tennis-net.jp/clover/c56411",
    });
  });

  it("申込み欄の表記から受付前・中止を判別すること", () => {
    const statuses = list.map((t) => t.status);
    expect(statuses.filter((s) => s === "中止")).toHaveLength(1);
    expect(statuses.filter((s) => s === "受付前")).toHaveLength(1);
    expect(statuses).not.toContain("不明");
  });
});

describe("parseLeone", () => {
  const list = parseLeone(fixture("leone.html"));

  it("月見出しの行を除いて大会だけを取り出すこと", () => {
    expect(list.length).toBeGreaterThan(0);
    expect(list.every((t) => /^leone:\d+$/.test(t.id))).toBe(true);
  });

  it("大会の各項目を取り出すこと", () => {
    expect(list[0]).toEqual({
      id: "leone:3110",
      site: "leone",
      name: "【楽しく試合経験♪】 レオーネカップ 男子中上級シングルス",
      date: "2026-10-12",
      startTime: "14:00",
      venue: "アイビーTC",
      event: "男子シングルス",
      level: "中上級",
      levelRaw: "中上級",
      status: "不明",
      url: "https://leone.tokyo/frontend/tournament-public.html?tId=3110",
    });
  });

  it("1桁時の開始時刻を2桁に揃えること", () => {
    expect(list.find((t) => t.id === "leone:3084")?.startTime).toBe("09:00");
  });

  it("すべての大会が男子シングルスでレベルが判別できること", () => {
    expect(list.every((t) => t.event === "男子シングルス")).toBe(true);
    expect(list.map((t) => t.level)).not.toContain("不明");
  });
});

describe("parseInspirits", () => {
  const html = fixture("inspirits-page2.html");
  const list = parseInspirits(html);

  it("1ページ分の20件を取り出すこと", () => {
    expect(list).toHaveLength(20);
  });

  it("大会の各項目を取り出すこと", () => {
    expect(list[0]).toEqual({
      id: "inspirits:29177@2026-10-17T08:00",
      site: "inspirits",
      name: "大熊テニスクラブ 男子シングルス 中上級",
      date: "2026-10-17",
      startTime: "08:00",
      venue: "大熊テニスクラブ",
      event: "男子シングルス",
      level: "中上級",
      levelRaw: "中上級",
      status: "受付中",
      url: "https://reserve.inspirits-tennis-club.com/reservations/add?event_id=29177&usage_timestamp_from=2026%2F10%2F17+08%3A00",
    });
  });

  it("在庫表示から受付中・空き少・満員を判別すること", () => {
    const count = (s: string) => list.filter((t) => t.status === s).length;
    expect([count("受付中"), count("空き少"), count("満員")]).toEqual([6, 8, 6]);
  });

  it("ページ送りから最終ページ番号を読むこと", () => {
    expect(lastPage(html)).toBe(6);
  });
});
