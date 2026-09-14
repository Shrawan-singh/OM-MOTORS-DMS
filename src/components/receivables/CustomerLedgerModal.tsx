'use client';

import React, { useMemo } from 'react';
import { X, Printer, FileText, ArrowDownLeft, ArrowUpRight, Building } from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { money } from '@/lib/billing/types';

interface CustomerLedgerModalProps {
  customerId: string;
  onClose: () => void;
}

interface LedgerEntry {
  id: string;
  date: string;
  type: 'invoice' | 'payment';
  reference: string;
  description: string;
  debit: number;
  credit: number;
  balance: number;
}

export function CustomerLedgerModal({ customerId, onClose }: CustomerLedgerModalProps) {
  const { customers, documents, payments, profile } = useDealerStore();

  const customer = useMemo(() => customers.find((c) => c.id === customerId), [customers, customerId]);

  const ledgerEntries = useMemo(() => {
    const custInvoices = documents.filter((d) => d.kind === 'invoice' && d.customer_id === customerId);
    const invoiceMap = new Map(custInvoices.map((inv) => [inv.id, inv]));
    const custPayments = payments.filter((p) => invoiceMap.has(p.invoiceId));

    // Raw events
    const rawEvents: Array<{
      id: string;
      date: string;
      type: 'invoice' | 'payment';
      reference: string;
      description: string;
      debit: number;
      credit: number;
    }> = [];

    custInvoices.forEach((inv) => {
      rawEvents.push({
        id: inv.id,
        date: inv.document_date,
        type: 'invoice',
        reference: inv.number,
        description: `Tax Invoice: ${inv.items.map((i) => i.name).slice(0, 2).join(', ')}${inv.items.length > 2 ? '…' : ''}`,
        debit: inv.total,
        credit: 0,
      });
    });

    custPayments.forEach((pay) => {
      const inv = invoiceMap.get(pay.invoiceId);
      rawEvents.push({
        id: pay.id,
        date: pay.paidAt.slice(0, 10),
        type: 'payment',
        reference: pay.referenceNo ? `${pay.method.toUpperCase()} (${pay.referenceNo})` : pay.method.toUpperCase(),
        description: `Payment against ${inv ? inv.number : 'Invoice'}`,
        debit: 0,
        credit: pay.amount,
      });
    });

    // Sort chronologically ascending
    rawEvents.sort((a, b) => a.date.localeCompare(b.date));

    // Compute running balance
    let runningBalance = 0;
    const entries: LedgerEntry[] = rawEvents.map((evt) => {
      runningBalance = runningBalance + evt.debit - evt.credit;
      return {
        ...evt,
        balance: runningBalance,
      };
    });

    return entries;
  }, [documents, payments, customerId]);

  const totalDebits = useMemo(() => ledgerEntries.reduce((sum, e) => sum + e.debit, 0), [ledgerEntries]);
  const totalCredits = useMemo(() => ledgerEntries.reduce((sum, e) => sum + e.credit, 0), [ledgerEntries]);
  const netBalance = totalDebits - totalCredits;

  const handlePrint = () => {
    window.print();
  };

  if (!customer) return null;

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Customer Statement of Account">
      <div className="admin-panel modal-card max-w-4xl w-full max-h-[90vh] overflow-y-auto p-6 sm:p-8 bg-white">
        {/* Header (Screen + Print) */}
        <div className="flex items-start justify-between border-b pb-4 mb-6">
          <div>
            <div className="flex items-center gap-2 text-xs font-semibold text-brand-900 tracking-wide uppercase">
              <Building className="w-4 h-4" />
              {profile?.name || 'OM Motors'} · Financial Ledger
            </div>
            <h1 className="text-xl font-bold text-slate-900 mt-1">Customer Statement of Account</h1>
            <p className="text-xs text-slate-500 mt-0.5">
              Statement as of {new Date().toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
            </p>
          </div>
          <div className="flex items-center gap-2 print:hidden">
            <button
              type="button"
              onClick={handlePrint}
              className="secondary-button text-xs py-2 px-3 flex items-center gap-1.5"
            >
              <Printer size={14} /> Print Statement
            </button>
            <button
              type="button"
              onClick={onClose}
              className="p-1.5 rounded-lg text-slate-400 hover:text-slate-700 hover:bg-slate-100"
              aria-label="Close statement"
            >
              <X size={20} />
            </button>
          </div>
        </div>

        {/* Customer & Dealer Info Banner */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 p-4 rounded-2xl bg-slate-50 border border-slate-200/80 mb-6 text-xs">
          <div>
            <h3 className="font-semibold text-slate-800 uppercase tracking-wider text-[11px] mb-1">Customer Details</h3>
            <p className="text-sm font-bold text-slate-900">{customer.name}</p>
            <p className="text-slate-600 mt-0.5">📞 {customer.phone}</p>
            <p className="text-slate-600">📍 Village: {customer.village} {customer.address ? `, ${customer.address}` : ''}</p>
            {customer.creditLimit ? (
              <p className="text-slate-600 mt-1">
                Credit Limit: <span className="font-semibold">{money(customer.creditLimit)}</span> · Terms: {customer.paymentTermsDays || 15} days
              </p>
            ) : null}
          </div>
          <div className="sm:text-right">
            <h3 className="font-semibold text-slate-800 uppercase tracking-wider text-[11px] mb-1">Dealership / Issuer</h3>
            <p className="font-bold text-slate-900">{profile?.name || 'OM Motors'}</p>
            <p className="text-slate-600">{profile?.address}</p>
            <p className="text-slate-600">GSTIN: {profile?.gstin || 'N/A'}</p>
            <p className="text-slate-600">Phone: {profile?.phone}</p>
          </div>
        </div>

        {/* Financial KPI Summary */}
        <div className="grid grid-cols-3 gap-3 mb-6">
          <div className="p-3.5 rounded-2xl bg-slate-50 border border-slate-200/80">
            <span className="text-[11px] font-medium text-slate-500 uppercase flex items-center gap-1">
              <ArrowDownLeft size={13} className="text-blue-600" /> Total Invoiced
            </span>
            <strong className="block text-base sm:text-lg font-bold text-slate-900 mt-1">
              {money(totalDebits)}
            </strong>
          </div>
          <div className="p-3.5 rounded-2xl bg-slate-50 border border-slate-200/80">
            <span className="text-[11px] font-medium text-slate-500 uppercase flex items-center gap-1">
              <ArrowUpRight size={13} className="text-emerald-600" /> Total Payments Received
            </span>
            <strong className="block text-base sm:text-lg font-bold text-emerald-700 mt-1">
              {money(totalCredits)}
            </strong>
          </div>
          <div className="p-3.5 rounded-2xl bg-slate-50 border border-slate-200/80">
            <span className="text-[11px] font-medium text-slate-500 uppercase">
              Current Outstanding Balance
            </span>
            <strong className={`block text-base sm:text-lg font-bold mt-1 ${netBalance > 0 ? 'text-amber-700' : 'text-emerald-700'}`}>
              {money(netBalance)}
            </strong>
          </div>
        </div>

        {/* Statement Table */}
        <div className="overflow-x-auto border border-slate-200 rounded-2xl mb-6">
          <table className="w-full text-left text-xs border-collapse">
            <thead>
              <tr className="bg-slate-100/80 border-b border-slate-200 text-slate-700">
                <th className="py-3 px-3.5 font-semibold">Date</th>
                <th className="py-3 px-3.5 font-semibold">Document / Reference</th>
                <th className="py-3 px-3.5 font-semibold">Description</th>
                <th className="py-3 px-3.5 font-semibold text-right">Debit (₹)</th>
                <th className="py-3 px-3.5 font-semibold text-right">Credit (₹)</th>
                <th className="py-3 px-3.5 font-semibold text-right">Balance (₹)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {ledgerEntries.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-8 text-center text-slate-400">
                    No transactions recorded for this customer yet.
                  </td>
                </tr>
              ) : (
                ledgerEntries.map((entry) => (
                  <tr key={entry.id} className="hover:bg-slate-50/50">
                    <td className="py-2.5 px-3.5 font-mono text-slate-600 whitespace-nowrap">{entry.date}</td>
                    <td className="py-2.5 px-3.5 font-semibold text-slate-900">
                      <span className="inline-flex items-center gap-1">
                        <FileText size={12} className={entry.type === 'invoice' ? 'text-blue-500' : 'text-emerald-500'} />
                        {entry.reference}
                      </span>
                    </td>
                    <td className="py-2.5 px-3.5 text-slate-600">{entry.description}</td>
                    <td className="py-2.5 px-3.5 text-right font-mono text-slate-900">
                      {entry.debit > 0 ? money(entry.debit) : '—'}
                    </td>
                    <td className="py-2.5 px-3.5 text-right font-mono text-emerald-700">
                      {entry.credit > 0 ? money(entry.credit) : '—'}
                    </td>
                    <td className="py-2.5 px-3.5 text-right font-mono font-bold text-slate-900">
                      {money(entry.balance)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
            {ledgerEntries.length > 0 && (
              <tfoot>
                <tr className="bg-slate-100/90 font-bold border-t border-slate-300 text-slate-900">
                  <td colSpan={3} className="py-3 px-3.5 text-right uppercase tracking-wider text-[11px]">
                    Total / Closing Balance:
                  </td>
                  <td className="py-3 px-3.5 text-right font-mono">{money(totalDebits)}</td>
                  <td className="py-3 px-3.5 text-right font-mono text-emerald-700">{money(totalCredits)}</td>
                  <td className="py-3 px-3.5 text-right font-mono text-base text-brand-900">
                    {money(netBalance)}
                  </td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>

        {/* Bank details for payment footer */}
        {profile?.bank_details && (
          <div className="p-4 rounded-xl bg-slate-50 border border-slate-200 text-xs text-slate-700 mb-6">
            <span className="font-semibold block mb-1">Remittance Instructions:</span>
            <p className="whitespace-pre-line">{profile.bank_details}</p>
          </div>
        )}

        {/* Signatures */}
        <div className="hidden print:flex items-end justify-between pt-12 text-xs text-slate-600">
          <div>
            <div className="w-48 border-b border-slate-400 mb-1"></div>
            <span>Customer Acknowledgment</span>
          </div>
          <div className="text-right">
            <div className="w-48 border-b border-slate-400 mb-1 ml-auto"></div>
            <span>Authorized Signatory · {profile?.name || 'OM Motors'}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
