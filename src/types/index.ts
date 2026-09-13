export type StaffRole = 'owner' | 'salesperson' | 'inventory' | 'mechanic' | 'accountant';

export type VehicleCategory = 'tractor' | 'e_rickshaw' | 'cng_rickshaw' | 'diesel_rickshaw';

export type VehicleStatus = 'in_stock' | 'reserved' | 'sold' | 'delivered';

export type ItemType = 'vehicle' | 'battery' | 'part' | 'implement';

export type QuotationStatus = 'draft' | 'sent' | 'accepted' | 'converted_to_invoice' | 'rejected' | 'expired';

export type SaleStatus = 'pending' | 'confirmed' | 'delivered' | 'cancelled';

export type PaymentMethod = 'cash' | 'upi' | 'bank_transfer' | 'cheque' | 'finance';

export type ServiceJobStatus = 'scheduled' | 'in_progress' | 'completed' | 'cancelled';

export interface Staff {
  id: string;
  name: string;
  phone: string;
  role: StaffRole;
  active: boolean;
}

export interface Customer {
  id: string;
  name: string;
  phone: string;
  altPhone?: string;
  village: string;
  tehsil?: string;
  district?: string;
  state?: string;
  address?: string;
  aadhaarLast4?: string;
  panNo?: string;
  requirementNotes?: string;
  createdAt: string;
}

export interface VehicleModel {
  id: string;
  category: VehicleCategory;
  brand: string;
  modelName: string;
  series?: string;
  hp: number;
  hsnCode: string;
  gstRatePct: number;
  price: number; // Placeholder value clearly marked
  warrantyMonths: number;
  specs: {
    engine?: string;
    cylinders?: number;
    cubicCapacity?: string;
    ptoHp?: number;
    transmission?: string;
    gears?: string;
    liftCapacityKg?: number;
    fuelTankL?: number;
    batteryCapacityAh?: number;
    rangeKm?: number;
    chargingTimeHours?: number;
    seatingCapacity?: number;
  };
  recommendedImplements?: string[]; // IDs of compatible implements
  active: boolean;
}

export interface PhysicalVehicle {
  id: string;
  modelId: string;
  modelName: string;
  category: VehicleCategory;
  chassisNo: string;
  engineNo: string;
  colour: string;
  manufacturingYear: number;
  status: VehicleStatus;
  customerId?: string;
  receivedDate: string;
  price: number;
}

export interface Battery {
  id: string;
  brand: string;
  model: string;
  ah: number;
  voltage: number;
  batteryType: string;
  price: number;
  warrantyMonths: number;
  hsnCode: string;
  gstRatePct: number;
}

export interface BatterySerial {
  id: string;
  batteryId: string;
  serialNo: string;
  status: 'in_stock' | 'sold';
  customerId?: string;
  warrantyEnd?: string;
}

export interface Implement {
  id: string;
  name: string;
  category: string; // Rotavator, MB Plough, Cultivator, etc.
  brand: string;
  price: number;
  hsnCode: string;
  gstRatePct: number;
  minHpRequired: number;
  specs: Record<string, string | number>;
  compatibleModelIds: string[];
}

export interface SparePart {
  id: string;
  partNo: string;
  name: string;
  category: string;
  purchasePrice: number;
  sellingPrice: number;
  hsnCode: string;
  gstRatePct: number;
  compatibleModelIds: string[];
}

export interface InventoryItem {
  id: string;
  itemType: ItemType;
  itemId: string;
  itemName: string;
  skuOrCode: string;
  qtyAvailable: number;
  qtyReserved: number;
  minStockThreshold: number;
  unitPrice: number;
}

export interface QuotationItem {
  itemType: ItemType;
  itemId: string;
  name: string;
  codeOrSerial?: string;
  qty: number;
  unitPrice: number;
  discount: number;
  gstRatePct: number;
  total: number;
}

export interface Quotation {
  id: string;
  quotationNo: string;
  customerId: string;
  customerName: string;
  customerPhone: string;
  customerVillage: string;
  items: QuotationItem[];
  subtotal: number;
  discount: number;
  taxAmount: number;
  total: number;
  validUntil: string;
  status: QuotationStatus;
  notes?: string;
  createdAt: string;
}

export interface Invoice {
  id: string;
  saleId: string;
  invoiceNo: string;
  customerId: string;
  customerName: string;
  customerPhone: string;
  customerVillage: string;
  subtotal: number;
  discount: number;
  cgstAmount: number;
  sgstAmount: number;
  igstAmount: number;
  totalAmount: number;
  amountPaid: number;
  balanceDue: number;
  items: QuotationItem[];
  createdAt: string;
}

export interface Payment {
  id: string;
  invoiceId: string;
  saleId: string;
  amount: number;
  method: PaymentMethod;
  referenceNo?: string;
  paidAt: string;
  receivedByName: string;
}

export interface Sale {
  id: string;
  saleNo: string;
  customerId: string;
  customerName: string;
  customerPhone: string;
  quotationId?: string;
  items: QuotationItem[];
  total: number;
  status: SaleStatus;
  confirmedAt?: string;
  createdAt: string;
}

export interface Warranty {
  id: string;
  itemType: ItemType;
  itemId: string;
  serialNo: string;
  customerName: string;
  customerId: string;
  invoiceNo: string;
  startDate: string;
  endDate: string;
  status: 'active' | 'expired';
}

export interface PDICheck {
  id: string;
  vehicleId: string;
  vehicleName: string;
  chassisNo: string;
  saleId: string;
  passed: boolean;
  inspectedAt?: string;
  inspectedBy?: string;
  checklist: {
    engine: { oilLevel: boolean; coolantLevel: boolean; leakInspection: boolean; fanBelt: boolean };
    electrical: { batteryTerminal: boolean; headlights: boolean; indicators: boolean; horn: boolean; cluster: boolean };
    tyres: { pressureFront: boolean; pressureRear: boolean; wheelNuts: boolean };
    hydraulics: { gearShift: boolean; hydraulicLift: boolean; ptoRotation: boolean; brakes: boolean };
    docs: { paintFinish: boolean; toolKitIncluded: boolean; manualIncluded: boolean };
  };
}

export interface ServiceJob {
  id: string;
  vehicleId: string;
  vehicleName: string;
  chassisNo: string;
  customerId: string;
  customerName: string;
  customerPhone: string;
  jobType: string;
  status: ServiceJobStatus;
  scheduledDate: string;
  completedDate?: string;
  notes?: string;
}

export interface CustomerTimelineEvent {
  id: string;
  customerId: string;
  eventType: 'lead_created' | 'quotation_sent' | 'sale_confirmed' | 'payment_received' | 'pdi_completed' | 'delivered' | 'service_scheduled';
  description: string;
  referenceId?: string;
  occurredAt: string;
}

export interface BillScanResult {
  supplierName: string;
  supplierGstin?: string;
  billNo: string;
  billDate: string;
  items: Array<{
    itemType: ItemType;
    description: string;
    partOrChassisNo?: string;
    qty: number;
    unitPrice: number;
    taxPct: number;
  }>;
  taxAmount: number;
  totalAmount: number;
}
