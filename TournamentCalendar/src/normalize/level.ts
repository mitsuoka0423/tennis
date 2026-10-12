import type { Level } from "../types.ts";

// 判定順に意味がある: 「初中級」は「中級」を、「中級以上」は「中級」を部分文字列として含む
const RULES: ReadonlyArray<readonly [RegExp, Level]> = [
  [/オープン/, "オープン"],
  [/中上級|中級以上/, "中上級"],
  [/初中級/, "初中級"],
  [/中級/, "中級"],
  [/初級/, "初級"],
];

export const normalizeLevel = (raw: string): Level =>
  RULES.find(([re]) => re.test(raw))?.[1] ?? "不明";
