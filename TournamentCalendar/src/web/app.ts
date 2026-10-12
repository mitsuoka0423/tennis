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
/* ダークのみ: ユーザーの希望（2026-10-12）。真っ黒・真っ白の組み合わせは目が疲れるため、背景を明るめの墨色、文字を灰白にしてコントラストを抑える */
:root { color-scheme: dark; --bg:#1e2227; --surface:#262b31; --surface-2:#2e343b; --fg:#d5d9de; --muted:#9aa3ad;
  --line:#363d45; --accent:#6cc08b; --few:#e0b062; --bad:#e08a84; }
* { box-sizing:border-box; }
body { margin:0; font:15px/1.7 -apple-system, "Hiragino Sans", sans-serif; color:var(--fg); background:var(--bg); }
.layout { display:grid; grid-template-columns:260px minmax(0,1fr); gap:32px; max-width:1080px; margin:0 auto; padding:24px; }
.sidebar { position:sticky; top:24px; align-self:start; max-height:calc(100vh - 48px); overflow-y:auto;
  background:var(--surface); border-radius:12px; padding:20px; }
.sidebar h2 { font-size:15px; margin:0 0 8px; }
.toggle, .open-filter, .close-filter, .backdrop { display:none; }
/* 狭い画面では左右に並べる幅が無い。サイドバーを画面外に置き、ボタンで横から引き出す */
@media (max-width:767px) {
  .layout { display:block; padding:16px; }
  .sidebar { position:fixed; top:0; left:0; bottom:0; width:min(320px, 88vw); max-height:none; z-index:2;
    border-radius:0 12px 12px 0; padding:24px 20px; transform:translateX(-100%); transition:transform .2s; }
  .toggle:checked ~ .layout .sidebar { transform:none; }
  .toggle:checked ~ .layout .backdrop { display:block; position:fixed; inset:0; z-index:1; background:rgba(0,0,0,.5); }
  .open-filter { display:inline-block; position:sticky; top:12px; z-index:1; float:right; padding:6px 14px;
    border:1px solid var(--line); border-radius:8px; background:var(--surface); cursor:pointer; font-size:14px; }
  .close-filter { display:inline-block; float:right; cursor:pointer; color:var(--muted); padding:0 4px; }
}
h1 { font-size:20px; margin:4px 0 4px; }
fieldset { border:0; padding:0; margin:0 0 16px; }
legend { font-size:12px; color:var(--muted); padding:0; margin-bottom:6px; }
.chip { display:inline-flex; align-items:center; gap:6px; margin:0 14px 6px 0; white-space:nowrap; }
input[type=checkbox] { accent-color:var(--accent); width:16px; height:16px; }
input[type=date] { font:inherit; font-size:14px; color:var(--fg); background:var(--surface-2); border:1px solid var(--line);
  border-radius:6px; padding:4px 6px; max-width:100%; }
.actions { margin-top:4px; display:flex; align-items:center; gap:16px; }
.actions a { color:var(--muted); font-size:14px; }
button { font:inherit; padding:8px 20px; border-radius:8px; border:0; background:var(--accent); color:#14261b; font-weight:600; cursor:pointer; }
.count { color:var(--muted); font-size:13px; margin:0 0 16px; }
.runs { color:var(--muted); font-size:12px; margin-top:24px; }
ul { list-style:none; padding:0; margin:0; display:flex; flex-direction:column; gap:12px; }
.item { background:var(--surface); border-radius:12px; padding:16px 18px; }
.when { font-weight:600; color:var(--fg); margin-bottom:2px; }
.name { color:var(--fg); display:block; overflow-wrap:anywhere; text-decoration:none; margin-bottom:8px; }
.name:hover { text-decoration:underline; }
.meta { display:flex; flex-wrap:wrap; align-items:center; gap:6px 14px; font-size:13px; color:var(--muted); }
.status { font-weight:600; font-size:12px; padding:2px 10px; border-radius:999px; background:var(--surface-2); }
.status.open { color:var(--accent); } .status.few { color:var(--few); } .status.full, .status.cancel { color:var(--bad); }
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
</head><body>
<input type="checkbox" id="filter-toggle" class="toggle" aria-hidden="true">
<div class="layout">
<aside class="sidebar">
<label for="filter-toggle" class="close-filter" aria-label="閉じる">✕</label>
<h2>絞り込み</h2>
${filterForm(filter)}
</aside>
<label for="filter-toggle" class="backdrop"></label>
<main>
<label for="filter-toggle" class="open-filter">絞り込み</label>
<h1>草トー一覧</h1>
<p class="count">${list.length} 件</p>
<ul>${list.map((t) => row(t, holidays))}</ul>
<p class="runs">${runs.map(
      (r) => html`${SITE_NAMES[r.site as keyof typeof SITE_NAMES] ?? r.site}: ${r.ok ? `${r.count}件` : "取得失敗"}（${r.ranAt.slice(0, 16).replace("T", " ")}） `,
    )}</p>
</main>
</div>
</body></html>`);
  });
  return app;
};
