import type { SiteId, Tournament } from "./types.ts";
import { CLOVER_URL, parseClover } from "./sites/clover.ts";
import { LEONE_URL, parseLeone } from "./sites/leone.ts";
import { INSPIRITS_ORIGIN, lastPage, parseInspirits } from "./sites/inspirits.ts";

const USER_AGENT = "TournamentCalendar/0.1 (personal use; once a day)";
const PAGE_INTERVAL_MS = 2000;
// 先の大会ほど募集前で変化が少ない。全ページ（2026-10-12 時点で6ページ）を毎日取る必要はない
const INSPIRITS_MAX_PAGES = 10;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const getText = async (url: string, init?: RequestInit): Promise<Response> => {
  const res = await fetch(url, {
    ...init,
    headers: { "User-Agent": USER_AGENT, ...init?.headers },
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}: ${url}`);
  return res;
};

const fetchClover = async () => parseClover(await (await getText(CLOVER_URL)).text());

const fetchLeone = async () => parseLeone(await (await getText(LEONE_URL)).text());

const fetchInspirits = async (today: Date) => {
  const listPath = "/reservations/calendar?label_id=&tag_id%5B2%5D%5B4%5D=4";
  const page = await getText(INSPIRITS_ORIGIN + listPath);
  // API は一覧ページで発行される CSRF トークンとセッション Cookie の組を要求する
  const cookie = page.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const token = (await page.text()).match(/name="_csrfToken"[^>]*value="([^"]+)"/)?.[1];
  if (!token) throw new Error("inspirits: _csrfToken が見つからない");

  const date = `${today.getFullYear()}/${today.getMonth() + 1}/${today.getDate()}`;
  const fetchPage = async (n: number): Promise<string> => {
    const body = new URLSearchParams({
      _csrfToken: token,
      calendar_type: "8",
      date,
      "tag_id[2][4]": "4",
      limit: "20",
      page: String(n),
    });
    const res = await getText(`${INSPIRITS_ORIGIN}/ajax/reservations/calendar`, {
      method: "POST",
      body,
      headers: { Cookie: cookie, "X-Requested-With": "XMLHttpRequest" },
    });
    return ((await res.json()) as { html: string }).html;
  };

  const first = await fetchPage(1);
  const results = parseInspirits(first);
  const last = Math.min(lastPage(first), INSPIRITS_MAX_PAGES);
  for (let n = 2; n <= last; n++) {
    await sleep(PAGE_INTERVAL_MS);
    results.push(...parseInspirits(await fetchPage(n)));
  }
  return results;
};

export type FetchResult =
  | { site: SiteId; ok: true; tournaments: Tournament[] }
  | { site: SiteId; ok: false; error: string };

export const fetchAll = async (today = new Date()): Promise<FetchResult[]> => {
  const jobs: Record<SiteId, () => Promise<Tournament[]>> = {
    clover: fetchClover,
    leone: fetchLeone,
    inspirits: () => fetchInspirits(today),
  };
  return Promise.all(
    Object.entries(jobs).map(async ([site, job]): Promise<FetchResult> => {
      try {
        return { site: site as SiteId, ok: true, tournaments: await job() };
      } catch (e) {
        return { site: site as SiteId, ok: false, error: String(e) };
      }
    }),
  );
};
