import { openDb } from "../db.ts";
import { fetchAll } from "../fetch.ts";
import { fetchHolidays } from "../holidays.ts";
import { nowJst } from "../time.ts";
import { geocode } from "../venues.ts";

const db = openDb(process.env.DB_PATH ?? "tournaments.sqlite");
const now = nowJst();

try {
  db.replaceHolidays(await fetchHolidays());
} catch (e) {
  // 祝日は年単位でしか変わらない。前回の値で十分に判定できるため取得失敗で止めない
  console.error(`祝日の取得に失敗: ${e}`);
}

const results = await fetchAll(new Date(), db.knownVenues());
db.saveCrawl(results, now);
for (const r of results) console.log(`${r.site}: ${r.ok ? `${r.tournaments.length} 件` : `失敗 ${r.error}`}`);

// 会場はほとんど変わらないので、新しい会場か住所が変わった会場だけを問い合わせる
const GEOCODE_INTERVAL_MS = 1000;
for (const v of db.venuesToGeocode()) {
  try {
    const coords = await geocode(v.address);
    db.setCoords(v.site, v.name, v.address, coords);
    console.log(`座標: ${v.site} ${v.name} ${coords ? `${coords.lat},${coords.lng}` : "見つからない"}`);
  } catch (e) {
    console.error(`座標の取得に失敗: ${v.site} ${v.name} ${e}`);
  }
  await new Promise((r) => setTimeout(r, GEOCODE_INTERVAL_MS));
}
db.close();
