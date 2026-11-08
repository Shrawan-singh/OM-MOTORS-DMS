'use client';

import { useState } from 'react';
import { X, ShieldCheck, Package, Cpu, Battery, Wrench, Tag, Save } from 'lucide-react';
import type { BillingLine, BillingDocument, AssetSerials } from '@/lib/billing/types';
import { money } from '@/lib/billing/types';
import { useDealerStore } from '@/lib/store/dealer-store';

type AssetEntry = {
  lineIndex: number;
  chassisNo: string;
  engineNo: string;
  motorNo: string;
  batterySerial: string;
  serialNo: string;
  registrationNo: string;
  warrantyMonths: number;
  notes: string;
};

/** Determines the item category from product or line name */
function guessCategory(line: BillingLine, products: { id: string; category: string }[]): string {
  if (line.productId) {
    const p = products.find((p) => p.id === line.productId);
    if (p) return p.category;
  }
  const name = line.name.toLowerCase();
  if (/tractor|vehicle|rickshaw/.test(name)) return 'vehicle';
  if (/battery|cell|lithium|lead.acid/.test(name)) return 'battery';
  if (/rotavator|plough|cultivator|implement|trolley|laser|leveller/.test(name)) return 'implement';
  return 'part';
}

/** Get relevant serial fields for a category */
function getFieldsForCategory(cat: string) {
  switch (cat) {
    case 'tractor':
    case 'e_rickshaw':
    case 'cng_rickshaw':
    case 'diesel_rickshaw':
    case 'vehicle':
      return ['chassisNo', 'engineNo', 'motorNo', 'batterySerial', 'registrationNo'];
    case 'battery':
      return ['batterySerial'];
    case 'implement':
      return ['serialNo'];
    default:
      return ['serialNo'];
  }
}

const fieldLabels: Record<string, string> = {
  chassisNo: 'Chassis Number',
  engineNo: 'Engine Number',
  motorNo: 'Motor Number',
  batterySerial: 'Battery Serial Number',
  serialNo: 'Serial / Identification Number',
  registrationNo: 'Registration Number',
};

const fieldIcons: Record<string, React.ReactNode> = {
  chassisNo: <Tag size={14} />,
  engineNo: <Cpu size={14} />,
  motorNo: <Cpu size={14} />,
  batterySerial: <Battery size={14} />,
  serialNo: <Package size={14} />,
  registrationNo: <Tag size={14} />,
};

type Props = {
  isOpen: boolean;
  onClose: () => void;
  document: BillingDocument;
  onSuccess?: () => void;
};

