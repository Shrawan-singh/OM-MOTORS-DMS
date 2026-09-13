'use client';
import {useEffect,useState} from 'react';
import {useRouter} from 'next/navigation';
import {useDealerStore} from '@/lib/store/dealer-store';
import {useAuth} from '@/lib/auth/provider';
import {Search,X,ArrowRight} from 'lucide-react';
export function QuickGlobalSearch({isOpen,onClose}:{isOpen:boolean;onClose:()=>void}){
 const router=useRouter();const {customers,products,documents,inventory}=useDealerStore();const {can}=useAuth();const [query,setQuery]=useState('');
 useEffect(()=>{if(!isOpen)return;const key=(e:KeyboardEvent)=>{if(e.key==='Escape')onClose()};window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key)},[isOpen,onClose]);
 if(!isOpen)return null;
 const q=query.trim().toLowerCase();const match=(...values:unknown[])=>q&&values.join(' ').toLowerCase().includes(q);
 const groups=[
 {name:'Customers',rows:customers.filter(c=>match(c.name,c.phone,c.village)).slice(0,5).map(c=>({id:c.id,title:c.name,detail:c.phone,url:`/customers?search=${encodeURIComponent(c.phone)}`}))},
 {name:'Products',rows:can('catalogue.read')?products.filter(p=>match(p.brand,p.model_name,p.variant,p.code)).slice(0,5).map(p=>({id:p.id,title:`${p.brand} ${p.model_name} ${p.variant}`,detail:p.code,url:`/catalogue?search=${encodeURIComponent(p.model_name)}`})):[]},
 {name:'Quotations & invoices',rows:documents.filter(d=>match(d.number,d.customer_snapshot.name)).slice(0,5).map(d=>({id:d.id,title:d.number,detail:d.customer_snapshot.name,url:`/${d.kind==='invoice'?'invoices':'quotations'}/${d.id}`}))},
 {name:'Inventory',rows:inventory.filter(i=>match(i.itemName,i.skuOrCode)).slice(0,5).map(i=>({id:i.id,title:i.itemName,detail:i.skuOrCode,url:'/inventory'}))}
 ];
 return <div className="modal-overlay"><div role="dialog" aria-modal="true" aria-label="Search workspace" className="admin-panel modal-card"><div className="flex items-center gap-3"><Search size={20}/><input autoFocus className="search-field flex-1" placeholder="Search customers, products or bill numbers" value={query} onChange={e=>setQuery(e.target.value)}/><button aria-label="Close search" onClick={onClose}><X size={20}/></button></div><div className="max-h-[60vh] overflow-y-auto">{!q&&<p className="info-note">Search your saved dealership records.</p>}{q&&!groups.some(g=>g.rows.length>0)&&<p className="info-note">No matching records found.</p>}{groups.filter(g=>g.rows.length>0).map(g=><section key={g.name} className="mt-5"><h3 className="eyebrow">{g.name}</h3>{g.rows.map(r=><button key={r.id} className="w-full text-left p-3 flex items-center justify-between rounded-lg hover:bg-slate-50" onClick={()=>{router.push(r.url);onClose()}}><span><strong className="block text-sm">{r.title}</strong><small>{r.detail}</small></span><ArrowRight size={16}/></button>)}</section>)}</div></div></div>
}
