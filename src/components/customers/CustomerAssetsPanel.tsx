'use client';

import { useCallback, useEffect, useState } from 'react';
import {
  Package,
  ShieldCheck,
  ShieldOff,
  ShieldAlert,
  Clock,
  Search,
  ChevronRight,
  Battery,
  Wrench,
  Truck,
  Tag,
  History,
  ArrowRightLeft,
  AlertTriangle,
} from 'lucide-react';
import { useDealerStore } from '@/lib/store/dealer-store';
import type { CustomerAsset, CustomerAssetHistory } from '@/types';

type Props = {
  customerId: string;
  onClose?: () => void;
};

function warrantyStatusBadge(asset: CustomerAsset) {
  if (!asset.warrantyEnd) return { label: 'No warranty', color: 'neutral', icon: ShieldOff };
  const now = new Date();
  const end = new Date(asset.warrantyEnd + 'T23:59:59');
  if (end < now) return { label: 'Expired', color: 'red', icon: ShieldOff };
  const daysLeft = Math.ceil((end.getTime() - now.getTime()) / 86400000);
  if (daysLeft <= 30) return { label: `${daysLeft}d left`, color: 'amber', icon: ShieldAlert };
  return { label: 'Active', color: 'green', icon: ShieldCheck };
}

function statusBadge(status: string) {
  switch (status) {
    case 'active':
      return 'active';
    case 'replaced':
      return 'replaced';
    case 'transferred':
      return 'transferred';
    case 'returned':
      return 'returned';
    default:
      return 'neutral';
  }
}

function typeIcon(type: string) {
  switch (type) {
    case 'vehicle':
      return <Truck size={16} />;
    case 'battery':
      return <Battery size={16} />;
    case 'implement':
      return <Wrench size={16} />;
    default:
      return <Package size={16} />;
  }
}

function primarySerial(asset: CustomerAsset): string {
  return (
    asset.chassisNo ||
    asset.batterySerial ||
    asset.serialNo ||
    asset.engineNo ||
    asset.motorNo ||
    '—'
  );
}

