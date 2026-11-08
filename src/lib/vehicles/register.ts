'use client';

import { useEffect, useState } from 'react';
import { useAuth } from '@/lib/auth/provider';
import { supabase } from '@/lib/supabase/client';
import type { Product } from '@/lib/billing/types';

export const vehicleTypes = ['tractor', 'e_rickshaw', 'cng_rickshaw', 'diesel_rickshaw'];
export const lifecycles = [
  'received',
  'pdi_pending',
  'pdi_passed',
  'pdi_failed',
  'pdi_issues',
  'available',
  'reserved',
  'sold',
  'delivered',
];
export const label = (key: string) =>
  key
    .replaceAll('_', ' ')
    .replace(/\bpdi\b/gi, 'PDI')
    .replace(/\bcng\b/gi, 'CNG')
    .replace(/^./, (c) => c.toUpperCase());
export type IntakeProduct = Pick<
  Product,
  'id' | 'code' | 'category' | 'brand' | 'model_name' | 'variant'
>;
export type IntakeOptions = { products: IntakeProduct[]; inspectors: string[] };
export type Part = { component_type: string; serial_no: string };
export type Receipt = {
  product_id: string;
  colour: string;
  chassis_no: string;
  engine_no: string;
  motor_no: string;
  components: Part[];
  supplier: string;
  supplier_invoice: string;
  shipment_ref: string;
  location: string;
  received_date: string;
  inspector_email: string;
};
export type BatchResult = {
  count: number;
  ids: string[];
  errors: { row: number; message: string }[];
};
export type VehicleRow = {
  id: string;
  chassis_no: string;
  engine_no: string | null;
  motor_no: string | null;
  model_name: string;
  variant: string;
  lifecycle: string;
  registration_no: string | null;
  received_date: string | null;
  location: string;
  colour: string;
  owner_name: string | null;
};
export type DetailRow = Record<string, string | boolean | number | null>;
export type Detail = {
  activity: DetailRow[];
  specs: DetailRow;
  vehicle: DetailRow & {
    id: string;
    chassis_no: string;
    model_name: string;
    variant: string;
    lifecycle: string;
  };
  invoice: (DetailRow & { id: string; number: string }) | null;
  components: DetailRow[];
  registrations: DetailRow[];
  ownership: DetailRow[] | null;
  pdi: DetailRow[] | null;
  delivery: DetailRow[] | null;
  warranties: DetailRow[] | null;
  jobs: DetailRow[] | null;
  payments: DetailRow[] | null;
  attachments: DetailRow[] | null;
};

export async function vehicleRpc<T>(
  name: string,
  args: Record<string, unknown>,
  signal?: AbortSignal
): Promise<T> {
  if (!supabase) throw new Error('Supabase connection is unavailable.');
  const request = supabase.rpc(name, args);
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw new Error(error.message);
  return data as T;
}

export function useVehicleQuery<T>(
  name: string,
  args: Record<string, unknown>,
  delay = 0,
  enabled = true
) {
  const { role, permissions, email } = useAuth();
  const params = JSON.stringify(args);
  const key = JSON.stringify([name, params, email, role, permissions, enabled]);
  const [result, setResult] = useState<{ key: string; data?: T; error?: string }>();
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    if (!enabled || !role) return;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      try {
        const data = await vehicleRpc<T>(name, JSON.parse(params), controller.signal);
        if (!controller.signal.aborted) setResult({ key, data });
      } catch (err) {
        if (!controller.signal.aborted)
          setResult({ key, error: err instanceof Error ? err.message : 'Unable to load records.' });
      }
    }, delay);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [delay, enabled, key, name, params, revision, role]);
  return { ...(result?.key === key ? result : {}), retry: () => setRevision((n) => n + 1) };
}
