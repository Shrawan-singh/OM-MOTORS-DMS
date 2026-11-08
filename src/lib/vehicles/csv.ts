import type { IntakeProduct, Receipt } from './register';

export const headers = [
  'product_code',
  'chassis_no',
  'engine_no',
  'motor_no',
  'colour',
  'battery_serials',
  'charger_serials',
  'controller_serials',
  'supplier',
  'supplier_invoice',
  'shipment_ref',
  'location',
  'received_date',
  'inspector_email',
];

// Preserve string identifiers (including leading zeroes), quoted commas, doubled quotes and CRLF.
function readRecords(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [],
    field = '',
    quoted = false,
    closed = false;
  const input = text.replace(/^\uFEFF/, '');
  function endField() {
    row.push(field.trim());
    field = '';
    closed = false;
  }
  function endRow() {
    endField();
    if (row.some(Boolean)) rows.push(row);
    row = [];
  }
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (quoted) {
      if (c !== '"') field += c;
      else if (input[i + 1] === '"') {
        field += '"';
        i++;
      } else {
        quoted = false;
        closed = true;
      }
    } else if (c === ',') endField();
    else if (c === '\n' || c === '\r') {
      endRow();
      if (c === '\r' && input[i + 1] === '\n') i++;
    } else if (c === '"' && !field && !closed) quoted = true;
    else {
      if (c === '"' || closed) throw new Error('Invalid quotes in CSV record ' + (rows.length + 1));
      field += c;
    }
  }
  if (quoted) throw new Error('Unclosed quote in CSV record ' + (rows.length + 1));
  endRow();
  return rows;
}

export function parseShipment(text: string, products: IntakeProduct[], inspector: string) {
  const [columns, ...records] = readRecords(text);
  if (
    !columns ||
    !['product_code', 'chassis_no'].every((c) => columns.includes(c)) ||
    new Set(columns).size !== columns.length ||
    columns.some((c) => !headers.includes(c))
  ) {
    throw new Error(
      'Use the template headers. Product code and chassis number are required columns.'
    );
  }
  if (records.length < 1 || records.length > 250)
    throw new Error('Choose a CSV with 1–250 vehicle rows.');
  const errors: { row: number; message: string }[] = [];
  const rows: Receipt[] = records.map((record, i) => {
    const fields: Record<string, string> = Object.fromEntries(
      columns.map((c, j) => [c, record[j] ?? ''])
    );
    const product = products.find(
      (p) => p.code.toUpperCase() === fields.product_code.toUpperCase()
    );
    if (record.length !== columns.length)
      errors.push({ row: i + 1, message: 'Field count differs from header.' });
    if (!product)
      errors.push({ row: i + 1, message: 'Unknown vehicle product code: ' + fields.product_code });
    if (fields.received_date && !/^\d{4}-\d{2}-\d{2}$/.test(fields.received_date))
      errors.push({ row: i + 1, message: 'Use YYYY-MM-DD for the received date.' });
    return {
      product_id: product?.id ?? '',
      chassis_no: fields.chassis_no,
      engine_no: fields.engine_no ?? '',
      motor_no: fields.motor_no ?? '',
      colour: fields.colour ?? '',
      supplier: fields.supplier ?? '',
      supplier_invoice: fields.supplier_invoice ?? '',
      shipment_ref: fields.shipment_ref ?? '',
      location: fields.location ?? '',
      received_date: fields.received_date ?? '',
      inspector_email: fields.inspector_email || inspector,
      components: ['battery', 'charger', 'controller'].flatMap((component_type) =>
        (fields[component_type + '_serials'] || '')
          .split('|')
          .map((s) => s.trim())
          .filter(Boolean)
          .map((serial_no) => ({ component_type, serial_no }))
      ),
    };
  });
  return { rows, errors };
}
