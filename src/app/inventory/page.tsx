'use client';

import { useState } from 'react';
import { useDealerStore } from '@/lib/store/dealer-store';
import { useAuth } from '@/lib/auth/provider';
import { useToast } from '@/components/ui/Toast';
import { ConfirmDialog } from '@/components/ui/ConfirmDialog';

export default function Inventory() {
  const { inventory, products, movements, receiveStock, adjustStock, loading } =
    useDealerStore();
  const { can } = useAuth();
  const { success, error: showError } = useToast();

  const [search, setSearch] = useState('');
  const [product, setProduct] = useState('');
  const [qty, setQty] = useState(1);
  const [reference, setReference] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  // Confirm dialog state for stock adjustments
  const [adjustDialog, setAdjustDialog] = useState<{
    id: string;
    delta: number;
    name: string;
  } | null>(null);

  async function receive(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      await receiveStock(product, qty, reference);
      success('Stock receipt saved to Supabase.');
      setReference('');
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Unable to save stock';
      setError(msg);
      showError(msg);
    } finally {
      setBusy(false);
    }
  }

  async function handleAdjust(reason?: string) {
    if (!adjustDialog || !reason) return;
    setBusy(true);
    setError('');
    try {
      await adjustStock(adjustDialog.id, 'part', adjustDialog.delta, reason);
      success('Stock adjustment saved.');
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Adjustment failed';
      setError(msg);
      showError(msg);
    } finally {
      setBusy(false);
      setAdjustDialog(null);
    }
  }

  const filteredInventory = inventory.filter((i) =>
    `${i.itemName} ${i.skuOrCode}`.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div>
      {/* Page heading */}
      <div className="page-heading">
        <div>
          <p className="eyebrow">STOCK CONTROL</p>
          <h1>Inventory</h1>
          <p>Actual stock receipts and movements. Product catalogue entries do not create stock.</p>
        </div>
      </div>

      {error && (
        <p role="alert" className="error-message">
          {error}
        </p>
      )}

      {/* Receive stock form */}
      {can('inventory.write') && (
        <form onSubmit={receive} className="admin-panel billing-editor mb-6">
          <h2 className="font-semibold mb-5">Receive stock</h2>
          <div className="form-grid">
            <label>
              Product
              <select
                required
                value={product}
                onChange={(e) => setProduct(e.target.value)}
              >
                <option value="">Choose a product</option>
                {products.map((p) => (
                  <option value={p.id} key={p.id}>
                    {p.brand} {p.model_name} {p.variant}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Quantity
              <input
                required
                type="number"
                min="1"
                step="1"
                value={qty}
                onChange={(e) => setQty(Number(e.target.value))}
              />
            </label>
            <label>
              Purchase bill / receipt reference
              <input
                required
                minLength={3}
                value={reference}
                onChange={(e) => setReference(e.target.value)}
              />
            </label>
          </div>
          <button className="primary-button" disabled={busy}>
            {busy ? 'Saving…' : 'Confirm stock receipt'}
          </button>
        </form>
      )}

      {/* Search */}
      <input
        className="search-field"
        aria-label="Search stock"
        placeholder="Search product or SKU"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      {/* Stock table */}
      <section className="admin-panel overflow-x-auto">
        <table className="team-table">
          <thead>
            <tr>
              <th>PRODUCT</th>
              <th>SKU</th>
              <th>IN STOCK</th>
              <th>RESERVED</th>
              <th>AVAILABLE</th>
              <th>ADJUST</th>
            </tr>
          </thead>
          <tbody>
            {filteredInventory.map((i) => (
              <tr key={i.id}>
                <td>{i.itemName}</td>
                <td>{i.skuOrCode}</td>
                <td>{i.qtyAvailable}</td>
                <td>{i.qtyReserved}</td>
                <td>{i.qtyAvailable - i.qtyReserved}</td>
                <td>
                  <button
                    className="secondary-button"
                    disabled={
                      busy ||
                      !can('inventory.write') ||
                      i.qtyAvailable <= i.qtyReserved
                    }
                    onClick={() =>
                      setAdjustDialog({ id: i.id, delta: -1, name: i.itemName })
                    }
                  >
                    −1
                  </button>{' '}
                  <button
                    className="secondary-button"
                    disabled={busy || !can('inventory.write')}
                    onClick={() =>
                      setAdjustDialog({ id: i.id, delta: 1, name: i.itemName })
                    }
                  >
                    +1
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!loading && !inventory.length && (
          <p className="empty-state">No stock received yet.</p>
        )}
      </section>

      {/* Stock movement ledger */}
      <section className="admin-panel mt-6 overflow-x-auto">
        <h2 className="font-semibold mb-4">Stock movement ledger</h2>
        <table className="team-table">
          <thead>
            <tr>
              <th>DATE</th>
              <th>PRODUCT</th>
              <th>CHANGE</th>
              <th>BEFORE → AFTER</th>
              <th>REFERENCE</th>
            </tr>
          </thead>
          <tbody>
            {movements.map((m) => (
              <tr key={m.id}>
                <td>{new Date(m.created_at).toLocaleString('en-IN')}</td>
                <td>
                  {inventory.find((i) => i.id === m.inventory_id)?.itemName ||
                    m.inventory_id}
                </td>
                <td>
                  {m.delta > 0 ? '+' : ''}
                  {m.delta}
                </td>
                <td>
                  {m.before_qty} → {m.after_qty}
                </td>
                <td>{m.reference}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {!movements.length && (
          <p className="empty-state">No stock movements recorded.</p>
        )}
      </section>

      {/* Stock adjustment confirm dialog — replaces browser prompt() */}
      <ConfirmDialog
        isOpen={!!adjustDialog}
        title="Stock adjustment"
        message={
          adjustDialog
            ? `${adjustDialog.delta > 0 ? 'Increase' : 'Decrease'} ${adjustDialog.name} by ${Math.abs(adjustDialog.delta)} unit(s). Enter a reason or reference for this adjustment.`
            : ''
        }
        confirmLabel="Apply adjustment"
        requireInput
        inputLabel="Reason / reference"
        inputPlaceholder="e.g. Damaged stock, returned by customer, physical count correction"
        onConfirm={(reason) => void handleAdjust(reason)}
        onCancel={() => setAdjustDialog(null)}
      />
    </div>
  );
}
