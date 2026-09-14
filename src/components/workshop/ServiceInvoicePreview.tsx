'use client';
import { Row, WorkshopData, label } from '@/lib/workshop/types';
import { money } from '@/lib/billing/types';

type Props = {
    job: Row;
    vehicle?: Row;
    customer?: Row;
    data: WorkshopData;
    taxMode: string;
};

export function ServiceInvoicePreview({ job, vehicle, customer, data, taxMode }: Props) {
    const round = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;

    // Build line items from parts
    const partLines = (job.parts_used || [])
        .filter((p: Row) => p.inventoryId)
        .map((p: Row) => {
            const inv = data.inventory.find(s => s.id === p.inventoryId);
            const r = job.financials?.rates?.[p.inventoryId] || {};
            const qty = Number(p.qty) || 0;
            const unitPrice = Number(r.price) || 0;
            const discount = Number(r.discount) || 0;
            const gstPct = Number(r.gst) || 0;
            const hsn = r.hsn || '';
            const taxable = round(Math.max(0, qty * unitPrice - discount));
            const tax = round(taxable * gstPct / 100);
            const total = round(taxable + tax);
            return { name: inv?.item_name || 'Part', hsn, qty, unitPrice, discount, taxable, gstPct, tax, total };
        });

    // Labour line
    const labourCharge = Number(job.financials?.labour_charge) || 0;
    const labourDiscount = Number(job.financials?.labour_discount) || 0;
    const labourGst = Number(job.financials?.labour_gst) || 0;
    const labourHsn = job.financials?.labour_hsn || '';
    const labourTaxable = round(Math.max(0, labourCharge - labourDiscount));
    const labourTax = round(labourTaxable * labourGst / 100);
    const labourTotal = round(labourTaxable + labourTax);
    const hasLabour = labourCharge > 0;

    // Totals
    const allLines = [...partLines, ...(hasLabour ? [{ name: 'Labour / Service', hsn: labourHsn, qty: 1, unitPrice: labourCharge, discount: labourDiscount, taxable: labourTaxable, gstPct: labourGst, tax: labourTax, total: labourTotal }] : [])];
    const subtotal = round(allLines.reduce((s, l) => s + l.taxable, 0));
    const totalTax = round(allLines.reduce((s, l) => s + l.tax, 0));
    const grandTotal = round(subtotal + totalTax);
    const totalDiscount = round(allLines.reduce((s, l) => s + l.discount, 0));

    if (allLines.length === 0 && grandTotal === 0) {
        return <div className="ws-invoice-preview"><p className="ws-muted">Add parts or labour charges to see the live invoice preview.</p></div>;
    }

    return (
        <div className="ws-invoice-preview">
            <div className="ws-inv-header">
                <h4>LIVE INVOICE PREVIEW</h4>
                <span className="ws-inv-badge">Draft · Updates as you type</span>
            </div>

            {/* Seller + Customer */}
            <div className="ws-inv-parties">
                <div>
                    <small>FROM</small>
                    <strong>OM Motors</strong>
                </div>
                <div>
                    <small>{customer ? 'BILL TO' : 'CUSTOMER'}</small>
                    <strong>{customer?.name || '—'}</strong>
                    {customer?.phone && <span>{customer.phone}</span>}
                    {customer?.village && <span>{customer.village}</span>}
                </div>
            </div>

            {/* Vehicle + Job */}
            {vehicle && (
                <div className="ws-inv-vehicle">
                    <span><strong>{vehicle.model_name}</strong> {vehicle.variant || ''} · {label(vehicle.vehicle_type)}</span>
                    <span>Chassis: {vehicle.chassis_no || '—'} · Engine: {vehicle.engine_no || '—'} · Motor: {vehicle.motor_no || '—'} · Battery: {vehicle.battery_no || '—'}</span>
                    {job.number && <span>Job: {job.number}</span>}
                </div>
            )}

            {/* Line items table */}
            <table className="ws-inv-table">
                <thead>
                    <tr>
                        <th>#</th>
                        <th>Description / HSN</th>
                        <th>Qty</th>
                        <th>Rate ₹</th>
                        <th>Disc ₹</th>
                        <th>Taxable ₹</th>
                        <th>GST %</th>
                        <th>GST ₹</th>
                        <th>Total ₹</th>
                    </tr>
                </thead>
                <tbody>
                    {allLines.map((line, i) => (
                        <tr key={i}>
                            <td>{i + 1}</td>
                            <td><strong>{line.name}</strong>{line.hsn && <small>HSN: {line.hsn}</small>}</td>
                            <td>{line.qty}</td>
                            <td>{line.unitPrice.toFixed(2)}</td>
                            <td>{line.discount.toFixed(2)}</td>
                            <td>{line.taxable.toFixed(2)}</td>
                            <td>{line.gstPct}%</td>
                            <td>{line.tax.toFixed(2)}</td>
                            <td>{line.total.toFixed(2)}</td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* Summary */}
            <div className="ws-inv-summary">
                <div className="ws-inv-totals">
                    {totalDiscount > 0 && <p><span>Total Discount:</span><strong className="ws-text-red">−{money(totalDiscount)}</strong></p>}
                    <p><span>Taxable Amount:</span><strong>{money(subtotal)}</strong></p>
                    {taxMode === 'igst' ? (
                        <p><span>IGST:</span><strong>{money(totalTax)}</strong></p>
                    ) : (
                        <>
                            <p><span>CGST:</span><strong>{money(round(totalTax / 2))}</strong></p>
                            <p><span>SGST:</span><strong>{money(round(totalTax - round(totalTax / 2)))}</strong></p>
                        </>
                    )}
                    <p className="ws-inv-grand"><span>Grand Total:</span><strong>{money(grandTotal)}</strong></p>
                </div>
            </div>
        </div>
    );
}
