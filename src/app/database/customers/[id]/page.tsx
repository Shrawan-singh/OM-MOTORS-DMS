import Link from 'next/link';
import { serverSupabase } from '@/lib/supabase/server';
import { ExportLink } from '@/components/vehicles/ExportLink';
import type { Detail } from '@/lib/vehicles/register';
type Customer = {
  name: string;
  mobile: string;
  village: string;
  address: string;
  vehicles: Detail[];
  invoices: { id: string; number: string; date: string; total: number; balance: number }[] | null;
  jobs: { number: string; status: string; date: string }[];
};
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const db = await serverSupabase();
  const { data, error } = await db.rpc('customer_360', { customer_id: id });
  if (error || !data) return <p role="alert">{error?.message || 'Customer unavailable'}</p>;
  const c = data as Customer;
  return (
    <div className="space-y-4">
      <Link href="/database">← Database</Link>
      <header className="page-heading">
        <h1>{c.name}</h1>
        <ExportLink dataset="full_register" filters={{ customer_id: id }} />
      </header>
      <p>{[c.mobile, c.village, c.address].filter(Boolean).join(' · ')}</p>
      <section className="admin-panel">
        <h2>Current and past vehicles</h2>
        {c.vehicles.map(({ vehicle: v, ownership }) => (
          <p key={v.id}>
            <Link className="underline" href={'/vehicles/' + v.id}>
              {v.chassis_no}
            </Link>{' '}
            · {v.model_name} {v.variant} · {v.registration_no || 'Unregistered'} ·{' '}
            {ownership?.some((o) => o.customer_id === id && !o.to_date)
              ? 'Current owner'
              : 'Former owner'}
          </p>
        ))}
        {!c.vehicles.length && <p>No vehicles recorded.</p>}
      </section>
      {c.invoices && (
        <section className="admin-panel">
          <h2>Invoices</h2>
          <p>
            Outstanding ₹
            {c.invoices.reduce((sum, b) => sum + Number(b.balance), 0).toLocaleString('en-IN')}
          </p>
          {c.invoices.map((b) => (
            <p key={b.id}>
              <Link className="underline" href={'/invoices/' + b.id}>
                {b.number}
              </Link>{' '}
              · {b.date} · ₹{b.total} · Balance ₹{b.balance}
            </p>
          ))}
        </section>
      )}
      <section className="admin-panel">
        <h2>Service history</h2>
        {c.jobs.map((j) => (
          <p key={j.number}>
            {j.number} · {j.date} · {j.status}
          </p>
        ))}
        {!c.jobs.length && <p>No visible jobs.</p>}
      </section>
    </div>
  );
}
