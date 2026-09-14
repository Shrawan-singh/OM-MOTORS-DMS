'use client';

import React, { useState, useMemo } from 'react';
import Link from 'next/link';
import {
  Receipt,
  Search,
  Filter,
  CreditCard,
  MessageSquare,
  PhoneCall,
  Calendar,
  AlertTriangle,
  Clock,
  CheckCircle2,
  XCircle,
  FileText,
  Printer,
  ChevronRight,
  ArrowUpRight,
  Plus,
  RefreshCw,
  X,
  Building,
  UserCheck
} from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useAuth } from '@/lib/auth/provider';
import {
  BillingDocument,
  money,
  getDaysOverdue,
  getAgingBucket,
  AgingCategory
} from '@/lib/billing/types';
import { WhatsAppReminderModal } from '@/components/receivables/WhatsAppReminderModal';
import { FollowupModal } from '@/components/receivables/FollowupModal';
import { CustomerLedgerModal } from '@/components/receivables/CustomerLedgerModal';

export default function ReceivablesPage() {
  const {
    documents,
    customers,
    payments,
    collectionFollowups,
    recordPayment,
    updateFollowupStatus,
    loading,
    refresh,
  } = useDealerStore();
  const { can } = useAuth();

  const [activeTab, setActiveTab] = useState<'aging' | 'customers' | 'ptp'>('aging');
  const [searchQuery, setSearchQuery] = useState('');
  const [bucketFilter, setBucketFilter] = useState<string>('all');
  const [ptpFilter, setPtpFilter] = useState<string>('pending');

  // Modals state
  const [paymentTarget, setPaymentTarget] = useState<BillingDocument | null>(null);
  const [payAmount, setPayAmount] = useState('');
  const [payMethod, setPayMethod] = useState('upi');
  const [payRef, setPayRef] = useState('');
  const [payRequestId, setPayRequestId] = useState('');
  const [payBusy, setPayBusy] = useState(false);
  const [payError, setPayError] = useState('');

  const [whatsappTarget, setWhatsappTarget] = useState<{
    customer: { id: string; name: string; phone: string; village: string };
    invoice?: BillingDocument | null;
    outstandingAmount: number;
  } | null>(null);

  const [followupTarget, setFollowupTarget] = useState<{
    customer: { id: string; name: string; phone: string; village: string };
    invoice?: BillingDocument | null;
    outstandingAmount: number;
  } | null>(null);

  const [ledgerCustomerId, setLedgerCustomerId] = useState<string | null>(null);

  // Invoices with balance due
  const unpaidInvoices = useMemo(() => {
    return documents
      .filter((d) => d.kind === 'invoice' && d.total > d.amount_paid)
      .map((d) => {
        const daysOverdue = getDaysOverdue(d.due_date, d.document_date);
        const bucket = getAgingBucket(daysOverdue);
        return {
          ...d,
          balance_due: d.total - d.amount_paid,
          days_overdue: daysOverdue,
          bucket,
        };
      });
  }, [documents]);

  // Aging Summary Metrics
  const agingStats = useMemo(() => {
    let totalOutstanding = 0;
    let totalOverdue = 0;
    let countOverdue = 0;
    let bCurrent = 0;
    let b1_30 = 0;
    let b31_60 = 0;
    let b61_90 = 0;
    let b90Plus = 0;

    unpaidInvoices.forEach((inv) => {
      totalOutstanding += inv.balance_due;
      if (inv.days_overdue > 0) {
        totalOverdue += inv.balance_due;
        countOverdue++;
      }

      switch (inv.bucket) {
        case 'current':
          bCurrent += inv.balance_due;
          break;
        case '1_30':
          b1_30 += inv.balance_due;
          break;
        case '31_60':
          b31_60 += inv.balance_due;
          break;
        case '61_90':
          b61_90 += inv.balance_due;
          break;
        case '90_plus':
          b90Plus += inv.balance_due;
          break;
      }
    });

    return {
      totalOutstanding,
      totalOverdue,
      countOverdue,
      bCurrent,
      b1_30,
      b31_60,
      b61_90,
      b90Plus,
    };
  }, [unpaidInvoices]);

  // Filtered Invoices for Tab 1
  const filteredInvoices = useMemo(() => {
    const q = searchQuery.toLowerCase().trim();
    return unpaidInvoices.filter((inv) => {
      const matchQuery =
        !q ||
        inv.number.toLowerCase().includes(q) ||
        inv.customer_snapshot.name.toLowerCase().includes(q) ||
        inv.customer_snapshot.phone.includes(q) ||
        inv.customer_snapshot.village.toLowerCase().includes(q);

      const matchBucket = bucketFilter === 'all' || inv.bucket === bucketFilter;

      return matchQuery && matchBucket;
    });
  }, [unpaidInvoices, searchQuery, bucketFilter]);

  // Customer Balances for Tab 2
  const customerBalances = useMemo(() => {
    const map = new Map<
      string,
      {
        id: string;
        name: string;
        phone: string;
        village: string;
        creditLimit: number;
        termsDays: number;
        priority: string;
        invoiceCount: number;
        totalBilled: number;
        totalPaid: number;
        balanceDue: number;
        overdueAmount: number;
        maxDaysOverdue: number;
      }
    >();

    // Initial pass over all customers with invoices
    documents
      .filter((d) => d.kind === 'invoice')
      .forEach((d) => {
        const custId = d.customer_id;
        const cust = customers.find((c) => c.id === custId);
        const daysOverdue = getDaysOverdue(d.due_date, d.document_date);
        const due = d.total - d.amount_paid;

        if (!map.has(custId)) {
          map.set(custId, {
            id: custId,
            name: d.customer_snapshot.name || cust?.name || 'Customer',
            phone: d.customer_snapshot.phone || cust?.phone || '',
            village: d.customer_snapshot.village || cust?.village || '',
            creditLimit: cust?.creditLimit || 0,
            termsDays: cust?.paymentTermsDays || 15,
            priority: cust?.collectionPriority || 'normal',
            invoiceCount: 0,
            totalBilled: 0,
            totalPaid: 0,
            balanceDue: 0,
            overdueAmount: 0,
            maxDaysOverdue: 0,
          });
        }

        const entry = map.get(custId)!;
        entry.invoiceCount++;
        entry.totalBilled += d.total;
        entry.totalPaid += d.amount_paid;
        entry.balanceDue += due;
        if (due > 0 && daysOverdue > 0) {
          entry.overdueAmount += due;
          if (daysOverdue > entry.maxDaysOverdue) {
            entry.maxDaysOverdue = daysOverdue;
          }
        }
      });

    const list = Array.from(map.values());
    const q = searchQuery.toLowerCase().trim();
    return list.filter((c) => {
      if (c.balanceDue <= 0 && bucketFilter !== 'all') return false;
      return (
        !q ||
        c.name.toLowerCase().includes(q) ||
        c.phone.includes(q) ||
        c.village.toLowerCase().includes(q)
      );
    }).sort((a, b) => b.balanceDue - a.balanceDue);
  }, [documents, customers, searchQuery, bucketFilter]);

  // Followups list for Tab 3
  const filteredFollowups = useMemo(() => {
    return collectionFollowups.filter((f) => {
      if (ptpFilter === 'pending') return f.status === 'pending';
      if (ptpFilter === 'all') return true;
      return f.status === ptpFilter;
    }).sort((a, b) => (b.ptp_date || b.contacted_at).localeCompare(a.ptp_date || a.contacted_at));
  }, [collectionFollowups, ptpFilter]);

  // Payment Handler
  async function handleRecordPayment(e: React.FormEvent) {
    e.preventDefault();
    if (!paymentTarget) return;
    setPayBusy(true);
    setPayError('');
    try {
      await recordPayment(
        paymentTarget.id,
        Number(payAmount),
        payMethod,
        payRef,
        payRequestId
      );
      setPaymentTarget(null);
    } catch (err: any) {
      setPayError(err?.message || 'Payment recording failed');
    } finally {
      setPayBusy(false);
    }
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-xs font-semibold text-brand-900 tracking-wide uppercase">
            <Receipt className="w-4 h-4" />
            Receivables & Collections
          </div>
          <h1 className="text-2xl font-bold text-slate-900 mt-1 tracking-tight">
            Receivables Management
          </h1>
          <p className="text-xs text-slate-500">
            {unpaidInvoices.length} outstanding invoices · Aging analysis, follow-ups, and payment reminders
          </p>
        </div>

        <div className="flex items-center gap-2 self-start sm:self-auto">
          <button
            onClick={() => void refresh()}
            disabled={loading}
            className="secondary-button text-xs py-2 px-3 inline-flex items-center gap-1.5"
            title="Refresh receivables"
          >
            <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <Link
            href="/invoices/new"
            className="primary-button text-xs py-2 px-3.5 inline-flex items-center gap-1.5 shadow-sm"
          >
            <Plus size={15} />
            New Invoice
          </Link>
        </div>
      </div>

      {/* Top Aging Summary KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-brand-900 shadow-xs">
          <span className="text-[11px] font-semibold text-slate-500 uppercase tracking-wider block">
            Total Outstanding
          </span>
          <strong className="text-base sm:text-lg font-bold text-slate-900 mt-1 block">
            {money(agingStats.totalOutstanding)}
          </strong>
          <span className="text-[10px] text-slate-400 mt-0.5 block">
            {unpaidInvoices.length} unpaid invoices
          </span>
        </div>

        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-amber-600 shadow-xs">
          <span className="text-[11px] font-semibold text-amber-700 uppercase tracking-wider block">
            Total Overdue
          </span>
          <strong className="text-base sm:text-lg font-bold text-amber-800 mt-1 block">
            {money(agingStats.totalOverdue)}
          </strong>
          <span className="text-[10px] text-amber-600 mt-0.5 block">
            {agingStats.countOverdue} invoices past due
          </span>
        </div>

        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-emerald-500 shadow-xs">
          <span className="text-[11px] font-semibold text-slate-500 uppercase tracking-wider block">
            Current (0–30 Days)
          </span>
          <strong className="text-base sm:text-lg font-bold text-slate-900 mt-1 block">
            {money(agingStats.bCurrent)}
          </strong>
          <span className="text-[10px] text-emerald-600 mt-0.5 block">Within payment terms</span>
        </div>

        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-amber-500 shadow-xs">
          <span className="text-[11px] font-semibold text-slate-500 uppercase tracking-wider block">
            31–60 Days
          </span>
          <strong className="text-base sm:text-lg font-bold text-slate-900 mt-1 block">
            {money(agingStats.b1_30)}
          </strong>
          <span className="text-[10px] text-slate-400 mt-0.5 block">1–30 days overdue</span>
        </div>

        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-orange-500 shadow-xs">
          <span className="text-[11px] font-semibold text-slate-500 uppercase tracking-wider block">
            61–90 Days
          </span>
          <strong className="text-base sm:text-lg font-bold text-slate-900 mt-1 block">
            {money(agingStats.b31_60)}
          </strong>
          <span className="text-[10px] text-orange-600 mt-0.5 block">31–60 days overdue</span>
        </div>

        <div className="admin-panel p-3.5 bg-white border-l-4 border-l-rose-600 shadow-xs">
          <span className="text-[11px] font-semibold text-slate-500 uppercase tracking-wider block">
            90+ Days (Critical)
          </span>
          <strong className="text-base sm:text-lg font-bold text-rose-700 mt-1 block">
            {money(agingStats.b90Plus)}
          </strong>
          <span className="text-[10px] text-rose-600 mt-0.5 block">Immediate recovery</span>
        </div>
      </div>

      {/* Tabs Navigation */}
      <div className="flex border-b border-slate-200">
        <button
          onClick={() => setActiveTab('aging')}
          className={`py-3 px-5 text-xs font-semibold border-b-2 transition-all ${
            activeTab === 'aging'
              ? 'border-brand-900 text-brand-900'
              : 'border-transparent text-slate-500 hover:text-slate-700'
          }`}
        >
          Outstanding Invoices & Aging ({unpaidInvoices.length})
        </button>
        <button
          onClick={() => setActiveTab('customers')}
          className={`py-3 px-5 text-xs font-semibold border-b-2 transition-all ${
            activeTab === 'customers'
              ? 'border-brand-900 text-brand-900'
              : 'border-transparent text-slate-500 hover:text-slate-700'
          }`}
        >
          Customer Balances & Terms ({customerBalances.filter((c) => c.balanceDue > 0).length})
        </button>
        <button
          onClick={() => setActiveTab('ptp')}
          className={`py-3 px-5 text-xs font-semibold border-b-2 transition-all ${
            activeTab === 'ptp'
              ? 'border-brand-900 text-brand-900'
              : 'border-transparent text-slate-500 hover:text-slate-700'
          }`}
        >
          Promises to Pay (PTP) & Follow-ups ({collectionFollowups.length})
        </button>
      </div>

      {/* TAB 1: OUTSTANDING INVOICES & AGING */}
      {activeTab === 'aging' && (
        <section className="space-y-4">
          {/* Filters Bar */}
          <div className="flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3">
            <div className="relative flex-1">
              <Search className="w-4 h-4 text-slate-400 absolute left-3.5 top-1/2 -translate-y-1/2" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search invoice number, customer name, phone, village..."
                className="w-full pl-10 pr-4 py-2 text-xs rounded-xl border border-slate-200 bg-white text-slate-900 focus:outline-none focus:border-brand-900"
              />
            </div>

            <div className="flex items-center gap-2">
              <Filter className="w-3.5 h-3.5 text-slate-400" />
              <select
                value={bucketFilter}
                onChange={(e) => setBucketFilter(e.target.value)}
                className="py-2 px-3 text-xs rounded-xl border border-slate-200 bg-white text-slate-700"
              >
                <option value="all">All Aging Buckets</option>
                <option value="current">Current (Not Overdue)</option>
                <option value="1_30">1–30 Days Overdue</option>
                <option value="31_60">31–60 Days Overdue</option>
                <option value="61_90">61–90 Days Overdue</option>
                <option value="90_plus">90+ Days Overdue (Critical)</option>
              </select>
            </div>
          </div>

          {/* Invoices Table */}
          <div className="overflow-x-auto border border-slate-200 rounded-2xl bg-white shadow-xs">
            <table className="w-full text-left text-xs border-collapse">
              <thead>
                <tr className="bg-slate-50 border-b border-slate-200 text-slate-600">
                  <th className="py-3 px-3.5 font-semibold">Invoice & Date</th>
                  <th className="py-3 px-3.5 font-semibold">Customer</th>
                  <th className="py-3 px-3.5 font-semibold">Due Date</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Invoice Total</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Paid</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Balance Due</th>
                  <th className="py-3 px-3.5 font-semibold">Aging Status</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filteredInvoices.length === 0 ? (
                  <tr>
                    <td colSpan={8} className="py-12 text-center text-slate-400">
                      No outstanding invoices matching this filter.
                    </td>
                  </tr>
                ) : (
                  filteredInvoices.map((inv) => {
                    const isOverdue = inv.days_overdue > 0;
                    const cust = customers.find((c) => c.id === inv.customer_id);

                    return (
                      <tr key={inv.id} className="hover:bg-slate-50/60 transition-colors">
                        {/* Invoice & Date */}
                        <td className="py-3 px-3.5">
                          <Link
                            href={`/invoices/${inv.id}/print`}
                            target="_blank"
                            className="font-bold text-slate-900 hover:text-brand-900 inline-flex items-center gap-1"
                          >
                            {inv.number}
                            <ArrowUpRight size={12} className="text-slate-400" />
                          </Link>
                          <div className="text-[11px] text-slate-400 mt-0.5">{inv.document_date}</div>
                        </td>

                        {/* Customer */}
                        <td className="py-3 px-3.5">
                          <strong className="text-slate-900 block">{inv.customer_snapshot.name}</strong>
                          <span className="text-[11px] text-slate-500 block">
                            📞 {inv.customer_snapshot.phone} · 📍 {inv.customer_snapshot.village}
                          </span>
                        </td>

                        {/* Due Date */}
                        <td className="py-3 px-3.5 whitespace-nowrap">
                          <span className="font-mono text-slate-700">
                            {inv.due_date || inv.document_date}
                          </span>
                        </td>

                        {/* Financials */}
                        <td className="py-3 px-3.5 text-right font-mono text-slate-700">
                          {money(inv.total)}
                        </td>
                        <td className="py-3 px-3.5 text-right font-mono text-emerald-700">
                          {money(inv.amount_paid)}
                        </td>
                        <td className="py-3 px-3.5 text-right font-mono font-bold text-slate-900">
                          {money(inv.balance_due)}
                        </td>

                        {/* Aging Badge */}
                        <td className="py-3 px-3.5">
                          {isOverdue ? (
                            <span
                              className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-[11px] font-semibold border ${
                                inv.days_overdue > 90
                                  ? 'bg-rose-50 text-rose-700 border-rose-200'
                                  : inv.days_overdue > 60
                                  ? 'bg-orange-50 text-orange-700 border-orange-200'
                                  : 'bg-amber-50 text-amber-700 border-amber-200'
                              }`}
                            >
                              <AlertTriangle size={11} />
                              {inv.days_overdue} days overdue
                            </span>
                          ) : (
                            <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-[11px] font-semibold bg-emerald-50 text-emerald-700 border border-emerald-200">
                              <CheckCircle2 size={11} />
                              Current
                            </span>
                          )}
                        </td>

                        {/* Action Buttons */}
                        <td className="py-3 px-3.5 text-right whitespace-nowrap">
                          <div className="inline-flex items-center gap-1.5">
                            {can('invoices.write') && (
                              <button
                                onClick={() => {
                                  setPaymentTarget(inv);
                                  setPayAmount(String(inv.balance_due));
                                  setPayRequestId(crypto.randomUUID());
                                  setPayRef('');
                                  setPayError('');
                                }}
                                className="touch-target px-2.5 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white font-semibold text-xs inline-flex items-center gap-1 shadow-xs"
                                title="Collect payment"
                              >
                                <CreditCard size={13} /> Pay
                              </button>
                            )}

                            <button
                              onClick={() => {
                                setWhatsappTarget({
                                  customer: {
                                    id: inv.customer_id,
                                    name: inv.customer_snapshot.name,
                                    phone: inv.customer_snapshot.phone,
                                    village: inv.customer_snapshot.village,
                                  },
                                  invoice: inv,
                                  outstandingAmount: inv.balance_due,
                                });
                              }}
                              className="touch-target p-1.5 rounded-lg bg-emerald-50 hover:bg-emerald-100 text-emerald-700 border border-emerald-200"
                              title="Send WhatsApp Reminder"
                            >
                              <MessageSquare size={14} />
                            </button>

                            <button
                              onClick={() => {
                                setFollowupTarget({
                                  customer: {
                                    id: inv.customer_id,
                                    name: inv.customer_snapshot.name,
                                    phone: inv.customer_snapshot.phone,
                                    village: inv.customer_snapshot.village,
                                  },
                                  invoice: inv,
                                  outstandingAmount: inv.balance_due,
                                });
                              }}
                              className="touch-target p-1.5 rounded-lg bg-slate-100 hover:bg-slate-200 text-slate-700"
                              title="Log Call / Follow-up"
                            >
                              <PhoneCall size={14} />
                            </button>

                            <button
                              onClick={() => setLedgerCustomerId(inv.customer_id)}
                              className="touch-target p-1.5 rounded-lg bg-slate-100 hover:bg-slate-200 text-slate-700"
                              title="View Customer Statement / Ledger"
                            >
                              <FileText size={14} />
                            </button>
                          </div>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {/* TAB 2: CUSTOMER BALANCES & TERMS */}
      {activeTab === 'customers' && (
        <section className="space-y-4">
          <div className="relative">
            <Search className="w-4 h-4 text-slate-400 absolute left-3.5 top-1/2 -translate-y-1/2" />
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search customer by name, phone, or village..."
              className="w-full pl-10 pr-4 py-2 text-xs rounded-xl border border-slate-200 bg-white text-slate-900 focus:outline-none focus:border-brand-900"
            />
          </div>

          <div className="overflow-x-auto border border-slate-200 rounded-2xl bg-white shadow-xs">
            <table className="w-full text-left text-xs border-collapse">
              <thead>
                <tr className="bg-slate-50 border-b border-slate-200 text-slate-600">
                  <th className="py-3 px-3.5 font-semibold">Customer</th>
                  <th className="py-3 px-3.5 font-semibold">Location</th>
                  <th className="py-3 px-3.5 font-semibold text-center">Invoices</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Total Billed</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Total Paid</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Balance Due</th>
                  <th className="py-3 px-3.5 font-semibold">Credit Limit</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {customerBalances.length === 0 ? (
                  <tr>
                    <td colSpan={8} className="py-12 text-center text-slate-400">
                      No customer balance records found.
                    </td>
                  </tr>
                ) : (
                  customerBalances.map((cust) => (
                    <tr key={cust.id} className="hover:bg-slate-50/60 transition-colors">
                      <td className="py-3 px-3.5">
                        <strong className="text-slate-900 block">{cust.name}</strong>
                        <span className="text-[11px] text-slate-500">📞 {cust.phone}</span>
                      </td>
                      <td className="py-3 px-3.5 text-slate-600">📍 {cust.village}</td>
                      <td className="py-3 px-3.5 text-center font-mono">{cust.invoiceCount}</td>
                      <td className="py-3 px-3.5 text-right font-mono text-slate-700">{money(cust.totalBilled)}</td>
                      <td className="py-3 px-3.5 text-right font-mono text-emerald-700">{money(cust.totalPaid)}</td>
                      <td className="py-3 px-3.5 text-right font-mono font-bold text-slate-900">
                        <span className={cust.balanceDue > 0 ? 'text-amber-700' : 'text-emerald-700'}>
                          {money(cust.balanceDue)}
                        </span>
                      </td>
                      <td className="py-3 px-3.5">
                        {cust.creditLimit > 0 ? (
                          <div>
                            <span className="font-semibold text-slate-800">{money(cust.creditLimit)}</span>
                            <span className="text-[10px] text-slate-400 block">{cust.termsDays} days term</span>
                          </div>
                        ) : (
                          <span className="text-slate-400">—</span>
                        )}
                      </td>
                      <td className="py-3 px-3.5 text-right whitespace-nowrap">
                        <div className="inline-flex items-center gap-1.5">
                          {cust.balanceDue > 0 && (
                            <button
                              onClick={() => {
                                setWhatsappTarget({
                                  customer: {
                                    id: cust.id,
                                    name: cust.name,
                                    phone: cust.phone,
                                    village: cust.village,
                                  },
                                  invoice: null,
                                  outstandingAmount: cust.balanceDue,
                                });
                              }}
                              className="touch-target p-1.5 rounded-lg bg-emerald-50 hover:bg-emerald-100 text-emerald-700 border border-emerald-200"
                              title="Send WhatsApp Reminder"
                            >
                              <MessageSquare size={14} />
                            </button>
                          )}

                          <button
                            onClick={() => {
                              setFollowupTarget({
                                customer: {
                                  id: cust.id,
                                  name: cust.name,
                                  phone: cust.phone,
                                  village: cust.village,
                                },
                                invoice: null,
                                outstandingAmount: cust.balanceDue,
                              });
                            }}
                            className="touch-target p-1.5 rounded-lg bg-slate-100 hover:bg-slate-200 text-slate-700"
                            title="Log Follow-up"
                          >
                            <PhoneCall size={14} />
                          </button>

                          <button
                            onClick={() => setLedgerCustomerId(cust.id)}
                            className="touch-target px-2.5 py-1.5 rounded-lg bg-slate-100 hover:bg-slate-200 text-slate-700 font-semibold text-xs inline-flex items-center gap-1"
                            title="View Statement / Ledger"
                          >
                            <FileText size={13} /> Statement
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {/* TAB 3: PROMISES TO PAY (PTP) & FOLLOW-UPS */}
      {activeTab === 'ptp' && (
        <section className="space-y-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <span className="text-xs font-semibold text-slate-600">Status:</span>
              <select
                value={ptpFilter}
                onChange={(e) => setPtpFilter(e.target.value)}
                className="py-1.5 px-3 text-xs rounded-xl border border-slate-200 bg-white"
              >
                <option value="pending">Pending Promises</option>
                <option value="honoured">Honoured</option>
                <option value="broken">Broken Promises</option>
                <option value="all">All Follow-ups</option>
              </select>
            </div>
          </div>

          <div className="overflow-x-auto border border-slate-200 rounded-2xl bg-white shadow-xs">
            <table className="w-full text-left text-xs border-collapse">
              <thead>
                <tr className="bg-slate-50 border-b border-slate-200 text-slate-600">
                  <th className="py-3 px-3.5 font-semibold">Contacted Date</th>
                  <th className="py-3 px-3.5 font-semibold">Customer</th>
                  <th className="py-3 px-3.5 font-semibold">Mode</th>
                  <th className="py-3 px-3.5 font-semibold">Remarks / Discussion Notes</th>
                  <th className="py-3 px-3.5 font-semibold">Promised Date (PTP)</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Promised Amount</th>
                  <th className="py-3 px-3.5 font-semibold">Status</th>
                  <th className="py-3 px-3.5 font-semibold text-right">Update</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filteredFollowups.length === 0 ? (
                  <tr>
                    <td colSpan={8} className="py-12 text-center text-slate-400">
                      No follow-up records found.
                    </td>
                  </tr>
                ) : (
                  filteredFollowups.map((f) => {
                    const cust = customers.find((c) => c.id === f.customer_id);

                    return (
                      <tr key={f.id} className="hover:bg-slate-50/60 transition-colors">
                        <td className="py-3 px-3.5 font-mono text-slate-600 whitespace-nowrap">
                          {f.contacted_at.slice(0, 10)}
                        </td>
                        <td className="py-3 px-3.5">
                          <strong className="text-slate-900 block">{cust?.name || 'Customer'}</strong>
                          <span className="text-[11px] text-slate-500">📞 {cust?.phone}</span>
                        </td>
                        <td className="py-3 px-3.5 uppercase font-medium text-[11px] text-slate-600">
                          {f.contact_method}
                        </td>
                        <td className="py-3 px-3.5 text-slate-700 max-w-xs">{f.notes}</td>
                        <td className="py-3 px-3.5 font-mono whitespace-nowrap">
                          {f.ptp_date || '—'}
                        </td>
                        <td className="py-3 px-3.5 text-right font-mono font-semibold text-slate-900">
                          {f.ptp_amount ? money(f.ptp_amount) : '—'}
                        </td>
                        <td className="py-3 px-3.5">
                          <span
                            className={`inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-semibold ${
                              f.status === 'honoured'
                                ? 'bg-emerald-50 text-emerald-700 border border-emerald-200'
                                : f.status === 'broken'
                                ? 'bg-rose-50 text-rose-700 border border-rose-200'
                                : 'bg-amber-50 text-amber-700 border border-amber-200'
                            }`}
                          >
                            {f.status.toUpperCase()}
                          </span>
                        </td>
                        <td className="py-3 px-3.5 text-right whitespace-nowrap">
                          {f.status === 'pending' && can('invoices.write') ? (
                            <div className="inline-flex items-center gap-1">
                              <button
                                onClick={() => updateFollowupStatus(f.id, 'honoured')}
                                className="px-2 py-1 bg-emerald-50 hover:bg-emerald-100 text-emerald-700 rounded text-[11px] font-semibold border border-emerald-200"
                                title="Mark as Honoured"
                              >
                                Honoured
                              </button>
                              <button
                                onClick={() => updateFollowupStatus(f.id, 'broken')}
                                className="px-2 py-1 bg-rose-50 hover:bg-rose-100 text-rose-700 rounded text-[11px] font-semibold border border-rose-200"
                                title="Mark as Broken"
                              >
                                Broken
                              </button>
                            </div>
                          ) : (
                            <span className="text-slate-400 text-[11px]">Logged</span>
                          )}
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {/* MODAL 1: RECORD PAYMENT */}
      {paymentTarget && (
        <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Record payment">
          <form onSubmit={handleRecordPayment} className="admin-panel modal-card max-w-md w-full">
            <div className="panel-heading border-b pb-3 mb-4 flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold text-slate-900">Record Payment</h2>
                <p className="text-xs text-slate-500">
                  {paymentTarget.number} · {paymentTarget.customer_snapshot.name}
                </p>
              </div>
              <button
                type="button"
                onClick={() => setPaymentTarget(null)}
                disabled={payBusy}
                className="p-1 rounded-lg text-slate-400 hover:text-slate-700"
                aria-label="Close"
              >
                <X size={18} />
              </button>
            </div>

            {payError && (
              <div className="error-message mb-4" role="alert">
                {payError}
              </div>
            )}

            <div className="space-y-3 text-xs">
              <label className="block">
                <span className="font-semibold text-slate-700">Amount to Receive (₹) *</span>
                <input
                  required
                  type="number"
                  step="0.01"
                  min="0.01"
                  max={paymentTarget.total - paymentTarget.amount_paid}
                  value={payAmount}
                  onChange={(e) => setPayAmount(e.target.value)}
                  className="w-full p-2.5 mt-1 border border-slate-200 rounded-xl font-mono text-sm"
                />
              </label>

              <label className="block">
                <span className="font-semibold text-slate-700">Payment Method</span>
                <select
                  value={payMethod}
                  onChange={(e) => setPayMethod(e.target.value)}
                  className="w-full p-2.5 mt-1 border border-slate-200 rounded-xl bg-white"
                >
                  <option value="upi">UPI / QR Code</option>
                  <option value="cash">Cash</option>
                  <option value="bank_transfer">Bank Transfer (NEFT/RTGS/IMPS)</option>
                  <option value="cheque">Cheque</option>
                  <option value="finance">Financier / Loan Disbursal</option>
                </select>
              </label>

              <label className="block">
                <span className="font-semibold text-slate-700">UTR / Reference / Cheque No.</span>
                <input
                  value={payRef}
                  onChange={(e) => setPayRef(e.target.value)}
                  placeholder="e.g. UPI Ref, Bank UTR, Cheque No."
                  className="w-full p-2.5 mt-1 border border-slate-200 rounded-xl font-mono"
                />
              </label>
            </div>

            <div className="flex items-center justify-end gap-2 pt-4 mt-4 border-t border-slate-100">
              <button
                type="button"
                onClick={() => setPaymentTarget(null)}
                disabled={payBusy}
                className="px-4 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-100 rounded-xl"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={payBusy}
                className="primary-button text-xs py-2 px-4 shadow-sm"
              >
                {payBusy ? 'Recording…' : 'Record Payment'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* MODAL 2: WHATSAPP REMINDER */}
      {whatsappTarget && (
        <WhatsAppReminderModal
          customer={whatsappTarget.customer}
          invoice={whatsappTarget.invoice}
          outstandingAmount={whatsappTarget.outstandingAmount}
          onClose={() => setWhatsappTarget(null)}
        />
      )}

      {/* MODAL 3: FOLLOW-UP / PTP */}
      {followupTarget && (
        <FollowupModal
          customer={followupTarget.customer}
          invoice={followupTarget.invoice}
          outstandingAmount={followupTarget.outstandingAmount}
          onClose={() => setFollowupTarget(null)}
        />
      )}

      {/* MODAL 4: CUSTOMER LEDGER STATEMENT */}
      {ledgerCustomerId && (
        <CustomerLedgerModal
          customerId={ledgerCustomerId}
          onClose={() => setLedgerCustomerId(null)}
        />
      )}
    </div>
  );
}
