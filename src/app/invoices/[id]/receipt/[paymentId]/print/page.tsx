import { PrintReceipt } from '@/components/billing/PrintReceipt';

export const dynamic = 'force-dynamic';

export default async function Page({
  params,
}: {
  params: Promise<{ id: string; paymentId: string }>;
}) {
  const { id, paymentId } = await params;
  return <PrintReceipt invoiceId={id} paymentId={paymentId} />;
}
