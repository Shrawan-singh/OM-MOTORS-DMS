export type Row = Record<string, any>;

export type WorkshopJob = {
  id: string;
  number: string;
  vehicle_id: string;
  customer_id: string;
  job_type: string;
  priority: string;
  status: string;
  complaint: string;
  diagnosis?: string;
  findings?: string;
  work_performed?: string;
  recommended_work?: string;
  notes?: string;
  received_at: string;
  expected_date?: string;
  completed_date?: string;
  next_service_date?: string;
  next_service_meter?: number;
  meter?: number;
  meter_unit: 'hours' | 'km';
  labour_hours: number;
  technician_emails: string[];
  parts_used: WorkshopPartUsed[];
  financials: WorkshopFinancials;
  invoice_id?: string;
  updated_at?: string;
};

export type WorkshopPartUsed = {
  inventoryId: string;
  qty: number;
};

export type WorkshopFinancials = {
  rates: Record<string, PartRate>;
  labour_charge?: number;
  labour_cost?: number;
  labour_gst?: number;
  labour_discount?: number;
  labour_hsn?: string;
};

export type PartRate = {
  price?: number;
  cost?: number;
  gst?: number;
  discount?: number;
  hsn?: string;
};

export type WorkshopVehicle = {
  id: string;
  customer_id: string;
  product_id?: string;
  model_name: string;
  variant?: string;
  vehicle_type: string;
  chassis_no: string;
  engine_no?: string;
  motor_no?: string;
  battery_no?: string;
  registration_no?: string;
  colour?: string;
  manufacturer?: string;
  location?: string;
  lifecycle: string;
  received_at?: string;
  received_date?: string;
  shipment_ref?: string;
  supplier_invoice?: string;
  inspector_email?: string;
  purchase_date?: string;
  purchase_invoice_id?: string;
  intake?: boolean;
  correction_reason?: string;
  created_at?: string;
  updated_at?: string;
};

export type WorkshopPDI = {
  id: string;
  vehicle_id: string;
  inspector_email: string;
  result: 'pending' | 'passed' | 'failed' | 'issues';
  corrective_action?: string;
  responsible_email?: string;
  checklist: PDIChecklistItem[];
  inspected_at?: string;
  created_at?: string;
  updated_at?: string;
};

export type PDIChecklistItem = {
  id: string;
  section: string;
  label: string;
  required: boolean;
  result: '' | 'pass' | 'fail' | 'na';
  notes: string;
};

export type WorkshopWarranty = {
  id: string;
  customer_id: string;
  vehicle_id?: string;
  product_id?: string;
  item_type: string;
  product_name: string;
  brand?: string;
  serial_no: string;
  billing_invoice_id?: string;
  invoice_no?: string;
  start_date: string;
  end_date: string;
  coverage_evidence: string;
  created_at?: string;
  updated_at?: string;
};

export type WorkshopClaim = {
  id: string;
  number?: string;
  warranty_id: string;
  job_id?: string;
  complaint_description: string;
  diagnosis?: string;
  technician_email?: string;
  status: string;
  review_reason?: string;
  replacement_product_id?: string;
  replacement_serial?: string;
  resolution?: string;
  notes?: string;
  created_at?: string;
  updated_at?: string;
};

export type WorkshopDelivery = {
  id: string;
  vehicle_id: string;
  invoice_id: string;
  assigned_email: string;
  checklist: Record<string, boolean>;
  notes?: string;
  override_reason?: string;
  finish?: boolean;
  signed_at?: string;
  created_at?: string;
  updated_at?: string;
};

export type WorkshopTemplate = {
  id: string;
  name: string;
  vehicle_type: string;
  items: PDIChecklistItem[];
  created_at?: string;
  updated_at?: string;
};

export type WorkshopTechnician = {
  email: string;
  role: string;
};

export type WorkshopEvent = {
  id: string;
  record_id: string;
  vehicle_id?: string;
  action: string;
  role: string;
  actor: string;
  reason?: string;
  created_at: string;
};

export type WorkshopData = {
  jobs: Row[];
  vehicles: Row[];
  customers: Row[];
  products: Row[];
  inventory: Row[];
  technicians: Row[];
  pdi: Row[];
  templates: Row[];
  warranties: Row[];
  claims: Row[];
  deliveries: Row[];
  invoices: Row[];
  payments: Row[];
  events: Row[];
};

export const emptyWorkshop: WorkshopData = {
  jobs: [],
  vehicles: [],
  customers: [],
  products: [],
  inventory: [],
  technicians: [],
  pdi: [],
  templates: [],
  warranties: [],
  claims: [],
  deliveries: [],
  invoices: [],
  payments: [],
  events: [],
};

export const jobStatuses = [
  'new',
  'assigned',
  'vehicle_received',
  'inspection',
  'work_in_progress',
  'waiting_for_parts',
  'ready_for_delivery',
  'invoiced',
  'paid',
  'completed',
];

export const serviceTypes = [
  'General Service',
  'Periodic Service',
  'Breakdown',
  'Engine Repair',
  'Hydraulic',
  'Electrical',
  'Brake',
  'Battery',
  'Tyre',
  'Warranty',
  'Other',
];

export const label = (s: string) =>
  s.replaceAll('_', ' ').replace(/\b\w/g, (c) => c.toUpperCase());

export const today = () => new Date().toLocaleDateString('en-CA');

export const warrantyStatus = (w: Row) => {
  const now = new Date();
  const end = new Date(w.end_date + 'T23:59:59');
  if (new Date(w.start_date) > now) return 'Not started';
  if (end < now) return 'Expired';
  if (end.getTime() - now.getTime() < 30 * 86400000) return 'Expiring soon';
  return 'Active';
};
