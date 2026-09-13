export type Product = {
 id: string; code: string; brand: string; family: string; model_name: string; variant: string; category: string; status: string;
 specs: Record<string,string|number>; selling_price: number|null; gst_rate_pct: number|null; hsn_code: string|null;
 source_urls: string[]; source_type: string; source_checked_on: string; verification_status: string; source_excerpt: string; notes: string;
};
export type BillingLine = { productId: string|null; inventoryId: string|null; name: string; hsnCode: string; qty: number; unitPrice: number; discount: number; gstRatePct: number; taxable: number; tax: number; total: number };
export type BusinessProfile = { id: boolean; name: string; address: string; phone: string; email: string; gstin: string; bank_details: string; terms: string };
export type BillingDocument = { id: string; kind: 'quotation'|'invoice'; number: string; customer_id: string; customer_snapshot: {name:string;phone:string;village:string;address?:string;gstin?:string}; seller_snapshot: BusinessProfile; document_date: string; valid_until: string|null; items: BillingLine[]; subtotal: number; tax_amount: number; total: number; amount_paid: number; tax_mode: 'cgst_sgst'|'igst'; notes: string; source_quotation_id: string|null; created_at: string; updated_at:string };
export type DocumentInput = { id?: string; kind: 'quotation'|'invoice'; number: string; customerId: string; date: string; validUntil: string|null; items: Partial<BillingLine>[]; taxMode: 'cgst_sgst'|'igst'; notes:string; sourceQuotationId?:string|null; expectedUpdatedAt?:string };
export const money = (value:number) => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',minimumFractionDigits:2}).format(value);
export function lineTotals(line: Pick<BillingLine,'qty'|'unitPrice'|'discount'|'gstRatePct'>) { const round=(n:number)=>Math.round((n+Number.EPSILON)*100)/100; const taxable=round(line.qty*line.unitPrice-line.discount); const tax=round(taxable*line.gstRatePct/100); return { taxable,tax,total:round(taxable+tax) }; }
