export const squash = (s: string): string => s.replace(/[\s　]+/g, " ").trim();

export const pad2 = (n: number | string): string => String(n).padStart(2, "0");

export const isoDate = (y: number | string, m: number | string, d: number | string): string =>
  `${y}-${pad2(m)}-${pad2(d)}`;

export const hhmm = (s: string): string | null => {
  const m = s.match(/(\d{1,2}):(\d{2})/);
  return m ? `${pad2(m[1]!)}:${m[2]}` : null;
};