export function AssetRegistrationModal({ isOpen, onClose, document: doc, onSuccess }: Props) {
  const store = useDealerStore();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  // Build initial entries for each line item that can have serials
  const [entries, setEntries] = useState<AssetEntry[]>(() =>
    doc.items
      .map((line, i) => {
        const existing = line.serials;
        return {
          lineIndex: i,
          chassisNo: existing?.chassisNo || '',
          engineNo: existing?.engineNo || '',
          motorNo: existing?.motorNo || '',
          batterySerial: existing?.batterySerial || '',
          serialNo: existing?.serialNo || '',
          registrationNo: existing?.registrationNo || '',
          warrantyMonths: 0,
          notes: '',
        };
      })
  );

  const changeEntry = (index: number, field: string, value: string | number) =>
    setEntries((prev) =>
      prev.map((e, i) => (i === index ? { ...e, [field]: value } : e))
    );

  const products = store.products;

  async function handleSave() {
    setError('');
    setSuccess('');
    setBusy(true);
    try {
      // Filter to only entries that have at least one serial filled
      const toRegister = entries.filter((e) => {
        return (
          e.chassisNo.trim() ||
          e.engineNo.trim() ||
          e.motorNo.trim() ||
          e.batterySerial.trim() ||
          e.serialNo.trim() ||
          e.registrationNo.trim()
        );
      });

      if (toRegister.length === 0) {
        throw new Error('Enter at least one serial/chassis number to register assets.');
      }

      // Check if lines already have assets registered
      const alreadyRegistered = toRegister.filter(
        (e) => doc.items[e.lineIndex]?.serials?.assetId
      );
      if (alreadyRegistered.length > 0) {
        const names = alreadyRegistered.map((e) => doc.items[e.lineIndex].name).join(', ');
        throw new Error(
          `Asset already registered for: ${names}. Open the customer's asset registry to manage existing assets.`
        );
      }

      await store.registerInvoiceAssets(doc.id, toRegister);
      setSuccess(
        `${toRegister.length} asset${toRegister.length > 1 ? 's' : ''} registered successfully with warranty tracking!`
      );
      onSuccess?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to register assets.');
    } finally {
      setBusy(false);
    }
  }

  if (!isOpen) return null;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal asset-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div>
            <div className="modal-icon">
              <ShieldCheck size={20} />
            </div>
            <div>
              <h2>Register Assets & Warranty</h2>
              <p>
                Link serial numbers to this customer for warranty tracking. Invoice{' '}
                <strong>{doc.number}</strong>
              </p>
            </div>
          </div>
          <button className="modal-close" onClick={onClose} aria-label="Close">
            <X size={20} />
          </button>
        </div>

        {error && (
          <div role="alert" className="error-message">
            {error}
          </div>
        )}
        {success && (
          <div role="status" className="success-message">
            {success}
          </div>
        )}

        <div className="asset-modal-body">
          {entries.map((entry, i) => {
            const line = doc.items[entry.lineIndex];
            if (!line) return null;
            const cat = guessCategory(line, products);
            const fields = getFieldsForCategory(cat);
            const hasExisting = !!line.serials?.assetId;

            return (
              <div
                key={i}
                className={`asset-line-card ${hasExisting ? 'registered' : ''}`}
              >
                <div className="asset-line-header">
                  <div className="asset-line-info">
                    <strong>{line.name}</strong>
                    <span className="asset-line-meta">
                      {line.hsnCode && `HSN ${line.hsnCode} · `}
                      Qty {line.qty} · {money(line.total || line.unitPrice * line.qty)}
                    </span>
                  </div>
                  <span className={`asset-badge ${cat}`}>
                    {cat === 'battery' ? (
                      <Battery size={12} />
                    ) : cat === 'vehicle' || cat === 'tractor' || cat === 'e_rickshaw' || cat === 'cng_rickshaw' || cat === 'diesel_rickshaw' ? (
                      <Package size={12} />
                    ) : (
                      <Wrench size={12} />
                    )}
                    {cat.replace(/_/g, ' ')}
                  </span>
                </div>

                {hasExisting ? (
                  <div className="asset-registered-notice">
                    <ShieldCheck size={14} />
                    <span>
                      Asset already registered
                      {line.serials?.chassisNo && ` · Chassis: ${line.serials.chassisNo}`}
                      {line.serials?.batterySerial && ` · Battery: ${line.serials.batterySerial}`}
                      {line.serials?.serialNo && ` · Serial: ${line.serials.serialNo}`}
                    </span>
                  </div>
                ) : (
                  <div className="asset-serial-fields">
                    {fields.map((field) => (
                      <label key={field} className="asset-field">
                        <span className="asset-field-label">
                          {fieldIcons[field]}
                          {fieldLabels[field]}
                        </span>
                        <input
                          type="text"
                          value={(entry as any)[field] || ''}
                          onChange={(e) =>
                            changeEntry(i, field, e.target.value.toUpperCase())
                          }
                          placeholder={`Enter ${fieldLabels[field]?.toLowerCase()}`}
                        />
                      </label>
                    ))}

                    <label className="asset-field">
                      <span className="asset-field-label">
                        <ShieldCheck size={14} />
                        Warranty (months)
                      </span>
                      <input
                        type="number"
                        min="0"
                        max="120"
                        value={entry.warrantyMonths || ''}
                        onChange={(e) =>
                          changeEntry(
                            i,
                            'warrantyMonths',
                            e.target.value === '' ? 0 : Number(e.target.value)
                          )
                        }
                        placeholder="e.g. 24"
                      />
                    </label>

                    <label className="asset-field wide">
                      <span className="asset-field-label">Notes</span>
                      <input
                        type="text"
                        value={entry.notes}
                        onChange={(e) => changeEntry(i, 'notes', e.target.value)}
                        placeholder="Optional notes"
                      />
                    </label>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div className="asset-modal-footer">
          <button className="secondary-button" type="button" onClick={onClose}>
            {success ? 'Done' : 'Cancel'}
          </button>
          {!success && (
            <button
              className="primary-button"
              type="button"
              onClick={handleSave}
              disabled={busy}
            >
              <Save size={15} />
              {busy ? 'Registering…' : 'Register Assets & Create Warranty'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
