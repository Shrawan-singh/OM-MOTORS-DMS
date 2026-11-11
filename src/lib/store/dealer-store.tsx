'use client';

import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import { useAuth } from '@/lib/auth/provider';
import { supabase } from '@/lib/supabase/client';
import type {
  Customer,
  StaffRole,
  InventoryItem,
  VehicleModel,
  Implement,
  SparePart,
  Battery,
  Quotation,
  Invoice,
  Payment,
  CustomerTimelineEvent,
  ItemType,
  CustomerAsset,
  CustomerAssetHistory,
} from '@/types';
import type {
  Product,
  BillingDocument,
  BusinessProfile,
  DocumentInput,
  CollectionFollowup,
} from '@/lib/billing/types';

type Row = Record<string, any>;

type State = {
  products: Product[];
  documents: BillingDocument[];
  profile: BusinessProfile | null;
  customers: Customer[];
  inventory: InventoryItem[];
  vehicleModels: VehicleModel[];
  implementsList: Implement[];
  parts: SparePart[];
  batteries: Battery[];
  quotations: Quotation[];
  invoices: Invoice[];
  payments: Payment[];
  timeline: CustomerTimelineEvent[];
  movements: Row[];
  collectionFollowups: CollectionFollowup[];
  customerAssets: CustomerAsset[];
};

const empty: State = {
  products: [],
  documents: [],
  profile: null,
  customers: [],
  inventory: [],
  vehicleModels: [],
  implementsList: [],
  parts: [],
  batteries: [],
  quotations: [],
  invoices: [],
  payments: [],
  timeline: [],
  movements: [],
  collectionFollowups: [],
  customerAssets: [],
};

type Store = State & {
  activeRole: StaffRole;
  loading: boolean;
  initialized: boolean;
  error: string;
  refresh: (opts?: { background?: boolean }) => Promise<void>;
  quickAddCustomer: (data: {
    name: string;
    phone: string;
    village: string;
    requirementNotes?: string;
  }) => Promise<Customer>;
  getCustomerById: (id: string) => Customer | undefined;
  saveDocument: (data: DocumentInput) => Promise<BillingDocument>;
  recordPayment: (
    invoiceId: string,
    amount: number,
    method: string,
    reference: string,
    requestId: string
  ) => Promise<void>;
  adjustStock: (id: string, type: ItemType, delta: number, reason: string) => Promise<void>;
  receiveStock: (product: string, qty: number, reference: string) => Promise<void>;
  savePricing: (id: string, price: number | null, gst: number | null, hsn: string) => Promise<void>;
  saveProfile: (profile: BusinessProfile) => Promise<void>;
  logFollowup: (data: {
    customerId: string;
    invoiceId?: string | null;
    method: 'phone' | 'whatsapp' | 'in_person' | 'notice';
    notes: string;
    ptpDate?: string | null;
    ptpAmount?: number | null;
  }) => Promise<void>;
  updateFollowupStatus: (
    id: string,
    status: 'pending' | 'honoured' | 'broken' | 'cancelled'
  ) => Promise<void>;
  registerInvoiceAssets: (invoiceId: string, assets: Array<{
    lineIndex: number;
    chassisNo?: string;
    engineNo?: string;
    motorNo?: string;
    batterySerial?: string;
    serialNo?: string;
    registrationNo?: string;
    warrantyMonths?: number;
    notes?: string;
  }>) => Promise<any>;
  fetchCustomerAssets: (customerId: string) => Promise<{ assets: CustomerAsset[]; history: CustomerAssetHistory[] }>;
};

const Context = createContext<Store | null>(null);

const db = () => {
  if (!supabase) throw new Error('Supabase configuration is missing.');
  return supabase;
};

const friendly = (e: { message: string; code?: string }) =>
  e.code === 'PGRST205' || e.code === 'PGRST202'
    ? 'Database upgrade required. Apply supabase/UPGRADE_LIVE_OPERATIONS.sql in the Supabase SQL Editor, then refresh.'
    : e.message;

