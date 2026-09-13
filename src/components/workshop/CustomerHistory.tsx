'use client';
import {useEffect,useState} from 'react';
import Link from 'next/link';
import {supabase} from '@/lib/supabase/client';
import {WorkshopData,warrantyStatus,label} from '@/lib/workshop/types';
export function CustomerHistory({id}:{id:string}){
 const [data,setData]=useState<WorkshopData|null>(null),[error,setError]=useState('');
 useEffect(()=>{let alive=true;void supabase!.rpc('ws_snapshot').then(({data,error})=>{if(alive){setData(error?null:data);setError(error?'Workshop history is unavailable until the workshop database upgrade is applied.':'')}});return()=>{alive=false}},[id]);
 return <section className="ws-section"><h3>Vehicles & workshop history</h3>{error&&<p className="ws-muted">{error}</p>}{data?.vehicles.filter(v=>v.customer_id===id).map(v=><p key={v.id} className="ws-event"><strong>{v.model_name} {v.variant}</strong><small>{v.chassis_no} · {v.registration_no||'No registration recorded'}</small></p>)}{data?.jobs.filter(j=>j.customer_id===id).map(j=><Link className="ws-history-link" href={`/service?job=${j.id}`} key={j.id}>{j.number} · {j.received_at} · {label(j.status)}<small className="block">{j.complaint} · {j.parts_used.length} parts entries</small></Link>)}{data?.warranties.filter(w=>w.customer_id===id).map(w=><p className="ws-event" key={w.id}>{w.product_name} · {w.serial_no}<small>{warrantyStatus(w)} · expires {w.end_date}</small></p>)}</section>
}
