import { fetchAll } from "../fetch.ts";

for (const r of await fetchAll()) {
  if (!r.ok) {
    console.error(`${r.site}: 失敗 ${r.error}`);
    continue;
  }
  const count = (key: "event" | "level" | "status") =>
    Object.entries(Object.groupBy(r.tournaments, (t) => t[key])).map(([k, v]) => `${k}=${v?.length}`).join(" ");
  console.log(`${r.site}: ${r.tournaments.length} 件`);
  console.log(`  種目: ${count("event")}`);
  console.log(`  レベル: ${count("level")}`);
  console.log(`  状態: ${count("status")}`);
}
