import ExcelJS from 'exceljs';
import type { Column, ExportData } from './exports';
export const safeText = (s: string) => (/^[=+@-]/.test(s) ? "'" + s : s);
export function writeSheet(
  book: ExcelJS.Workbook,
  name: string,
  columns: Column[],
  data: ExportData
) {
  const sheet = book.addWorksheet(name, { views: [{ state: 'frozen', ySplit: 1 }] });
  sheet.columns = columns
    .filter((c) => data.columns.includes(c.key))
    .map((c) => ({
      key: c.key,
      header: safeText(c.header || c.key),
      width: Math.max(16, Math.min(c.header.length + 6, 48)),
    }));
  for (const record of data.rows) {
    const row = sheet.addRow({});
    for (const column of sheet.columns) {
      const key = column.key!;
      const v = record[key];
      const cell = row.getCell(key);
      if (
        typeof v === 'string' &&
        /(?:_date|_on|^last_service)$/.test(key) &&
        /^\d{4}-\d\d-\d\d$/.test(v)
      ) {
        cell.value = new Date(v + 'T00:00:00Z');
        cell.numFmt = 'dd-mm-yyyy';
      } else if (typeof v === 'string') {
        cell.value = safeText(v);
        cell.numFmt = '@';
      } else {
        cell.value = v ?? null;
        if (['balance', 'paid', 'amount'].includes(key)) cell.numFmt = '"₹"#,##0.00';
      }
    }
  }
  sheet.getRow(1).font = { bold: true };
  if (sheet.columnCount)
    sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: sheet.columnCount } };
}
