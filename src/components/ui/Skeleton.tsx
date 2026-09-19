'use client';

export function SkeletonCard() {
  return (
    <div className="skeleton-card" aria-hidden="true">
      <div className="skeleton-line skeleton-line-short" />
      <div className="skeleton-line skeleton-line-long" />
      <div className="skeleton-line skeleton-line-medium" />
    </div>
  );
}

export function SkeletonTable({ rows = 5, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="skeleton-table" aria-hidden="true">
      <div className="skeleton-table-header">
        {Array.from({ length: cols }).map((_, i) => (
          <div key={i} className="skeleton-line skeleton-line-short" />
        ))}
      </div>
      {Array.from({ length: rows }).map((_, r) => (
        <div key={r} className="skeleton-table-row">
          {Array.from({ length: cols }).map((_, c) => (
            <div key={c} className="skeleton-line skeleton-line-medium" />
          ))}
        </div>
      ))}
    </div>
  );
}

export function SkeletonStats({ count = 3 }: { count?: number }) {
  return (
    <div className="admin-stats" aria-hidden="true">
      {Array.from({ length: count }).map((_, i) => (
        <div key={i} className="skeleton-stat">
          <div className="skeleton-line skeleton-line-short" />
          <div className="skeleton-line skeleton-line-long" style={{ height: 28 }} />
          <div className="skeleton-line skeleton-line-medium" />
        </div>
      ))}
    </div>
  );
}

export function SkeletonDashboard() {
  return (
    <div role="status" aria-label="Loading dashboard">
      <div className="skeleton-heading">
        <div className="skeleton-line" style={{ width: 180, height: 32 }} />
        <div className="skeleton-line" style={{ width: 240, height: 14, marginTop: 10 }} />
      </div>
      <SkeletonStats />
      <div className="products-grid" style={{ marginTop: 20 }}>
        {Array.from({ length: 6 }).map((_, i) => (
          <SkeletonCard key={i} />
        ))}
      </div>
    </div>
  );
}
