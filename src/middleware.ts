import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { routeModule } from '@/lib/auth/permissions';

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const path = request.nextUrl.pathname;
  const publicPage = path === '/login' || path === '/access-pending' || path.startsWith('/auth/');
  const redirect = (to: string) => {
    const next = NextResponse.redirect(new URL(to, request.url));
    next.headers.set('Cache-Control', 'private, no-store');
    response.cookies.getAll().forEach(cookie => next.cookies.set(cookie));
    return next;
  };
  if (!url || !key) return publicPage ? response : redirect('/login');
  const client = createServerClient(url, key, { cookies: {
    getAll: () => request.cookies.getAll(),
    setAll: (values: { name: string; value: string; options: CookieOptions }[]) => { values.forEach(({ name, value }) => request.cookies.set(name, value)); response = NextResponse.next({ request }); values.forEach(({ name, value, options }) => response.cookies.set(name, value, options)); }
  } });
  const { data: { user } } = await client.auth.getUser();
  if (!user) return publicPage ? response : redirect('/login');
  if (publicPage) { response.headers.set('Cache-Control', 'private, no-store'); return response; }
  const { data, error } = await client.rpc('my_access');
  if (error || !data?.role) return redirect('/access-pending');
  if (path === '/' && data.role !== 'owner' && !data.permissions?.includes('dashboard.read') && data.permissions?.includes('service.read')) return redirect('/service');
  const permission = `${routeModule(path)}.${path === '/quotations/new' || path === '/invoices/new' ? 'write' : 'read'}`;
  const allowed = data.role === 'owner' || (path !== '/admin' && data.permissions?.includes(permission));
  response.headers.set('Cache-Control', 'private, no-store');
  return allowed ? response : redirect('/access-pending?reason=permission');
}
export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|ico)$).*)'] };

