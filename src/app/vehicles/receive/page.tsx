'use client';
import { useState } from 'react';
import Link from 'next/link';
import { useAuth } from '@/lib/auth/provider';
import { useVehicleQuery, type IntakeOptions } from '@/lib/vehicles/register';
import { ReceiveForm } from '@/components/vehicles/ReceiveForm';
import { ShipmentImport } from '@/components/vehicles/ShipmentImport';

export default function ReceiveVehicle() {
  const { email } = useAuth();
  const options = useVehicleQuery<IntakeOptions>('vehicle_intake_options', {});
  const [selection, setSelection] = useState('');
  const [csv, setCsv] = useState(false);
  const inspectors = options.data?.inspectors ?? [];
  const inspector =
    selection ||
    (inspectors.includes(email) ? email : inspectors.length === 1 ? inspectors[0] : '');
  return (
    <div>
      <Link href="/vehicles" className="back-link">
        ← Vehicle register
      </Link>
      <header className="page-heading">
        <h1>Receive vehicle</h1>
      </header>
      {options.error ? (
        <p className="error-message" role="alert">
          {options.error} <button onClick={options.retry}>Retry</button>
        </p>
      ) : !options.data ? (
        <p role="status">Loading intake options…</p>
      ) : (
        <>
          <section className="admin-panel mb-4 space-y-4">
            <label>
              PDI inspector
              <select value={inspector} onChange={(e) => setSelection(e.target.value)}>
                <option value="">Choose an inspector</option>
                {inspectors.map((s) => (
                  <option key={s}>{s}</option>
                ))}
              </select>
            </label>
            {!inspectors.length && (
              <p role="alert">
                Assign an active PDI inspector in Team &amp; permissions before receiving stock.
              </p>
            )}
            <div className="flex flex-wrap gap-2">
              {['Single vehicle', 'Import CSV'].map((title, i) => (
                <button
                  key={title}
                  aria-pressed={csv === Boolean(i)}
                  className={csv === Boolean(i) ? 'primary-button' : 'secondary-button'}
                  onClick={() => setCsv(Boolean(i))}
                >
                  {title}
                </button>
              ))}
            </div>
          </section>
          {csv ? (
            <ShipmentImport
              key={inspector}
              products={options.data.products}
              inspector={inspector}
            />
          ) : (
            <ReceiveForm products={options.data.products} inspector={inspector} />
          )}
        </>
      )}
    </div>
  );
}
