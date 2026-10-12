import { openDb } from "../db.ts";
import { buildDigest, formatDigest, isEmpty, sendDiscord } from "../notify/digest.ts";
import { nowJst, todayJst } from "../time.ts";

const webhook = process.env.DISCORD_WEBHOOK_URL;
const dryRun = process.argv.includes("--dry-run");
if (!webhook && !dryRun) throw new Error("DISCORD_WEBHOOK_URL が未設定");

const db = openDb(process.env.DB_PATH ?? "tournaments.sqlite");
const now = nowJst();
// 初回は過去分すべてが「新着」になり、取得した数百件を一度に送ってしまうため、起点を今にする
const since = db.lastNotifiedAt();
if (since === null) {
  if (!dryRun) db.recordNotify(now);
  console.log("初回のため通知の起点だけを記録した");
} else {
  const digest = buildDigest({
    added: db.newSince(since),
    changes: db.statusChangesSince(since),
    runs: db.latestRuns(),
    holidays: db.holidays(),
    today: todayJst(),
  });
  const messages = isEmpty(digest) ? [] : formatDigest(digest);
  if (dryRun) console.log(messages.join("\n---\n") || "（変化なし）");
  else {
    if (messages.length > 0) await sendDiscord(webhook!, messages);
    db.recordNotify(now);
  }
}
db.close();
