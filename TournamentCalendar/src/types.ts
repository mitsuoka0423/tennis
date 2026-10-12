export const SITE_IDS = ["clover", "leone", "inspirits"] as const;
export type SiteId = (typeof SITE_IDS)[number];

export const EVENTS = [
  "男子シングルス",
  "女子シングルス",
  "男子ダブルス",
  "女子ダブルス",
  "ミックスダブルス",
  "団体戦",
  "その他",
] as const;
export type Event = (typeof EVENTS)[number];

export const LEVELS = ["初級", "初中級", "中級", "中上級", "オープン", "不明"] as const;
export type Level = (typeof LEVELS)[number];

export const STATUSES = ["受付前", "受付中", "空き少", "満員", "中止", "不明"] as const;
export type Status = (typeof STATUSES)[number];

export type Tournament = {
  /** `{site}:{サイト内の大会キー}` */
  id: string;
  site: SiteId;
  name: string;
  /** YYYY-MM-DD */
  date: string;
  /** HH:MM */
  startTime: string | null;
  venue: string;
  event: Event;
  level: Level;
  levelRaw: string;
  status: Status;
  url: string;
};
