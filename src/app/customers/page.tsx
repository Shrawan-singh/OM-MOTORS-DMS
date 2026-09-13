'use client';

import { useAuth } from '@/lib/auth/provider';
import React, { useState, useMemo } from 'react';
import Link from 'next/link';
import { useDealerStore } from '@/lib/store/dealer-store';
import {
  Users,
  Search,
  Plus,
  Phone,
  MapPin,
  FileText,
  Clock,
  ChevronRight,
  ShieldCheck,
  Receipt,
  X
} from 'lucide-react';
import { QuickAddCustomerModal } from '@/components/customers/QuickAddCustomerModal';
import { Customer } from '@/types';

export default function CustomersPage() {
  const { can } = useAuth();
  const { customers, timeline, invoices, warranties } = useDealerStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedCustomer, setSelectedCustomer] = useState<Customer | null>(null);
  const [isQuickAddOpen, setIsQuickAddOpen] = useState(false);

  // Filter customers by search term
  const filteredCustomers = useMemo(() => {
    const q = searchQuery.toLowerCase().trim();
    if (!q) return customers;
    return customers.filter(
      (c) =>
        c.name.toLowerCase().includes(q) ||
        c.phone.includes(q) ||
        c.village.toLowerCase().includes(q) ||
        (c.requirementNotes && c.requirementNotes.toLowerCase().includes(q))
    );
  }, [customers, searchQuery]);

  // Selected customer timeline events
  const customerTimelineEvents = useMemo(() => {
    if (!selectedCustomer) return [];
    return timeline.filter((t) => t.customerId === selectedCustomer.id);
  }, [timeline, selectedCustomer]);

  // Selected customer invoices
  const customerInvoices = useMemo(() => {
    if (!selectedCustomer) return [];
    return invoices.filter((i) => i.customerId === selectedCustomer.id);
  }, [invoices, selectedCustomer]);

  // Selected customer warranties
  const customerWarranties = useMemo(() => {
    if (!selectedCustomer) return [];
    return warranties.filter((w) => w.customerId === selectedCustomer.id);
  }, [warranties, selectedCustomer]);

  return (
    <div className="space-y-6">
      
      {/* Top Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-xs font-semibold text-brand-900 tracking-wide uppercase">
            <Users className="w-4 h-4" />
            Directory & CRM
          </div>
          <h1 className="text-2xl font-semibold text-slate-900 mt-1 tracking-tight">
            Customer Database
          </h1>
          <p className="text-xs text-slate-500">
            {customers.length} registered farmers, commercial operators, and institutional buyers
          </p>
        </div>

        <button
          disabled={!can('customers.write')} onClick={() => setIsQuickAddOpen(true)}
          className="touch-target px-4 py-2.5 rounded-xl bg-brand-900 hover:bg-brand-800 text-white text-xs font-semibold inline-flex items-center gap-2 shadow-sm transition-all self-start sm:self-auto"
        >
          <Plus className="w-4 h-4" />
          Quick-Add Customer
        </button>
      </div>

      {/* Search Bar */}
      <div className="relative">
        <Search className="w-4 h-4 text-slate-400 absolute left-4 top-1/2 -translate-y-1/2" />
        <input
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search by customer name, phone number, village, or requirement..."
          className="w-full pl-11 pr-4 py-3 rounded-2xl border border-slate-200/80 bg-white text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-brand-900 focus:ring-1 focus:ring-brand-900 shadow-subtle"
        />
        {searchQuery && (
          <button
            onClick={() => setSearchQuery('')}
            className="absolute right-3 top-1/2 -translate-y-1/2 p-1 text-slate-400 hover:text-slate-600"
          >
            <X className="w-4 h-4" />
          </button>
        )}
      </div>

      {/* Main Grid: List on Left, 360 View on Right */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        
        {/* Customer List (2 cols on wide) */}
        <div className="lg:col-span-2 space-y-3">
          {filteredCustomers.length === 0 ? (
            <div className="bg-white p-12 text-center rounded-2xl border border-slate-100 shadow-card">
              <Users className="w-8 h-8 text-slate-300 mx-auto mb-2" />
              <p className="text-sm font-semibold text-slate-700">No matching customers found</p>
              <p className="text-xs text-slate-400 mt-1">Try adjusting your search query or add a new customer.</p>
            </div>
          ) : (
            filteredCustomers.map((cust) => {
              const isSelected = selectedCustomer?.id === cust.id;
              const hasInvoices = invoices.some((i) => i.customerId === cust.id);

              return (
                <div
                  key={cust.id}
                  onClick={() => setSelectedCustomer(cust)}
                  className={`card-apple p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center justify-between gap-4 cursor-pointer transition-all ${
                    isSelected ? 'ring-2 ring-brand-900 border-brand-900 bg-brand-50/20' : 'hover:border-slate-300'
                  }`}
                >
                  <div className="space-y-1.5 flex-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-semibold text-slate-900">{cust.name}</span>
                      {hasInvoices ? (
                        <span className="text-[10px] font-semibold text-emerald-700 bg-emerald-50 px-2 py-0.5 rounded-full border border-emerald-100">
                          Purchased Vehicle
                        </span>
                      ) : (
                        <span className="text-[10px] font-semibold text-blue-700 bg-blue-50 px-2 py-0.5 rounded-full border border-blue-100">
                          Active Lead
                        </span>
                      )}
                    </div>

                    <div className="flex items-center gap-4 text-xs text-slate-500 flex-wrap">
                      <span className="inline-flex items-center gap-1 font-mono">
                        <Phone className="w-3 h-3 text-slate-400" /> {cust.phone}
                      </span>
                      <span className="inline-flex items-center gap-1">
                        <MapPin className="w-3 h-3 text-slate-400" /> {cust.village}
                      </span>
                      {cust.aadhaarLast4 && (
                        <span className="text-[11px] text-slate-400">
                          Aadhaar: **** {cust.aadhaarLast4}
                        </span>
                      )}
                    </div>

                    {cust.requirementNotes && (
                      <div className="text-xs text-slate-600 bg-slate-50/80 p-2 rounded-xl border border-slate-100 mt-2">
                        <span className="font-semibold text-slate-700">Requirement: </span>
                        {cust.requirementNotes}
                      </div>
                    )}
                  </div>

                  {/* Actions */}
                  <div className="flex items-center gap-2 self-end sm:self-center shrink-0">
                    <Link
                      href={`/quotations/new?customerId=${cust.id}`}
                      onClick={(e) => e.stopPropagation()}
                      className="touch-target px-3 py-1.5 rounded-xl bg-slate-100 hover:bg-slate-200 text-slate-700 text-xs font-semibold inline-flex items-center gap-1.5 transition-colors"
                    >
                      <FileText className="w-3.5 h-3.5 text-slate-500" />
                      Quote
                    </Link>

                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        setSelectedCustomer(cust);
                      }}
                      className="p-2 rounded-xl text-slate-400 hover:text-brand-900 hover:bg-slate-100 transition-colors"
                      title="View 360 profile"
                    >
                      <ChevronRight className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              );
            })
          )}
        </div>

        {/* 360-Degree Profile Drawer (Sticky on Right) */}
        <div className="lg:col-span-1">
          {selectedCustomer ? (
            <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-card sticky top-24 space-y-6 animate-in fade-in duration-150">
              
              <div className="flex items-start justify-between border-b border-slate-100 pb-4">
                <div>
                  <h3 className="text-base font-semibold text-slate-900">{selectedCustomer.name}</h3>
                  <div className="text-xs text-slate-500 mt-0.5">📞 {selectedCustomer.phone}</div>
                  <div className="text-xs text-slate-500">📍 Village: {selectedCustomer.village}</div>
                </div>
                <button
                  onClick={() => setSelectedCustomer(null)}
                  className="p-1 rounded-lg text-slate-400 hover:text-slate-600 hover:bg-slate-100"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>

              {/* Quick Actions */}
              <div className="flex items-center gap-2">
                <Link
                  href={`/quotations/new?customerId=${selectedCustomer.id}`}
                  className="flex-1 text-center py-2.5 px-3 rounded-xl bg-brand-900 hover:bg-brand-800 text-white text-xs font-semibold transition-all shadow-sm"
                >
                  Create Quotation
                </Link>
                <a
                  href={`tel:${selectedCustomer.phone}`}
                  className="py-2.5 px-3 rounded-xl border border-slate-200 text-slate-700 hover:bg-slate-50 text-xs font-semibold transition-all flex items-center gap-1.5"
                >
                  <Phone className="w-3.5 h-3.5" /> Call
                </a>
              </div>

              {/* Invoices & Purchase History */}
              <div>
                <h4 className="text-xs font-semibold text-slate-700 uppercase tracking-wider mb-2 flex items-center gap-1.5">
                  <Receipt className="w-3.5 h-3.5 text-slate-400" />
                  Tax Invoices ({customerInvoices.length})
                </h4>
                {customerInvoices.length === 0 ? (
                  <p className="text-xs text-slate-400 italic">No completed sales yet.</p>
                ) : (
                  <div className="space-y-2">
                    {customerInvoices.map((inv) => (
                      <div key={inv.id} className="p-2.5 rounded-xl bg-slate-50 border border-slate-100 text-xs">
                        <div className="flex items-center justify-between font-semibold text-slate-900">
                          <span>{inv.invoiceNo}</span>
                          <span>₹{inv.totalAmount.toLocaleString('en-IN')}</span>
                        </div>
                        <div className="flex items-center justify-between text-[11px] text-slate-500 mt-1">
                          <span>Paid: ₹{inv.amountPaid.toLocaleString('en-IN')}</span>
                          <span className={inv.balanceDue > 0 ? 'text-amber-600 font-semibold' : 'text-emerald-600'}>
                            {inv.balanceDue > 0 ? `Due: ₹${inv.balanceDue.toLocaleString('en-IN')}` : 'Paid'}
                          </span>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              {/* Warranties */}
              <div>
                <h4 className="text-xs font-semibold text-slate-700 uppercase tracking-wider mb-2 flex items-center gap-1.5">
                  <ShieldCheck className="w-3.5 h-3.5 text-slate-400" />
                  Active Warranties ({customerWarranties.length})
                </h4>
                {customerWarranties.length === 0 ? (
                  <p className="text-xs text-slate-400 italic">No warranty cards issued.</p>
                ) : (
                  <div className="space-y-2">
                    {customerWarranties.map((w) => (
                      <div key={w.id} className="p-2.5 rounded-xl bg-emerald-50/50 border border-emerald-100 text-xs">
                        <div className="font-semibold text-slate-900">Serial: {w.serialNo}</div>
                        <div className="text-[11px] text-slate-600 mt-0.5">
                          Valid until: {w.endDate} &bull; Invoice: {w.invoiceNo}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              {/* Timeline Feed */}
              <div>
                <h4 className="text-xs font-semibold text-slate-700 uppercase tracking-wider mb-2 flex items-center gap-1.5">
                  <Clock className="w-3.5 h-3.5 text-slate-400" />
                  Customer Timeline
                </h4>
                <div className="space-y-3 max-h-60 overflow-y-auto pr-1">
                  {customerTimelineEvents.length === 0 ? (
                    <p className="text-xs text-slate-400 italic">No timeline recorded yet.</p>
                  ) : (
                    customerTimelineEvents.map((evt) => (
                      <div key={evt.id} className="text-xs border-l-2 border-brand-900/40 pl-3 py-1 space-y-0.5">
                        <div className="text-slate-800 font-medium leading-tight">{evt.description}</div>
                        <div className="text-[10px] text-slate-400">
                          {new Date(evt.occurredAt).toLocaleDateString('en-IN', {
                            day: 'numeric',
                            month: 'short',
                            hour: '2-digit',
                            minute: '2-digit'
                          })}
                        </div>
                      </div>
                    ))
                  )}
                </div>
              </div>

            </div>
          ) : (
            <div className="bg-white p-8 text-center rounded-3xl border border-slate-100 shadow-card text-slate-400 sticky top-24">
              <Users className="w-8 h-8 mx-auto mb-2 text-slate-300" />
              <p className="text-xs font-medium text-slate-600">No Customer Selected</p>
              <p className="text-[11px] text-slate-400 mt-1">
                Select any customer from the list to view their 360&deg; timeline, active quotations, tax invoices, and warranty status.
              </p>
            </div>
          )}
        </div>

      </div>

      <QuickAddCustomerModal
        isOpen={isQuickAddOpen}
        onClose={() => setIsQuickAddOpen(false)}
      />

    </div>
  );
}
