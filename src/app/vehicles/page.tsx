'use client';
import { ExportLink } from '@/components/vehicles/ExportLink';
import Link from 'next/link';
import { useState } from 'react';
import { useAuth } from '@/lib/auth/provider';
import {
  label,
  lifecycles,
  vehicleTypes,
  useVehicleQuery,
  type VehicleRow,
} from '@/lib/vehicles/register';

const initialFilters = {
  status: '',
  type: '',
  model: '',
  owner: '',
  unsold: false,
  pdi: false,
  unregistered: false,
};
const size = 25;

export default function VehiclesPage() {
  const { can } = useAuth();
  const [q, setQ] = useState('');
  const [filters, setFilters] = useState(initialFilters);
  const [offset, setOffset] = useState(0);
  const result = useVehicleQuery<VehicleRow[]>(
    'vehicle_register_list',
    {
      q,
      filters: { ...filters, owner: can('customers.read') ? filters.owner : '' },
      page_offset: offset,
      page_size: size + 1,
    },
    200
  );
  function update<K extends keyof typeof filters>(key: K, v: (typeof filters)[K]) {
    setFilters((f) => ({ ...f, [key]: v }));
    setOffset(0);
  }
  return (
    <div>
      <header className="page-heading">
        <h1>Vehicle register</h1>
        <ExportLink dataset="vehicles" filters={{ q, ...filters }} />
        {can('vehicles.write') && (
          <Link href="/vehicles/receive" className="primary-button">
            Receive vehicle
          </Link>
        )}
      </header>
      <section aria-label="Search and filter vehicles" className="admin-panel mb-4 space-y-4">
        <label>
          Search vehicles
          <input
            type="search"
            placeholder="Chassis, engine, motor, registration or component serial"
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setOffset(0);
            }}
          />
        </label>
        <div className="form-grid">
          <label>
            Status
            <select value={filters.status} onChange={(e) => update('status', e.target.value)}>
              <option value="">All statuses</option>
              {lifecycles.map((s) => (
                <option key={s} value={s}>
                  {label(s)}
                </option>
              ))}
            </select>
          </label>
          <label>
            Vehicle type
            <select value={filters.type} onChange={(e) => update('type', e.target.value)}>
              <option value="">All vehicle types</option>
              {vehicleTypes.map((t) => (
                <option key={t} value={t}>
                  {label(t)}
                </option>
              ))}
            </select>
          </label>
          <label>
            Model
            <input value={filters.model} onChange={(e) => update('model', e.target.value)} />
          </label>
          {can('customers.read') && (
            <label>
              Owner name
              <input value={filters.owner} onChange={(e) => update('owner', e.target.value)} />
            </label>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          {(
            [
              ['unsold', 'Unsold'],
              ['pdi', 'In PDI'],
              ['unregistered', 'No registration'],
            ] as const
          ).map(([key, title]) => (
            <button
              key={key}
              aria-pressed={filters[key]}
              className={filters[key] ? 'primary-button' : 'secondary-button'}
              onClick={() => update(key, !filters[key])}
            >
              {title}
            </button>
          ))}
          {(q || Object.values(filters).some(Boolean)) && (
            <button
              className="underline text-sm"
              onClick={() => {
                setQ('');
                setFilters(initialFilters);
                setOffset(0);
              }}
            >
              Clear filters
            </button>
          )}
        </div>
      </section>
      <section aria-label="Vehicles" className="admin-panel overflow-x-auto">
        {result.error ? (
          <p role="alert" className="error-message">
            {result.error} <button onClick={result.retry}>Retry</button>
          </p>
        ) : !result.data ? (
          <p role="status">Loading vehicles…</p>
        ) : result.data.length === 0 ? (
          <p className="empty-state vehicle-empty">No vehicles found.</p>
        ) : (
          <>
            <table className="team-table">
              <caption className="sr-only">Matching vehicles</caption>
              <thead>
                <tr>
                  <th scope="col">Chassis</th>
                  <th scope="col">Model</th>
                  <th scope="col">Status</th>
                  <th scope="col">Registration</th>
                  {can('customers.read') && <th scope="col">Owner</th>}
                  <th scope="col">Received</th>
                  <th scope="col">Location</th>
                </tr>
              </thead>
              <tbody>
                {result.data.slice(0, size).map((v) => (
                  <tr key={v.id}>
                    <td>
                      <Link className="font-semibold underline" href={'/vehicles/' + v.id}>
                        {v.chassis_no}
                      </Link>
                      <small className="block">{v.motor_no || v.engine_no}</small>
                    </td>
                    <td>
                      {v.model_name} {v.variant}
                    </td>
                    <td>{label(v.lifecycle)}</td>
                    <td>{v.registration_no || '—'}</td>
                    {can('customers.read') && <td>{v.owner_name || '—'}</td>}
                    <td>{v.received_date || '—'}</td>
                    <td>{v.location || '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
        <nav aria-label="Vehicle pages" className="flex items-center gap-4 mt-4">
          <button
            className="secondary-button"
            onClick={() => setOffset((n) => Math.max(0, n - size))}
            disabled={!offset}
          >
            Previous
          </button>
          <span role="status">Page {offset / size + 1}</span>
          <button
            className="secondary-button"
            disabled={!result.data || result.data.length <= size}
            onClick={() => setOffset((n) => n + size)}
          >
            Next
          </button>
        </nav>
      </section>
    </div>
  );
}
