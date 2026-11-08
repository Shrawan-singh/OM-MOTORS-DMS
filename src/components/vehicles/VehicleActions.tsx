'use client';

import { useState, type FormEvent } from 'react';
import { useAuth } from '@/lib/auth/provider';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useToast } from '@/components/ui/Toast';
import { vehicleRpc, type Detail, type DetailRow } from '@/lib/vehicles/register';

type Action = 'registration' | 'components' | 'transfer';
const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
const inputValue = (v: DetailRow[string] | undefined) => String(v ?? '');

function ComponentFields({
  rows,
  mode,
  setMode,
}: {
  rows: DetailRow[];
  mode: string;
  setMode: (value: string) => void;
}) {
  const active = rows.filter((row) => !row.removed_on);
  const [selected, select] = useState('');
  const part = active.find((row) => row.id === selected) ?? active[0];
  return (
    <>
      <label>
        Action
        <select value={mode} onChange={(e) => setMode(e.target.value)}>
          <option value="add">Add component</option>
          {active.length > 0 &&
            ['edit', 'remove', 'replace'].map((a) => (
              <option key={a} value={a}>
                {a[0].toUpperCase() + a.slice(1)} component
              </option>
            ))}
        </select>
      </label>
      {mode === 'add' ? (
        <label>
          Component type
          <select name="component_type">
            {['battery', 'charger', 'controller', 'motor', 'engine', 'other'].map((t) => (
              <option key={t}>{t}</option>
            ))}
          </select>
        </label>
      ) : (
        <label>
          Installed component
          <select name="id" value={inputValue(part?.id)} onChange={(e) => select(e.target.value)}>
            {active.map((r) => (
              <option key={String(r.id)} value={String(r.id)}>
                {r.component_type} · {r.serial_no}
              </option>
            ))}
          </select>
        </label>
      )}
      <div key={mode + inputValue(part?.id)} className="contents">
        {(mode === 'add' || mode === 'replace') && (
          <label>
            {mode === 'replace' ? 'Replacement serial' : 'Serial number'}
            <input name="serial_no" required />
          </label>
        )}
        {mode !== 'remove' && (
          <>
            <label>
              Brand
              <input name="brand" defaultValue={mode === 'edit' ? inputValue(part?.brand) : ''} />
            </label>
            <label>
              Specification
              <input name="spec" defaultValue={mode === 'edit' ? inputValue(part?.spec) : ''} />
            </label>
          </>
        )}
        <label>
          {mode === 'remove'
            ? 'Removal date'
            : mode === 'replace'
              ? 'Replacement date'
              : 'Installation date'}
          <input
            name="date"
            type="date"
            required={mode !== 'edit'}
            defaultValue={mode === 'edit' ? inputValue(part?.installed_on) : today()}
          />
        </label>
        {mode !== 'add' && (
          <label>
            Reason
            <input name="reason" required />
          </label>
        )}
      </div>
    </>
  );
}

export function VehicleActions({ record, reload }: { record: Detail; reload: () => void }) {
  const { can } = useAuth();
  const { customers } = useDealerStore();
  const { success } = useToast();
  const [action, setAction] = useState<Action | null>(null);
  const [mode, setMode] = useState('add');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  if (!can('vehicles.write')) return null;
  const current = record.registrations.find((r) => r.is_current);
  const owner = record.ownership?.find((r) => !r.to_date);
  const actions: Partial<Record<Action, string>> = {
    registration: current ? 'Update registration' : 'Add registration',
    components: 'Edit components',
  };
  if (owner && can('customers.read') && can('service_approve.write'))
    actions.transfer = 'Transfer owner';

  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setBusy(true);
    setError('');
    const fields = Object.fromEntries(new FormData(e.currentTarget));
    const p: Record<string, unknown> = {
      ...fields,
      vehicle_id: record.vehicle.id,
      expected_updated_at: record.vehicle.updated_at,
    };
    let rpc = 'vehicle_set_registration';
    if (action === 'transfer') rpc = 'vehicle_transfer_owner';
    if (action === 'components') {
      rpc = mode === 'replace' ? 'component_replace' : 'component_save';
      p.action = mode;
      if (mode === 'edit' || mode === 'add') p.installed_on = fields.date;
      if (mode === 'replace')
        p.replacement = { serial_no: fields.serial_no, brand: fields.brand, spec: fields.spec };
    }
    try {
      await vehicleRpc(rpc, { p });
      success('Vehicle record updated.');
      setAction(null);
      reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to save changes.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <section aria-label="Vehicle actions" className="admin-panel space-y-4">
      <div className="flex gap-2 flex-wrap">
        {Object.entries(actions).map(([key, title]) => (
          <button
            key={key}
            disabled={busy}
            aria-expanded={action === key}
            className={action === key ? 'primary-button' : 'secondary-button'}
            onClick={() => {
              setAction(action === key ? null : (key as Action));
              setMode('add');
              setError('');
            }}
          >
            {title}
          </button>
        ))}
      </div>
      {action && actions[action] && (
        <form key={action} onSubmit={save}>
          <fieldset className="form-grid" disabled={busy}>
            <legend className="font-semibold mb-3">{actions[action]}</legend>
            {action === 'registration' && (
              <>
                <label>
                  Registration number
                  <input
                    name="registration_no"
                    required
                    defaultValue={inputValue(current?.registration_no)}
                  />
                </label>
                <label>
                  Registration date
                  <input
                    type="date"
                    name="registration_date"
                    defaultValue={inputValue(current?.registration_date)}
                  />
                </label>
                <label>
                  RTO
                  <input name="rto" defaultValue={inputValue(current?.rto)} />
                </label>
                {current && (
                  <label>
                    Reason when replacing an existing value
                    <input name="reason" />
                  </label>
                )}
              </>
            )}
            {action === 'components' && (
              <ComponentFields rows={record.components} mode={mode} setMode={setMode} />
            )}
            {action === 'transfer' && (
              <>
                <p>Current owner · {owner?.name}</p>
                <label>
                  New owner
                  <select name="customer_id" required defaultValue="">
                    <option value="">Choose customer</option>
                    {customers
                      .filter((c) => c.id !== owner?.customer_id)
                      .map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.name} · {c.phone}
                        </option>
                      ))}
                  </select>
                </label>
                <label>
                  Transfer date
                  <input
                    name="from_date"
                    required
                    type="date"
                    min={inputValue(owner?.from_date)}
                    max={today()}
                    defaultValue={today()}
                  />
                </label>
                <label>
                  Transfer reason
                  <input name="reason" required />
                </label>
              </>
            )}
          </fieldset>
          {error && (
            <p role="alert" className="error-message">
              {error}{' '}
              <button
                type="button"
                onClick={() => {
                  setAction(null);
                  reload();
                }}
              >
                Reload vehicle
              </button>
            </p>
          )}
          <button disabled={busy} className="primary-button mt-3">
            {busy ? 'Saving…' : action === 'transfer' ? 'Confirm transfer' : 'Save changes'}
          </button>
        </form>
      )}
    </section>
  );
}