export function CustomerAssetsPanel({ customerId, onClose }: Props) {
  const store = useDealerStore();
  const [assets, setAssets] = useState<CustomerAsset[]>([]);
  const [history, setHistory] = useState<CustomerAssetHistory[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [selectedAsset, setSelectedAsset] = useState<CustomerAsset | null>(null);
  const [showHistory, setShowHistory] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const data = await store.fetchCustomerAssets(customerId);
      setAssets(data.assets);
      setHistory(data.history);
    } catch (e: any) {
      // Fallback to store data if RPC not available
      setAssets(store.customerAssets.filter((a) => a.customerId === customerId));
      setHistory([]);
      if (e.message && !e.message.includes('PGRST')) {
        setError(e.message);
      }
    } finally {
      setLoading(false);
    }
  }, [customerId, store]);

  useEffect(() => {
    void load();
  }, [load]);

  const customer = store.customers.find((c) => c.id === customerId);
  const filtered = assets.filter((a) => {
    if (!search.trim()) return true;
    const q = search.toLowerCase();
    return (
      a.productName.toLowerCase().includes(q) ||
      a.brand.toLowerCase().includes(q) ||
      a.chassisNo.toLowerCase().includes(q) ||
      a.engineNo.toLowerCase().includes(q) ||
      a.batterySerial.toLowerCase().includes(q) ||
      a.serialNo.toLowerCase().includes(q) ||
      a.registrationNo.toLowerCase().includes(q) ||
      a.itemType.toLowerCase().includes(q) ||
      a.status.toLowerCase().includes(q)
    );
  });

  const activeAssets = filtered.filter((a) => a.status === 'active');
  const inactiveAssets = filtered.filter((a) => a.status !== 'active');

  const assetHistory = selectedAsset
    ? history.filter((h) => h.assetId === selectedAsset.id)
    : history;

  const invoiceNo = (id?: string) => {
    if (!id) return '';
    const doc = store.documents.find((d) => d.id === id);
    return doc?.number || '';
  };

  return (
    <div className="asset-registry-panel">
      <div className="asset-registry-header">
        <div>
          <h2>
            <Package size={20} />
            Asset Registry
          </h2>
          <p>
            {customer?.name || 'Customer'} ·{' '}
            {assets.length} registered asset{assets.length !== 1 ? 's' : ''}
          </p>
        </div>
        {onClose && (
          <button className="secondary-button" onClick={onClose}>
            Close
          </button>
        )}
      </div>

      {error && (
        <div role="alert" className="error-message">
          {error}
        </div>
      )}

      {loading && <p className="asset-loading">Loading asset registry…</p>}

      {!loading && assets.length === 0 && (
        <div className="asset-empty">
          <Package size={32} />
          <h3>No registered assets</h3>
          <p>
            Assets are registered when serial/chassis numbers are captured during invoice
            creation. Open an existing invoice and click "Register Assets" to add
            identifiers.
          </p>
        </div>
      )}

      {!loading && assets.length > 0 && (
        <>
          <div className="asset-search-bar">
            <Search size={16} />
            <input
              aria-label="Search assets"
              placeholder="Search by serial, chassis, battery, product name…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>

          <div className="asset-summary-strip">
            <div className="asset-kpi">
              <span className="kpi-value">{activeAssets.length}</span>
              <span className="kpi-label">Active</span>
            </div>
            <div className="asset-kpi">
              <span className="kpi-value">
                {activeAssets.filter((a) => {
                  const s = warrantyStatusBadge(a);
                  return s.color === 'green';
                }).length}
              </span>
              <span className="kpi-label">Under Warranty</span>
            </div>
            <div className="asset-kpi warn">
              <span className="kpi-value">
                {activeAssets.filter((a) => {
                  const s = warrantyStatusBadge(a);
                  return s.color === 'amber';
                }).length}
              </span>
              <span className="kpi-label">Expiring Soon</span>
            </div>
            <div className="asset-kpi danger">
              <span className="kpi-value">
                {activeAssets.filter((a) => {
                  const s = warrantyStatusBadge(a);
                  return s.color === 'red';
                }).length}
              </span>
              <span className="kpi-label">Expired</span>
            </div>
            <div className="asset-kpi neutral">
              <span className="kpi-value">{inactiveAssets.length}</span>
              <span className="kpi-label">Replaced/Other</span>
            </div>
          </div>

          {/* Asset cards */}
          <div className="asset-card-list">
            {activeAssets.map((asset) => {
              const warranty = warrantyStatusBadge(asset);
              const WarrantyIcon = warranty.icon;
              const isSelected = selectedAsset?.id === asset.id;
              return (
                <button
                  key={asset.id}
                  className={`asset-card ${isSelected ? 'selected' : ''}`}
                  onClick={() => {
                    setSelectedAsset(isSelected ? null : asset);
                    setShowHistory(false);
                  }}
                >
                  <div className="asset-card-left">
                    <div className={`asset-type-icon ${asset.itemType}`}>
                      {typeIcon(asset.itemType)}
                    </div>
                    <div className="asset-card-info">
                      <strong>{asset.productName}</strong>
                      <span className="asset-serial-primary">
                        <Tag size={12} /> {primarySerial(asset)}
                      </span>
                      {asset.brand && (
                        <span className="asset-brand">{asset.brand}</span>
                      )}
                    </div>
                  </div>
                  <div className="asset-card-right">
                    <span className={`asset-warranty-badge ${warranty.color}`}>
                      <WarrantyIcon size={12} />
                      {warranty.label}
                    </span>
                    {asset.warrantyEnd && (
                      <span className="asset-warranty-date">
                        {asset.warrantyStart} – {asset.warrantyEnd}
                      </span>
                    )}
                    <ChevronRight size={14} className="asset-chevron" />
                  </div>
                </button>
              );
            })}

            {inactiveAssets.length > 0 && (
              <>
                <h4 className="asset-section-title">
                  <ArrowRightLeft size={14} /> Replaced / Inactive
                </h4>
                {inactiveAssets.map((asset) => {
                  const isSelected = selectedAsset?.id === asset.id;
                  return (
                    <button
                      key={asset.id}
                      className={`asset-card inactive ${isSelected ? 'selected' : ''}`}
                      onClick={() => {
                        setSelectedAsset(isSelected ? null : asset);
                        setShowHistory(false);
                      }}
                    >
                      <div className="asset-card-left">
                        <div className={`asset-type-icon ${asset.itemType} inactive`}>
                          {typeIcon(asset.itemType)}
                        </div>
                        <div className="asset-card-info">
                          <strong>{asset.productName}</strong>
                          <span className="asset-serial-primary">
                            <Tag size={12} /> {primarySerial(asset)}
                          </span>
                        </div>
                      </div>
                      <div className="asset-card-right">
                        <span className={`asset-status-badge ${statusBadge(asset.status)}`}>
                          {asset.status}
                        </span>
                        <ChevronRight size={14} className="asset-chevron" />
                      </div>
                    </button>
                  );
                })}
              </>
            )}
          </div>

          {/* Selected asset detail */}
          {selectedAsset && (
            <div className="asset-detail-panel">
              <div className="asset-detail-header">
                <h3>
                  {typeIcon(selectedAsset.itemType)}
                  {selectedAsset.productName}
                </h3>
                <div className="asset-detail-actions">
                  <button
                    className={`secondary-button ${showHistory ? 'active' : ''}`}
                    onClick={() => setShowHistory(!showHistory)}
                  >
                    <History size={14} />
                    {showHistory ? 'Hide History' : 'Audit Trail'}
                  </button>
                </div>
              </div>

              <div className="asset-detail-grid">
                {selectedAsset.chassisNo && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Chassis No.</span>
                    <span className="detail-value">{selectedAsset.chassisNo}</span>
                  </div>
                )}
                {selectedAsset.engineNo && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Engine No.</span>
                    <span className="detail-value">{selectedAsset.engineNo}</span>
                  </div>
                )}
                {selectedAsset.motorNo && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Motor No.</span>
                    <span className="detail-value">{selectedAsset.motorNo}</span>
                  </div>
                )}
                {selectedAsset.batterySerial && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Battery Serial</span>
                    <span className="detail-value">{selectedAsset.batterySerial}</span>
                  </div>
                )}
                {selectedAsset.serialNo && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Serial No.</span>
                    <span className="detail-value">{selectedAsset.serialNo}</span>
                  </div>
                )}
                {selectedAsset.registrationNo && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Registration</span>
                    <span className="detail-value">{selectedAsset.registrationNo}</span>
                  </div>
                )}
                <div className="asset-detail-item">
                  <span className="detail-label">Item Type</span>
                  <span className="detail-value capitalize">{selectedAsset.itemType.replace(/_/g, ' ')}</span>
                </div>
                {selectedAsset.brand && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Brand</span>
                    <span className="detail-value">{selectedAsset.brand}</span>
                  </div>
                )}
                <div className="asset-detail-item">
                  <span className="detail-label">Status</span>
                  <span className={`detail-value asset-status-badge ${statusBadge(selectedAsset.status)}`}>
                    {selectedAsset.status}
                  </span>
                </div>
                {selectedAsset.warrantyStart && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Warranty Period</span>
                    <span className="detail-value">
                      {selectedAsset.warrantyStart} – {selectedAsset.warrantyEnd || '—'}
                      {selectedAsset.warrantyMonths > 0 && ` (${selectedAsset.warrantyMonths} mo)`}
                    </span>
                  </div>
                )}
                {invoiceNo(selectedAsset.billingInvoiceId) && (
                  <div className="asset-detail-item">
                    <span className="detail-label">Invoice</span>
                    <span className="detail-value">{invoiceNo(selectedAsset.billingInvoiceId)}</span>
                  </div>
                )}
                <div className="asset-detail-item">
                  <span className="detail-label">Registered</span>
                  <span className="detail-value">
                    {new Date(selectedAsset.createdAt).toLocaleDateString('en-IN', {
                      day: '2-digit',
                      month: 'short',
                      year: 'numeric',
                    })}
                  </span>
                </div>
                {selectedAsset.notes && (
                  <div className="asset-detail-item wide">
                    <span className="detail-label">Notes</span>
                    <span className="detail-value">{selectedAsset.notes}</span>
                  </div>
                )}
                {selectedAsset.replaces && (
                  <div className="asset-detail-item wide">
                    <span className="detail-label">
                      <ArrowRightLeft size={12} /> Replaces
                    </span>
                    <span className="detail-value">
                      {assets.find((a) => a.id === selectedAsset.replaces)?.productName || 'Previous asset'}{' '}
                      ({primarySerial(assets.find((a) => a.id === selectedAsset.replaces) || selectedAsset)})
                    </span>
                  </div>
                )}
                {selectedAsset.replacedBy && (
                  <div className="asset-detail-item wide">
                    <span className="detail-label">
                      <AlertTriangle size={12} /> Replaced By
                    </span>
                    <span className="detail-value">
                      {assets.find((a) => a.id === selectedAsset.replacedBy)?.productName || 'New asset'}{' '}
                      ({primarySerial(assets.find((a) => a.id === selectedAsset.replacedBy) || selectedAsset)})
                    </span>
                  </div>
                )}
              </div>

              {/* Audit history */}
              {showHistory && (
                <div className="asset-history">
                  <h4>
                    <Clock size={14} /> Asset Audit Trail
                  </h4>
                  {assetHistory.length === 0 && (
                    <p className="asset-no-history">No recorded changes.</p>
                  )}
                  {assetHistory.map((h) => (
                    <div key={h.id} className="asset-history-entry">
                      <div className="history-action">{h.action.replace(/_/g, ' ')}</div>
                      <div className="history-meta">
                        {new Date(h.createdAt).toLocaleString('en-IN')}
                        {h.reason && ` · ${h.reason}`}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}
