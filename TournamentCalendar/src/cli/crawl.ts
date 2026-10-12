import { openDb } from "../db.ts";
import { fetchAll } from "../fetch.ts";
import { fetchHolidays } from "../holidays.ts";
import { nowJst } from "../time.ts";

const db = openDb(process.env.DB_PATH ?? "tournaments.sqlite");
const now = nowJst();

try {
  db.replaceHolidays(await fetchHolidays());
} catch (e) {
  // 祝日は年単位でしか変わらない。前回の値で十分に判定できるため取得失敗で止めない
  console.error(`祝日の取得に失敗: ${e}`);
}

const results = await fetchAll();
db.saveCrawl(results, now);
for (const r of results) console.log(`${r.site}: ${r.ok ? `${r.tournaments.length} 件` : `失敗 ${r.error}`}`);
db.close();
