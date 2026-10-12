const HOLIDAYS_CSV = "https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv";

export const parseHolidaysCsv = (csv: string): { date: string; name: string }[] =>
  csv.split(/\r?\n/).flatMap((line) => {
    const m = line.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2}),(.+)$/);
    return m ? [{ date: `${m[1]}-${m[2]!.padStart(2, "0")}-${m[3]!.padStart(2, "0")}`, name: m[4]!.trim() }] : [];
  });

export const fetchHolidays = async () => {
  const res = await fetch(HOLIDAYS_CSV);
  if (!res.ok) throw new Error(`${res.status}: ${HOLIDAYS_CSV}`);
  return parseHolidaysCsv(new TextDecoder("shift_jis").decode(await res.arrayBuffer()));
};

/** date は YYYY-MM-DD。曜日はタイムゾーンに左右されないよう UTC として計算する */
export const isDayOff = (date: string, holidays: ReadonlySet<string>): boolean => {
  const day = new Date(`${date}T00:00:00Z`).getUTCDay();
  return day === 0 || day === 6 || holidays.has(date);
};
