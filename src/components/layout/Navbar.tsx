'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import {
  Tractor,
  LayoutDashboard,
  Users,
  Package,
  FileText,
  Receipt,
  CreditCard,
  Wrench,
  Search,
  ShieldCheck,
  LogOut,
  BookOpen,
  History,
} from 'lucide-react';
import { useAuth } from '@/lib/auth/provider';
import { roleLabels } from '@/lib/auth/permissions';
import { supabase } from '@/lib/supabase/client';

interface NavbarProps {
  onOpenSearch: () => void;
  sidebarOpen?: boolean;
  onCloseSidebar?: () => void;
}

const navLinks = [
  { href: '/', label: 'Overview', icon: LayoutDashboard, permission: 'dashboard.read' },
  { href: '/catalogue', label: 'Product catalogue', icon: BookOpen, permission: 'catalogue.read' },
  { href: '/customers', label: 'Customers', icon: Users, permission: 'customers.read' },
  { href: '/inventory', label: 'Inventory', icon: Package, permission: 'inventory.read' },
  { href: '/quotations', label: 'Quotations', icon: FileText, permission: 'quotations.read' },
  { href: '/invoices', label: 'Invoices & payments', icon: Receipt, permission: 'invoices.read' },
  { href: '/receivables', label: 'Receivables', icon: CreditCard, permission: 'invoices.read' },
  { href: '/service', label: 'Service & PDI', icon: Wrench, permission: 'service.read' },
];

export function Navbar({ onOpenSearch, sidebarOpen, onCloseSidebar }: NavbarProps) {
  const path = usePathname();
  const { email, role, can } = useAuth();

  const handleSignOut = async () => {
    await supabase?.auth.signOut();
    window.location.assign('/login');
  };

  const currentPageLabel =
    path === '/admin'
      ? 'Team & permissions'
      : path === '/admin/audit'
      ? 'Audit logs'
      : navLinks.find((l) => l.href === path)?.label || 'Dealership';

  return (
    <>
      {/* Sidebar */}
      <aside className={`app-sidebar${sidebarOpen ? ' sidebar-open' : ''}`}>
        <Link href="/" className="sidebar-brand" onClick={onCloseSidebar}>
          <span>
            <Tractor size={24} />
          </span>
          <div>
            OM MOTORS
            <small>DEALERSHIP WORKSPACE</small>
          </div>
        </Link>

        <p className="nav-caption">WORKSPACE</p>

        <nav>
          {navLinks
            .filter((l) => can(l.permission))
            .map((l) => (
              <Link
                key={l.href}
                href={l.href}
                className={
                  path === l.href || (l.href !== '/' && path.startsWith(l.href))
                    ? 'active'
                    : ''
                }
                onClick={onCloseSidebar}
              >
                <l.icon size={18} />
                {l.label}
              </Link>
            ))}
        </nav>

        {role === 'owner' && (
          <>
            <p className="nav-caption">ADMINISTRATION</p>
            <nav>
              <Link
                href="/admin"
                className={path === '/admin' ? 'active' : ''}
                onClick={onCloseSidebar}
              >
                <ShieldCheck size={18} />
                Team & permissions
              </Link>
              <Link
                href="/admin/audit"
                className={path === '/admin/audit' ? 'active' : ''}
                onClick={onCloseSidebar}
              >
                <History size={18} />
                Audit logs
              </Link>
            </nav>
          </>
        )}

        {/* User info & sign out */}
        <div className="sidebar-bottom">
          <span className="avatar">{email.slice(0, 1).toUpperCase() || 'O'}</span>
          <div>
            <strong>{roleLabels[role || ''] || 'Staff member'}</strong>
            <small title={email}>{email}</small>
          </div>
          <button aria-label="Sign out" onClick={handleSignOut}>
            <LogOut size={17} />
          </button>
        </div>
      </aside>

      {/* Top bar */}
      <header className="workspace-topbar">
        <span>
          Workspace <span className="text-slate-300 mx-3">/</span>
          <strong>{currentPageLabel}</strong>
        </span>
        <button onClick={onOpenSearch} className="search-trigger">
          <Search size={16} />
          <span>Search your workspace</span>
          <kbd>Ctrl K</kbd>
        </button>
      </header>
    </>
  );
}
