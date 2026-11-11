'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { Plus, Trash2, Save, ArrowLeft, Printer } from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useAuth } from '@/lib/auth/provider';
import { BillingLine, BillingDocument, lineTotals, money } from '@/lib/billing/types';
import { QuickAddCustomerModal } from '@/components/customers/QuickAddCustomerModal';

import { SaleVehiclePicker } from '@/components/vehicles/SaleVehiclePicker';
import { vehicleTypes, vehicleRpc } from '@/lib/vehicles/register';
import { ConfirmDialog } from '@/components/ui/ConfirmDialog';

type EditableLine = Omit<BillingLine, 'taxable' | 'tax' | 'total' | 'gstRatePct' | 'unitPrice'> & {
  gstRatePct: number | '';
  unitPrice: number | '';
};

const blank = (): EditableLine => ({
  productId: null,
  inventoryId: null,
  name: '',
  hsnCode: '',
  qty: 1,
  unitPrice: '',
  discount: 0,
  gstRatePct: '',
});

const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

type EditorProps = { kind: 'quotation' | 'invoice'; id?: string };

type Draft = {
  requestId: string;
  customer: string;
  number: string;
  date: string;
  valid: string;
  dueDate: string;
  taxMode: 'cgst_sgst' | 'igst';
  notes: string;
  lines: EditableLine[];
};

export function DocumentEditor(props: EditorProps) {
  const { email } = useAuth();
  const query = useSearchParams();
  const context = [props.kind, props.id || 'new', email, query.get('from'),
    query.get('customerId'), query.get('productId') || query.get('vehicleId')];
  const key = 'om.billing.draft.v1:' + JSON.stringify(context);
  return <Editor key={key} {...props} draftKey={!props.id && email ? key : null} />;
}

