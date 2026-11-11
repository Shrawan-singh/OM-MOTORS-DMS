'use client';

import Link from 'next/link';
import { useVehicleQuery } from '@/lib/vehicles/register';
import type { WorkshopData } from '@/lib/workshop/types';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useAuth } from '@/lib/auth/provider';
import { money, getDaysOverdue } from '@/lib/billing/types';
import {
  Users,
  Package,
  FileText,
  Receipt,
  BookOpen,
  Wrench,
  CreditCard,
  AlertTriangle,
} from 'lucide-react';

const tasks = [
  ['vehicles.write', '/vehicles/receive', 'Receive vehicle', 'Nayi gaadi aur chassis darj karein', Package],
  ['pdi.read', '/service?tab=pdi&status=pending', 'Pending PDI', 'Jaanch ke liye taiyar gaadiyan dekhein', Wrench],
  ['customers.read', '/customers', 'Customer khojein', 'Mobile ya naam se buyer ka record kholein', Users],
  ['quotations.write', '/quotations/new', 'Quotation banayein', 'Buyer ko estimate dein', FileText],
  ['invoices.write', '/invoices/new', 'Sale invoice banayein', 'Buyer aur chassis ko bill se jodein', Receipt],
  ['invoices.write', '/receivables', 'Payment darj karein', 'Bill chunein aur mili hui rakam bharein', CreditCard],
  ['invoices.read', '/receivables?view=today', 'Aaj ke follow-ups', 'Aaj ke payment waade dekhein', CreditCard],
  ['delivery.read', '/vehicles?status=sold', 'Delivery karein', 'Biki hui gaadi ka handover kholein', Package],
  ['vehicles.read', '/vehicles', 'Vehicle register', 'Chassis, parts aur RC dekhein', BookOpen],
  ['inventory.read', '/inventory', 'Inventory', 'Parts receive karein aur stock milayein', Package],
  ['catalogue.read', '/catalogue', 'Product catalogue', 'Model, variant aur daam dekhein', BookOpen],
  ['service.read', '/service', 'Service & PDI', 'Workshop ke jobs aur warranty dekhein', Wrench],
] as const;

export default function Dashboard() {
  const { customers, documents } = useDealerStore();
  const { can } = useAuth();
  const workshop = useVehicleQuery<WorkshopData>('ws_snapshot', {}, 0, can('service.read'));

  const invoices = documents.filter((d) => d.kind === 'invoice');
  const unpaid = invoices.filter((i) => i.total > i.amount_paid);
  const overdue = unpaid.filter((i) => getDaysOverdue(i.due_date, i.document_date) > 0);
  const overdueTotal = overdue.reduce((s, i) => s + (i.total - i.amount_paid), 0);

  const paymentsReceived = can('invoices.read')
    ? money(invoices.reduce((s, i) => s + i.amount_paid, 0))
    : '—';

  const totalReceivables = can('invoices.read')
    ? money(unpaid.reduce((s, i) => s + i.total - i.amount_paid, 0))
    : '—';

  const customerCount = can('customers.read') ? customers.length : '—';

  return (
    <div>
      {/* Page heading */}
      <div className="page-heading">
        <div>
          <p className="eyebrow">OM MOTORS WORKSPACE</p>
          <h1>Dealership overview</h1>
          <p>Showroom mein aaj ka kaam chunein.</p>
        </div>
      </div>

      {/* Stats row */}
      <div className="admin-stats">
        <div>
          <Receipt />
          <strong>{paymentsReceived}</strong>
          <span>Payments received</span>
        </div>
        <div>
          <CreditCard />
          <strong>{totalReceivables}</strong>
          <span>Total receivables ({unpaid.length})</span>
        </div>
        {overdueTotal > 0 ? (
          <div>
            <AlertTriangle className="text-amber-600" />
            <strong>{can('invoices.read') ? money(overdueTotal) : '—'}</strong>
            <span className="text-amber-700">Overdue ({overdue.length} invoices)</span>
          </div>
        ) : (
          <div>
            <Users />
            <strong>{customerCount}</strong>
            <span>Customers</span>
          </div>
        )}
      </div>

      {/* Module links grid */}
      <div className="products-grid">
        {tasks.filter(([permission, href]) => can(permission)
          && (!href.startsWith('/service?') || can('service.read'))
          && (href !== '/vehicles?status=sold' || can('vehicles.read'))
          && (href !== '/receivables' || can('invoices.read')))
          .map(([, href, title, description, Icon]) => (
          <div key={href} className="admin-panel dashboard-link">
            <Link href={href} className="block">
              <Icon size={24} />
              <h2>{title}</h2>
              <p>{description}</p>
            </Link>
            {href === '/service' && (workshop.error
              ? <p role="alert">Job count load nahi hua. <button onClick={workshop.retry}>Dobara load karein</button></p>
              : <p role="status">{workshop.data ? workshop.data.jobs.length + ' service jobs' : 'Jobs load ho rahe hain…'}</p>)}
          </div>
        ))}
      </div>

      {/* Recent documents */}
      <section className="admin-panel mt-6">
        <h2 className="font-semibold mb-5">Recent documents</h2>
        {documents.slice(0, 6).map((d) => (
          <Link
            className="recent-document"
            key={d.id}
            href={`/${d.kind === 'invoice' ? 'invoices' : 'quotations'}/${d.id}/print`}
          >
            <span>
              {d.number}
              <small>{d.customer_snapshot.name}</small>
            </span>
            <strong>{money(d.total)}</strong>
          </Link>
        ))}
        {!documents.length && (
          <p className="text-sm text-slate-500">No saved quotations or invoices yet.</p>
        )}
      </section>
    </div>
  );
}
