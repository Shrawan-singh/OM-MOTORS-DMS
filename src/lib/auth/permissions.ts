export const modules = ['dashboard', 'catalogue', 'customers', 'inventory', 'quotations', 'invoices', 'service'] as const;
export type Module = typeof modules[number];
export const roleLabels: Record<string, string> = { owner: 'Administrator', salesperson: 'Sales staff', inventory: 'Inventory manager', mechanic: 'Service technician', accountant: 'Accountant' };
export function routeModule(path: string): string { return path === '/' ? 'dashboard' : path.split('/')[1]; }
