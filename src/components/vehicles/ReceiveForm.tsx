'use client';
import { useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { useToast } from '@/components/ui/Toast';
import { useDealerStore } from '@/lib/store/dealer-store';
import {
  label,
  useVehicleQuery,
  vehicleRpc,
  type IntakeOptions,
  type Receipt,
} from '@/lib/vehicles/register';
import { ChassisScan } from './ChassisScan';

function emptyReceipt(): Receipt {
  return {
    product_id: '',
    colour: '',
    chassis_no: '',
    engine_no: '',
    motor_no: '',
    supplier: '',
    supplier_invoice: '',
    shipment_ref: '',
    location: '',
    received_date: new Date().toLocaleDateString('en-CA'),
    inspector_email: '',
    components: [],
  };
}

export function ReceiveForm({
  products,
  inspector,
}: {
  products: IntakeOptions['products'];
  inspector: string;
}) {
  const router = useRouter();
  const { success } = useToast();
  const { refresh } = useDealerStore();
  const [row, setRow] = useState(emptyReceipt);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const product = products.find((p) => p.id === row.product_id);
  const duplicate = useVehicleQuery<string[]>(
    'vehicle_check_duplicates',
    {
      p: {
        chassis_no: row.chassis_no,
        motor_no: row.motor_no,
        engine_no: row.engine_no,
        components: row.components,
      },
    },
    300,
    Boolean(
      row.chassis_no || row.motor_no || row.engine_no || row.components.some((c) => c.serial_no)
    )
  );
  function set(key: keyof Omit<Receipt, 'components'>, value: string) {
    setRow((r) => ({ ...r, [key]: value }));
  }
  function field(
    key: keyof Omit<Receipt, 'components'>,
    title: string,
    type = 'text',
    required = false
  ) {
    return (
      <label>
        {title}
        <input
          name={key}
          type={type}
          required={required}
          value={row[key]}
          onChange={(e) => set(key, e.target.value)}
        />
      </label>
    );
  }
  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const another =
      ((e.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null)?.value === 'another';
    setError('');
    setBusy(true);
    try {
      const id = await vehicleRpc<string>('vehicle_receive', {
        p: { ...row, inspector_email: inspector },
      });
      success('Received ' + row.chassis_no + '. PDI created.');
      void refresh({ background: true });
      if (another) {
        setRow((r) => ({ ...r, chassis_no: '', engine_no: '', motor_no: '', components: [] }));
        requestAnimationFrame(() => document.getElementById('receive-chassis')?.focus());
      } else router.push('/vehicles/' + id);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to receive vehicle.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <form onSubmit={save} className="admin-panel billing-editor">
      <fieldset disabled={busy} className="space-y-6">
        <legend className="font-semibold mb-4">Vehicle identity</legend>
        <div className="form-grid">
          <label>
            Catalogue vehicle
            <select
              required
              value={row.product_id}
              onChange={(e) =>
                setRow((r) => ({ ...r, product_id: e.target.value, engine_no: '', motor_no: '' }))
              }
            >
              <option value="">Choose a model and variant</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.brand} {p.model_name} {p.variant}
                </option>
              ))}
            </select>
          </label>
          <label>
            Chassis number
            <input
              id="receive-chassis"
              autoComplete="off"
              required
              minLength={3}
              value={row.chassis_no}
              onChange={(e) => set('chassis_no', e.target.value)}
            />
          </label>
          {process.env.NEXT_PUBLIC_ENABLE_CHASSIS_SCAN === 'true' && (
            <ChassisScan onScan={(s) => set('chassis_no', s)} />
          )}
          {product &&
            (product.category === 'e_rickshaw'
              ? field('motor_no', 'Motor number', 'text', true)
              : field('engine_no', 'Engine number', 'text', true))}
          {field('colour', 'Colour')}
        </div>
        <section>
          <h2 className="font-semibold mb-3">Components</h2>
          {row.components.map((c, i) => (
            <div key={i} className="form-grid mb-2 items-end">
              <label>
                Component {i + 1}
                <select
                  value={c.component_type}
                  onChange={(e) =>
                    setRow((r) => ({
                      ...r,
                      components: r.components.map((v, j) =>
                        j === i ? { ...v, component_type: e.target.value } : v
                      ),
                    }))
                  }
                >
                  {['battery', 'charger', 'controller', 'other'].map((t) => (
                    <option key={t} value={t}>
                      {label(t)}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Serial {i + 1}
                <input
                  required
                  value={c.serial_no}
                  onChange={(e) =>
                    setRow((r) => ({
                      ...r,
                      components: r.components.map((v, j) =>
                        j === i ? { ...v, serial_no: e.target.value } : v
                      ),
                    }))
                  }
                />
              </label>
              <button
                type="button"
                className="secondary-button"
                aria-label={'Remove component ' + (i + 1)}
                onClick={() =>
                  setRow((r) => ({ ...r, components: r.components.filter((_, j) => j !== i) }))
                }
              >
                Remove
              </button>
            </div>
          ))}
          <button
            type="button"
            className="secondary-button"
            onClick={() =>
              setRow((r) => ({
                ...r,
                components: [...r.components, { component_type: 'battery', serial_no: '' }],
              }))
            }
          >
            Add component
          </button>
        </section>
        <section>
          <h2 className="font-semibold mb-3">Receipt details</h2>
          <div className="form-grid">
            {field('supplier', 'Supplier')}
            {field('supplier_invoice', 'Supplier invoice')}
            {field('shipment_ref', 'Shipment reference')}
            {field('location', 'Location')}
            {field('received_date', 'Received date', 'date', true)}
          </div>
        </section>
        {!!duplicate.data?.length && (
          <ul className="error-message" role="alert">
            {duplicate.data.map((m, i) => (
              <li key={i}>{m}</li>
            ))}
          </ul>
        )}
        {(error || duplicate.error) && (
          <p role="alert" className="error-message">
            {error || duplicate.error}
          </p>
        )}
        <div className="flex flex-wrap gap-3">
          <button className="primary-button" disabled={!inspector || !!duplicate.data?.length}>
            {busy ? 'Receiving…' : 'Receive vehicle'}
          </button>
          <button
            className="secondary-button"
            value="another"
            disabled={!inspector || !!duplicate.data?.length}
          >
            Receive and add another
          </button>
        </div>
      </fieldset>
    </form>
  );
}
