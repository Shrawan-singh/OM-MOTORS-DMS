import { BillingDocument, money } from '@/lib/billing/types';

export function DocumentSheet({ doc }: { doc: BillingDocument }) {
  const seller = doc.seller_snapshot;
  const customer = doc.customer_snapshot;

  return (
    <article className="document-sheet">
      {/* Header — Seller info & document type */}
      <header className="print-header">
        <div>
          <h1>{seller.name}</h1>
          {seller.address && <p className="preserve-lines">{seller.address}</p>}
          {seller.phone && <p>Phone: {seller.phone}</p>}
          {seller.email && <p>{seller.email}</p>}
          {seller.gstin && (
            <p>
              <strong>GSTIN:</strong> {seller.gstin}
            </p>
          )}
        </div>
        <div className="print-title">
          <h2>{doc.kind === 'invoice' ? 'INVOICE' : 'QUOTATION'}</h2>
          <strong>{doc.number}</strong>
          <p>Date: {doc.document_date}</p>
          {doc.valid_until && <p>Valid until: {doc.valid_until}</p>}
        </div>
      </header>

      {/* Customer info */}
      <section className="print-customer">
        <div>
          <h3>{doc.kind === 'invoice' ? 'BILL TO' : 'PREPARED FOR'}</h3>
          <strong>{customer.name}</strong>
          <p>{customer.address || customer.village}</p>
          {customer.address && customer.village && <p>{customer.village}</p>}
          <p>Phone: {customer.phone}</p>
          {customer.gstin && <p>GSTIN: {customer.gstin}</p>}
        </div>
        <div>
          <h3>TAX TREATMENT</h3>
          <p>{doc.tax_mode === 'igst' ? 'IGST' : 'CGST + SGST'}</p>
          <p>All prices in Indian Rupees (INR)</p>
        </div>
      </section>

      {/* Line items table */}
      <table className="print-items">
        <thead>
          <tr>
            <th>#</th>
            <th>Description / HSN</th>
            <th>Qty</th>
            <th>Rate ₹</th>
            <th>Discount ₹</th>
            <th>Taxable ₹</th>
            <th>GST %</th>
            <th>GST ₹</th>
            <th>Total ₹</th>
          </tr>
        </thead>
        <tbody>
          {doc.items.map((line, i) => (
            <tr key={i}>
              <td>{i + 1}</td>
              <td>
                <strong>{line.name}</strong>
                {line.hsnCode && <small>HSN / SAC: {line.hsnCode}</small>}
              </td>
              <td>{line.qty}</td>
              <td>{line.unitPrice.toFixed(2)}</td>
              <td>{line.discount.toFixed(2)}</td>
              <td>{line.taxable.toFixed(2)}</td>
              <td>{line.gstRatePct}%</td>
              <td>{line.tax.toFixed(2)}</td>
              <td>{line.total.toFixed(2)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      {/* Summary — notes, terms, totals */}
      <section className="print-summary">
        <div>
          {doc.notes && (
            <>
              <h3>NOTES</h3>
              <p className="preserve-lines">{doc.notes}</p>
            </>
          )}
          {seller.terms && (
            <>
              <h3>TERMS</h3>
              <p className="preserve-lines">{seller.terms}</p>
            </>
          )}
          {seller.bank_details && (
            <>
              <h3>PAYMENT DETAILS</h3>
              <p className="preserve-lines">{seller.bank_details}</p>
            </>
          )}
        </div>

        <div className="print-totals">
          <p>
            <span>Taxable amount</span>
            <strong>{money(doc.subtotal)}</strong>
          </p>

          {doc.tax_mode === 'igst' ? (
            <p>
              <span>IGST</span>
              <strong>{money(doc.tax_amount)}</strong>
            </p>
          ) : (
            <>
              <p>
                <span>CGST</span>
                <strong>{money(Math.round(doc.tax_amount * 50) / 100)}</strong>
              </p>
              <p>
                <span>SGST</span>
                <strong>
                  {money(doc.tax_amount - Math.round(doc.tax_amount * 50) / 100)}
                </strong>
              </p>
            </>
          )}

          <p className="total">
            <span>Grand total</span>
            <strong>{money(doc.total)}</strong>
          </p>

          {doc.kind === 'invoice' && (
            <>
              <p>
                <span>Amount paid</span>
                <strong>{money(doc.amount_paid)}</strong>
              </p>
              <p>
                <span>Balance due</span>
                <strong>{money(doc.total - doc.amount_paid)}</strong>
              </p>
            </>
          )}
        </div>
      </section>

      {/* Footer */}
      <footer className="print-footer">
        <p>
          {doc.kind === 'quotation'
            ? 'This quotation is an estimate and is not a tax invoice.'
            : 'Thank you for your business.'}
        </p>
        <div>
          For {seller.name}
          <br />
          <br />
          <br />
          Authorised signatory
        </div>
      </footer>
    </article>
  );
}
