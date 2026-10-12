// サーバーのタイムゾーン設定に依存させない。記録・表示・「今日」の判定をすべて日本時間で揃える
const JST = new Intl.DateTimeFormat("sv-SE", {
  timeZone: "Asia/Tokyo",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

/** `YYYY-MM-DDTHH:MM:SS`（日本時間）。文字列比較で前後を判定できる */
export const nowJst = (d = new Date()): string => JST.format(d).replace(" ", "T");

export const todayJst = (d = new Date()): string => nowJst(d).slice(0, 10);