function Editor({ kind, id, draftKey }: EditorProps & { draftKey: string | null }) {
  const query = useSearchParams();
  const router = useRouter();
  const store = useDealerStore();
  const { can } = useAuth();
  const [requestId, setRequestId] = useState(() => crypto.randomUUID());
  const initialized = useRef('');

  const sourceId = query.get('from');
  const existing = store.documents.find((d) => d.id === id);
  const source = store.documents.find((d) => d.id === sourceId && d.kind === 'quotation');

  const [number, setNumber] = useState('');
  const [customer, setCustomer] = useState(query.get('customerId') || '');
  const [date, setDate] = useState(today);
  const [valid, setValid] = useState(() =>
    new Date(Date.now() + 15 * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
  );
  const [dueDate, setDueDate] = useState(() =>
    new Date(Date.now() + 15 * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
  );
  const [taxMode, setTaxMode] = useState<'cgst_sgst' | 'igst'>('cgst_sgst');
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<EditableLine[]>([blank()]);
  const [version, setVersion] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [cancelOpen, setCancelOpen] = useState(false);
  const [addCustomer, setAddCustomer] = useState(false);

  const [pendingDraft, setPendingDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  const [draftStatus, setDraftStatus] = useState('');
  const [checkedDraft, setCheckedDraft] = useState(false);
  const canWrite = can(kind === 'invoice' ? 'invoices.write' : 'quotations.write');

  useEffect(() => {
    try {
      const raw = draftKey && canWrite ? sessionStorage.getItem(draftKey) : null;
      if (raw) {
        const draft: Draft = JSON.parse(raw);
        if (typeof draft.requestId !== 'string' || !Array.isArray(draft.lines) || !draft.lines.length ||
            !draft.lines.every(line => line && typeof line.name === 'string')) {
          throw new Error('Unreadable draft');
        }
        setPendingDraft(draft);
      }
    } catch {
      setDraftStatus('Is tab ka draft nahi khul saka.');
    }
    setCheckedDraft(true);
  }, [draftKey, canWrite]);

  useEffect(() => {
    if (!draftKey || !canWrite || !dirty || pendingDraft || !checkedDraft) return;
    const draft: Draft = { requestId, customer, number, date, valid, dueDate, taxMode, notes, lines };
    try {
      sessionStorage.setItem(draftKey, JSON.stringify(draft));
      setDraftStatus('Draft is tab mein save hua.');
    } catch {
      setDraftStatus('Draft save nahi hua. Final save se pehle tab khula rakhein.');
    }
  }, [draftKey, canWrite, dirty, pendingDraft, checkedDraft, requestId, customer, number,
      date, valid, dueDate, taxMode, notes, lines]);

  function clearDraft() {
    if (draftKey) {
      try { sessionStorage.removeItem(draftKey); } catch { /* Storage can be disabled. */ }
    }
    setPendingDraft(null);
    setDirty(false);
    setDraftStatus('');
  }

  function restoreDraft(draft: Draft) {
    setRequestId(draft.requestId);
    setCustomer(draft.customer);
    setNumber(draft.number);
    setDate(draft.date);
    setValid(draft.valid);
    setDueDate(draft.dueDate);
    setTaxMode(draft.taxMode);
    setNotes(draft.notes);
    setLines(draft.lines);
    setPendingDraft(null);
    setDirty(true);
  }

  useEffect(() => {
    const d = existing || source;
    if (!d || initialized.current === d.id) return;
    initialized.current = d.id;
    setNumber(existing ? d.number : '');
    setCustomer(d.customer_id);
    setDate(existing ? d.document_date : today());
    setValid(d.valid_until || valid);
    setDueDate(existing?.due_date || dueDate);
    setTaxMode(d.tax_mode);
    setNotes(d.notes);
    setLines(d.items);
    setVersion(existing ? d.updated_at : undefined);
  }, [existing, source]);

  useEffect(() => {
    const productId = query.get('productId') || query.get('vehicleId');
    if (id || sourceId || !productId || initialized.current) return;
    const p = store.products.find((p) => p.id === productId);
    if (!p) return;
    initialized.current = p.id;
    setLines([
      {
        ...blank(),
        productId: p.id,
        inventoryId: store.inventory.find((i) => i.itemId === p.id)?.id || null,
        name: [p.brand, p.model_name, p.variant].filter(Boolean).join(' '),
        unitPrice: p.selling_price ?? '',
        gstRatePct: p.gst_rate_pct ?? '',
        hsnCode: p.hsn_code || '',
      },
    ]);
  }, [query, store.products, store.inventory, id, sourceId]);

  const change = (index: number, patch: Partial<EditableLine>) =>
    setLines((prev) => prev.map((l, i) => (i === index ? { ...l, ...patch } : l)));

  function selectProduct(index: number, value: string) {
    const p = store.products.find((p) => p.id === value);
    if (!p) {
      change(index, {
        vehicleId: undefined,
        chassisNo: undefined,
        motorNo: undefined,
        engineNo: undefined,
        productId: null,
        inventoryId: null,
      });
      return;
    }
    change(index, {
      vehicleId: undefined,
      chassisNo: undefined,
      motorNo: undefined,
      engineNo: undefined,
      productId: p.id,
      inventoryId: store.inventory.find((i) => i.itemId === p.id)?.id || null,
      name: [p.brand, p.model_name, p.variant].filter(Boolean).join(' '),
      unitPrice: p.selling_price ?? '',
      gstRatePct: p.gst_rate_pct ?? '',
      hsnCode: p.hsn_code || '',
    });
  }

  const totals = lines.map((l) =>
    lineTotals({ ...l, unitPrice: Number(l.unitPrice), gstRatePct: Number(l.gstRatePct) })
  );
  const net = totals.reduce((s, l) => s + l.taxable, 0);
  const tax = totals.reduce((s, l) => s + l.tax, 0);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      if (!customer) throw new Error('Select a customer.');
      if (lines.some((l) => !l.name.trim() || l.unitPrice === '' || l.gstRatePct === '')) {
        throw new Error(
          'Every item needs a name, price and GST rate. Enter 0 explicitly for a zero-rated item.'
        );
      }
      if (id && !existing) throw new Error('Document has not loaded.');
      if (sourceId && !source) throw new Error('Source quotation is unavailable.');

      const d = await store.saveDocument({
        id: id || requestId,
        kind,
        number,
        customerId: customer,
        date,
        validUntil: kind === 'quotation' ? valid : null,
        dueDate: kind === 'invoice' ? dueDate : null,
        items: lines as BillingLine[],
        taxMode,
        notes,
        sourceQuotationId: existing?.source_quotation_id || sourceId,
        expectedUpdatedAt: version,
      });
      clearDraft();
      router.push(`/${kind === 'invoice' ? 'invoices' : 'quotations'}/${d.id}`);
      setLines(d.items);
      setVersion(d.updated_at);
      setNumber(d.number);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to save document.');
    } finally {
      setBusy(false);
    }
  }

  const documentModule = kind === 'invoice' ? 'invoices' : 'quotations';

  if (id && !store.loading && !existing) {
    return (
      <div className="admin-panel">
        Document not found or access denied.{' '}
        <Link href={`/${documentModule}`}>Back to {documentModule}</Link>
      </div>
    );
  }

  return (
    <div>
      {/* Heading */}
      <div className="page-heading">
        <div>
          <Link className="back-link" href={`/${documentModule}`}>
            <ArrowLeft size={14} /> {documentModule}
          </Link>
          <h1>
            {id ? 'Edit' : 'New'} {kind}
          </h1>
          <p>Prices exclude GST. Discount poori line par lagta hai.</p>
        </div>
        {existing && (
          <Link
            className="secondary-button"
            target="_blank"
            href={`/${documentModule}/${existing.id}/print`}
          >
            <Printer size={15} />
            Print / PDF
          </Link>
        )}
      </div>

      {error && (
        <div role="alert" className="error-message">
          {error}
        </div>
      )}

      {pendingDraft && canWrite && <section className="admin-panel mb-4" aria-label="Saved draft">
        <p>Is kaam ka adhura {kind} is tab mein mila.</p>
        <div className="document-actions">
          <button className="primary-button" disabled={store.loading} onClick={() => restoreDraft(pendingDraft)}>Pichhla draft kholein</button>
          <button className="secondary-button" onClick={clearDraft}>Draft hata kar naya banayein</button>
        </div>
      </section>}
      {draftStatus && <p role="status" className="info-note">{draftStatus}</p>}
      <form onSubmit={save} onChangeCapture={() => setDirty(true)} className="billing-editor">
        <fieldset
          disabled={busy || store.loading || !!store.error || !canWrite || !!pendingDraft || !checkedDraft}
        >
          {/* Document details */}
          <section className="admin-panel">
            <div className="form-grid">
              <label>
                {kind === 'invoice' ? 'Invoice / bill' : 'Quotation'} number
                <input
                  value={number}
                  onChange={(e) => setNumber(e.target.value)}
                  placeholder="Auto-generated when left blank"
                  maxLength={50}
                />
              </label>

              <label>
                Document date
                <input
                  required
                  type="date"
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                />
              </label>

              {kind === 'quotation' && (
                <label>
                  Valid until
                  <input
                    required
                    type="date"
                    min={date}
                    value={valid}
                    onChange={(e) => setValid(e.target.value)}
                  />
                </label>
              )}

              {kind === 'invoice' && (
                <label>
                  Payment due date
                  <input
                    required
                    type="date"
                    value={dueDate}
                    onChange={(e) => setDueDate(e.target.value)}
                  />
                </label>
              )}

              <label>
                Customer
                <select required value={customer} onChange={(e) => setCustomer(e.target.value)}>
                  <option value="">Select customer</option>
                  {store.customers.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name} · {c.phone}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                GST treatment
                <select
                  value={taxMode}
                  onChange={(e) => setTaxMode(e.target.value as typeof taxMode)}
                >
                  <option value="cgst_sgst">CGST + SGST</option>
                  <option value="igst">IGST</option>
                </select>
              </label>
            </div>

            {can('customers.write') && (
              <button
                type="button"
                className="secondary-button"
                onClick={() => setAddCustomer(true)}
              >
                <Plus size={14} />
                Add customer
              </button>
            )}
          </section>

          {/* Line items */}
          <section className="admin-panel mt-5">
            <div className="panel-heading">
              <div>
                <h2>Items</h2>
                <p>
                  Select a catalogue product or type a custom item. Saved product GST is prefilled
                  and can be changed for this bill.
                </p>
              </div>
            </div>

            <div className="line-items">
              {lines.map((l, i) => (
                <div className="billing-line" key={i}>
                  <div className="line-heading">
                    <strong>Item {i + 1}</strong>
                    <button
                      type="button"
                      className="secondary-button"
                      disabled={lines.length === 1}
                      aria-label={`Remove item ${i + 1}`}
                      onClick={() => { setDirty(true); setLines(lines.filter((_, j) => i !== j)); }}
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>

                  <div className="form-grid">
                    <label>
                      Catalogue (optional)
                      <select
                        value={l.productId || ''}
                        onChange={(e) => selectProduct(i, e.target.value)}
                      >
                        <option value="">Manually entered item</option>
                        {store.products.map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.brand} {p.model_name} {p.variant}
                            {p.status === 'legacy' ? ' · legacy' : ''}
                          </option>
                        ))}
                      </select>
                    </label>

                    {l.productId &&
                      vehicleTypes.includes(
                        store.products.find((p) => p.id === l.productId)?.category || ''
                      ) &&
                      can(kind === 'invoice' ? 'vehicles.write' : 'vehicles.read') && (
                        <SaleVehiclePicker
                          productId={l.productId}
                          line={{ vehicleId: l.vehicleId, chassisNo: l.chassisNo, qty: l.qty }}
                          backfill={
                            !!existing && kind === 'invoice' && !existing.items[i]?.vehicleId
                          }
                          onChange={(patch) => change(i, patch as Partial<EditableLine>)}
                        />
                      )}
                    <label className="wide-field">
                      Item name / description
                      <input
                        required
                        maxLength={300}
                        value={l.name}
                        onChange={(e) => change(i, { name: e.target.value })}
                        placeholder="Enter item or service name"
                      />
                    </label>

                    <label>
                      HSN / SAC
                      <input
                        value={l.hsnCode}
                        onChange={(e) => change(i, { hsnCode: e.target.value })}
                      />
                    </label>

                    <label>
                      Quantity
                      <input
                        required
                        type="number"
                        min="1"
                        step="1"
                        readOnly={!!l.chassisNo}
                        value={l.qty}
                        onChange={(e) => change(i, { qty: Number(e.target.value) })}
                      />
                    </label>

                    <label>
                      Unit price (₹, before GST)
                      <input
                        required
                        type="number"
                        min="0"
                        step="0.01"
                        value={l.unitPrice}
                        onChange={(e) =>
                          change(i, {
                            unitPrice: e.target.value === '' ? '' : Number(e.target.value),
                          })
                        }
                      />
                    </label>

                    <label>
                      Line discount (₹)
                      <input
                        required
                        type="number"
                        min="0"
                        max={l.qty * Number(l.unitPrice)}
                        step="0.01"
                        value={l.discount}
                        onChange={(e) => change(i, { discount: Number(e.target.value) })}
                      />
                    </label>

                    <label>
                      GST rate (%)
                      <input
                        required
                        type="number"
                        min="0"
                        max="100"
                        step="0.01"
                        value={l.gstRatePct}
                        placeholder="Enter GST rate"
                        onChange={(e) =>
                          change(i, {
                            gstRatePct: e.target.value === '' ? '' : Number(e.target.value),
                          })
                        }
                      />
                    </label>
                  </div>

                  <div className="line-summary">
                    <span>
                      {l.inventoryId
                        ? 'Linked stock will be adjusted on invoice save.'
                        : 'No linked stock. This line does not change inventory.'}
                    </span>
                    <span>
                      Taxable {money(totals[i].taxable)} · GST {money(totals[i].tax)} ·{' '}
                      <strong>{money(totals[i].total)}</strong>
                    </span>
                  </div>
                </div>
              ))}
            </div>

            <button
              type="button"
              className="secondary-button mt-5"
              onClick={() => { setDirty(true); setLines([...lines, blank()]); }}
            >
              <Plus size={15} />
              Add item
            </button>
          </section>

          {/* Notes & totals */}
          <section className="admin-panel mt-5 document-bottom">
            <label>
              Notes / additional terms
              <textarea
                rows={4}
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Payment terms, delivery or other agreed details"
              />
            </label>
            <div className="bill-totals">
              <p>
                <span>Taxable amount</span>
                <strong>{money(net)}</strong>
              </p>
              <p>
                <span>GST</span>
                <strong>{money(tax)}</strong>
              </p>
              <p className="grand-total">
                <span>Total</span>
                <strong>{money(net + tax)}</strong>
              </p>
              <button className="primary-button w-full" type="submit">
                <Save size={16} />
                {busy ? 'Saving…' : `Save ${kind}`}
              </button>
            </div>
          </section>
        </fieldset>
      </form>

      {existing &&
        kind === 'invoice' &&
        !existing.service_job_id &&
        can('invoices.write') &&
        can('vehicles.write') &&
        can('service_approve.write') && (
          <button
            className="secondary-button"
            type="button"
            disabled={busy}
            onClick={() => setCancelOpen(true)}
          >
            Cancel sales invoice
          </button>
        )}
      <ConfirmDialog
        isOpen={cancelOpen}
        title="Cancel sales invoice"
        message="Release the chassis and restore the invoiced stock."
        confirmLabel="Cancel invoice"
        requireInput
        onCancel={() => setCancelOpen(false)}
        onConfirm={async (reason) => {
          setCancelOpen(false);
          setBusy(true);
          try {
            await vehicleRpc('vehicle_cancel_invoice', { p: { invoice_id: id, reason } });
            await store.refresh();
            router.push('/invoices');
          } catch (err) {
            setError(err instanceof Error ? err.message : 'Unable to cancel invoice');
          } finally {
            setBusy(false);
          }
        }}
      />
      <QuickAddCustomerModal
        isOpen={addCustomer}
        onClose={() => setAddCustomer(false)}
        onSuccess={value => { setDirty(true); setCustomer(value); }}
      />
    </div>
  );
}
