import { describe, expect, it } from "vitest";
import { normalizeEvent } from "../src/normalize/event.ts";
import { normalizeLevel } from "../src/normalize/level.ts";

describe("normalizeEvent", () => {
  it.each([
    ["男子シングルス", "男子シングルス"],
    // レオーネカップは性別と種目の間にレベルが入る
    ["レオーネカップ 男子中上級シングルス", "男子シングルス"],
    ["ナイター男子ダブルス", "男子ダブルス"],
    ["ナイター夫婦ミックスダブルス", "ミックスダブルス"],
    ["ミックスチーム戦", "ミックスダブルス"],
    ["団体戦", "団体戦"],
    ["講座・練習会", "その他"],
    ["インスピ練習会(担当：佐藤可奈) 男子シングルス編 中級～オープン", "その他"],
    ["シングルス強化講座 初中級～中級", "その他"],
  ])("%s は %s になること", (input, expected) => {
    expect(normalizeEvent(input)).toBe(expected);
  });
});

describe("normalizeLevel", () => {
  it.each([
    // 各サイトの実際の表記（2026-10-12 時点）
    ["中級以上", "中上級"],
    ["中上級", "中上級"],
    ["中級", "中級"],
    ["中級以下", "中級"],
    ["初中級", "初中級"],
    ["初中級以下", "初中級"],
    ["初級", "初級"],
    ["超初級", "初級"],
    ["オープン （グレードC）", "オープン"],
    ["", "不明"],
  ])("%s は %s になること", (input, expected) => {
    expect(normalizeLevel(input)).toBe(expected);
  });
});
