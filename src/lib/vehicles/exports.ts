const identity =
  'type model variant colour chassis motor engine status location received_date supplier supplier_invoice shipment_ref';
const customer = 'owner mobile alt_mobile village tehsil district address gstin';
const invoice = 'invoice invoice_date amount paid balance payment_mode';
const full = [
  identity,
  'batteries chargers controllers registration registration_date rto',
  customer,
  invoice,
  'delivery_date delivered_by pdi_result warranty_ends service_count last_service ownership_history',
].join(' ');
export const fields: Record<string, string[]> = Object.fromEntries(
  Object.entries({
    full_register: full,
    vehicles: full,
    customers: customer,
    sales: invoice + ' payments owner mobile',
    stock: 'model sku quantity reserved',
    components: 'chassis model component_type serial installed_on removed_on removal_reason',
    registrations: 'chassis model registration registration_date rto is_current',
    ownership: 'chassis model owner mobile from_date to_date source',
  }).map(([k, v]) => [k, v.split(' ')])
);
export const sheetNames: Record<string, string> = {
  vehicles: 'Vehicles',
  full_register: 'Full vehicle register',
  components: 'Components',
  ownership: 'Ownership history',
  registrations: 'Registrations',
  customers: 'Customers',
  sales: 'Invoices & payments',
  stock: 'Stock',
};
export type Column = { key: string; header: string };
export type Filters = Record<string, string | boolean | string[]>;
export type Config = {
  id?: string;
  name: string;
  dataset: string;
  columns: Column[];
  filters: Filters;
  sheet_layout: 'single' | 'multi';
  sheets: Record<string, Column[]>;
  shared: boolean;
};
export const columnsFor = (keys: string[]) =>
  keys.map((key) => ({
    key,
    header: key.replaceAll('_', ' ').replace(/^./, (c) => c.toUpperCase()),
  }));
export function configFor(dataset: string, filters: Filters = {}, keys = fields[dataset]): Config {
  return {
    name: '',
    dataset,
    columns: columnsFor(keys),
    filters,
    sheet_layout: 'single',
    sheets: {},
    shared: false,
  };
}
export function presets(): Config[] {
  const month = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }).slice(0, 7);
  const last = new Date(Number(month.slice(0, 4)), Number(month.slice(5)), 0).getDate();
  return [
    ['Full vehicle register', configFor('full_register')],
    ['Stock in showroom (unsold)', configFor('vehicles', { unsold: true })],
    [
      'Sold vehicles with customer details',
      configFor(
        'vehicles',
        { sold: true },
        'chassis model registration owner mobile invoice invoice_date'.split(' ')
      ),
    ],
    ['Vehicles without registration number', configFor('vehicles', { unregistered: true })],
    ['Battery & component serial list', configFor('components')],
    [
      'Customer-wise vehicles (by mobile)',
      configFor('ownership', {}, 'owner mobile chassis model from_date to_date'.split(' ')),
    ],
    ['Monthly sales register', configFor('sales', { from: month + '-01', to: month + '-' + last })],
    ['Balance due on vehicles', configFor('vehicles', { balance_due: true })],
  ].map((pair) => ({ ...(pair[1] as Config), name: String(pair[0]) }));
}
export type ExportData = {
  columns: string[];
  dropped: string[];
  rows: Record<string, string | number | boolean | null>[];
};
export type Hit = {
  id: string;
  vehicle_id?: string;
  title: string;
  detail: string;
  matched_on: string;
};
export type Groups = Record<'vehicles' | 'customers' | 'invoices' | 'components', Hit[]>;
export const hitUrl = (group: string, h: Hit) =>
  group === 'customers'
    ? '/database/customers/' + h.id
    : group === 'invoices'
      ? '/invoices/' + h.id
      : '/vehicles/' + (h.vehicle_id || h.id);
