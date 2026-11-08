import { Suspense } from 'react';
import { ExportBuilder } from '@/components/vehicles/ExportBuilder';
export default function Page() {
  return (
    <Suspense fallback={<p>Loading export…</p>}>
      <ExportBuilder />
    </Suspense>
  );
}
