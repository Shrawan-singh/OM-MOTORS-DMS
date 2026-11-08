'use client';
import { useRouter } from 'next/navigation';
import { useAuth } from '@/lib/auth/provider';
import type { Filters } from '@/lib/vehicles/exports';
export function ExportLink({ dataset, filters = {} }: { dataset: string; filters?: Filters }) {
  const { can } = useAuth();
  const router = useRouter();
  if (!can('vehicles.export')) return null;
  return (
    <button
      className="secondary-button print:hidden"
      type="button"
      onClick={() => {
        const key = crypto.randomUUID();
        sessionStorage.setItem(key, JSON.stringify(filters));
        router.push('/export?dataset=' + encodeURIComponent(dataset) + '&selection=' + key);
      }}
    >
      Download Excel
    </button>
  );
}
