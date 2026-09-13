import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverSupabase } from '@/lib/supabase/server';
import { BillingDocument,money } from '@/lib/billing/types';
import { PrintButton } from './PrintButton';
import { DocumentSheet } from './DocumentSheet';
export async function PrintDocument({id,kind}:{id:string;kind:'invoice'|'quotation'}){
 const db=await serverSupabase();const {data:{user}}=await db.auth.getUser();if(!user)notFound();
 const {data,error}=await db.from('billing_documents').select('*').eq('id',id).eq('kind',kind).single();if(error||!data)notFound();
 const doc=data as BillingDocument;return <div className="document-frame"><div className="print-toolbar"><Link href={`/${kind==='invoice'?'invoices':'quotations'}`}>← Back to {kind}s</Link><span>Print only this document. For a clean PDF, turn off browser headers and footers.</span><PrintButton/></div><DocumentSheet doc={doc}/></div>
}
