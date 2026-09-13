import { PrintDocument } from '@/components/billing/PrintDocument';
export const dynamic='force-dynamic';
export default async function Page({params}:{params:Promise<{id:string}>}){const {id}=await params;return <PrintDocument id={id} kind="invoice"/>}
