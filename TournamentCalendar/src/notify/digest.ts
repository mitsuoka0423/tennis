import type { CrawlRun, StatusChange } from "../db.ts";
import { matchesPreference } from "../filter.ts";
import type { Tournament } from "../types.ts";

const OPENED_FROM = new Set(["受付前"]);
const VACANCY_FROM = new Set(["満員"]);
const AVAILABLE = new Set(["受付中", "空き少"]);

export type Digest = {
  added: Tournament[];
  opened: Tournament[];
  vacancy: Tournament[];
  failures: CrawlRun[];
};

export const buildDigest = (input: {
  added: Tournament[];
  changes: StatusChange[];
  runs: CrawlRun[];
  holidays: ReadonlySet<string>;
  today: string;
}): Digest => {
  const relevant = (t: Tournament) => t.date >= input.today && matchesPreference(t, input.holidays);
  const addedIds = new Set(input.added.map((t) => t.id));
  // 同じ大会が期間中に何度も変化しても1回だけ載せる
  const changed = (from: Set<string>) => {
    const seen = new Map<string, Tournament>();
    for (const c of input.changes) {
      if (from.has(c.from) && AVAILABLE.has(c.to) && relevant(c.tournament) && !addedIds.has(c.tournament.id)) {
        seen.set(c.tournament.id, c.tournament);
      }
    }
    return [...seen.values()];
  };
  return {
    // 満員・中止の新着は申し込めないので知らせない。空きが出れば「空き発生」で拾える
    added: input.added.filter((t) => relevant(t) && t.status !== "満員" && t.status !== "中止"),
    opened: changed(OPENED_FROM),
    vacancy: changed(VACANCY_FROM),
    failures: input.runs.filter((r) => !r.ok || r.count === 0),
  };
};

export const isEmpty = (d: Digest): boolean =>
  d.added.length + d.opened.length + d.vacancy.length + d.failures.length === 0;

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];

const line = (t: Tournament) => {
  const [, m, d] = t.date.split("-");
  const wd = WEEKDAYS[new Date(`${t.date}T00:00:00Z`).getUTCDay()];
  // Discord の埋め込みプレビューで通知が長くなるのを避けるため、URL を <> で囲む
  return `- ${Number(m)}/${Number(d)}(${wd}) ${t.startTime ?? ""} ${t.venue} ${t.level}【${t.status}】 <${t.url}>`;
};

/** Discord の1メッセージ上限（2000文字）に収まるよう分割する */
export const formatDigest = (d: Digest, limit = 2000): string[] => {
  const lines: string[] = ["**草トー通知**"];
  const section = (title: string, list: Tournament[]) => {
    if (list.length === 0) return;
    lines.push("", `__${title}（${list.length}件）__`, ...list.map(line));
  };
  section("新着", d.added);
  section("申込開始", d.opened);
  section("空き発生", d.vacancy);
  if (d.failures.length > 0) {
    lines.push("", "__取得失敗__", ...d.failures.map((r) => `- ${r.site}: ${r.ok ? "0件" : r.error}`));
  }

  const messages: string[] = [];
  let current = "";
  for (const l of lines) {
    const next = current ? `${current}\n${l}` : l;
    if (next.length > limit && current) {
      messages.push(current);
      current = l.slice(0, limit);
    } else {
      current = next.slice(0, limit);
    }
  }
  if (current) messages.push(current);
  return messages;
};

export const sendDiscord = async (webhookUrl: string, messages: string[]) => {
  for (const content of messages) {
    const res = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content, allowed_mentions: { parse: [] } }),
    });
    if (!res.ok) throw new Error(`Discord ${res.status}: ${await res.text()}`);
  }
};
