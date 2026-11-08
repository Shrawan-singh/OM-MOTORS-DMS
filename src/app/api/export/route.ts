import ExcelJS from 'exceljs';
import { PassThrough, Readable } from 'node:stream';
import { serverSupabase } from '@/lib/supabase/server';
import {
  fields,
  sheetNames,
  columnsFor,
  type Config,
  type ExportData,
} from '@/lib/vehicles/exports';
import { writeSheet, safeText } from '@/lib/vehicles/workbook';
export const runtime = 'nodejs';
export async function POST(request: Request) {
  const db = await serverSupabase();
  const {
    data: { user },
  } = await db.auth.getUser();
  if (!user) return Response.json({ error: 'Sign in to export.' }, { status: 401 });
  try {
    const p: Config = await request.json();
    if (!Object.hasOwn(fields, p.dataset)) throw new Error('Choose a supported dataset.');
    const multi = p.sheet_layout === 'multi';
    const selections = multi ? p.sheets : { [p.dataset]: p.columns };
    if (!Object.keys(selections).length) throw new Error('Choose at least one sheet.');
    const book = new ExcelJS.Workbook();
    const notes: Record<string, string | number>[] = [];
    const warnings: string[] = [];
    const keys: Record<string, string[]> = {};
    for (const [ds, columns] of Object.entries(selections)) {
      if (
        !Object.hasOwn(fields, ds) ||
        !Array.isArray(columns) ||
        !columns.length ||
        columns.length > 100
      )
        throw new Error('Invalid sheet selection.');
      if (
        columns.some((c) => typeof c.key !== 'string' || typeof c.header !== 'string') ||
        new Set(columns.map((c) => c.key)).size !== columns.length
      )
        throw new Error('Choose distinct columns and text headers.');
      keys[ds] = columns.map((c) => c.key);
    }
    const { data, error } = await db.rpc('export_workbook', {
      dataset: p.dataset,
      sheets: keys,
      filters: { ...p.filters, ...(p.id ? { template_id: p.id } : {}) },
    });
    if (error) throw new Error(error.message);
    for (const [ds, columns] of Object.entries(selections)) {
      const result = (data as Record<string, ExportData>)[ds];
      writeSheet(book, sheetNames[ds], columns, result);
      if (result.dropped.length) warnings.push(ds + ' omitted ' + result.dropped.join(', '));
      notes.push({ item: sheetNames[ds], value: result.rows.length });
    }
    const now = new Date();
    if (multi) {
      notes.unshift(
        { item: 'Generated on', value: now.toISOString() },
        { item: 'Exported by', value: user.email || user.id },
        { item: 'Filters', value: JSON.stringify(p.filters) }
      );
      writeSheet(book, 'Read me', columnsFor(['item', 'value']), {
        columns: ['item', 'value'],
        dropped: [],
        rows: notes,
      });
    }
    const stream = new PassThrough();
    void book.xlsx.write(stream).then(
      () => stream.end(),
      (err) => stream.destroy(err)
    );
    return new Response(Readable.toWeb(stream) as ReadableStream, {
      headers: {
        'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'Content-Disposition':
          'attachment; filename="OM-Motors_' +
          p.dataset +
          '_' +
          now.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) +
          '.xlsx"',
        'Cache-Control': 'private, no-store',
        'X-Export-Omissions': encodeURIComponent(safeText(warnings.join('; '))),
      },
    });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : 'Export failed' },
      { status: 400 }
    );
  }
}
