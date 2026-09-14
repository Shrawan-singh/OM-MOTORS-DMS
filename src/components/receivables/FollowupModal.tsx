'use client';

import React, { useState } from 'react';
import { X, PhoneCall, MessageSquare, UserCheck, FileText, Calendar, IndianRupee } from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { money } from '@/lib/billing/types';

interface FollowupModalProps {
  customer: {
    id: string;
    name: string;
    phone: string;
    village: string;
  };
  invoice?: {
    id: string;
    number: string;
    total: number;
    amount_paid: number;
  } | null;
  outstandingAmount: number;
  onClose: () => void;
  onSaved?: () => void;
}

export function FollowupModal({
  customer,
  invoice,
  outstandingAmount,
  onClose,
  onSaved,
}: FollowupModalProps) {
  const { logFollowup } = useDealerStore();
  const [method, setMethod] = useState<'phone' | 'whatsapp' | 'in_person' | 'notice'>('phone');
  const [notes, setNotes] = useState('');
  const [hasPtp, setHasPtp] = useState(true);
  const [ptpDate, setPtpDate] = useState(() => {
    const d = new Date();
    d.setDate(d.getDate() + 7);
    return d.toISOString().slice(0, 10);
  });
  const [ptpAmount, setPtpAmount] = useState(String(outstandingAmount || ''));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!notes.trim()) {
      setError('Please enter follow-up conversation notes.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await logFollowup({
        customerId: customer.id,
        invoiceId: invoice?.id || null,
        method,
        notes: notes.trim(),
        ptpDate: hasPtp && ptpDate ? ptpDate : null,
        ptpAmount: hasPtp && ptpAmount ? Number(ptpAmount) : null,
      });
      if (onSaved) onSaved();
      onClose();
    } catch (err: any) {
      setError(err?.message || 'Failed to record follow-up');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Log Collection Follow-up">
      <div className="admin-panel modal-card max-w-lg w-full">
        <div className="panel-heading border-b pb-3 mb-4 flex items-center justify-between">
          <div>
            <h2 className="text-base font-semibold text-slate-900">Log Collection Follow-up</h2>
            <p className="text-xs text-slate-500">
              {customer.name} ({customer.village}) · Outstanding: {money(outstandingAmount)}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="p-1 rounded-lg text-slate-400 hover:text-slate-700 hover:bg-slate-100"
            aria-label="Close modal"
          >
            <X size={18} />
          </button>
        </div>

        {error && (
          <div className="error-message mb-4" role="alert">
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          {/* Contact Method */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 uppercase tracking-wider mb-2">
              Contact Mode
            </label>
            <div className="grid grid-cols-4 gap-2">
              {[
                ['phone', 'Phone Call', PhoneCall],
                ['whatsapp', 'WhatsApp', MessageSquare],
                ['in_person', 'In-Person', UserCheck],
                ['notice', 'Formal Notice', FileText],
              ].map(([key, label, Icon]: any) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => setMethod(key)}
                  className={`p-2.5 rounded-xl text-xs font-medium border flex flex-col items-center gap-1.5 transition-all ${
                    method === key
                      ? 'border-brand-900 bg-brand-50/40 text-brand-900 font-semibold shadow-xs'
                      : 'border-slate-200 bg-white text-slate-600 hover:bg-slate-50'
                  }`}
                >
                  <Icon size={16} />
                  <span>{label}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Reference Invoice */}
          {invoice && (
            <div className="text-xs text-slate-600 bg-slate-50 p-2.5 rounded-xl border border-slate-200">
              <span className="font-semibold text-slate-700">Linked Invoice: </span>
              {invoice.number} (Total: {money(invoice.total)}, Due: {money(invoice.total - invoice.amount_paid)})
            </div>
          )}

          {/* Conversation Notes */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1">
              Discussion Notes / Remarks *
            </label>
            <textarea
              required
              rows={3}
              placeholder="e.g. Spoke with customer, agreed to clear balance after crop mandi sale next Tuesday."
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              className="w-full p-2.5 text-xs sm:text-sm rounded-xl border border-slate-200 focus:border-brand-900 focus:ring-1 focus:ring-brand-900"
            />
          </div>

          {/* Promise to Pay (PTP) */}
          <div className="p-3 bg-slate-50/70 rounded-2xl border border-slate-200/80 space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-slate-800 flex items-center gap-1.5">
                <Calendar size={14} className="text-slate-500" />
                Record Promise to Pay (PTP)
              </span>
              <label className="relative inline-flex items-center cursor-pointer">
                <input
                  type="checkbox"
                  checked={hasPtp}
                  onChange={(e) => setHasPtp(e.target.checked)}
                  className="sr-only peer"
                />
                <div className="w-8 h-4 bg-slate-300 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-slate-300 after:border after:rounded-full after:h-3 after:w-3 after:transition-all peer-checked:bg-emerald-600"></div>
              </label>
            </div>

            {hasPtp && (
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1">
                <div>
                  <label className="block text-[11px] font-medium text-slate-600 mb-1">
                    Promised Date
                  </label>
                  <input
                    type="date"
                    required={hasPtp}
                    value={ptpDate}
                    onChange={(e) => setPtpDate(e.target.value)}
                    className="w-full p-2 text-xs rounded-xl border border-slate-200 bg-white"
                  />
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-slate-600 mb-1">
                    Promised Amount (₹)
                  </label>
                  <div className="relative">
                    <IndianRupee size={12} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-slate-400" />
                    <input
                      type="number"
                      step="0.01"
                      min="0.01"
                      required={hasPtp}
                      value={ptpAmount}
                      onChange={(e) => setPtpAmount(e.target.value)}
                      className="w-full pl-7 pr-3 py-2 text-xs rounded-xl border border-slate-200 bg-white"
                    />
                  </div>
                </div>
              </div>
            )}
          </div>

          {/* Action Buttons */}
          <div className="flex items-center justify-end gap-2 pt-3 border-t border-slate-100">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="px-4 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-100 rounded-xl transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy}
              className="primary-button text-xs py-2 px-4 shadow-sm"
            >
              {busy ? 'Saving…' : 'Save Follow-up'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
