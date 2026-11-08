'use client';
import { useState } from 'react';

type Detector = new () => { detect: (image: ImageBitmap) => Promise<{ rawValue: string }[]> };

export function ChassisScan({ onScan }: { onScan: (chassis: string) => void }) {
  const [message, setMessage] = useState('');
  const detector =
    typeof window === 'undefined'
      ? undefined
      : (window as Window & { BarcodeDetector?: Detector }).BarcodeDetector;
  if (!detector) return null;
  async function scan(file?: File) {
    if (!file || !detector) return;
    let bitmap: ImageBitmap | undefined;
    try {
      bitmap = await createImageBitmap(file);
      const results = await new detector().detect(bitmap);
      if (results.length !== 1) throw new Error('Capture one readable chassis barcode.');
      onScan(results[0].rawValue);
      setMessage('Check the scanned chassis number before saving.');
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'Enter the chassis number manually.');
    } finally {
      bitmap?.close();
    }
  }
  return (
    <label>
      Scan chassis barcode
      <input
        type="file"
        accept="image/*"
        capture="environment"
        onChange={(e) => void scan(e.target.files?.[0])}
      />
      <span role="status">{message}</span>
    </label>
  );
}
