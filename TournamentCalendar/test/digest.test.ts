import { describe, expect, it } from "vitest";
import { buildDigest, formatDigest, isEmpty } from "../src/notify/digest.ts";
import { tournament } from "./helpers.ts";

const base = { added: [], changes: [], runs: [], holidays: new Set<string>(), today: "2026-10-12" };

describe("buildDigest", () => {
  it("参加条件に合わない新着や過去の大会を載せないこと", () => {
    const d = buildDigest({
      ...base,
      added: [
        tournament({ id: "ok" }),
        tournament({ id: "beginner", level: "初級" }),
        tournament({ id: "past", date: "2026-10-10" }),
      ],
    });
    expect(d.added.map((t) => t.id)).toEqual(["ok"]);
  });

  it("満員・中止の新着を載せないこと", () => {
    const d = buildDigest({
      ...base,
      added: [tournament({ id: "full", status: "満員" }), tournament({ id: "cancel", status: "中止" })],
    });
    expect(d.added).toEqual([]);
  });

  it("受付前から受付中を申込開始、満員から空きを空き発生に分けること", () => {
    const d = buildDigest({
      ...base,
      changes: [
        { tournament: tournament({ id: "a" }), from: "受付前", to: "受付中" },
        { tournament: tournament({ id: "b", status: "空き少" }), from: "満員", to: "空き少" },
        { tournament: tournament({ id: "c", status: "満員" }), from: "受付中", to: "満員" },
      ],
    });
    expect(d.opened.map((t) => t.id)).toEqual(["a"]);
    expect(d.vacancy.map((t) => t.id)).toEqual(["b"]);
  });

  it("新着に載せた大会を状態変化に重ねて載せないこと", () => {
    const t = tournament();
    const d = buildDigest({ ...base, added: [t], changes: [{ tournament: t, from: "満員", to: "受付中" }] });
    expect(d.vacancy).toEqual([]);
  });

  it("取得失敗と0件のサイトを載せること", () => {
    const d = buildDigest({
      ...base,
      runs: [
        { site: "clover", ok: false, count: 0, error: "timeout", ranAt: "" },
        { site: "leone", ok: true, count: 0, error: null, ranAt: "" },
        { site: "inspirits", ok: true, count: 100, error: null, ranAt: "" },
      ],
    });
    expect(d.failures.map((r) => r.site)).toEqual(["clover", "leone"]);
  });

  it("何も無ければ空と判定すること", () => {
    expect(isEmpty(buildDigest(base))).toBe(true);
  });
});

describe("formatDigest", () => {
  it("1通が上限文字数を超えないよう分割すること", () => {
    const added = Array.from({ length: 50 }, (_, i) => tournament({ id: `x${i}` }));
    const messages = formatDigest({ added, opened: [], vacancy: [], failures: [] }, 500);
    expect(messages.length).toBeGreaterThan(1);
    expect(messages.every((m) => m.length <= 500)).toBe(true);
    expect(messages.join("\n").match(/テストコート/g)).toHaveLength(50);
  });
});
