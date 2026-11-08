import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PrintButton } from '@/components/billing/PrintButton';
import { serverSupabase } from '@/lib/supabase/server';
import type { Detail } from '@/lib/vehicles/register';

export default async function VehicleCard({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const db = await serverSupabase();
  const { data, error } = await db.rpc('vehicle_360', { vehicle_id: id });
  if (error?.message === 'Vehicle not found') notFound();
  if (error || !data)
    return (
      <p role="alert" className="error-message">
        Unable to load vehicle card. {error?.message}
      </p>
    );
  const { vehicle: v, components, ownership } = data as Detail;
  const owner = ownership?.find((row) => !row.to_date);
  const active = components.filter((c) => !c.removed_on);
  return (
    <div className="document-frame">
      <div className="print-toolbar">
        <Link href={'/vehicles/' + id}>← Vehicle details</Link>
        <PrintButton />
      </div>
      <article className="document-sheet">
        <header className="print-header">
          <h1>OM MOTORS</h1>
          <div>
            <h2>Vehicle card</h2>
            <strong>{v.chassis_no}</strong>
          </div>
        </header>
        <section className="print-customer">
          <div>
            <strong>
              {v.model_name} {v.variant}
            </strong>
            <p>
              {v.manufacturer} {v.colour}
            </p>
            <p>Chassis · {v.chassis_no}</p>
            {v.engine_no && <p>Engine · {v.engine_no}</p>}
            {v.motor_no && <p>Motor · {v.motor_no}</p>}
            <p>Registration · {v.registration_no || 'Pending'}</p>
          </div>
          <div>
            <p>Status · {v.lifecycle.replaceAll('_', ' ')}</p>
            <p>Received · {v.received_date || '—'}</p>
            <p>Location · {v.location || '—'}</p>
            {owner && (
              <p>
                Owner · {owner.name} · {owner.phone}
              </p>
            )}
          </div>
        </section>
        <h3>Installed components</h3>
        {active.length ? (
          <table className="print-items">
            <thead>
              <tr>
                <th>Component</th>
                <th>Serial number</th>
                <th>Installed on</th>
              </tr>
            </thead>
            <tbody>
              {active.map((c) => (
                <tr key={String(c.serial_no)}>
                  <td>{c.component_type}</td>
                  <td>{c.serial_no}</td>
                  <td>{c.installed_on || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p>No components recorded.</p>
        )}
      </article>
    </div>
  );
}
