export type Product = {
  id: string;
  code: string;
  brand: string;
  family: string;
  model_name: string;
  variant: string;
  category: string;
  status: string;
  specs: Record<string, string | number>;
  selling_price: number | null;
  gst_rate_pct: number | null;
  hsn_code: string | null;
  source_urls: string[];
  source_type: string;
  source_checked_on: string;
  verification_status: string;
  source_excerpt: string;
  notes: string;
};

export type BillingLine = {
  productId: string | null;
  inventoryId: string | null;
  name: string;
  hsnCode: string;
  qty: number;
  unitPrice: number;
  discount: number;
  gstRatePct: number;
  taxable: number;
  tax: number;
  total: number;
};

export type BusinessProfile = {
  id: boolean;
  name: string;
  address: string;
  phone: string;
  email: string;
  gstin: string;
  bank_details: string;
  terms: string;
};

export type BillingDocument = {
  id: string;
  service_job_id?: string | null;
  cancelled_at?: string | null;
  kind: 'quotation' | 'invoice';
  number: string;
  customer_id: string;
  customer_snapshot: {
    name: string;
    phone: string;
    village: string;
    address?: string;
    gstin?: string;
  };
  seller_snapshot: BusinessProfile;
  document_date: string;
  valid_until: string | null;
  due_date?: string | null;
  items: BillingLine[];
  subtotal: number;
  tax_amount: number;
  total: number;
  amount_paid: number;
  tax_mode: 'cgst_sgst' | 'igst';
  notes: string;
  source_quotation_id: string | null;
  created_at: string;
  updated_at: string;
};

export type DocumentInput = {
  id?: string;
  kind: 'quotation' | 'invoice';
  number: string;
  customerId: string;
  date: string;
  validUntil: string | null;
  dueDate?: string | null;
  items: Partial<BillingLine>[];
  taxMode: 'cgst_sgst' | 'igst';
  notes: string;
  sourceQuotationId?: string | null;
  expectedUpdatedAt?: string;
};

export type CollectionFollowup = {
  id: string;
  customer_id: string;
  invoice_id?: string | null;
  contact_method: 'phone' | 'whatsapp' | 'in_person' | 'notice';
  contacted_at: string;
  notes: string;
  ptp_date?: string | null;
  ptp_amount?: number | null;
  status: 'pending' | 'honoured' | 'broken' | 'cancelled';
  created_by: string;
  created_at: string;
};

export type AgingCategory = 'current' | '1_30' | '31_60' | '61_90' | '90_plus';

export function getDaysOverdue(dueDate: string | null | undefined, documentDate: string): number {
  const target = dueDate || documentDate;
  const due = new Date(target).setHours(0, 0, 0, 0);
  const today = new Date().setHours(0, 0, 0, 0);
  const diff = Math.floor((today - due) / (1000 * 60 * 60 * 24));
  return Math.max(0, diff);
}

export function getAgingBucket(daysOverdue: number): AgingCategory {
  if (daysOverdue === 0) return 'current';
  if (daysOverdue <= 30) return '1_30';
  if (daysOverdue <= 60) return '31_60';
  if (daysOverdue <= 90) return '61_90';
  return '90_plus';
}

export const money = (value: number) =>
  new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
  }).format(value);

export function lineTotals(
  line: Pick<BillingLine, 'qty' | 'unitPrice' | 'discount' | 'gstRatePct'>
) {
  const round = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;
  const taxable = round(line.qty * line.unitPrice - line.discount);
  const tax = round((taxable * line.gstRatePct) / 100);
  return { taxable, tax, total: round(taxable + tax) };
}
