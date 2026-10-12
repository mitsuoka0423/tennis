import { isDayOff } from "./holidays.ts";
import { EVENTS, LEVELS, SITE_IDS, type Event, type Level, type SiteId, type Tournament } from "./types.ts";

export const DAY_KINDS = ["休日", "平日"] as const;
export type DayKind = (typeof DAY_KINDS)[number];

export type Filter = {
  from: string;
  to: string;
  days: DayKind[];
  events: Event[];
  levels: Level[];
  sites: SiteId[];
  hideFull: boolean;
};

const DEFAULT_RANGE_DAYS = 60;

const addDays = (date: string, n: number): string => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

export const defaultFilter = (today: string): Filter => ({
  from: today,
  to: addDays(today, DEFAULT_RANGE_DAYS),
  days: ["休日"],
  events: ["男子シングルス"],
  levels: ["中級", "中上級"],
  sites: [...SITE_IDS],
  hideFull: true,
});

const pick = <T extends string>(values: string[], allowed: readonly T[]): T[] =>
  values.filter((v): v is T => (allowed as readonly string[]).includes(v));

/**
 * フォーム未送信（クエリ無し）なら既定値、送信済みならチェックの無い項目は空として扱う。
 * チェックを全部外した状態と、初回表示を区別するため `q` を送信の印にする。
 */
export const parseFilter = (params: URLSearchParams, today: string): Filter => {
  const base = defaultFilter(today);
  if (!params.has("q")) return base;
  const date = (key: string, fallback: string) => {
    const v = params.get(key) ?? "";
    return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : fallback;
  };
  return {
    from: date("from", base.from),
    to: date("to", base.to),
    days: pick(params.getAll("day"), DAY_KINDS),
    events: pick(params.getAll("event"), EVENTS),
    levels: pick(params.getAll("level"), LEVELS),
    sites: pick(params.getAll("site"), SITE_IDS),
    hideFull: params.get("hideFull") === "1",
  };
};

export const applyFilter = (
  list: readonly Tournament[],
  filter: Filter,
  holidays: ReadonlySet<string>,
): Tournament[] =>
  list.filter(
    (t) =>
      t.date >= filter.from &&
      t.date <= filter.to &&
      filter.days.includes(isDayOff(t.date, holidays) ? "休日" : "平日") &&
      filter.events.includes(t.event) &&
      filter.levels.includes(t.level) &&
      filter.sites.includes(t.site) &&
      !(filter.hideFull && (t.status === "満員" || t.status === "中止")),
  );

/** 通知はこの条件で絞る（要求定義 3章の参加条件）。期間は区切らない */
export const matchesPreference = (t: Tournament, holidays: ReadonlySet<string>): boolean => {
  const f = defaultFilter(t.date);
  return applyFilter([t], { ...f, to: "9999-12-31", hideFull: false }, holidays).length === 1;
};
