'use client';
import { useState } from 'react';
import { ArrowRight, ShieldCheck, Tractor } from 'lucide-react';
import { supabase } from '@/lib/supabase/client';
export default function Login() {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  async function login() {
    setError(''); setBusy(true);
    if (!supabase) { setError('Supabase is not configured. Contact your administrator.'); setBusy(false); return; }
    const { error } = await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: `${window.location.origin}/auth/callback`, queryParams: { prompt: 'select_account' } } });
    if (error) { setError(error.message); setBusy(false); }
  }
  return <div className="login-layout"><section className="login-story"><div className="wordmark"><Tractor size={30} /> OM MOTORS <span>WORKSPACE</span></div><div><p className="eyebrow">ONE DEALERSHIP. ONE CONNECTED WORKSPACE.</p><h1>Every customer.<br />Every journey.<br /><em>All together.</em></h1><p className="story-copy">A clearer view of your dealership. Bring your people, products and daily operations into one place.</p></div><div className="story-bottom"><span>SALES & CUSTOMER CARE</span><span>INVENTORY & SERVICE</span></div></section><section className="login-form"><div className="login-card"><span className="login-icon"><ShieldCheck size={26} /></span><p className="eyebrow">YOUR DEALERSHIP, CONNECTED</p><h2>Welcome to OM Motors</h2><p>Sign in with your approved Google account to access your workspace.</p><button className="google-button" onClick={login} disabled={busy}><svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true"><path fill="#4285F4" d="M21.6 12.2c0-.7-.1-1.4-.2-2.2H12v4.2h5.4a4.6 4.6 0 0 1-2 3v2.5h3.3c2-1.8 2.9-4.3 2.9-7.5Z"/><path fill="#34A853" d="M12 22c2.7 0 5-.9 6.7-2.4l-3.3-2.5c-.9.6-2 .9-3.4.9-2.6 0-4.8-1.8-5.6-4.1H3v2.6A10 10 0 0 0 12 22Z"/><path fill="#FBBC05" d="M6.4 13.9a6 6 0 0 1 0-3.8V7.5H3a10 10 0 0 0 0 9l3.4-2.6Z"/><path fill="#EA4335" d="M12 6c1.5 0 2.8.5 3.8 1.5l2.9-2.9A9.6 9.6 0 0 0 12 2a10 10 0 0 0-9 5.5l3.4 2.6A6 6 0 0 1 12 6Z"/></svg>{busy ? 'Connecting to Google…' : 'Continue with Google'}<ArrowRight size={18}/></button>{error && <p role="alert" className="error-message">{error}</p>}<div className="access-note"><ShieldCheck size={18}/><span>Your administrator assigns your role and permissions. New accounts need approval before accessing dealership records.</span></div><p className="login-help">Having trouble? Contact your dealership administrator.<br/>If a sign-in link expired, try signing in again.</p></div><footer>OM Motors · Dealership management</footer></section></div>;
}
