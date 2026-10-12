import * as cheerio from "cheerio";
import { squash } from "./normalize/text.ts";

export type VenueAddress = { name: string; address: string };

/** 郵便番号と括弧書きの補足（「(旧 ○○)」など）はジオコーディングの妨げになるので落とす */
export const cleanAddress = (raw: string): string =>
  squash(raw)
    .replace(/〒?\s*\d{3}-?\d{4}\s*/, "")
    .replace(/[(（][^)）]*[)）]/g, "")
    .trim();

/** clover の大会ページの「会場住所」 */
export const parseCloverAddress = (html: string): string | null => {
  const $ = cheerio.load(html);
  const text = squash(
    $("th")
      .filter((_, th) => $(th).text().trim() === "会場住所")
      .first()
      .next("td")
      .text(),
  );
  return text ? cleanAddress(text) : null;
};

/** leone の会場ページの表から1項目を取り出す */
const leoneVenueField = ($: cheerio.CheerioAPI, label: string): string =>
  squash(
    $("td")
      .filter((_, td) => $(td).text().trim() === label)
      .first()
      .next("td")
      .text(),
  );

export const parseLeoneVenue = (html: string): { surface: string | null; address: string | null } => {
  const $ = cheerio.load(html);
  // 面数は大会と関係ないので落とす
  const surface = leoneVenueField($, "サーフェース").replace(/\s*\d+\s*面.*$/, "");
  const address = leoneVenueField($, "住所");
  return { surface: surface || null, address: address ? cleanAddress(address) : null };
};

/** inspirits の「アクセス」ページにある試合会場一覧 */
export const parseInspiritsVenues = (html: string): VenueAddress[] => {
  const $ = cheerio.load(html);
  return $(".access_list_item > li")
    .toArray()
    .flatMap((el) => {
      const name = squash($(el).find("dt").text());
      const address = squash($(el).find("dd > p").first().text());
      return name && address ? [{ name, address: cleanAddress(address) }] : [];
    });
};

const GEOCODER = "https://msearch.gsi.go.jp/address-search/AddressSearch";

export type Coords = { lat: number; lng: number };

/** 国土地理院のジオコーダ。最初の候補を採る */
export const geocode = async (address: string): Promise<Coords | null> => {
  const res = await fetch(`${GEOCODER}?q=${encodeURIComponent(address)}`);
  if (!res.ok) throw new Error(`${res.status}: ${GEOCODER}`);
  const [first] = (await res.json()) as { geometry: { coordinates: [number, number] } }[];
  return first ? { lng: first.geometry.coordinates[0], lat: first.geometry.coordinates[1] } : null;
};
