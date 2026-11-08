'use client';
import { useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth/provider';
import { vehicleRpc } from '@/lib/vehicles/register';
import {
  fields,
  sheetNames,
  configFor,
  columnsFor,
  presets,
  type Column,
  type Config,
  type ExportData,
} from '@/lib/vehicles/exports';

function Columns({
  dataset,
  value,
  change,
}: {
  dataset: string;
  value: Column[];
  change: (v: Column[]) => void;
}) {
  const keys = value.map((c) => c.key);
  return (
    <fieldset>
      <legend>Columns in workbook order</legend>
      {[...value, ...columnsFor(fields[dataset].filter((k) => !keys.includes(k)))].map((c, i) => (
        <div className="flex items-center gap-3 mb-2" key={c.key}>
          <label>
            <input
              type="checkbox"
              checked={keys.includes(c.key)}
              onChange={(e) =>
                change(e.target.checked ? [...value, c] : value.filter((v) => v.key !== c.key))
              }
            />{' '}
            {c.key.replaceAll('_', ' ')}
          </label>
          {i < value.length && (
            <>
              <input
                aria-label={'Header for ' + c.key}
                value={c.header}
                onChange={(e) =>
                  change(value.map((v) => (v.key === c.key ? { ...v, header: e.target.value } : v)))
                }
              />
              <button
                disabled={!i}
                aria-label={'Move ' + c.key + ' up'}
                onClick={() => {
                  const next = value.slice();
                  [next[i], next[i - 1]] = [next[i - 1], next[i]];
                  change(next);
                }}
              >
                ↑
              </button>
              <button
                disabled={i === value.length - 1}
                aria-label={'Move ' + c.key + ' down'}
                onClick={() => {
                  const next = value.slice();
                  [next[i], next[i + 1]] = [next[i + 1], next[i]];
                  change(next);
                }}
              >
                ↓
              </button>
            </>
          )}
        </div>
      ))}
    </fieldset>
  );
}
export function ExportBuilder() {
  const params = useSearchParams();
  const ds = params.get('dataset') || 'full_register';
  const selection = params.get('selection');
  const [config, set] = useState<Config>(() =>
    configFor(Object.hasOwn(fields, ds) ? ds : 'full_register')
  );
  const [templates, setTemplates] = useState<Config[]>([]);
  const [revision, refresh] = useState(0);
  const [preview, show] = useState<ExportData>();
  const [message, notice] = useState('');
  const [busy, working] = useState(false);
  const [sheet, editSheet] = useState('vehicles');
  const { can, role } = useAuth();
  const includeCustomers = can('customers.read');
  const includeInvoices = can('invoices.read');
  useEffect(() => {
    if (selection) {
      const raw = sessionStorage.getItem(selection);
      if (raw)
        queueMicrotask(() => {
          const config = configFor(
            Object.hasOwn(fields, ds) ? ds : 'full_register',
            JSON.parse(raw)
          );
          if (config.filters.database_results) {
            const groups = ['vehicles', 'components'];
            if (includeCustomers) groups.push('customers');
            if (includeInvoices) groups.push('sales');
            config.sheet_layout = 'multi';
            config.sheets = Object.fromEntries(
              groups.map((group) => [group, configFor(group).columns])
            );
          }
          set(config);
        });
    }
  }, [selection, ds, includeCustomers, includeInvoices]);
  useEffect(() => {
    let alive = true;
    if (role && supabase)
      void supabase
        .from('export_templates')
        .select('*')
        .order('name')
        .then((r) => {
          if (alive) {
            if (r.error) notice(r.error.message);
            else setTemplates(r.data as Config[]);
          }
        });
    return () => {
      alive = false;
    };
  }, [revision, role]);
  const update = (v: Partial<Config>) => {
    set({ ...config, ...v });
    show(undefined);
    notice('');
  };
  const multi = config.sheet_layout === 'multi';
  const available = (ds: string) =>
    ds === 'sales'
      ? can('invoices.read')
      : ['customers', 'ownership'].includes(ds)
        ? can('customers.read')
        : ds === 'stock'
          ? can('inventory.read')
          : true;
  const current = multi
    ? config.sheets[sheet]
      ? sheet
      : Object.keys(config.sheets)[0]
    : config.dataset;
  const cols = multi ? config.sheets[current] : config.columns;
  async function run(action: () => Promise<void>) {
    working(true);
    notice('');
    try {
      await action();
    } catch (e) {
      notice(e instanceof Error ? e.message : 'Export failed');
    } finally {
      working(false);
    }
  }
  async function download(p: Config) {
    const r = await fetch('/api/export', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(p),
    });
    if (!r.ok || !r.headers.get('Content-Type')?.includes('spreadsheetml'))
      throw new Error(
        (await r.json().catch(() => ({}))).error ||
          'Download failed. Check your session and try a smaller date range.'
      );
    const url = URL.createObjectURL(await r.blob());
    const a = document.createElement('a');
    a.href = url;
    a.download = r.headers.get('Content-Disposition')?.split('"')[1] || 'OM-Motors.xlsx';
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    notice(decodeURIComponent(r.headers.get('X-Export-Omissions') || '') || 'Workbook downloaded.');
  }
  return (
    <div className="space-y-4">
      <h1 className="page-heading">Excel exports</h1>
      <section className="admin-panel">
        <h2>Templates</h2>
        {[...presets(), ...templates]
          .filter((t) => available(t.dataset))
          .map((t, i) => (
            <div className="flex gap-3 items-center" key={t.id || i}>
              <button
                className="underline"
                onClick={() => {
                  set(t);
                  show(undefined);
                  notice('');
                }}
              >
                {t.name}
              </button>
              <button
                disabled={busy}
                className="secondary-button"
                aria-label={'Run template ' + t.name}
                onClick={() => void run(() => download(t))}
              >
                Run
              </button>
            </div>
          ))}
      </section>
      <section className="admin-panel space-y-4">
        <div className="form-grid">
          <label>
            Dataset
            <select
              value={config.dataset}
              onChange={(e) => {
                set(configFor(e.target.value));
                show(undefined);
              }}
            >
              {Object.keys(fields)
                .filter(available)
                .map((d) => (
                  <option key={d} value={d}>
                    {sheetNames[d]}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Workbook layout
            <select
              value={config.sheet_layout}
              onChange={(e) =>
                update({
                  sheet_layout: e.target.value as Config['sheet_layout'],
                  sheets: Object.fromEntries(
                    ['vehicles', 'components', 'ownership', 'registrations', 'customers', 'sales']
                      .filter(available)
                      .map((d) => [d, columnsFor(fields[d])])
                  ),
                })
              }
            >
              <option value="single">Single sheet</option>
              <option value="multi">Multiple sheets</option>
            </select>
          </label>
        </div>
        {multi && (
          <fieldset>
            <legend>Sheets</legend>
            {Object.keys(sheetNames)
              .filter((d) => d !== 'full_register' && available(d))
              .map((d) => (
                <label key={d}>
                  <input
                    type="checkbox"
                    checked={!!config.sheets[d]}
                    onChange={(e) => {
                      const next = { ...config.sheets };
                      if (e.target.checked) next[d] = columnsFor(fields[d]);
                      else delete next[d];
                      update({ sheets: next });
                    }}
                  />{' '}
                  {sheetNames[d]}
                </label>
              ))}
            <label>
              Edit sheet
              <select
                value={current || ''}
                onChange={(e) => {
                  editSheet(e.target.value);
                  show(undefined);
                }}
              >
                {Object.keys(config.sheets).map((d) => (
                  <option key={d} value={d}>
                    {sheetNames[d]}
                  </option>
                ))}
              </select>
            </label>
          </fieldset>
        )}
        <fieldset className="form-grid">
          <legend>Filters</legend>
          {['q', 'from', 'to', 'status', 'model', 'type', 'owner'].map((k) => (
            <label key={k}>
              {k === 'q' ? 'Search' : k}
              <input
                type={['from', 'to'].includes(k) ? 'date' : 'text'}
                value={String(config.filters[k] || '')}
                onChange={(e) => {
                  const filters = { ...config.filters };
                  if (e.target.value) filters[k] = e.target.value;
                  else delete filters[k];
                  update({ filters });
                }}
              />
            </label>
          ))}
          {['unsold', 'unregistered', 'registered', 'balance_due'].map((k) => (
            <label key={k}>
              <input
                type="checkbox"
                checked={!!config.filters[k]}
                onChange={(e) => {
                  const f = { ...config.filters };
                  if (e.target.checked) f[k] = true;
                  else delete f[k];
                  update({ filters: f });
                }}
              />{' '}
              {k.replaceAll('_', ' ')}
            </label>
          ))}
        </fieldset>
        {current && cols && (
          <Columns
            dataset={current}
            value={cols}
            change={(v) =>
              update(multi ? { sheets: { ...config.sheets, [current]: v } } : { columns: v })
            }
          />
        )}
        <label>
          Template name
          <input value={config.name} onChange={(e) => update({ name: e.target.value })} />
        </label>
        <label>
          <input
            type="checkbox"
            checked={config.shared}
            onChange={(e) => update({ shared: e.target.checked })}
          />{' '}
          Share with export staff
        </label>
        <div className="flex flex-wrap gap-2">
          <button
            className="secondary-button"
            disabled={busy || !config.name.trim()}
            onClick={() =>
              void run(async () => {
                const id = await vehicleRpc<string>('export_template_save', { p: config });
                set({ ...config, id });
                refresh((n) => n + 1);
                notice('Template saved.');
              })
            }
          >
            Save template
          </button>
          {config.id && (
            <button
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  await vehicleRpc('export_template_delete', { id: config.id });
                  set({ ...config, id: undefined });
                  refresh((n) => n + 1);
                  notice('Template deleted.');
                })
              }
            >
              Delete template
            </button>
          )}
          <button
            className="secondary-button"
            disabled={busy || !cols?.length}
            onClick={() =>
              void run(async () => {
                const r = await vehicleRpc<ExportData>('export_preview', {
                  dataset: current,
                  columns: cols.map((c) => c.key),
                  filters: {
                    ...config.filters,
                    root_dataset: config.dataset,
                    ...(multi &&
                    current !== config.dataset &&
                    !['sales', 'customers', 'stock'].includes(config.dataset)
                      ? { linked_only: true }
                      : {}),
                  },
                });
                show(r);
                notice(
                  `Preview ready, ${r.rows.length} rows.` +
                    (r.dropped.length ? ' Omitted columns: ' + r.dropped.join(', ') : '')
                );
              })
            }
          >
            Preview 20 rows
          </button>
          <button
            className="primary-button"
            disabled={busy || !cols?.length}
            onClick={() => void run(() => download(config))}
          >
            Download Excel
          </button>
        </div>
      </section>
      <p role="status">{busy ? 'Preparing export…' : message}</p>
      {preview && (
        <div className="overflow-x-auto">
          <table className="team-table">
            <caption className="sr-only">Export preview for {sheetNames[current]}</caption>
            <thead>
              <tr>
                {preview.columns.map((k) => (
                  <th scope="col" key={k}>
                    {cols.find((c) => c.key === k)?.header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {preview.rows.map((row, i) => (
                <tr key={i}>
                  {preview.columns.map((k) => (
                    <td key={k}>{String(row[k] ?? '')}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
          {!preview.rows.length && <p>No matching rows.</p>}
        </div>
      )}
    </div>
  );
}
