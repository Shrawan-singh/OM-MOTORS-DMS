'use client';

import React, { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useDealerStore } from '@/lib/store/dealer-store';
import { X, UserPlus, Phone, MapPin, FileText, CheckCircle2 } from 'lucide-react';

interface QuickAddCustomerModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: (customerId: string) => void;
}

export function QuickAddCustomerModal({ isOpen, onClose, onSuccess }: QuickAddCustomerModalProps) {
  const router = useRouter();
  const { quickAddCustomer } = useDealerStore();

  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [village, setVillage] = useState('');
  const [requirementNotes, setRequirementNotes] = useState('');
  const [goToQuote, setGoToQuote] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim() || !phone.trim() || !village.trim()) {
      alert('Please fill Name, Phone, and Village.');
      return;
    }

    setIsSubmitting(true);
    try { const newCust = await quickAddCustomer({
      name,
      phone,
      village,
      requirementNotes
    });

    setIsSubmitting(false);

    // Clear form
    setName('');
    setPhone('');
    setVillage('');
    setRequirementNotes('');

    if (onSuccess) {
      onSuccess(newCust.id);
    }

    onClose();

    if (goToQuote) {
      router.push(`/quotations/new?customerId=${newCust.id}`);
    }
    } catch (error) {
      alert(error instanceof Error ? error.message : 'Customer could not be saved.');
    } finally { setIsSubmitting(false); }
  };

  return (
    <div className="fixed inset-0 z-50 bg-slate-900/40 backdrop-blur-sm flex items-center justify-center p-4">
      <div className="bg-white w-full max-w-lg rounded-3xl shadow-2xl border border-slate-100 overflow-hidden animate-in fade-in zoom-in-95 duration-150">
        
        {/* Header */}
        <div className="px-6 py-5 border-b border-slate-100 flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-xl bg-brand-50 text-brand-900 flex items-center justify-center">
              <UserPlus className="w-4 h-4" />
            </div>
            <div>
              <h2 className="text-sm font-semibold text-slate-900">Quick-Add Customer</h2>
              <p className="text-[11px] text-slate-500">Shop-floor speed registration (&lt; 15 seconds)</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 hover:bg-slate-100"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Form Body */}
        <form onSubmit={handleSubmit} className="p-6 space-y-4">
          
          {/* Customer Full Name */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5">
              Customer Full Name *
            </label>
            <input
              type="text"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Customer full name"
              className="touch-target w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-brand-900 focus:ring-1 focus:ring-brand-900"
              autoFocus
            />
          </div>

          {/* Phone Number */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5 flex items-center gap-1">
              <Phone className="w-3 h-3 text-slate-400" /> Mobile Phone Number *
            </label>
            <input
              type="tel"
              required
              maxLength={10}
              value={phone}
              onChange={(e) => setPhone(e.target.value.replace(/\D/g, ''))}
              placeholder="10-digit mobile number"
              className="touch-target w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-brand-900 focus:ring-1 focus:ring-brand-900 font-mono"
            />
          </div>

          {/* Village / Tehsil */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5 flex items-center gap-1">
              <MapPin className="w-3 h-3 text-slate-400" /> Village / Location *
            </label>
            <input
              type="text"
              required
              value={village}
              onChange={(e) => setVillage(e.target.value)}
              placeholder="Village / city"
              className="touch-target w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-brand-900 focus:ring-1 focus:ring-brand-900"
            />
          </div>

          {/* Requirement / Notes */}
          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5">
              Requirement / Vehicle Interest (Optional)
            </label>
            <input
              type="text"
              value={requirementNotes}
              onChange={(e) => setRequirementNotes(e.target.value)}
              placeholder="Product requirement or enquiry"
              className="touch-target w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-brand-900 focus:ring-1 focus:ring-brand-900"
            />
          </div>

          {/* Checkbox: Immediately Build Quotation */}
          <div className="pt-2">
            <label className="flex items-center gap-2 cursor-pointer select-none">
              <input
                type="checkbox"
                checked={goToQuote}
                onChange={(e) => setGoToQuote(e.target.checked)}
                className="w-4 h-4 rounded text-brand-900 border-slate-300 focus:ring-brand-900"
              />
              <span className="text-xs text-slate-700 font-medium">
                Immediately open Quotation Builder for this customer
              </span>
            </label>
          </div>

          {/* Action Buttons */}
          <div className="pt-4 border-t border-slate-100 flex items-center justify-end gap-3">
            <button
              type="button"
              onClick={onClose}
              className="touch-target px-4 py-2.5 rounded-xl text-xs font-medium text-slate-600 hover:bg-slate-100 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={isSubmitting}
              className="touch-target px-5 py-2.5 rounded-xl bg-brand-900 hover:bg-brand-800 text-white text-xs font-semibold shadow-sm transition-all inline-flex items-center gap-2"
            >
              <CheckCircle2 className="w-4 h-4" />
              Save Customer Record
            </button>
          </div>

        </form>

      </div>
    </div>
  );
}

