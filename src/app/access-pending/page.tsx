'use client';
import Link from 'next/link';
import { ShieldCheck } from 'lucide-react';
import { supabase } from '@/lib/supabase/client';
export default function Pending() { return <div className="pending-page"><div className="card-apple p-10 max-w-lg"><ShieldCheck className="text-blue-800 mb-6" size={36}/><h1 className="text-2xl font-semibold mb-3">Access needs administrator approval</h1><p className="text-slate-500 leading-7">Your account has no assigned role, or your role does not include access to this page. Ask your administrator to approve your Google email or update your permissions.</p><div className="flex gap-3 mt-7"><Link className="primary-button" href="/">Check access again</Link><button className="secondary-button" onClick={async () => { await supabase?.auth.signOut(); window.location.assign('/login'); }}>Sign out</button></div></div></div>; }
