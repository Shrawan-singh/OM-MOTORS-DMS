import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverSupabase } from '@/lib/supabase/server';
import { BillingDocument, money } from '@/lib/billing/types';
import { PrintButton } from './PrintButton';
import { Receipt, CheckCircle, Building } from 'lucide-react';

export async function PrintReceipt({ invoiceId, paymentId }: { invoiceId: string; paymentId: string }) {
  const db = await serverSupabase();
  const { data: { user } } = await db.auth.getUser();
  if (!user) notFound();

  const [invRes, payRes, profRes] = await Promise.all([
    db.from('billing_documents').select('*').eq('id', invoiceId).eq('kind', 'invoice').single(),
    db.from('billing_payments').select('*').eq('id', paymentId).single(),
    db.from('business_profile').select('*').eq('id', true).single(),
  ]);

  if (invRes.error || !invRes.data || payRes.error || !payRes.data) notFound();

  const inv = invRes.data as BillingDocument;
  const pay = payRes.data as {
    id: string;
    invoice_id: string;
    amount: number;
    method: string;
    reference_no: string;
    paid_at: string;
  };
  const profile = profRes.data || inv.seller_snapshot;

  const receiptNumber = `REC-${pay.paid_at.slice(0, 4)}-${pay.id.slice(0, 8).toUpperCase()}`;

  return (
    <div className="document-frame">
      <div className="print-toolbar">
        <Link href="/invoices">← Back to Invoices</Link>
        <span>Print only this receipt. For a clean PDF, turn off browser headers and footers.</span>
        <PrintButton />
      </div>

      <div className="document-sheet">
        {/* Header */}
        <header className="document-header">
          <div>
            <p className="eyebrow flex items-center gap-1">
              <Building size={14} /> {profile.name || 'OM Motors'}
            </p>
            <h1 className="text-xl font-bold">OFFICIAL PAYMENT RECEIPT</h1>
            <p className="document-meta">Receipt No: <strong>{receiptNumber}</strong></p>
            <p className="document-meta">Date: {new Date(pay.paid_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}</p>
          </div>
          <div className="seller-block">
            <strong>{profile.name}</strong>
            <p>{profile.address}</p>
            <p>Phone: {profile.phone}</p>
            {profile.gstin && <p>GSTIN: {profile.gstin}</p>}
          </div>
        </header>

        {/* Customer & Invoice Box */}
        <div className="party-grid">
          <div className="party-card">
            <span className="party-label">Received With Thanks From</span>
            <strong>{inv.customer_snapshot.name}</strong>
            <p>Phone: {inv.customer_snapshot.phone}</p>
            <p>Village / Location: {inv.customer_snapshot.village}</p>
            {inv.customer_snapshot.address && <p>{inv.customer_snapshot.address}</p>}
            {inv.customer_snapshot.gstin && <p>GSTIN: {inv.customer_snapshot.gstin}</p>}
          </div>
          <div className="party-card">
            <span className="party-label">Against Tax Invoice</span>
            <strong>Invoice No: {inv.number}</strong>
            <p>Dated: {inv.document_date}</p>
            <p>Total Invoice Value: {money(inv.total)}</p>
            <p className="text-emerald-700 font-semibold flex items-center gap-1 mt-1">
              <CheckCircle size={14} /> Valid Dealership Voucher
            </p>
          </div>
        </div>

        {/* Receipt Particulars Table */}
        <table className="items-table my-6">
          <thead>
            <tr>
              <th>Description / Particulars</th>
              <th>Payment Mode</th>
              <th>Reference / UTR / Cheque No.</th>
              <th className="num">Amount Received</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <strong>Payment Received towards Tax Invoice {inv.number}</strong>
                <p className="text-xs text-slate-500 mt-0.5">
                  Items: {inv.items.map((i) => i.name).slice(0, 2).join(', ')}{inv.items.length > 2 ? '…' : ''}
                </p>
              </td>
              <td className="uppercase font-medium">{pay.method.replace('_', ' ')}</td>
              <td className="font-mono">{pay.reference_no || '—'}</td>
              <td className="num font-bold text-base text-emerald-800">{money(pay.amount)}</td>
            </tr>
          </tbody>
        </table>

        {/* Financial Summary */}
        <div className="totals-wrap">
          <div className="payment-terms">
            <strong>Account Status after this Payment</strong>
            <p className="text-xs text-slate-600 mt-1">
              Original Invoice Amount: {money(inv.total)}<br />
              Total Cumulative Paid: {money(inv.amount_paid)}<br />
              Remaining Balance Due: <strong className={inv.total - inv.amount_paid > 0 ? 'text-amber-700' : 'text-emerald-700'}>{money(inv.total - inv.amount_paid)}</strong>
            </p>
          </div>
          <div className="totals-box">
            <div>
              <span>Amount Received</span>
              <strong>{money(pay.amount)}</strong>
            </div>
          </div>
        </div>

        {/* Footer & Signatures */}
        <footer className="document-footer mt-12">
          <div>
            <div className="w-44 border-b border-slate-400 mb-1"></div>
            <span>Customer Signature</span>
          </div>
          <div className="text-right">
            <div className="w-48 border-b border-slate-400 mb-1 ml-auto"></div>
            <span>Authorized Signatory · {profile.name}</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
