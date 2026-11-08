'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useAuth } from '@/lib/auth/provider';
import { Search, X, ArrowRight } from 'lucide-react';
import { useVehicleQuery } from '@/lib/vehicles/register';
import { type Groups, hitUrl } from '@/lib/vehicles/exports';

interface QuickGlobalSearchProps {
  isOpen: boolean;
  onClose: () => void;
}

export function QuickGlobalSearch({ isOpen, onClose }: QuickGlobalSearchProps) {
  const router = useRouter();
  const { customers, products, documents, inventory } = useDealerStore();
  const { can } = useAuth();
  const [query, setQuery] = useState('');

  const matches = useVehicleQuery<Groups>(
    'db_search',
    { q: query, filters: {}, lim: 5 },
    200,
    isOpen && !!query.trim() && can('vehicles.read')
  );
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current;
    if (!isOpen || !element) return;
    const trigger = document.activeElement;
    element.showModal();
    return () => {
      element.close();
      if (trigger instanceof HTMLElement && trigger.isConnected) trigger.focus();
    };
  }, [isOpen]);

  if (!isOpen) return null;

  const q = query.trim().toLowerCase();
  const match = (...values: unknown[]) => q && values.join(' ').toLowerCase().includes(q);

  const groups = [
    ...(['vehicles', 'components'] as const).map((group) => ({
      name: group === 'vehicles' ? 'Vehicles' : 'Components',
      rows: (matches.data?.[group] || []).map((h) => ({
        id: h.id,
        title: h.title,
        detail: h.matched_on + ' · ' + h.detail,
        url: hitUrl(group, h),
      })),
    })),
    {
      name: 'Customers',
      rows: customers
        .filter((c) => match(c.name, c.phone, c.village))
        .slice(0, 5)
        .map((c) => ({
          id: c.id,
          title: c.name,
          detail: c.phone,
          url: `/customers?search=${encodeURIComponent(c.phone)}`,
        })),
    },
    {
      name: 'Products',
      rows: can('catalogue.read')
        ? products
            .filter((p) => match(p.brand, p.model_name, p.variant, p.code))
            .slice(0, 5)
            .map((p) => ({
              id: p.id,
              title: `${p.brand} ${p.model_name} ${p.variant}`,
              detail: p.code,
              url: `/catalogue?search=${encodeURIComponent(p.model_name)}`,
            }))
        : [],
    },
    {
      name: 'Quotations & invoices',
      rows: documents
        .filter((d) => match(d.number, d.customer_snapshot.name))
        .slice(0, 5)
        .map((d) => ({
          id: d.id,
          title: d.number,
          detail: d.customer_snapshot.name,
          url: `/${d.kind === 'invoice' ? 'invoices' : 'quotations'}/${d.id}`,
        })),
    },
    {
      name: 'Inventory',
      rows: inventory
        .filter((i) => match(i.itemName, i.skuOrCode))
        .slice(0, 5)
        .map((i) => ({
          id: i.id,
          title: i.itemName,
          detail: i.skuOrCode,
          url: '/inventory',
        })),
    },
  ];

  const hasResults = groups.some((g) => g.rows.length > 0);

  return (
    <dialog
      ref={dialog}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      aria-label="Search workspace"
      className="admin-panel modal-card workspace-search"
    >
      {/* Search input */}
      <div className="flex items-center gap-3">
        <Search size={20} />
        <input
          aria-label="Search workspace records"
          className="search-field flex-1"
          placeholder="Chassis, serial, customer, product or bill number"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <button aria-label="Close search" onClick={onClose}>
          <X size={20} />
        </button>
      </div>

      {/* Results */}
      <div className="max-h-[60vh] overflow-y-auto">
        {!q && <p className="info-note">Search your saved dealership records.</p>}
        {matches.error && (
          <p role="alert">
            {matches.error} <button onClick={matches.retry}>Retry search</button>
          </p>
        )}
        {q && !hasResults && !matches.error && (
          <p role="status" className="info-note">
            {can('vehicles.read') && !matches.data ? 'Searching…' : 'No matching records found.'}
          </p>
        )}

        {groups
          .filter((g) => g.rows.length > 0)
          .map((g) => (
            <section key={g.name} className="mt-5">
              <h3 className="eyebrow">{g.name}</h3>
              {g.rows.map((r) => (
                <button
                  key={r.id}
                  className="w-full text-left p-3 flex items-center justify-between rounded-lg hover:bg-slate-50"
                  onClick={() => {
                    router.push(r.url);
                    onClose();
                  }}
                >
                  <span>
                    <strong className="block text-sm">{r.title}</strong>
                    <small>{r.detail}</small>
                  </span>
                  <ArrowRight size={16} />
                </button>
              ))}
            </section>
          ))}
      </div>
    </dialog>
  );
}
