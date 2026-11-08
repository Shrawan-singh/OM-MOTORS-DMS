'use client';
import Link from 'next/link';
import { VehicleActions } from './VehicleActions';
import { label, useVehicleQuery, type Detail, type DetailRow } from '@/lib/vehicles/register';

const headings: Record<string, string> = {
  chassis_no: 'Chassis number',
  engine_no: 'Engine number',
  motor_no: 'Motor number',
  registration_no: 'Registration',
  from_date: 'Owned from',
  to_date: 'Owned until',
  phone: 'Mobile',
  rto: 'RTO',
  is_current: 'Current',
  spec: 'Specification',
  supplier_invoice: 'Supplier invoice',
  shipment_ref: 'Shipment reference',
  pdi: 'PDI',
  serial_no: 'Serial number',
  paid_at: 'Paid on',
  assigned_email: 'Assigned to',
  signed_at: 'Delivered on',
  amount_paid: 'Paid',
  balance: 'Balance due',
};
function title(key: string) {
  return headings[key] || label(key);
}
function display(key: string, value: DetailRow[string]) {
  if (key === 'created_at' && typeof value === 'string')
    return new Date(value).toLocaleString('en-IN');
  if (value === null && key === 'to_date') return 'Current owner';
  if (value === null && key === 'removed_on') return 'Installed';
  if (value === null || value === '') return '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'number' && ['total', 'amount', 'amount_paid', 'balance'].includes(key))
    return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(value);
  if (
    typeof value === 'string' &&
    /(?:_date|_on|_at)$/.test(key) &&
    /^\d{4}-\d{2}-\d{2}(T|$)/.test(value)
  ) {
    return new Date(value.length === 10 ? value + 'T12:00:00' : value).toLocaleDateString('en-IN');
  }
  return ['vehicle_type', 'status', 'source', 'component_type'].includes(key)
    ? label(String(value))
    : String(value);
}
function Facts({ row }: { row: DetailRow }) {
  return (
    <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2 lg:grid-cols-3">
      {Object.entries(row).map(([k, v]) => (
        <div key={k}>
          <dt className="text-xs text-slate-500">{title(k)}</dt>
          <dd className="text-sm font-medium break-words">{display(k, v)}</dd>
        </div>
      ))}
    </dl>
  );
}
function History({ name, rows }: { name: string; rows: DetailRow[] | null }) {
  if (rows === null) return null;
  const keys = Object.keys(rows[0] ?? {}).filter((k) => k !== 'id' && k !== 'customer_id');
  return (
    <section className="admin-panel overflow-x-auto">
      <h2 className="font-semibold mb-3">{name}</h2>
      {rows.length ? (
        <table className="team-table">
          <thead>
            <tr>
              {keys.map((k) => (
                <th key={k}>{title(k)}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i}>
                {keys.map((k) => (
                  <td key={k}>{display(k, r[k])}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <p className="text-sm text-slate-500">No records.</p>
      )}
    </section>
  );
}

export function VehicleDetail({ vehicleId }: { vehicleId: string }) {
  const query = useVehicleQuery<Detail>('vehicle_360', { vehicle_id: vehicleId });
  const record = query.data;
  if (query.error)
    return (
      <p role="alert" className="error-message">
        {query.error} <button onClick={query.retry}>Retry</button>
      </p>
    );
  if (!record) return <p role="status">Loading vehicle…</p>;
  const { vehicle, invoice } = record;
  const fields = [
    'vehicle_type',
    'manufacturer',
    'variant',
    'colour',
    'engine_no',
    'motor_no',
    'registration_no',
    'received_date',
    'location',
    'supplier',
    'supplier_invoice',
    'shipment_ref',
  ];
  return (
    <div className="space-y-4">
      <Link href="/vehicles" className="back-link">
        ← Vehicle register
      </Link>
      <header className="page-heading">
        <div>
          <h1>{vehicle.chassis_no}</h1>
          <p>
            {vehicle.model_name} {vehicle.variant} · {label(vehicle.lifecycle)}
          </p>
        </div>
        <Link className="secondary-button" href={'/vehicles/' + vehicleId + '/print'}>
          Print vehicle card
        </Link>
      </header>
      <section className="admin-panel">
        <h2 className="font-semibold mb-3">Vehicle details</h2>
        <Facts row={Object.fromEntries(fields.map((k) => [k, vehicle[k]]))} />
      </section>
      {!!Object.keys(record.specs).length && (
        <section className="admin-panel">
          <h2 className="font-semibold mb-3">Model specifications</h2>
          <Facts row={record.specs} />
        </section>
      )}
      <VehicleActions key={String(vehicle.updated_at)} record={record} reload={query.retry} />
      <History name="Components" rows={record.components} />
      <History name="Registration history" rows={record.registrations} />
      <History name="Ownership history" rows={record.ownership} />
      {invoice && (
        <section className="admin-panel">
          <h2 className="font-semibold mb-3">
            <Link href={'/invoices/' + invoice.id} className="underline">
              Invoice {invoice.number}
            </Link>
          </h2>
          <Facts
            row={{
              document_date: invoice.document_date,
              total: invoice.total,
              amount_paid: invoice.amount_paid,
              balance: invoice.balance,
            }}
          />
        </section>
      )}
      {invoice && <History name="Payments" rows={record.payments} />}
      <History name="Pre-delivery inspections" rows={record.pdi} />
      <History name="Delivery" rows={record.delivery} />
      <History name="Warranties" rows={record.warranties} />
      <History name="Service jobs" rows={record.jobs} />
      <History name="Recent register activity" rows={record.activity} />
      <History name="Workshop attachments" rows={record.attachments} />
    </div>
  );
}
