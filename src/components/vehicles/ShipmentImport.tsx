'use client';
import { useState } from 'react';
import Link from 'next/link';
import { headers, parseShipment } from '@/lib/vehicles/csv';
import {
  vehicleRpc,
  type BatchResult,
  type IntakeOptions,
  type Receipt,
} from '@/lib/vehicles/register';
import { useToast } from '@/components/ui/Toast';
import { useDealerStore } from '@/lib/store/dealer-store';

export function ShipmentImport({
  products,
  inspector,
}: {
  products: IntakeOptions['products'];
  inspector: string;
}) {
  const [rows, setRows] = useState<Receipt[]>([]);
  const [preview, setPreview] = useState<BatchResult>();
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [received, setReceived] = useState(0);
  const { success } = useToast();
  const { refresh } = useDealerStore();

  async function validate(file?: File) {
    setError('');
    setRows([]);
    setPreview(undefined);
    setReceived(0);
    if (!file) return;
    setBusy(true);
    try {
      if (file.size > 2_000_000) throw new Error('Choose a CSV smaller than 2 MB.');
      const parsed = parseShipment(await file.text(), products, inspector);
      setRows(parsed.rows);
      setPreview(
        parsed.errors.length
          ? { count: parsed.rows.length, errors: parsed.errors, ids: [] }
          : await vehicleRpc<BatchResult>('vehicle_bulk_preview', { rows: parsed.rows })
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to validate CSV.');
    } finally {
      setBusy(false);
    }
  }
  async function save() {
    setBusy(true);
    setError('');
    try {
      const result = await vehicleRpc<BatchResult>('vehicle_bulk_receive', { rows });
      setPreview(result);
      if (!result.errors.length) {
        setReceived(result.ids.length);
        setRows([]);
        success(result.ids.length + ' vehicles received.');
        void refresh({ background: true });
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to receive shipment.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="admin-panel space-y-4">
      <h2 className="font-semibold">Import a shipment</h2>
      <p className="text-sm">
        Enter one chassis per row. Separate multiple serials with | and enter dates as YYYY-MM-DD.
        Blank inspector cells use the selected PDI inspector.
      </p>
      <a
        className="secondary-button"
        download="OM-Motors_vehicle-intake.csv"
        href={'data:text/csv;charset=utf-8,' + encodeURIComponent(headers.join(',') + '\r\n')}
      >
        Download CSV template
      </a>
      <details>
        <summary>Catalogue product codes</summary>
        <ul className="text-sm space-y-1 mt-2">
          {products.map((p) => (
            <li key={p.id}>
              <code>{p.code}</code> · {p.brand} {p.model_name} {p.variant}
            </li>
          ))}
        </ul>
      </details>
      <label>
        Shipment CSV
        <input
          type="file"
          accept=".csv,text/csv"
          disabled={busy}
          onChange={(e) => void validate(e.target.files?.[0])}
        />
      </label>
      {busy && <p role="status">Processing shipment…</p>}
      {error && (
        <p role="alert" className="error-message">
          {error}
        </p>
      )}
      {!!received && (
        <p role="status">
          {received} vehicles received.{' '}
          <Link href="/vehicles" className="underline">
            Open register
          </Link>
        </p>
      )}
      {!!rows.length && (
        <div className="overflow-x-auto">
          <table className="team-table">
            <caption>Shipment preview · {rows.length} vehicle rows</caption>
            <thead>
              <tr>
                <th>Row</th>
                <th>Model</th>
                <th>Chassis</th>
                <th>Engine / motor</th>
                <th>Components</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}>
                  <td>{i + 1}</td>
                  <td>{products.find((p) => p.id === r.product_id)?.model_name || 'Unknown'}</td>
                  <td>{r.chassis_no}</td>
                  <td>{r.engine_no || r.motor_no}</td>
                  <td>{r.components.map((c) => c.serial_no).join(', ') || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {!!preview?.errors.length && (
        <div role="alert" className="error-message">
          <p>Correct these rows and select the file again.</p>
          <ul>
            {preview.errors.map((e, i) => (
              <li key={i}>
                Row {e.row} · {e.message}
              </li>
            ))}
          </ul>
        </div>
      )}
      {!!rows.length && (
        <button
          className="primary-button"
          disabled={busy || !preview || !!preview.errors.length}
          onClick={() => void save()}
        >
          Receive {rows.length} vehicles
        </button>
      )}
    </section>
  );
}
