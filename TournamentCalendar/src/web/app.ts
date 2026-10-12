import { Hono } from "hono";
import { html, raw } from "hono/html";
import type { Db } from "../db.ts";
import { applyFilter, DAY_KINDS, parseFilter, type Filter } from "../filter.ts";
import { EVENTS, LEVELS, SITE_IDS, type Status, type Tournament } from "../types.ts";

export const SITE_NAMES = {
  clover: "クローバーカップ",
  leone: "レオーネカップ",
  inspirits: "インスピリッツ",
} as const;

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];

const STATUS_CLASS: Record<Status, string> = {
  受付前: "before",
  受付中: "open",
  空き少: "few",
  満員: "full",
  中止: "cancel",
  不明: "unknown",
};

const formatDate = (date: string, holidays: ReadonlySet<string>) => {
  const [, m, d] = date.split("-");
  const wd = WEEKDAYS[new Date(`${date}T00:00:00Z`).getUTCDay()];
  return `${Number(m)}/${Number(d)}（${wd}${holidays.has(date) ? "・祝" : ""}）`;
};

const checkboxes = (name: string, values: readonly string[], selected: readonly string[], label = (v: string) => v) =>
  values.map(
    (v) =>
      html`<label class="chip"><input type="checkbox" name="${name}" value="${v}" ${selected.includes(v) ? "checked" : ""}>${label(v)}</label>`,
  );

const filterForm = (f: Filter) => html`
  <form method="get" class="filter">
    <input type="hidden" name="q" value="1">
    <fieldset><legend>期間</legend>
      <input type="date" name="from" value="${f.from}"> 〜 <input type="date" name="to" value="${f.to}">
    </fieldset>
    <fieldset><legend>曜日</legend>${checkboxes("day", DAY_KINDS, f.days)}</fieldset>
    <fieldset><legend>種目</legend>${checkboxes("event", EVENTS, f.events)}</fieldset>
    <fieldset><legend>レベル</legend>${checkboxes("level", LEVELS, f.levels)}</fieldset>
    <fieldset><legend>サイト</legend>${checkboxes("site", SITE_IDS, f.sites, (v) => SITE_NAMES[v as keyof typeof SITE_NAMES])}</fieldset>
    <fieldset><legend>状態</legend>
      <label class="chip"><input type="checkbox" name="hideFull" value="1" ${f.hideFull ? "checked" : ""}>満員・中止を隠す</label>
    </fieldset>
    <div class="actions"><button type="submit">絞り込む</button> <a href="/">既定に戻す</a></div>
  </form>`;

const row = (t: Tournament, holidays: ReadonlySet<string>) => html`
  <li class="item">
    <div class="when">${formatDate(t.date, holidays)} ${t.startTime ?? ""}</div>
    <a class="name" href="${t.url}" target="_blank" rel="noopener">${t.name}</a>
    <div class="meta">
      <span class="status ${STATUS_CLASS[t.status]}">${t.status}</span>
      <span>${t.venue}</span>
      <span>${t.event}</span>
      <span>${t.level}${t.levelRaw && t.levelRaw !== t.level ? `（${t.levelRaw}）` : ""}</span>
      <span class="site">${SITE_NAMES[t.site]}</span>
    </div>
  </li>`;

const STYLE = `
:root { color-scheme: light dark; --fg:#1d1d1f; --bg:#fff; --muted:#6e6e73; --line:#d2d2d7; --accent:#0a7d3b; }
@media (prefers-color-scheme: dark) { :root { --fg:#f5f5f7; --bg:#111; --muted:#a1a1a6; --line:#3a3a3c; --accent:#4cd07d; } }
body { margin:0; font:15px/1.5 -apple-system, "Hiragino Sans", sans-serif; color:var(--fg); background:var(--bg); }
main { max-width:760px; margin:0 auto; padding:16px; }
h1 { font-size:20px; margin:0 0 12px; }
details { border:1px solid var(--line); border-radius:10px; padding:8px 12px; margin-bottom:12px; }
summary { cursor:pointer; font-weight:600; }
fieldset { border:0; padding:6px 0; margin:0; }
legend { font-size:12px; color:var(--muted); padding:0; }
.chip { display:inline-flex; align-items:center; gap:4px; margin:2px 10px 2px 0; white-space:nowrap; }
.actions { margin-top:8px; }
button { font:inherit; padding:6px 16px; border-radius:8px; border:0; background:var(--accent); color:#fff; }
.count, .runs { color:var(--muted); font-size:13px; }
ul { list-style:none; padding:0; margin:0; }
.item { border-bottom:1px solid var(--line); padding:10px 0; }
.when { font-weight:600; }
.name { color:inherit; display:block; overflow-wrap:anywhere; }
.meta { display:flex; flex-wrap:wrap; gap:4px 10px; font-size:13px; color:var(--muted); }
.status { font-weight:600; }
.status.open { color:var(--accent); } .status.few { color:#c77700; } .status.full, .status.cancel { color:#c62828; }
`;

export const createApp = (db: Db, today: () => string) => {
  const app = new Hono();
  app.get("/", (c) => {
    const filter = parseFilter(new URL(c.req.url).searchParams, today());
    const holidays = db.holidays();
    const list = applyFilter(db.upcoming(filter.from), filter, holidays);
    const runs = db.latestRuns();
    return c.html(html`<!doctype html>
<html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>草トー一覧</title><style>${raw(STYLE)}</style>
</head><body><main>
<h1>草トー一覧</h1>
<details ${new URL(c.req.url).searchParams.has("q") ? "" : "open"}><summary>絞り込み</summary>${filterForm(filter)}</details>
<p class="count">${list.length} 件</p>
<ul>${list.map((t) => row(t, holidays))}</ul>
<p class="runs">${runs.map(
      (r) => html`${SITE_NAMES[r.site as keyof typeof SITE_NAMES] ?? r.site}: ${r.ok ? `${r.count}件` : "取得失敗"}（${r.ranAt.slice(0, 16).replace("T", " ")}） `,
    )}</p>
</main></body></html>`);
  });
  return app;
};
