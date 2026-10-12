import type { Event } from "../types.ts";

export const normalizeEvent = (text: string): Event => {
  // inspirits の試合一覧には練習会・講座も混ざる。「男子シングルス編」のように種目名を含むため先に除く
  if (/練習会|講座|オフ会/.test(text)) return "その他";
  if (/ミックス/.test(text)) return "ミックスダブルス";
  if (/団体|チーム戦/.test(text)) return "団体戦";
  const gender = text.match(/男子|女子/)?.[0];
  // 「男子中上級シングルス」のように性別と種目の間にレベルが挟まる表記があるため、連続一致にしない
  const type = text.match(/シングルス|ダブルス/)?.[0];
  return gender && type ? (`${gender}${type}` as Event) : "その他";
};
