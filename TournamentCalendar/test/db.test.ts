import { describe, expect, it } from "vitest";
import { openDb } from "../src/db.ts";
import { tournament } from "./helpers.ts";

const T1 = "2026-10-12T19:30:00";
const T2 = "2026-10-13T19:30:00";

describe("openDb", () => {
  it("同じ大会を取り直しても1件のまま、最新の内容で上書きすること", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament()] }], T1);
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament({ venue: "変更後" })] }], T2);
    expect(db.upcoming("2026-01-01")).toEqual([tournament({ venue: "変更後" })]);
  });

  it("状態が変わったときだけ変化を記録すること", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament({ status: "満員" })] }], T1);
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament({ status: "満員" })] }], T1);
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament({ status: "受付中" })] }], T2);
    expect(db.statusChangesSince(T1).map((c) => [c.from, c.to])).toEqual([["満員", "受付中"]]);
  });

  it("前回の取得以降に初めて見た大会だけを新着として返すこと", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament()] }], T1);
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament(), tournament({ id: "clover:c2" })] }], T2);
    expect(db.newSince(T1).map((t) => t.id)).toEqual(["clover:c2"]);
  });

  it("最新の取得で一覧から消えた大会は表示しないこと", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament(), tournament({ id: "clover:c2" })] }], T1);
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament()] }], T2);
    expect(db.upcoming("2026-01-01").map((t) => t.id)).toEqual(["clover:c1"]);
  });

  it("取得に失敗したサイトは前回成功時の大会を表示し続けること", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament()] }], T1);
    db.saveCrawl([{ site: "clover", ok: false, error: "timeout" }], T2);
    expect(db.upcoming("2026-01-01")).toHaveLength(1);
    expect(db.latestRuns()).toEqual([{ site: "clover", ok: false, count: 0, error: "timeout", ranAt: T2 }]);
  });

  it("開始日より前の大会を表示しないこと", () => {
    const db = openDb(":memory:");
    db.saveCrawl([{ site: "clover", ok: true, tournaments: [tournament()] }], T1);
    expect(db.upcoming("2026-10-18")).toEqual([]);
  });
});
