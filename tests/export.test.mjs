import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import ts from 'typescript';
import ExcelJS from 'exceljs';

const nativeRequire = createRequire(import.meta.url);
function compile(path, dependencies = {}) {
  const source = ts.transpileModule(readFileSync(path, 'utf8'), {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.CommonJS,
      esModuleInterop: true,
    },
  }).outputText;
  const exports = {};
  new Function('require', 'exports', source)(
    (name) => dependencies[name] ?? nativeRequire(name),
    exports
  );
  return exports;
}
const catalog = compile('src/lib/vehicles/exports.ts');
const workbook = compile('src/lib/vehicles/workbook.ts');
const sheets = ['vehicles', 'components', 'ownership', 'registrations', 'customers', 'sales'];
const rows = {
  mobile: '0009876543',
  chassis: '0000000123',
  model: '=2+5',
  amount: 1750,
  received_date: '2026-11-09',
};
const config = catalog.configFor('full_register');
config.sheet_layout = 'multi';
config.sheets = Object.fromEntries(sheets.map((ds) => [ds, catalog.columnsFor(Object.keys(rows))]));
config.sheets.vehicles[0].header = 'Phone';
let permitted = true;
const db = {
  auth: { getUser: async () => ({ data: { user: { id: 'test', email: 'test@example.test' } } }) },
  rpc: async (name, p) => {
    assert.equal(name, 'export_workbook');
    return permitted
      ? {
          data: Object.fromEntries(
            Object.entries(p.sheets).map(([ds, columns]) => [
              ds,
              { columns, dropped: [], rows: [rows] },
            ])
          ),
        }
      : { error: { message: 'Vehicle export permission required' } };
  },
};
const { POST } = compile('src/app/api/export/route.ts', {
  '@/lib/supabase/server': { serverSupabase: async () => db },
  '@/lib/vehicles/exports': catalog,
  '@/lib/vehicles/workbook': workbook,
});
const post = () =>
  POST(
    new Request('http://localhost/api/export', { method: 'POST', body: JSON.stringify(config) })
  );
const response = await post();
assert.equal(response.status, 200);
const reopened = new ExcelJS.Workbook();
await reopened.xlsx.load(await response.arrayBuffer());
assert.deepEqual(
  reopened.worksheets.map((s) => s.name),
  [...sheets.map((k) => catalog.sheetNames[k]), 'Read me']
);
const sheet = reopened.getWorksheet('Vehicles');
assert.equal(sheet.getCell('A1').value, 'Phone');
assert.equal(sheet.getCell('A2').value, rows.mobile);
assert.equal(sheet.getCell('B2').value, rows.chassis);
assert.equal(sheet.getCell('C2').value, "'=2+5");
assert.equal(sheet.getCell('D2').type, ExcelJS.ValueType.Number);
assert.equal(sheet.getCell('E2').numFmt, 'dd-mm-yyyy');
assert.equal(sheet.views[0].state, 'frozen');
assert.ok(sheet.autoFilter);
assert.equal(sheet.getCell('A1').font.bold, true);
for (const prefix of ['@', '+', '-', '='])
  assert.equal(workbook.safeText(prefix + 'test'), "'" + prefix + 'test');
permitted = false;
assert.ok(!(await post()).ok);
console.log(
  'PASS: Excel route round-trip, all workbook sheets, ordered custom headers, literal identifiers, dates, money, injection protection and denied export.'
);
