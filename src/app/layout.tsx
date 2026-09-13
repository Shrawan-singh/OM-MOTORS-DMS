import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { DealerStoreProvider } from '@/lib/store/dealer-store';
import { AppShell } from '@/components/layout/AppShell';
import { AuthProvider } from '@/lib/auth/provider';

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-inter',
  display: 'swap',
});

export const metadata: Metadata = {
  title: 'OM Motors — DealerOS',
  description: 'Dealership Management Operating System for New Holland Tractors, E-Rickshaws, Implements & Spares',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="font-sans antialiased text-slate-900 bg-[#FBFBFD]">
        <AuthProvider><DealerStoreProvider>
          <AppShell>{children}</AppShell>
        </DealerStoreProvider></AuthProvider>
      </body>
    </html>
  );
}
