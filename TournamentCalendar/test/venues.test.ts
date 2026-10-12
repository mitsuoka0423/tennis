import { describe, expect, it } from "vitest";
import { cleanAddress, parseCloverAddress, parseInspiritsVenues, parseLeoneVenue } from "../src/venues.ts";
import { fixture } from "./fixture.ts";

describe("cleanAddress", () => {
  it.each([
    ["〒193-0802 東京都八王子市犬目町１０９２−１", "東京都八王子市犬目町１０９２−１"],
    ["〒192-0352　東京都八王子市大塚266", "東京都八王子市大塚266"],
    ["埼玉県志木市館2-3-9(旧 テニスクラブNAS志木)", "埼玉県志木市館2-3-9"],
  ])("%s から郵便番号と括弧書きを除くこと", (input, expected) => {
    expect(cleanAddress(input)).toBe(expected);
  });
});

describe("parseCloverAddress", () => {
  it("大会ページの会場住所を取り出すこと", () => {
    expect(parseCloverAddress(fixture("clover-detail.html"))).toBe("東京都三鷹市下連雀7-17-20");
  });

  it("会場住所が無ければ null を返すこと", () => {
    expect(parseCloverAddress("<table><tr><th>会場</th><td>x</td></tr></table>")).toBeNull();
  });
});

describe("parseLeoneVenue", () => {
  it("会場ページからサーフェス（面数を除く）と住所を取り出すこと", () => {
    expect(parseLeoneVenue(fixture("leone-venue.html"))).toEqual({
      surface: "インドアオムニコート",
      address: "立川市泉町935番地1",
    });
  });

  it("欄が無ければ null を返すこと", () => {
    expect(parseLeoneVenue("<table><tr><td>駐車場</td><td>無料</td></tr></table>")).toEqual({
      surface: null,
      address: null,
    });
  });
});

describe("parseInspiritsVenues", () => {
  const venues = parseInspiritsVenues(fixture("inspirits-access.html"));

  it("試合会場一覧の会場名と住所を取り出すこと", () => {
    expect(venues).toContainEqual({ name: "和光スポーツアイランド", address: "埼玉県和光市新倉６丁目１番10号" });
  });

  it("試合一覧に出る会場名と同じ表記であること", () => {
    const names = new Set(venues.map((v) => v.name));
    for (const name of ["エステス・テニスパーク", "大熊テニスクラブ", "ファンテニススクール八潮", "大宮運動場"]) {
      expect(names).toContain(name);
    }
  });
});
