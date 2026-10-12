import { DatabaseSync } from "node:sqlite";
import type { FetchResult } from "./fetch.ts";
import type { Status, Tournament } from "./types.ts";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS tournaments (
  id TEXT PRIMARY KEY,
  site TEXT NOT NULL,
  name TEXT NOT NULL,
  date TEXT NOT NULL,
  start_time TEXT,
  venue TEXT NOT NULL,
  event TEXT NOT NULL,
  level TEXT NOT NULL,
  level_raw TEXT NOT NULL,
  status TEXT NOT NULL,
  surface TEXT,
  url TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS tournaments_date ON tournaments (date);
CREATE TABLE IF NOT EXISTS status_history (
  id INTEGER PRIMARY KEY,
  tournament_id TEXT NOT NULL REFERENCES tournaments (id),
  from_status TEXT NOT NULL,
  to_status TEXT NOT NULL,
  changed_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS crawl_runs (
  id INTEGER PRIMARY KEY,
  site TEXT NOT NULL,
  ok INTEGER NOT NULL,
  count INTEGER NOT NULL,
  error TEXT,
  ran_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS holidays (
  date TEXT PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notify_runs (
  id INTEGER PRIMARY KEY,
  sent_at TEXT NOT NULL
);
`;

type Row = Record<string, unknown>;

const toTournament = (r: Row): Tournament => ({
  id: r.id as string,
  site: r.site as Tournament["site"],
  name: r.name as string,
  date: r.date as string,
  startTime: (r.start_time as string | null) ?? null,
  venue: r.venue as string,
  event: r.event as Tournament["event"],
  level: r.level as Tournament["level"],
  levelRaw: r.level_raw as string,
  status: r.status as Status,
  surface: (r.surface as string | null) ?? null,
  url: r.url as string,
});

export type StatusChange = { tournament: Tournament; from: Status; to: Status };
export type CrawlRun = { site: string; ok: boolean; count: number; error: string | null; ranAt: string };

export const openDb = (path: string) => {
  const db = new DatabaseSync(path);
  db.exec(SCHEMA);
  // surface は導入後に足した列。既存の DB には CREATE TABLE IF NOT EXISTS では入らない
  const columns = db.prepare("PRAGMA table_info(tournaments)").all().map((c) => c.name);
  if (!columns.includes("surface")) db.exec("ALTER TABLE tournaments ADD COLUMN surface TEXT");

  const selectStatus = db.prepare("SELECT status FROM tournaments WHERE id = ?");
  const upsert = db.prepare(`
    INSERT INTO tournaments (id, site, name, date, start_time, venue, event, level, level_raw, status, surface, url, first_seen_at, last_seen_at)
    VALUES (:id, :site, :name, :date, :startTime, :venue, :event, :level, :levelRaw, :status, :surface, :url, :now, :now)
    ON CONFLICT (id) DO UPDATE SET
      name = excluded.name, date = excluded.date, start_time = excluded.start_time, venue = excluded.venue,
      event = excluded.event, level = excluded.level, level_raw = excluded.level_raw,
      status = excluded.status, surface = excluded.surface, url = excluded.url, last_seen_at = excluded.last_seen_at`);
  const insertHistory = db.prepare(
    "INSERT INTO status_history (tournament_id, from_status, to_status, changed_at) VALUES (?, ?, ?, ?)",
  );
  const insertRun = db.prepare("INSERT INTO crawl_runs (site, ok, count, error, ran_at) VALUES (?, ?, ?, ?, ?)");

  const transaction = (fn: () => void) => {
    db.exec("BEGIN");
    try {
      fn();
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  };

  return {
    close: () => db.close(),

    saveCrawl: (results: FetchResult[], now: string) =>
      transaction(() => {
        for (const r of results) {
          if (!r.ok) {
            insertRun.run(r.site, 0, 0, r.error, now);
            continue;
          }
          for (const t of r.tournaments) {
            const prev = selectStatus.get(t.id)?.status as Status | undefined;
            if (prev !== undefined && prev !== t.status) insertHistory.run(t.id, prev, t.status, now);
            upsert.run({ ...t, now });
          }
          insertRun.run(r.site, 1, r.tournaments.length, null, now);
        }
      }),

    replaceHolidays: (holidays: ReadonlyArray<{ date: string; name: string }>) =>
      transaction(() => {
        db.exec("DELETE FROM holidays");
        const insert = db.prepare("INSERT INTO holidays (date, name) VALUES (?, ?)");
        for (const h of holidays) insert.run(h.date, h.name);
      }),

    holidays: (): Set<string> =>
      new Set(db.prepare("SELECT date FROM holidays").all().map((r) => r.date as string)),

    /** 一覧から消えた大会は出さない: 最新の取得で見かけたものだけを返す */
    upcoming: (fromDate: string): Tournament[] =>
      db
        .prepare(`
          SELECT t.* FROM tournaments t
          WHERE t.date >= ?
            AND t.last_seen_at = (SELECT MAX(ran_at) FROM crawl_runs c WHERE c.site = t.site AND c.ok = 1)
          ORDER BY t.date, t.start_time, t.id`)
        .all(fromDate)
        .map(toTournament),

    newSince: (since: string): Tournament[] =>
      db
        .prepare("SELECT * FROM tournaments WHERE first_seen_at > ? ORDER BY date, start_time, id")
        .all(since)
        .map(toTournament),

    statusChangesSince: (since: string): StatusChange[] =>
      db
        .prepare(`
          SELECT t.*, h.from_status, h.to_status FROM status_history h
          JOIN tournaments t ON t.id = h.tournament_id
          WHERE h.changed_at > ? ORDER BY t.date, t.start_time, h.id`)
        .all(since)
        .map((r) => ({ tournament: toTournament(r), from: r.from_status as Status, to: r.to_status as Status })),

    lastNotifiedAt: (): string | null =>
      (db.prepare("SELECT MAX(sent_at) AS at FROM notify_runs").get()?.at as string | null) ?? null,

    recordNotify: (now: string) => {
      db.prepare("INSERT INTO notify_runs (sent_at) VALUES (?)").run(now);
    },

    /** サイトごとの直近の取得結果 */
    latestRuns: (): CrawlRun[] =>
      db
        .prepare(`
          SELECT site, ok, count, error, ran_at FROM crawl_runs c
          WHERE id = (SELECT MAX(id) FROM crawl_runs WHERE site = c.site) ORDER BY site`)
        .all()
        .map((r) => ({
          site: r.site as string,
          ok: r.ok === 1,
          count: r.count as number,
          error: (r.error as string | null) ?? null,
          ranAt: r.ran_at as string,
        })),
  };
};

export type Db = ReturnType<typeof openDb>;
