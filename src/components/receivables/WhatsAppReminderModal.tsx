'use client';

import React, { useState } from 'react';
import { X, Send, Copy, Check, MessageSquare } from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { money, getDaysOverdue } from '@/lib/billing/types';

interface WhatsAppReminderModalProps {
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
    document_date: string;
    due_date?: string | null;
  } | null;
  outstandingAmount: number;
  onClose: () => void;
}

export function WhatsAppReminderModal({
  customer,
  invoice,
  outstandingAmount,
  onClose,
}: WhatsAppReminderModalProps) {
  const { profile } = useDealerStore();
  const [templateType, setTemplateType] = useState<'gentle' | 'due_today' | 'overdue' | 'ptp'>('overdue');
  const [copied, setCopied] = useState(false);

  const dealershipName = profile?.name || 'OM Motors';
  const dealerPhone = profile?.phone || '';
  const bankDetails = profile?.bank_details ? `\nBank / UPI Details: ${profile.bank_details}` : '';
  const daysOverdue = invoice ? getDaysOverdue(invoice.due_date, invoice.document_date) : 0;
  const invNumber = invoice ? invoice.number : 'outstanding accounts';
  const dueDateStr = invoice?.due_date || invoice?.document_date || 'immediate';

  const templates: Record<string, string> = {
    gentle: `नमस्ते ${customer.name} जी,\n\n${dealershipName} से सादर प्रणाम।\nआपके बिल (${invNumber}) की राशि ${money(outstandingAmount)} भुगतान हेतु नियत तिथि (${dueDateStr}) पर देय है। कृपया समयानुसार भुगतान करने की कृपा करें।${bankDetails}\n\nधन्यवाद,\n${dealershipName}\nफ़ोन: ${dealerPhone}`,
    due_today: `नमस्ते ${customer.name} जी,\n\n${dealershipName} से सादर प्रणाम।\nआपके बिल (${invNumber}) की राशि ${money(outstandingAmount)} का भुगतान आज (${dueDateStr}) देय है। कृपया UPI या बैंक ट्रांसफर के माध्यम से भुगतान सुनिश्चित करें।${bankDetails}\n\nसधन्यवाद,\n${dealershipName}\nफ़ोन: ${dealerPhone}`,
    overdue: `नमस्ते ${customer.name} जी,\n\n${dealershipName} से महत्वपूर्ण सूचना:\nआपके बिल (${invNumber}) की बकाया राशि ${money(outstandingAmount)} पिछले ${daysOverdue} दिनों से अतिदेय (Overdue) है।\nकृपया असुविधा से बचने के लिए तुरंत भुगतान करें।${bankDetails}\n\nसहायता के लिए संपर्क करें: ${dealerPhone}\n${dealershipName}`,
    ptp: `नमस्ते ${customer.name} जी,\n\n${dealershipName} से अनुरोध:\nआपके द्वारा दिए गए वादे (Promise to Pay) के अनुसार बकाया राशि ${money(outstandingAmount)} का भुगतान आज अपेक्षित है। कृपया भुगतान रसीद हमें शेयर करें।${bankDetails}\n\nधन्यवाद,\n${dealershipName}\nफ़ोन: ${dealerPhone}`,
  };

  const [customMessage, setCustomMessage] = useState(templates[templateType]);

  const handleTemplateChange = (type: 'gentle' | 'due_today' | 'overdue' | 'ptp') => {
    setTemplateType(type);
    setCustomMessage(templates[type]);
  };

  const cleanPhone = customer.phone.replace(/\D/g, '');
  const formattedPhone = cleanPhone.length === 10 ? `91${cleanPhone}` : cleanPhone;
  const waUrl = `https://wa.me/${formattedPhone}?text=${encodeURIComponent(customMessage)}`;

  const copyToClipboard = async () => {
    try {
      await navigator.clipboard.writeText(customMessage);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Fallback
    }
  };

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="WhatsApp Payment Reminder">
      <div className="admin-panel modal-card max-w-xl w-full">
        <div className="panel-heading border-b pb-3 mb-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-full bg-emerald-100 text-emerald-700 flex items-center justify-center">
              <MessageSquare size={18} />
            </div>
            <div>
              <h2 className="text-base font-semibold text-slate-900">WhatsApp Payment Reminder</h2>
              <p className="text-xs text-slate-500">
                Send to {customer.name} ({customer.phone}) · {money(outstandingAmount)} due
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1 rounded-lg text-slate-400 hover:text-slate-700 hover:bg-slate-100"
            aria-label="Close modal"
          >
            <X size={18} />
          </button>
        </div>

        {/* Template Selectors */}
        <div className="mb-4">
          <label className="block text-xs font-semibold text-slate-700 uppercase tracking-wider mb-2">
            Choose Message Template
          </label>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
            {[
              ['gentle', 'Gentle Reminder'],
              ['due_today', 'Due Today'],
              ['overdue', 'Overdue Alert'],
              ['ptp', 'PTP Follow-up'],
            ].map(([key, label]) => (
              <button
                key={key}
                type="button"
                onClick={() => handleTemplateChange(key as any)}
                className={`py-2 px-2.5 rounded-xl text-xs font-medium border text-center transition-all ${
                  templateType === key
                    ? 'border-emerald-600 bg-emerald-50 text-emerald-800 font-semibold shadow-xs'
                    : 'border-slate-200 bg-white text-slate-600 hover:bg-slate-50'
                }`}
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        {/* Message Preview & Edit */}
        <div className="mb-4">
          <div className="flex items-center justify-between mb-1.5">
            <label className="text-xs font-semibold text-slate-700">
              Message Content (Editable)
            </label>
            <span className="text-[11px] text-slate-400">Hindi / Hinglish</span>
          </div>
          <textarea
            rows={7}
            value={customMessage}
            onChange={(e) => setCustomMessage(e.target.value)}
            className="w-full p-3 text-xs sm:text-sm font-sans rounded-xl border border-slate-200 focus:border-emerald-600 focus:ring-1 focus:ring-emerald-600 text-slate-800 bg-slate-50/50 leading-relaxed"
          />
        </div>

        {/* Action Buttons */}
        <div className="flex flex-col-reverse sm:flex-row items-center justify-between gap-3 pt-3 border-t border-slate-100">
          <button
            type="button"
            onClick={copyToClipboard}
            className="w-full sm:w-auto secondary-button flex items-center justify-center gap-1.5 text-xs py-2 px-3"
          >
            {copied ? <Check size={14} className="text-emerald-600" /> : <Copy size={14} />}
            {copied ? 'Copied to Clipboard' : 'Copy Message'}
          </button>

          <div className="flex items-center gap-2 w-full sm:w-auto">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 sm:flex-none px-4 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-100 rounded-xl transition-colors"
            >
              Cancel
            </button>
            <a
              href={waUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="flex-1 sm:flex-none px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-semibold rounded-xl inline-flex items-center justify-center gap-2 shadow-sm transition-all"
            >
              <Send size={14} />
              Open in WhatsApp
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}
