import type { SiteId, Tournament } from "./types.ts";
import { CLOVER_URL, parseClover } from "./sites/clover.ts";
import { LEONE_URL, parseLeone } from "./sites/leone.ts";
import { sha256, WISE_PDF_SHA256, WISE_PDF_URL, WISE_VENUE_ADDRESS, wiseTournaments } from "./sites/wise.ts";
import { parseCloverAddress, parseInspiritsVenues, parseLeoneVenue, type VenueAddress } from "./venues.ts";
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

type SiteData = { tournaments: Tournament[]; venues: VenueAddress[] };

/** 住所が分かっている会場は取りに行かない。clover は大会ページにしか住所が無く、大会ごとに取ると数が多いため */
const fetchClover = async (knownVenues: ReadonlySet<string>): Promise<SiteData> => {
  const tournaments = parseClover(await (await getText(CLOVER_URL)).text());
  const venues: VenueAddress[] = [];
  const firstOfVenue = new Map(tournaments.filter((t) => !knownVenues.has(t.venue)).map((t) => [t.venue, t.url]));
  for (const [name, url] of firstOfVenue) {
    await sleep(PAGE_INTERVAL_MS);
    try {
      const address = parseCloverAddress(await (await getText(url)).text());
      if (address) venues.push({ name, address });
    } catch {
      // 住所は地図のための補足情報。取れなくても大会一覧は使える
    }
  }
  return { tournaments, venues };
};

const fetchLeone = async (): Promise<SiteData> => {
  const list = parseLeone(await (await getText(LEONE_URL)).text());
  // 会場は数か所（2026-10-12 時点で3か所）。大会ごとではなく会場ごとに1回だけ取る
  const info = new Map<string, ReturnType<typeof parseLeoneVenue>>();
  for (const url of new Set(list.flatMap((t) => (t.venueUrl ? [t.venueUrl] : [])))) {
    if (info.size > 0) await sleep(PAGE_INTERVAL_MS);
    try {
      info.set(url, parseLeoneVenue(await (await getText(url)).text()));
    } catch {
      // サーフェス・住所は補足情報。会場ページが取れなくても大会一覧は使える
    }
  }
  const venues = new Map<string, VenueAddress>();
  const tournaments = list.map(({ venueUrl, ...t }) => {
    const v = venueUrl ? info.get(venueUrl) : undefined;
    if (v?.address) venues.set(t.venue, { name: t.venue, address: v.address });
    return { ...t, surface: v?.surface ?? null };
  });
  return { tournaments, venues: [...venues.values()] };
};

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

  const accessPage = await getText("https://inspirits-tennis-club.com/access");
  const venues = parseInspiritsVenues(await accessPage.text());

  const first = await fetchPage(1);
  const results = parseInspirits(first);
  const last = Math.min(lastPage(first), INSPIRITS_MAX_PAGES);
  for (let n = 2; n <= last; n++) {
    await sleep(PAGE_INTERVAL_MS);
    results.push(...parseInspirits(await fetchPage(n)));
  }
  return { tournaments: results, venues };
};

const fetchWise = async (): Promise<SiteData> => {
  const pdf = await (await getText(WISE_PDF_URL)).arrayBuffer();
  // 書き写した日程が古くなったまま出し続けないよう、取得失敗として通知に載せる
  if (sha256(pdf) !== WISE_PDF_SHA256) throw new Error("PDF が更新された。src/sites/wise.ts の日程の書き写しを見直す");
  return { tournaments: wiseTournaments(), venues: [{ name: "東宝調布スポーツパーク", address: WISE_VENUE_ADDRESS }] };
};

export type FetchResult =
  | { site: SiteId; ok: true; tournaments: Tournament[]; venues: VenueAddress[] }
  | { site: SiteId; ok: false; error: string };

export const fetchAll = async (
  today = new Date(),
  knownVenues: Record<SiteId, ReadonlySet<string>> = {
    clover: new Set(),
    leone: new Set(),
    inspirits: new Set(),
    wise: new Set(),
  },
): Promise<FetchResult[]> => {
  const jobs: Record<SiteId, () => Promise<SiteData>> = {
    clover: () => fetchClover(knownVenues.clover),
    leone: fetchLeone,
    inspirits: () => fetchInspirits(today),
    wise: fetchWise,
  };
  return Promise.all(
    Object.entries(jobs).map(async ([site, job]): Promise<FetchResult> => {
      try {
        return { site: site as SiteId, ok: true, ...(await job()) };
      } catch (e) {
        return { site: site as SiteId, ok: false, error: String(e) };
      }
    }),
  );
};
