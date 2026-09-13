'use client';
import { useEffect,useState } from 'react';
import { usePathname } from 'next/navigation';
import { Navbar } from '@/components/layout/Navbar';
import { QuickGlobalSearch } from '@/components/layout/QuickGlobalSearch';
import { useDealerStore } from '@/lib/store/dealer-store';
export function AppShell({children}:{children:React.ReactNode}){
 const [open,setOpen]=useState(false);const path=usePathname();const {loading,error,refresh}=useDealerStore();
 const standalone=path==='/login'||path==='/access-pending'||path.startsWith('/auth/')||path.endsWith('/print');
 useEffect(()=>{const key=(e:KeyboardEvent)=>{if((e.ctrlKey||e.metaKey)&&e.key==='k'){e.preventDefault();setOpen(v=>!v)}};window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key)},[]);
 if(standalone)return <>{children}</>;
 return <div className="workspace"><Navbar onOpenSearch={()=>setOpen(true)}/><main className="workspace-main">{error&&<div className="error-message" role="alert">{error} <button className="underline ml-3" onClick={()=>void refresh()}>Retry</button></div>}{loading&&<div className="sync-status" role="status">Loading saved Supabase records…</div>}{children}</main><QuickGlobalSearch isOpen={open} onClose={()=>setOpen(false)}/></div>;
}
