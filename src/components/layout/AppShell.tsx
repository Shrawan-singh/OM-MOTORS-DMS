'use client';

import { useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import { Navbar } from '@/components/layout/Navbar';
import { QuickGlobalSearch } from '@/components/layout/QuickGlobalSearch';
import { useDealerStore } from '@/lib/store/dealer-store';
import { SkeletonDashboard } from '@/components/ui/Skeleton';
import { ErrorBoundary } from '@/components/ui/ErrorBoundary';
import { Menu } from 'lucide-react';

export function AppShell({ children }: { children: React.ReactNode }) {
  const [searchOpen, setSearchOpen] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const path = usePathname();
  const { loading, error, refresh } = useDealerStore();

  const standalone =
    path === '/login' ||
    path === '/access-pending' ||
    path.startsWith('/auth/') ||
    path.endsWith('/print');

  // Ctrl+K shortcut for search
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
        e.preventDefault();
        setSearchOpen((v) => !v);
      }
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);

  // Close sidebar on route change
  useEffect(() => {
    setSidebarOpen(false);
  }, [path]);

  if (standalone) return <>{children}</>;

  return (
    <div className="workspace">
      {/* Mobile hamburger button */}
      <button
        className="mobile-menu-toggle"
        aria-label="Open navigation"
        onClick={() => setSidebarOpen(true)}
      >
        <Menu size={20} />
      </button>

      {/* Sidebar backdrop for mobile */}
      {sidebarOpen && (
        <div className="sidebar-backdrop" onClick={() => setSidebarOpen(false)} />
      )}

      <Navbar
        onOpenSearch={() => setSearchOpen(true)}
        sidebarOpen={sidebarOpen}
        onCloseSidebar={() => setSidebarOpen(false)}
      />

      <main className="workspace-main">
        {error && (
          <div className="error-message" role="alert">
            {error}{' '}
            <button className="underline ml-3" onClick={() => void refresh()}>
              Retry
            </button>
          </div>
        )}

        {loading && !error ? (
          <SkeletonDashboard />
        ) : (
          <ErrorBoundary>{children}</ErrorBoundary>
        )}
      </main>

      <QuickGlobalSearch isOpen={searchOpen} onClose={() => setSearchOpen(false)} />
    </div>
  );
}
