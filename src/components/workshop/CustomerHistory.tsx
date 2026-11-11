'use client';
import Link from 'next/link';
import { useVehicleQuery } from '@/lib/vehicles/register';
import { WorkshopData, warrantyStatus, label } from '@/lib/workshop/types';

export function CustomerHistory({ id }: { id: string }) {
  const { data, error, retry } = useVehicleQuery<WorkshopData>('ws_snapshot', {});
  if (error) return <p role="alert">Workshop history load nahi hui. <button onClick={retry}>Dobara load karein</button></p>;
  if (!data) return <p role="status">Workshop history load ho rahi hai…</p>;
  const warranties = data.warranties.filter(w => w.customer_id === id);
  const active = warranties.filter(w => ['Active', 'Expiring soon'].includes(warrantyStatus(w)));
  return <section className="ws-section">
    <h3>Vehicles & workshop history</h3>
    {data.vehicles.filter(v => v.customer_id === id).map(v => <p key={v.id} className="ws-event">
      <strong>{v.model_name} {v.variant}</strong><small>{v.chassis_no} · {v.registration_no || 'No registration recorded'}</small>
    </p>)}
    {data.jobs.filter(j => j.customer_id === id).map(j => <Link className="ws-history-link" href={`/service?job=${j.id}`} key={j.id}>
      {j.number} · {j.received_at} · {label(j.status)}<small className="block">{j.complaint} · {j.parts_used.length} parts entries</small>
    </Link>)}
    <h4>Active warranties ({active.length})</h4>
    {warranties.map(w => <p className="ws-event" key={w.id}>{w.product_name} · {w.serial_no}
      <small>{warrantyStatus(w)} · {w.start_date} to {w.end_date}</small>
    </p>)}
  </section>;
}
