'use client';
import { useId } from 'react';
import { useVehicleQuery } from '@/lib/vehicles/register';
import type { BillingLine } from '@/lib/billing/types';

type Choice = {
  id: string;
  chassis_no: string;
  motor_no: string | null;
  engine_no: string | null;
  colour: string;
  stock_id: string;
  received_date: string | null;
};
export function SaleVehiclePicker({
  productId,
  line,
  onChange,
  backfill,
}: {
  productId: string;
  line: Partial<BillingLine>;
  onChange: (patch: Partial<BillingLine>) => void;
  backfill: boolean;
}) {
  const id = useId();
  const query = useVehicleQuery<Choice[]>(
    'vehicle_sale_choices',
    { product: productId, q: line.chassisNo || '' },
    200
  );
  return (
    <label>
      {backfill ? 'Link vehicle' : 'Select vehicle'} · chassis
      <input
        disabled={(line.qty ?? 1) !== 1}
        list={id}
        value={line.chassisNo || ''}
        placeholder="Search or type the full chassis"
        onChange={(e) => {
          const chassisNo = e.target.value;
          const choice = query.data?.find((v) => v.chassis_no === chassisNo);
          onChange({
            vehicleId: choice?.id,
            chassisNo,
            motorNo: choice?.motor_no,
            engineNo: choice?.engine_no,
            ...(chassisNo ? { qty: 1 } : {}),
            ...(choice ? { inventoryId: choice.stock_id } : {}),
          });
        }}
      />
      <datalist id={id}>
        {query.data?.map((v) => (
          <option key={v.id} value={v.chassis_no}>
            {[
              v.motor_no || v.engine_no,
              v.colour,
              v.received_date &&
                Math.max(
                  0,
                  Math.floor((new Date().getTime() - Date.parse(v.received_date)) / 86400000)
                ) + ' days in stock',
            ]
              .filter(Boolean)
              .join(' · ')}
          </option>
        ))}
      </datalist>
      {(line.qty ?? 1) !== 1 && (
        <span>Split this quantity into single-unit lines before linking a chassis.</span>
      )}
      {query.error && <span role="alert">{query.error}</span>}
    </label>
  );
}
