import { Suspense } from 'react';
import { DocumentEditor } from '@/components/billing/DocumentEditor';
export default function Page(){return <Suspense fallback={<p>Loading…</p>}><DocumentEditor kind="quotation"/></Suspense>}
