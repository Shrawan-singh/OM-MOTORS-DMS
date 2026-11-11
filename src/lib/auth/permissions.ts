export const modules = [
  'dashboard',
  'catalogue',
  'customers',
  'inventory',
  'vehicles',
  'quotations',
  'invoices',
  'service',
  'service_work',
  'service_finance',
  'service_approve',
  'service_reports',
  'pdi',
  'delivery',
  'warranty',
] as const;

export type Module = (typeof modules)[number];

export const roleLabels: Record<string, string> = {
  owner: 'Administrator',
  manager: 'General Manager',
  service_manager: 'Service Manager',
  pdi: 'PDI / Delivery Staff',
  warranty: 'Warranty Staff',
  salesperson: 'Sales staff',
  inventory: 'Inventory manager',
  mechanic: 'Service technician',
  accountant: 'Accountant',
};

export function routeModule(path: string): string {
  if (path === '/receivables') return 'invoices';
  if (path.startsWith('/database') || path === '/export' || path === '/api/export') return 'vehicles';
  return path === '/' ? 'dashboard' : path.split('/')[1];
}
