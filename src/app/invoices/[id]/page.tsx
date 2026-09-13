import { Suspense } from 'react';
import { DocumentEditor } from '@/components/billing/DocumentEditor';
export default async function Page({params}:{params:Promise<{id:string}>}){const {id}=await params;return <Suspense fallback={<p>Loading…</p>}><DocumentEditor kind="invoice" id={id}/></Suspense>}