export function DealerStoreProvider({ children }: { children: React.ReactNode }) {
  const { role, email, permissions } = useAuth();
  const [state, setState] = useState<State>(empty);
  const [loading, setLoading] = useState(true);
  const [initialized, setInitialized] = useState(false);
  const initializedRef = useRef(false);
  const [error, setError] = useState('');
  const generation = useRef(0);
  const permissionKey = permissions.join('|');

  const refresh = useCallback(async (opts?: { background?: boolean }) => {
    const isBackground = opts?.background ?? initializedRef.current;
    const gen = ++generation.current;
    if (!role) {
      setState(empty);
      setLoading(false);
      return;
    }
    if (!isBackground) {
      setLoading(true);
    }
    setError('');

    const can = (p: string) => role === 'owner' || permissionKey.split('|').includes(p);
    const next: State = { ...empty };

    const fetchRows = async (table: string, allowed: boolean, select = '*') => {
      if (!allowed) return [];
      const rows: Row[] = [];
      for (let offset = 0; ; offset += 500) {
        const { data, error } = await db()
          .from(table)
          .select(select)
          .order('id')
          .range(offset, offset + 499);
        if (error) throw new Error(friendly(error));
        const page = (data || []) as unknown as Row[];
        rows.push(...page);
        if (page.length < 500) break;
      }
      return rows;
    };

    try {
      const [
        products,
        customers,
        documents,
        profile,
        inventory,
        payments,
        timeline,
        movements,
        followups,
        assets,
      ] = await Promise.all([
        fetchRows(
          'catalog_products',
          can('catalogue.read') ||
            can('quotations.write') ||
            can('invoices.write') ||
            can('inventory.read')
        ),
        fetchRows('customers', can('customers.read')),
        fetchRows('billing_documents', can('quotations.read') || can('invoices.read')),
        fetchRows('business_profile', true),
        fetchRows('inventory', can('inventory.read')),
        fetchRows('billing_payments', can('invoices.read')),
        fetchRows('customer_timeline', can('customers.read')),
        fetchRows('stock_movements', can('inventory.read')),
        fetchRows('collection_followups', can('invoices.read') || can('customers.read')).catch(
          () => [] as Row[]
        ),
        fetchRows('customer_assets', can('customers.read') || can('invoices.read') || can('service.read')).catch(
          () => [] as Row[]
        ),
      ]);

      next.products = products as Product[];
      next.documents = (documents as (BillingDocument & { cancelled_at?: string })[])
        .filter((d) => !d.cancelled_at)
        .sort((a, b) => b.created_at.localeCompare(a.created_at));
      next.profile = (profile[0] as BusinessProfile) || null;

      next.customers = customers.map((c) => ({
        id: c.id,
        name: c.name,
        phone: c.phone,
        village: c.village,
        address: c.address,
        requirementNotes: c.notes,
        creditLimit: c.credit_limit ? Number(c.credit_limit) : 0,
        paymentTermsDays: c.payment_terms_days ? Number(c.payment_terms_days) : 15,
        collectionPriority: c.collection_priority || 'normal',
        createdAt: c.created_at,
      }));

      next.inventory = inventory.map((i) => ({
        id: i.id,
        itemType: i.item_type,
        itemId: i.item_id,
        itemName: i.item_name,
        skuOrCode: i.sku_or_code || '',
        qtyAvailable: i.qty_available,
        qtyReserved: i.qty_reserved,
        minStockThreshold: i.min_stock_threshold,
        unitPrice: products.find((p) => p.id === i.item_id)?.selling_price ?? 0,
      }));

      const items = (d: BillingDocument) =>
        d.items.map((i) => ({
          itemType: 'part' as ItemType,
          itemId: i.productId || '',
          name: i.name,
          qty: i.qty,
          unitPrice: i.unitPrice,
          discount: i.discount,
          gstRatePct: i.gstRatePct,
          total: i.total,
          codeOrSerial: i.hsnCode,
        }));

      next.quotations = next.documents
        .filter((d) => d.kind === 'quotation')
        .map((d) => ({
          id: d.id,
          quotationNo: d.number,
          customerId: d.customer_id,
          customerName: d.customer_snapshot.name,
          customerPhone: d.customer_snapshot.phone,
          customerVillage: d.customer_snapshot.village,
          items: items(d),
          subtotal: d.subtotal,
          discount: 0,
          taxAmount: d.tax_amount,
          total: d.total,
          validUntil: d.valid_until || '',
          status: next.documents.some((i) => i.source_quotation_id === d.id)
            ? 'converted_to_invoice'
            : 'draft',
          notes: d.notes,
          createdAt: d.created_at,
        }));

      next.invoices = next.documents
        .filter((d) => d.kind === 'invoice')
        .map((d) => ({
          id: d.id,
          saleId: '',
          invoiceNo: d.number,
          customerId: d.customer_id,
          customerName: d.customer_snapshot.name,
          customerPhone: d.customer_snapshot.phone,
          customerVillage: d.customer_snapshot.village,
          items: items(d),
          subtotal: d.subtotal,
          discount: 0,
          cgstAmount: d.tax_mode === 'cgst_sgst' ? d.tax_amount / 2 : 0,
          sgstAmount: d.tax_mode === 'cgst_sgst' ? d.tax_amount / 2 : 0,
          igstAmount: d.tax_mode === 'igst' ? d.tax_amount : 0,
          totalAmount: d.total,
          amountPaid: d.amount_paid,
          balanceDue: d.total - d.amount_paid,
          dueDate: d.due_date || d.document_date,
          createdAt: d.created_at,
        }));

      next.payments = payments.map((p) => ({
        id: p.id,
        invoiceId: p.invoice_id,
        saleId: '',
        amount: p.amount,
        method: p.method,
        referenceNo: p.reference_no,
        paidAt: p.paid_at,
        receivedByName: p.received_by,
      }));

      next.timeline = timeline.map((t) => ({
        id: t.id,
        customerId: t.customer_id,
        eventType: t.event_type,
        description: t.description,
        referenceId: t.reference_id,
        occurredAt: t.occurred_at,
      }));
      next.movements = movements.sort((a, b) => b.created_at.localeCompare(a.created_at));

      next.collectionFollowups = (followups || []).map((f: Row) => ({
        id: f.id,
        customer_id: f.customer_id,
        invoice_id: f.invoice_id,
        contact_method: f.contact_method,
        contacted_at: f.contacted_at,
        notes: f.notes,
        ptp_date: f.ptp_date,
        ptp_amount: f.ptp_amount ? Number(f.ptp_amount) : null,
        status: f.status,
        created_by: f.created_by,
        created_at: f.created_at,
      }));

      next.customerAssets = (assets || []).map((a: Row) => ({
        id: a.id,
        customerId: a.customer_id,
        billingInvoiceId: a.billing_invoice_id,
        vehicleId: a.vehicle_id,
        warrantyId: a.warranty_id,
        itemType: a.item_type,
        productId: a.product_id,
        productName: a.product_name,
        brand: a.brand || '',
        chassisNo: a.chassis_no || '',
        engineNo: a.engine_no || '',
        motorNo: a.motor_no || '',
        batterySerial: a.battery_serial || '',
        serialNo: a.serial_no || '',
        registrationNo: a.registration_no || '',
        warrantyMonths: a.warranty_months || 0,
        warrantyStart: a.warranty_start,
        warrantyEnd: a.warranty_end,
        status: a.status || 'active',
        replacedBy: a.replaced_by,
        replaces: a.replaces,
        notes: a.notes || '',
        createdAt: a.created_at,
        updatedAt: a.updated_at,
      }));

      if (gen === generation.current) {
        setState(next);
        setInitialized(true);
        initializedRef.current = true;
      }
    } catch (e) {
      if (gen === generation.current) {
        if (!initializedRef.current) {
          setState(empty);
        }
        setError(e instanceof Error ? e.message : 'Unable to load dealership data.');
      }
    } finally {
      if (gen === generation.current) setLoading(false);
    }
  }, [role, email, permissionKey]);

  useEffect(() => {
    localStorage.removeItem('om_motors_dealeros_state_v1');
    void refresh({ background: initializedRef.current });
    const focus = () => void refresh({ background: true });
    window.addEventListener('focus', focus);
    return () => {
      generation.current++;
      window.removeEventListener('focus', focus);
    };
  }, [refresh]);

  async function rpc(name: string, args: Row) {
    const { data, error } = await db().rpc(name, args);
    if (error) throw new Error(friendly(error));
    await refresh({ background: true });
    return data;
  }

  const value: Store = {
    ...state,
    activeRole: (role || 'salesperson') as StaffRole,
    loading,
    initialized,
    error,
    refresh,
    getCustomerById: (id) => state.customers.find((c) => c.id === id),
    quickAddCustomer: async (c) => {
      if (!c.name.trim() || !/^\d{10}$/.test(c.phone) || !c.village.trim()) {
        throw new Error('Enter a name, 10-digit phone number and location.');
      }
      const { data, error } = await db()
        .from('customers')
        .insert({
          name: c.name.trim(),
          phone: c.phone,
          village: c.village.trim(),
          notes: c.requirementNotes || '',
        })
        .select()
        .single();
      if (error) throw new Error(friendly(error));
      await refresh();
      return {
        id: data.id,
        name: data.name,
        phone: data.phone,
        village: data.village,
        createdAt: data.created_at,
      };
    },
    saveDocument: async (d) => rpc('app_save_document', { p_doc: d }),
    recordPayment: async (id, amount, method, reference, requestId) => {
      await rpc('app_record_payment', {
        p_id: requestId,
        p_invoice: id,
        p_amount: amount,
        p_method: method,
        p_reference: reference,
      });
    },
    adjustStock: async (id, _type, delta, reason) => {
      await rpc('app_adjust_stock', { p_id: id, p_delta: delta, p_reason: reason });
    },
    receiveStock: async (product, qty, reference) => {
      await rpc('app_receive_stock', {
        p_product: product,
        p_qty: qty,
        p_reference: reference,
      });
    },
    savePricing: async (id, price, gst, hsn) => {
      await rpc('app_product_pricing', {
        p_id: id,
        p_price: price,
        p_gst: gst,
        p_hsn: hsn,
      });
    },
    saveProfile: async (profile) => {
      const { error } = await db()
        .from('business_profile')
        .update(profile)
        .eq('id', true)
        .select('id')
        .single();
      if (error) throw new Error(friendly(error));
      await refresh();
    },
    logFollowup: async (data) => {
      await rpc('app_log_collection_followup', {
        p_customer: data.customerId,
        p_invoice: data.invoiceId || null,
        p_method: data.method,
        p_notes: data.notes,
        p_ptp_date: data.ptpDate || null,
        p_ptp_amount: data.ptpAmount || null,
      });
    },
    updateFollowupStatus: async (id, status) => {
      await rpc('app_update_followup_status', { p_id: id, p_status: status });
    },
    registerInvoiceAssets: async (invoiceId, assets) => {
      return await rpc('app_register_invoice_assets', {
        p_invoice_id: invoiceId,
        p_assets: assets,
      });
    },
    fetchCustomerAssets: async (customerId) => {
      const { data, error } = await db().rpc('app_customer_assets', {
        p_customer_id: customerId,
      });
      if (error) throw new Error(friendly(error));
      const result = data as { assets: Row[]; history: Row[] };
      return {
        assets: (result.assets || []).map((a: Row) => ({
          id: a.id,
          customerId: a.customer_id,
          billingInvoiceId: a.billing_invoice_id,
          vehicleId: a.vehicle_id,
          warrantyId: a.warranty_id,
          itemType: a.item_type,
          productId: a.product_id,
          productName: a.product_name,
          brand: a.brand || '',
          chassisNo: a.chassis_no || '',
          engineNo: a.engine_no || '',
          motorNo: a.motor_no || '',
          batterySerial: a.battery_serial || '',
          serialNo: a.serial_no || '',
          registrationNo: a.registration_no || '',
          warrantyMonths: a.warranty_months || 0,
          warrantyStart: a.warranty_start,
          warrantyEnd: a.warranty_end,
          status: a.status || 'active',
          replacedBy: a.replaced_by,
          replaces: a.replaces,
          notes: a.notes || '',
          createdAt: a.created_at,
          updatedAt: a.updated_at,
        })),
        history: (result.history || []).map((h: Row) => ({
          id: h.id,
          assetId: h.asset_id,
          action: h.action,
          actor: h.actor,
          beforeRecord: h.before_record,
          afterRecord: h.after_record,
          reason: h.reason || '',
          claimId: h.claim_id,
          createdAt: h.created_at,
        })),
      };
    },
  };

  return <Context.Provider value={value}>{children}</Context.Provider>;
}

export function useDealerStore() {
  const ctx = useContext(Context);
  if (!ctx) throw new Error('DealerStoreProvider missing');
  return ctx;
}
