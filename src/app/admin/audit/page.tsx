'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  History,
  ShieldCheck,
  ShieldAlert,
  Search,
  Filter,
  Download,
  RefreshCw,
  Wrench,
  Receipt,
  UserCheck,
  Package,
  Calendar,
  X,
  ArrowRight,
  Eye,
  AlertTriangle,
  User,
  Clock,
  Layers,
} from 'lucide-react';
import { supabase } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth/provider';
import { roleLabels } from '@/lib/auth/permissions';

export interface AuditEvent {
  id: string;
  module: 'workshop' | 'billing' | 'access' | 'inventory';
  action: string;
  entity: string;
  record_id: string;
  actor_id: string;
  actor_email: string;
  actor_role: string;
  before_record: Record<string, any> | null;
  after_record: Record<string, any> | null;
  reason?: string;
  created_at: string;
  target_label: string;
}

export default function AuditLogsPage() {
  const { role, email: currentEmail } = useAuth();

  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [actorsList, setActorsList] = useState<{ email: string; role: string }[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [moduleFilter, setModuleFilter] = useState<'all' | 'workshop' | 'billing' | 'access' | 'inventory'>('all');
  const [actorFilter, setActorFilter] = useState('all');
  const [dateFilter, setDateFilter] = useState<'all' | 'today' | '7d' | '30d'>('all');
  const [selectedEvent, setSelectedEvent] = useState<AuditEvent | null>(null);
  const [inspectTab, setInspectTab] = useState<'diff' | 'after' | 'before' | 'raw'>('diff');

  // Load audit trail from Supabase RPC with client fallback
  const loadAuditTrail = useCallback(async () => {
    if (!supabase) return;
    setLoading(true);
    setError('');

    try {
      // 1. Primary: Call admin_get_audit_trail RPC
      const { data, error: rpcError } = await supabase.rpc('admin_get_audit_trail', {
        p_limit: 500,
        p_offset: 0,
        p_module: moduleFilter === 'all' ? null : moduleFilter,
        p_actor_email: actorFilter === 'all' ? null : actorFilter,
        p_search: search.trim() ? search.trim() : null,
      });

      if (!rpcError && data && Array.isArray(data.events)) {
        setEvents(data.events);
        if (Array.isArray(data.actors) && data.actors.length > 0) {
          setActorsList(data.actors);
        }
        return;
      }

      // 2. Fallback: Aggregate directly from available tables if RPC fails or is being deployed
      const aggregated: AuditEvent[] = [];
      const actorsMap = new Map<string, string>();

      // Fetch access assignments for role mapping
      const { data: assignments } = await supabase
        .from('access_assignments')
        .select('email, role');
      if (assignments) {
        for (const a of assignments) {
          actorsMap.set(a.email.toLowerCase(), a.role);
        }
      }

      // A) Workshop Audit
      try {
        const { data: wsSnapshot } = await supabase.rpc('ws_snapshot');
        if (wsSnapshot && Array.isArray(wsSnapshot.events)) {
          for (const ev of wsSnapshot.events) {
            aggregated.push({
              id: `ws_${ev.id || Math.random()}`,
              module: 'workshop',
              action: ev.action || 'Workshop action',
              entity: ev.entity || 'workshop',
              record_id: ev.record_id || '',
              actor_id: ev.actor || '',
              actor_email: ev.actor_email || 'staff@ommotors.in',
              actor_role: ev.role || 'staff',
              before_record: ev.before_record || null,
              after_record: ev.after_record || null,
              reason: ev.reason || '',
              created_at: ev.created_at || new Date().toISOString(),
              target_label: ev.after_record?.number || ev.before_record?.number || ev.entity || 'Service record',
            });
          }
        }
      } catch {
        // workshop snapshot fallback silent
      }

      // B) Access Audit
      try {
        const { data: accessLogs } = await supabase
          .from('access_audit')
          .select('*')
          .order('created_at', { ascending: false })
          .limit(100);

        if (accessLogs) {
          for (const acc of accessLogs) {
            aggregated.push({
              id: `acc_${acc.id}`,
              module: 'access',
              action: acc.action === 'assign_access' ? 'Team member access updated' : 'Role permissions updated',
              entity: 'access_assignment',
              record_id: String(acc.id),
              actor_id: acc.actor || '',
              actor_email: 'Administrator',
              actor_role: 'owner',
              before_record: null,
              after_record: acc.details || null,
              reason: '',
              created_at: acc.created_at,
              target_label: acc.target || 'Role / User',
            });
          }
        }
      } catch {
        // access audit fallback silent
      }

      // C) Billing Audit
      try {
        const { data: billingLogs } = await supabase
          .from('billing_audit')
          .select('*')
          .order('created_at', { ascending: false })
          .limit(100);

        if (billingLogs) {
          for (const b of billingLogs) {
            const kind = b.after_record?.kind || 'document';
            const action = !b.before_record
              ? `Document created (${kind})`
              : b.after_record?.status === 'cancelled'
              ? 'Invoice cancelled'
              : `Document updated (${kind})`;

            aggregated.push({
              id: `bill_${b.id}`,
              module: 'billing',
              action,
              entity: kind,
              record_id: b.document_id,
              actor_id: b.actor || '',
              actor_email: 'Billing staff',
              actor_role: 'accountant',
              before_record: b.before_record || null,
              after_record: b.after_record || null,
              reason: b.after_record?.cancel_reason || '',
              created_at: b.created_at,
              target_label: b.after_record?.number || `DOC #${String(b.document_id).slice(0, 8)}`,
            });
          }
        }
      } catch {
        // billing audit fallback silent
      }

      // D) Stock Movements
      try {
        const { data: stockLogs } = await supabase
          .from('stock_movements')
          .select('*')
          .order('created_at', { ascending: false })
          .limit(100);

        if (stockLogs) {
          for (const sm of stockLogs) {
            aggregated.push({
              id: `stock_${sm.id}`,
              module: 'inventory',
              action: sm.delta > 0 ? `Stock received (+${sm.delta})` : `Stock deducted (${sm.delta})`,
              entity: 'inventory',
              record_id: sm.inventory_id,
              actor_id: sm.actor || '',
              actor_email: 'Inventory manager',
              actor_role: 'inventory',
              before_record: { qty: sm.before_qty },
              after_record: { qty: sm.after_qty, delta: sm.delta, reference: sm.reference },
              reason: sm.reference || '',
              created_at: sm.created_at,
              target_label: `Stock #${String(sm.inventory_id).slice(0, 8)}`,
            });
          }
        }
      } catch {
        // stock fallback silent
      }

      aggregated.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
      setEvents(aggregated);

      // Extract unique actors from aggregated
      const uniqueActors = new Map<string, string>();
      for (const ev of aggregated) {
        if (ev.actor_email && !uniqueActors.has(ev.actor_email)) {
          uniqueActors.set(ev.actor_email, ev.actor_role);
        }
      }
      setActorsList(Array.from(uniqueActors.entries()).map(([email, role]) => ({ email, role })));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to load audit logs.');
    } finally {
      setLoading(false);
    }
  }, [moduleFilter, actorFilter, search]);

  useEffect(() => {
    void loadAuditTrail();
  }, [loadAuditTrail]);

  // Client-side date filter & search filtering refinement
  const filteredEvents = useMemo(() => {
    return events.filter((e) => {
      // Date filter
      if (dateFilter !== 'all') {
        const eventTime = new Date(e.created_at).getTime();
        const now = Date.now();
        if (dateFilter === 'today') {
          const startOfToday = new Date();
          startOfToday.setHours(0, 0, 0, 0);
          if (eventTime < startOfToday.getTime()) return false;
        } else if (dateFilter === '7d') {
          if (eventTime < now - 7 * 24 * 60 * 60 * 1000) return false;
        } else if (dateFilter === '30d') {
          if (eventTime < now - 30 * 24 * 60 * 60 * 1000) return false;
        }
      }

      // Search filter (client-side query matching)
      if (search.trim()) {
        const q = search.toLowerCase();
        const matchesAction = e.action.toLowerCase().includes(q);
        const matchesTarget = e.target_label.toLowerCase().includes(q);
        const matchesActor = e.actor_email.toLowerCase().includes(q);
        const matchesReason = (e.reason || '').toLowerCase().includes(q);
        const matchesEntity = e.entity.toLowerCase().includes(q);
        if (!matchesAction && !matchesTarget && !matchesActor && !matchesReason && !matchesEntity) {
          return false;
        }
      }

      // Module filter
      if (moduleFilter !== 'all' && e.module !== moduleFilter) return false;

      // Actor filter
      if (actorFilter !== 'all' && e.actor_email.toLowerCase() !== actorFilter.toLowerCase()) return false;

      return true;
    });
  }, [events, dateFilter, search, moduleFilter, actorFilter]);

  // Key metrics
  const stats = useMemo(() => {
    const todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);
    const todayMs = todayStart.getTime();

    const changesToday = events.filter((e) => new Date(e.created_at).getTime() >= todayMs).length;
    const uniqueActors = new Set(events.map((e) => e.actor_email)).size;
    const criticalOps = events.filter((e) => {
      const act = e.action.toLowerCase();
      return (
        act.includes('cancel') ||
        act.includes('revok') ||
        act.includes('override') ||
        act.includes('permission') ||
        act.includes('deleted') ||
        act.includes('correct')
      );
    }).length;

    return {
      total: events.length,
      today: changesToday,
      actors: uniqueActors,
      critical: criticalOps,
    };
  }, [events]);

  // Export CSV
  const handleExportCSV = () => {
    if (!filteredEvents.length) return;

    const headers = ['Timestamp', 'Module', 'Action', 'Target Reference', 'Actor Email', 'Actor Role', 'Reason / Notes', 'Record ID'];
    const rows = filteredEvents.map((e) => [
      new Date(e.created_at).toLocaleString(),
      e.module.toUpperCase(),
      `"${e.action.replace(/"/g, '""')}"`,
      `"${e.target_label.replace(/"/g, '""')}"`,
      `"${e.actor_email.replace(/"/g, '""')}"`,
      `"${e.actor_role.replace(/"/g, '""')}"`,
      `"${(e.reason || '').replace(/"/g, '""')}"`,
      `"${e.record_id}"`,
    ]);

    const csvContent = [headers.join(','), ...rows.map((r) => r.join(','))].join('\n');
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.setAttribute('download', `om_motors_audit_logs_${new Date().toISOString().slice(0, 10)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  // Helper for computing diffs
  const diffItems = useMemo(() => {
    if (!selectedEvent) return [];
    const before = selectedEvent.before_record || {};
    const after = selectedEvent.after_record || {};
    const keys = Array.from(new Set([...Object.keys(before), ...Object.keys(after)]));

    return keys
      .map((key) => {
        const prevVal = before[key];
        const nextVal = after[key];
        const isChanged = JSON.stringify(prevVal) !== JSON.stringify(nextVal);
        return { key, prevVal, nextVal, isChanged };
      })
      .filter((item) => item.isChanged);
  }, [selectedEvent]);

  // Strictly restrict to owner role
  if (role !== 'owner') {
    return (
      <div className="admin-page">
        <div className="page-heading">
          <div>
            <p className="eyebrow">ADMINISTRATION</p>
            <h1>Access Restricted</h1>
            <p>This audit section is strictly restricted to dealership owners.</p>
          </div>
          <span className="admin-badge">
            <ShieldAlert size={16} />
            Owner only
          </span>
        </div>
        <div className="empty-state">
          You do not have permission to view dealership audit logs. Please sign in with an authorized owner account.
        </div>
      </div>
    );
  }

  return (
    <div className="admin-page audit-page">
      {/* Header */}
      <div className="page-heading">
        <div>
          <p className="eyebrow">ADMINISTRATION</p>
          <h1>Audit trail & changes</h1>
          <p>Complete verified log of all actions, system modifications, and who performed them.</p>
        </div>
        <div className="flex items-center gap-3">
          <span className="admin-badge">
            <ShieldCheck size={16} />
            Administrator access
          </span>
        </div>
      </div>

      {/* Metrics Row */}
      <div className="admin-stats audit-stats-grid">
        <div>
          <History size={21} />
          <strong>{stats.total}</strong>
          <span>Total audited actions</span>
        </div>
        <div>
          <Clock size={21} />
          <strong>{stats.today}</strong>
          <span>Changes today</span>
        </div>
        <div>
          <User size={21} />
          <strong>{stats.actors}</strong>
          <span>Active staff actors</span>
        </div>
        <div>
          <AlertTriangle size={21} />
          <strong>{stats.critical}</strong>
          <span>Critical ops & overrides</span>
        </div>
      </div>

      {error && (
        <div role="alert" className="error-message">
          {error}
        </div>
      )}

      {/* Filter and Control Bar */}
      <section className="admin-panel audit-controls-panel mb-6">
        <div className="audit-search-row">
          <div className="audit-search-input-wrap">
            <Search size={16} className="audit-search-icon" />
            <input
              type="text"
              className="audit-search-input"
              placeholder="Search by action, job/invoice #, customer, actor, or reason..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
            {search && (
              <button
                type="button"
                className="audit-clear-search"
                onClick={() => setSearch('')}
                aria-label="Clear search"
              >
                <X size={14} />
              </button>
            )}
          </div>

          <div className="audit-action-buttons">
            <button
              type="button"
              className="secondary-button"
              onClick={handleExportCSV}
              disabled={!filteredEvents.length}
              title="Download CSV report of current filtered audit logs"
            >
              <Download size={15} />
              Export CSV
            </button>
            <button
              type="button"
              className="secondary-button"
              onClick={() => void loadAuditTrail()}
              disabled={loading}
              title="Refresh audit feed"
            >
              <RefreshCw size={15} className={loading ? 'animate-spin' : ''} />
              {loading ? 'Refreshing...' : 'Refresh'}
            </button>
          </div>
        </div>

        {/* Filter Pills and Dropdowns */}
        <div className="audit-filters-row">
          {/* Module Pills */}
          <div className="audit-module-pills">
            <button
              type="button"
              className={`audit-pill ${moduleFilter === 'all' ? 'active' : ''}`}
              onClick={() => setModuleFilter('all')}
            >
              <Layers size={13} />
              All modules
            </button>
            <button
              type="button"
              className={`audit-pill pill-workshop ${moduleFilter === 'workshop' ? 'active' : ''}`}
              onClick={() => setModuleFilter('workshop')}
            >
              <Wrench size={13} />
              Workshop & Service
            </button>
            <button
              type="button"
              className={`audit-pill pill-billing ${moduleFilter === 'billing' ? 'active' : ''}`}
              onClick={() => setModuleFilter('billing')}
            >
              <Receipt size={13} />
              Billing & Invoices
            </button>
            <button
              type="button"
              className={`audit-pill pill-access ${moduleFilter === 'access' ? 'active' : ''}`}
              onClick={() => setModuleFilter('access')}
            >
              <UserCheck size={13} />
              Access & Roles
            </button>
            <button
              type="button"
              className={`audit-pill pill-inventory ${moduleFilter === 'inventory' ? 'active' : ''}`}
              onClick={() => setModuleFilter('inventory')}
            >
              <Package size={13} />
              Inventory & Stock
            </button>
          </div>

          {/* Actor & Date Dropdowns */}
          <div className="audit-selects-wrap">
            {/* Filter by Actor (Who did it) */}
            <div className="audit-select-field">
              <label htmlFor="actor-filter">Who did it:</label>
              <select
                id="actor-filter"
                value={actorFilter}
                onChange={(e) => setActorFilter(e.target.value)}
              >
                <option value="all">All staff members</option>
                {actorsList.map((a) => (
                  <option key={a.email} value={a.email}>
                    {a.email} ({roleLabels[a.role] || a.role})
                  </option>
                ))}
              </select>
            </div>

            {/* Filter by Date */}
            <div className="audit-select-field">
              <label htmlFor="date-filter">Date range:</label>
              <select
                id="date-filter"
                value={dateFilter}
                onChange={(e) => setDateFilter(e.target.value as any)}
              >
                <option value="all">All time</option>
                <option value="today">Today only</option>
                <option value="7d">Last 7 days</option>
                <option value="30d">Last 30 days</option>
              </select>
            </div>
          </div>
        </div>

        {/* Active filter tags counter */}
        {(moduleFilter !== 'all' || actorFilter !== 'all' || dateFilter !== 'all' || search) && (
          <div className="audit-active-filters-bar">
            <span>Showing {filteredEvents.length} filtered changes</span>
            <button
              type="button"
              className="text-xs text-emerald-800 underline hover:text-emerald-950 ml-3"
              onClick={() => {
                setModuleFilter('all');
                setActorFilter('all');
                setDateFilter('all');
                setSearch('');
              }}
            >
              Reset all filters
            </button>
          </div>
        )}
      </section>

      {/* Audit Event List */}
      <section className="admin-panel audit-list-panel">
        <div className="panel-heading">
          <div>
            <h2>Verified system events</h2>
            <p>
              Displaying {filteredEvents.length} {filteredEvents.length === 1 ? 'audit record' : 'audit records'}
            </p>
          </div>
        </div>

        {loading ? (
          <div className="audit-loading-state">
            <RefreshCw size={24} className="animate-spin text-emerald-800 mb-2" />
            <p>Loading audit trail...</p>
          </div>
        ) : !filteredEvents.length ? (
          <div className="empty-state">
            No audit records match the selected filters. Try changing your search query or selecting &quot;All modules&quot;.
          </div>
        ) : (
          <div className="audit-timeline">
            {filteredEvents.map((event) => {
              const eventDate = new Date(event.created_at);
              const isToday = new Date().toDateString() === eventDate.toDateString();

              return (
                <article
                  key={event.id}
                  className={`audit-event-card audit-mod-${event.module}`}
                  onClick={() => {
                    setSelectedEvent(event);
                    setInspectTab('diff');
                  }}
                >
                  {/* Left Module Indicator */}
                  <div className="audit-event-module-col">
                    <span className={`audit-badge-icon badge-${event.module}`}>
                      {event.module === 'workshop' && <Wrench size={16} />}
                      {event.module === 'billing' && <Receipt size={16} />}
                      {event.module === 'access' && <UserCheck size={16} />}
                      {event.module === 'inventory' && <Package size={16} />}
                    </span>
                    <span className="audit-module-name">{event.module}</span>
                  </div>

                  {/* Middle Main Content */}
                  <div className="audit-event-main-col">
                    <div className="audit-event-header">
                      <h3 className="audit-event-title">{event.action}</h3>
                      <span className="audit-target-pill">{event.target_label}</span>
                    </div>

                    {/* Reason / Override Banner if exists */}
                    {event.reason && (
                      <div className="audit-reason-callout">
                        <AlertTriangle size={13} />
                        <span>{event.reason}</span>
                      </div>
                    )}

                    {/* Actor and Timestamp footer */}
                    <div className="audit-event-footer">
                      <div className="audit-actor-info">
                        <span className="audit-actor-avatar">
                          {event.actor_email ? event.actor_email[0].toUpperCase() : 'U'}
                        </span>
                        <div className="audit-actor-details">
                          <strong className="audit-actor-email">{event.actor_email}</strong>
                          <span className="audit-actor-role">
                            {roleLabels[event.actor_role] || event.actor_role || 'Staff member'}
                            {event.actor_email === currentEmail && (
                              <span className="ml-1 text-emerald-700 font-semibold">(You)</span>
                            )}
                          </span>
                        </div>
                      </div>

                      <div className="audit-timestamp" title={eventDate.toLocaleString()}>
                        <Clock size={13} />
                        <span>
                          {isToday
                            ? `Today at ${eventDate.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
                            : eventDate.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })}
                        </span>
                      </div>
                    </div>
                  </div>

                  {/* Right Inspect Trigger */}
                  <div className="audit-event-inspect-col">
                    <button
                      type="button"
                      className="audit-inspect-button"
                      aria-label="Inspect event diff"
                    >
                      <Eye size={15} />
                      <span>Inspect</span>
                    </button>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>

      {/* Change Inspector Modal */}
      {selectedEvent && (
        <div className="modal-overlay" onClick={() => setSelectedEvent(null)}>
          <div
            className="admin-panel modal-card audit-inspect-modal"
            onClick={(e) => e.stopPropagation()}
          >
            {/* Modal Header */}
            <div className="audit-modal-header">
              <div>
                <div className="flex items-center gap-2 mb-1">
                  <span className={`audit-badge-icon badge-${selectedEvent.module} mr-1`}>
                    {selectedEvent.module === 'workshop' && <Wrench size={14} />}
                    {selectedEvent.module === 'billing' && <Receipt size={14} />}
                    {selectedEvent.module === 'access' && <UserCheck size={14} />}
                    {selectedEvent.module === 'inventory' && <Package size={14} />}
                  </span>
                  <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
                    {selectedEvent.module} audit
                  </span>
                  <span className="audit-target-pill">{selectedEvent.target_label}</span>
                </div>
                <h2 className="text-lg font-bold text-slate-900">{selectedEvent.action}</h2>
              </div>
              <button
                type="button"
                className="audit-modal-close"
                onClick={() => setSelectedEvent(null)}
                aria-label="Close inspector"
              >
                <X size={18} />
              </button>
            </div>

            {/* Metadata Callout */}
            <div className="audit-inspector-meta">
              <div>
                <span className="text-xs text-slate-500 block">Performed by</span>
                <strong>{selectedEvent.actor_email}</strong>
                <span className="text-xs text-slate-600 block">
                  Role: {roleLabels[selectedEvent.actor_role] || selectedEvent.actor_role}
                </span>
              </div>
              <div>
                <span className="text-xs text-slate-500 block">Date & Time</span>
                <strong>{new Date(selectedEvent.created_at).toLocaleString()}</strong>
                <span className="text-xs text-slate-400 block font-mono">
                  Record ID: {selectedEvent.record_id || selectedEvent.id}
                </span>
              </div>
            </div>

            {selectedEvent.reason && (
              <div className="audit-modal-reason">
                <AlertTriangle size={15} />
                <div>
                  <strong>Reason / Note provided:</strong>
                  <p>{selectedEvent.reason}</p>
                </div>
              </div>
            )}

            {/* Inspector Tabs */}
            <div className="audit-tabs">
              <button
                type="button"
                className={`audit-tab ${inspectTab === 'diff' ? 'active' : ''}`}
                onClick={() => setInspectTab('diff')}
              >
                Field changes ({diffItems.length})
              </button>
              <button
                type="button"
                className={`audit-tab ${inspectTab === 'after' ? 'active' : ''}`}
                onClick={() => setInspectTab('after')}
              >
                New state
              </button>
              <button
                type="button"
                className={`audit-tab ${inspectTab === 'before' ? 'active' : ''}`}
                onClick={() => setInspectTab('before')}
              >
                Previous state
              </button>
              <button
                type="button"
                className={`audit-tab ${inspectTab === 'raw' ? 'active' : ''}`}
                onClick={() => setInspectTab('raw')}
              >
                Raw event
              </button>
            </div>

            {/* Tab Contents */}
            <div className="audit-tab-content">
              {inspectTab === 'diff' && (
                <div className="audit-diff-view">
                  {!diffItems.length ? (
                    <div className="audit-no-diff">
                      {selectedEvent.before_record === null ? (
                        <p>
                          This event was an initial creation or direct assignment. View the{' '}
                          <button
                            type="button"
                            className="text-emerald-700 underline font-semibold"
                            onClick={() => setInspectTab('after')}
                          >
                            New state tab
                          </button>{' '}
                          to see all initialized data.
                        </p>
                      ) : (
                        <p>No field-level differences detected between records.</p>
                      )}
                    </div>
                  ) : (
                    <div className="audit-diff-table-wrap">
                      <table className="audit-diff-table">
                        <thead>
                          <tr>
                            <th>FIELD</th>
                            <th>BEFORE</th>
                            <th>AFTER</th>
                          </tr>
                        </thead>
                        <tbody>
                          {diffItems.map(({ key, prevVal, nextVal }) => (
                            <tr key={key}>
                              <td className="font-mono text-xs font-semibold text-slate-700">{key}</td>
                              <td className="audit-val-prev">
                                {prevVal === undefined || prevVal === null ? (
                                  <span className="text-slate-400 italic">none</span>
                                ) : typeof prevVal === 'object' ? (
                                  <pre>{JSON.stringify(prevVal, null, 2)}</pre>
                                ) : (
                                  String(prevVal)
                                )}
                              </td>
                              <td className="audit-val-next">
                                {nextVal === undefined || nextVal === null ? (
                                  <span className="text-slate-400 italic">removed</span>
                                ) : typeof nextVal === 'object' ? (
                                  <pre>{JSON.stringify(nextVal, null, 2)}</pre>
                                ) : (
                                  String(nextVal)
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              )}

              {inspectTab === 'after' && (
                <div className="audit-json-wrap">
                  <pre>{JSON.stringify(selectedEvent.after_record || {}, null, 2)}</pre>
                </div>
              )}

              {inspectTab === 'before' && (
                <div className="audit-json-wrap">
                  <pre>
                    {selectedEvent.before_record
                      ? JSON.stringify(selectedEvent.before_record, null, 2)
                      : '// Initial creation - no previous state recorded'}
                  </pre>
                </div>
              )}

              {inspectTab === 'raw' && (
                <div className="audit-json-wrap">
                  <pre>{JSON.stringify(selectedEvent, null, 2)}</pre>
                </div>
              )}
            </div>

            <div className="document-actions mt-6">
              <button
                type="button"
                className="secondary-button ml-auto"
                onClick={() => setSelectedEvent(null)}
              >
                Close inspector
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
