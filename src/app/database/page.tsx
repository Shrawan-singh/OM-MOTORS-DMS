'use client';
import { Suspense, useState } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { useAuth } from '@/lib/auth/provider';
import { useVehicleQuery, vehicleRpc, label } from '@/lib/vehicles/register';
import { hitUrl, type Groups, type Filters } from '@/lib/vehicles/exports';
import { ExportLink } from '@/components/vehicles/ExportLink';

function Search() {
  const params = useSearchParams();
  const q = params.get('q') || '';
  const [filters, setFilters] = useState<Filters>({});
  const result = useVehicleQuery<Groups>('db_search', { q, filters, lim: 50 }, 250);
  const { can } = useAuth();
  const [error, setError] = useState('');
  async function csv() {
    try {
      const data = await vehicleRpc<Groups>('db_search_export', { q, filters, lim: 50 });
      const rows = [
        ['Group', 'Record', 'Detail', 'Matched on'],
        ...Object.entries(data).flatMap(([group, hits]) =>
          hits.map((h) => [group, h.title, h.detail, h.matched_on])
        ),
      ];
      const contents = rows
        .map((row) =>
          row
            .map(
              (v) =>
                '"' +
                String(v ?? '')
                  .replace(/^[=+@-]/, (m) => "'" + m)
                  .replaceAll('"', '""') +
                '"'
            )
            .join(',')
        )
        .join('\r\n');
      const url = URL.createObjectURL(new Blob(['\ufeff', contents], { type: 'text/csv' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = 'OM-Motors_search.csv';
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'CSV export failed');
    }
  }
  return (
    <div className="space-y-4">
      <header className="page-heading">
        <h1>Database</h1>
        <ExportLink dataset="full_register" filters={{ q, ...filters, database_results: true }} />
      </header>
      <section className="admin-panel space-y-3">
        <label>
          Search the database
          <input
            autoFocus
            type="search"
            value={q}
            placeholder="Chassis, component serial, registration, customer or mobile"
            onChange={(e) => {
              const url = new URL(location.href);
              if (e.target.value) url.searchParams.set('q', e.target.value);
              else url.searchParams.delete('q');
              history.replaceState(null, '', url);
            }}
          />
        </label>
        <div className="flex flex-wrap gap-2">
          {Object.entries({
            unsold: 'Unsold',
            pdi: 'In PDI',
            status: 'Sold, awaiting delivery',
            unregistered: 'No registration',
            balance_due: 'Balance due',
          }).map(([key, title]) => (
            <button
              key={key}
              className={filters[key] ? 'primary-button' : 'secondary-button'}
              aria-pressed={!!filters[key]}
              onClick={() => {
                const f = { ...filters };
                if (f[key]) delete f[key];
                else f[key] = key === 'status' ? 'sold' : true;
                setFilters(f);
              }}
            >
              {title}
            </button>
          ))}
        </div>
      </section>
      <div className="flex gap-2 print:hidden">
        <button onClick={() => window.print()}>Print results</button>
        {can('vehicles.export') && <button onClick={() => void csv()}>Download results CSV</button>}
      </div>
      {(error || result.error) && (
        <p role="alert">
          {error || result.error} <button onClick={result.retry}>Retry</button>
        </p>
      )}
      <p role="status" className={result.data ? 'sr-only' : undefined}>
        {result.data
          ? Object.entries(result.data)
              .map(([group, hits]) => hits.length + ' ' + group)
              .join(', ')
          : result.error
            ? ''
            : 'Searching…'}
      </p>
      {result.data &&
        Object.entries(result.data).map(([group, hits]) => (
          <section key={group} className="admin-panel">
            <h2>{label(group)}</h2>
            {hits.length ? (
              <ul>
                {hits.map((h) => (
                  <li key={h.id}>
                    <Link className="underline" href={hitUrl(group, h)}>
                      {h.title}
                    </Link>{' '}
                    · {h.detail} · {h.matched_on}
                  </li>
                ))}
              </ul>
            ) : (
              <p>No matches.</p>
            )}
          </section>
        ))}
    </div>
  );
}
export default function Page() {
  return (
    <Suspense fallback={<p>Loading database…</p>}>
      <Search />
    </Suspense>
  );
}
