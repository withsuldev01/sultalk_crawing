import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [, , rawJsonPath = "./output/april_2026_schedule_raw.json", outputXlsxPath = "./output/april_2026_schedule.xlsx"] = process.argv;

const rawDays = JSON.parse(await fs.readFile(rawJsonPath, "utf8"));

function parseDateLabel(label) {
  const match = label.match(/(\d{4})년\s+(\d{1,2})월\s+(\d{1,2})일/);
  if (!match) throw new Error(`Unexpected date label: ${label}`);
  const [, year, month, day] = match;
  return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
}

function parseDetail(detail) {
  const match = detail.match(/^(.*?)-([^(]+)\(([^)]+)\)(?:\s+(.*))?$/);
  if (!match) {
    return {
      customer: detail,
      staff: "",
      sessionType: "",
      note: "",
    };
  }

  const [, customer, staff, sessionType, note = ""] = match;
  return {
    customer: customer.trim(),
    staff: staff.trim(),
    sessionType: sessionType.trim(),
    note: note.trim(),
  };
}

const rows = [];
for (const day of rawDays) {
  const isoDate = parseDateLabel(day.date);
  for (const row of day.rows) {
    const parsed = parseDetail(row.detail);
    rows.push({
      date: isoDate,
      weekday: day.weekday,
      time: row.time,
      detail: row.detail,
      ...parsed,
    });
  }
}

rows.sort((a, b) => `${a.date} ${a.time}`.localeCompare(`${b.date} ${b.time}`));

const staffCounts = new Map();
const typeCounts = new Map();
for (const row of rows) {
  if (row.staff) staffCounts.set(row.staff, (staffCounts.get(row.staff) ?? 0) + 1);
  if (row.sessionType) typeCounts.set(row.sessionType, (typeCounts.get(row.sessionType) ?? 0) + 1);
}

const workbook = Workbook.create();
const summary = workbook.worksheets.add("요약");
const dataSheet = workbook.worksheets.add("일정목록");

summary.getRange("A1:F1").values = [[
  "2026년 4월 일정 요약",
  null,
  null,
  null,
  null,
  null,
]];
summary.getRange("A3:B6").values = [
  ["총 일정 수", rows.length],
  ["일정 있는 날짜 수", new Set(rows.map((row) => row.date)).size],
  ["담당 인력 수", new Set(rows.map((row) => row.staff).filter(Boolean)).size],
  ["유형 수", new Set(rows.map((row) => row.sessionType).filter(Boolean)).size],
];

const staffSummary = [["담당 인력", "건수"], ...[...staffCounts.entries()].sort((a, b) => b[1] - a[1])];
const typeSummary = [["유형", "건수"], ...[...typeCounts.entries()].sort((a, b) => b[1] - a[1])];
summary.getRange(`A9:B${8 + staffSummary.length}`).values = staffSummary;
summary.getRange(`D9:E${8 + typeSummary.length}`).values = typeSummary;

const header = [["날짜", "요일", "시간", "고객", "담당 인력", "유형", "메모", "원문"]];
const body = rows.map((row) => [
  new Date(`${row.date}T00:00:00`),
  row.weekday,
  row.time,
  row.customer,
  row.staff,
  row.sessionType,
  row.note,
  row.detail,
]);
dataSheet.getRange(`A1:H${1 + body.length}`).values = [...header, ...body];

await fs.mkdir(path.dirname(outputXlsxPath), { recursive: true });
const file = await SpreadsheetFile.exportXlsx(workbook);
await file.save(outputXlsxPath);

console.log(outputXlsxPath);
