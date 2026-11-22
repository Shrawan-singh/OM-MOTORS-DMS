'use client';

import Link from 'next/link';
import { useState } from 'react';
import { useAuth } from '@/lib/auth/provider';
import { money } from '@/lib/billing/types';
import { Row, WorkshopData } from '@/lib/workshop/types';

type Task = {
  key: string;
  title: string;
  detail: string;
  action: string;
  href?: string;
  run?: () => void;
};

export function TodayWork({
  data,
  open,
}: {
  data: WorkshopData;
  open: (entity: string, row: Row) => void;
}) {
  const { can } = useAuth();
  const [search, setSearch] = useState('');
  const showroom: Task[] = [];
  const repairs: Task[] = [];
  const vehicles = new Map(data.vehicles.map((v) => [v.id, v]));
  const buyers = new Map(data.customers.map((c) => [c.id, c]));
  const bills = new Map(data.invoices.filter((b) => !b.cancelled_at).map((b) => [b.id, b]));
  const inspections = new Map(
    [...data.pdi]
      .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)))
      .map((p) => [p.vehicle_id, p])
  );
  const handovers = new Map(data.deliveries.map((d) => [d.vehicle_id, d]));

  for (const v of data.vehicles) {
    const row = { key: v.id, title: [v.model_name, v.chassis_no].join(' · ') };
    const inspection = inspections.get(v.id);
    if (can('pdi.read') && ['pdi_pending', 'pdi_failed', 'pdi_issues'].includes(v.lifecycle)) {
      if (inspection || (v.lifecycle === 'pdi_pending' && can('pdi.write'))) {
        showroom.push({
          ...row,
          detail:
            v.lifecycle === 'pdi_pending' ? 'Jaanch baaki hai' : 'Issue darj hai · dobara jaanch',
          action: 'PDI kholein',
          run: () => open('pdi', inspection || { vehicle_id: v.id, pdi_mode: 'existing' }),
        });
      }
    }
    if (
      v.stock_id &&
      v.product_id &&
      !v.customer_id &&
      ['available', 'pdi_passed', 'pdi_issues'].includes(v.lifecycle) &&
      can('invoices.write') &&
      can('vehicles.write')
    ) {
      showroom.push({
        ...row,
        key: v.id + '-sale',
        detail:
          v.lifecycle === 'pdi_issues' ? 'PDI issue ke saath approved' : 'Sale ke liye taiyar',
        action: 'Sale invoice banayein',
        href:
          '/invoices/new?' +
          new URLSearchParams({ productId: v.product_id, chassis: v.chassis_no }),
      });
    }
    if (v.lifecycle === 'sold' && can('delivery.read')) {
      const draft = handovers.get(v.id);
      const bill = bills.get(v.purchase_invoice_id);
      if (!draft?.signed_at && (draft || (bill && can('delivery.write')))) {
        const due = bill && typeof bill.total === 'number' ? bill.total - bill.amount_paid : null;
        showroom.push({
          ...row,
          detail: [
            buyers.get(v.customer_id)?.name,
            'Handover baaki',
            due && due > 0 ? money(due) + ' baki' : '',
          ]
            .filter(Boolean)
            .join(' · '),
          action: 'Delivery kholein',
          run: () =>
            open('delivery', draft || { vehicle_id: v.id, invoice_id: v.purchase_invoice_id }),
        });
      }
    }
  }
  for (const job of data.jobs.filter((j) => j.status !== 'completed')) {
    const bill = bills.get(job.invoice_id);
    const buyer = buyers.get(job.customer_id);
    const vehicle = vehicles.get(job.vehicle_id);
    const stage =
      job.status === 'waiting_for_parts'
        ? 'Part ka intezaar'
        : job.status === 'ready_for_delivery'
          ? 'Bill taiyar karna hai'
          : 'Repair jaari hai';
    const settled = bill && (job.status === 'paid' || bill.amount_paid >= bill.total);
    repairs.push({
      key: job.id,
      title: [job.number, buyer?.name, vehicle?.chassis_no].filter(Boolean).join(' · '),
      detail: [
        bill ? (settled ? 'Gaadi wapas deni hai' : 'Payment baaki') : stage,
        job.complaint,
        buyer?.phone,
      ]
        .filter(Boolean)
        .join(' · '),
      action:
        bill || job.status === 'ready_for_delivery' ? 'Bill aur handover dekhein' : 'Job kholein',
      run: () => open('job', job),
    });
  }

  function list(title: string, tasks: Task[]) {
    const rows = tasks.filter((r) =>
      (r.title + ' ' + r.detail).toLowerCase().includes(search.trim().toLowerCase())
    );
    return (
      <section className="ws-panel">
        <h2>
          {title} ({rows.length})
        </h2>
        {rows.map((r) => (
          <div key={r.key} className="ws-event flex-wrap">
            <div>
              <strong>{r.title}</strong>
              <p>{r.detail}</p>
            </div>
            {r.href ? (
              <Link className="secondary-button" href={r.href}>
                {r.action}
              </Link>
            ) : (
              <button className="secondary-button" onClick={r.run}>
                {r.action}
              </button>
            )}
          </div>
        ))}
        {!rows.length && (
          <p className="ws-muted">
            {search ? 'Koi match nahi mila.' : 'Koi pending kaam nahi hai.'}
          </p>
        )}
      </section>
    );
  }
  return (
    <section className="space-y-4">
      <h2>Aaj ka kaam</h2>
      <input
        type="search"
        aria-label="Pending kaam khojein"
        placeholder="Chassis, job number ya naam khojein"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />
      <div className="ws-dashboard-grid">
        {list('Showroom · PDI aur delivery', showroom)}
        {list('Workshop · service aur repair', repairs)}
      </div>
    </section>
  );
}
