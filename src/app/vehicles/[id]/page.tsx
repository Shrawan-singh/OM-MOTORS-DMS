import { VehicleDetail } from '@/components/vehicles/VehicleDetail';
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return <VehicleDetail vehicleId={id} />;
}
