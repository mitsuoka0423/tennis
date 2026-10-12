import { describe, expect, it } from "vitest";
import { locate, toPins } from "../src/map.ts";
import { tournament } from "./helpers.ts";

const coords = new Map([
  ["clover:MTS三鷹", { lat: 35.68, lng: 139.55 }],
  ["inspirits:ジャクパ・スポーツクラブ 狭山総合グラウンド", { lat: 35.85, lng: 139.41 }],
  ["inspirits:大宮運動場", { lat: 35.9, lng: 139.6 }],
  ["leone:三鷹の別名", { lat: 35.68, lng: 139.55 }],
]);

describe("locate", () => {
  it("会場名が一致すればその座標を返すこと", () => {
    expect(locate(tournament({ site: "clover", venue: "MTS三鷹" }), coords)).toEqual({ lat: 35.68, lng: 139.55 });
  });

  it("表記が違っても会場名の語をすべて含む会場があればその座標を返すこと", () => {
    expect(locate(tournament({ site: "inspirits", venue: "ジャクパ 狭山総合グラウンド" }), coords)).toEqual({
      lat: 35.85,
      lng: 139.41,
    });
  });

  it("ほかのサイトの会場とは照合しないこと", () => {
    expect(locate(tournament({ site: "leone", venue: "大宮運動場" }), coords)).toBeNull();
  });

  it("1語だけの会場名では部分一致させないこと", () => {
    expect(locate(tournament({ site: "inspirits", venue: "大宮" }), coords)).toBeNull();
  });
});

describe("toPins", () => {
  it("同じ地点の大会はサイトが違っても1本のピンにまとめること", () => {
    const { pins, unlocated } = toPins(
      [
        tournament({ id: "a", site: "clover", venue: "MTS三鷹" }),
        tournament({ id: "b", site: "leone", venue: "三鷹の別名" }),
        tournament({ id: "c", site: "clover", venue: "不明な会場" }),
      ],
      coords,
    );
    expect(pins).toHaveLength(1);
    expect(pins[0]!.tournaments.map((t) => t.id)).toEqual(["a", "b"]);
    expect(unlocated.map((t) => t.id)).toEqual(["c"]);
  });
});
