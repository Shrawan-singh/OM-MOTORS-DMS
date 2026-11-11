import { money } from '@/lib/billing/types';

export function PaymentAmount({ due, amount, onChange }: {
  due: number;
  amount: string;
  onChange: (amount: string) => void;
}) {
  const outstanding = Math.round(due * 100) / 100;
  const received = Number(amount);
  return (
    <div className="space-y-2">
      <label>
        Aaj kitna mila? (₹)
        <input type="number" required min="0.01" max={outstanding} step="0.01"
          value={amount} onChange={e => onChange(e.target.value)} />
      </label>
      <button type="button" className="secondary-button"
        onClick={() => onChange(outstanding.toFixed(2))}>Poora baki mila · {money(outstanding)}</button>
      <p aria-live="polite" className="text-sm">
        {received > 0 && received <= outstanding
          ? `Aaj ${money(received)} jama honge · ${money(outstanding - received)} baki rahenge.`
          : received > outstanding ? 'Rakam is bill ke baki se zyada hai.' : `Abhi baki ${money(outstanding)}`}
      </p>
    </div>
  );
}
