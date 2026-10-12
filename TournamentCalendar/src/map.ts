import type { Tournament } from "./types.ts";
import type { Coords } from "./venues.ts";

/**
 * 大会の会場名で座標を引く。完全一致が無ければ、会場名の語をすべて含む会場を使う。
 * inspirits は試合一覧と会場一覧で表記が違う会場がある（例:「ジャクパ 狭山総合グラウンド」と
 * 「ジャクパ・スポーツクラブ 狭山総合グラウンド」）。
 */
export const locate = (t: Tournament, coords: ReadonlyMap<string, Coords>): Coords | null => {
  const exact = coords.get(`${t.site}:${t.venue}`);
  if (exact) return exact;
  const words = t.venue.split(/[\s・]+/).filter(Boolean);
  if (words.length < 2) return null;
  const prefix = `${t.site}:`;
  const hits = [...coords].filter(([key]) => key.startsWith(prefix) && words.every((w) => key.includes(w)));
  // 複数当たるときはどれが正しいか決められないので出さない
  return hits.length === 1 ? hits[0]![1] : null;
};

export type Pin = { coords: Coords; venue: string; tournaments: Tournament[] };

/** 同じ地点の大会を1本のピンにまとめる。サイトが違っても同じ会場なら1本にする */
export const toPins = (
  list: readonly Tournament[],
  coords: ReadonlyMap<string, Coords>,
): { pins: Pin[]; unlocated: Tournament[] } => {
  const pins = new Map<string, Pin>();
  const unlocated: Tournament[] = [];
  for (const t of list) {
    const c = locate(t, coords);
    if (!c) {
      unlocated.push(t);
      continue;
    }
    const key = `${c.lat.toFixed(4)},${c.lng.toFixed(4)}`;
    const pin = pins.get(key) ?? { coords: c, venue: t.venue, tournaments: [] };
    pin.tournaments.push(t);
    pins.set(key, pin);
  }
  return { pins: [...pins.values()], unlocated };
};
