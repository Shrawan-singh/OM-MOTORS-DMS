-- Migration: 20260914_011_admin_audit_trail.sql
-- Description: Unified administrative audit trail RPC function, restricted strictly to the owner role.

CREATE OR REPLACE FUNCTION public.admin_get_audit_trail(
  p_limit integer DEFAULT 500,
  p_offset integer DEFAULT 0,
  p_module text DEFAULT NULL,
  p_actor_email text DEFAULT NULL,
  p_search text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text := public.access_role();
  result jsonb;
BEGIN
  -- Strict owner-only access check
  IF v_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Administrator access required to view audit trail';
  END IF;

  WITH all_events AS (
    -- 1. WORKSHOP AUDIT
    SELECT
      ('ws_' || w.id::text) AS id,
      'workshop' AS module,
      w.action AS action,
      w.entity AS entity,
      w.record_id::text AS record_id,
      w.actor::text AS actor_id,
      coalesce(lower(u.email), 'Unknown staff') AS actor_email,
      coalesce(w.role, aa.role, 'staff') AS actor_role,
      w.before_record,
      w.after_record,
      w.reason,
      w.created_at,
      coalesce(
        w.after_record->>'number',
        w.before_record->>'number',
        c.name,
        v.registration_no,
        w.entity || ' #' || substring(w.record_id::text from 1 for 8)
      ) AS target_label
    FROM public.workshop_audit w
    LEFT JOIN auth.users u ON u.id = w.actor
    LEFT JOIN public.access_assignments aa ON lower(aa.email) = lower(u.email)
    LEFT JOIN public.customers c ON c.id = w.customer_id
    LEFT JOIN public.vehicles v ON v.id = w.vehicle_id

    UNION ALL

    -- 2. BILLING AUDIT
    SELECT
      ('bill_' || b.id::text) AS id,
      'billing' AS module,
      CASE
        WHEN b.before_record IS NULL THEN 'Document created (' || coalesce(b.after_record->>'kind', 'document') || ')'
        WHEN b.after_record->>'status' = 'cancelled' AND coalesce(b.before_record->>'status', '') <> 'cancelled' THEN 'Invoice cancelled'
        ELSE 'Document updated (' || coalesce(b.after_record->>'kind', 'document') || ')'
      END AS action,
      coalesce(b.after_record->>'kind', 'document') AS entity,
      b.document_id::text AS record_id,
      b.actor::text AS actor_id,
      coalesce(lower(u.email), 'Unknown staff') AS actor_email,
      coalesce(aa.role, 'staff') AS actor_role,
      b.before_record,
      b.after_record,
      coalesce(b.after_record->>'cancel_reason', '') AS reason,
      b.created_at,
      coalesce(
        b.after_record->>'number',
        b.before_record->>'number',
        'DOC #' || substring(b.document_id::text from 1 for 8)
      ) AS target_label
    FROM public.billing_audit b
    LEFT JOIN auth.users u ON u.id = b.actor
    LEFT JOIN public.access_assignments aa ON lower(aa.email) = lower(u.email)

    UNION ALL

    -- 3. ACCESS AUDIT
    SELECT
      ('acc_' || a.id::text) AS id,
      'access' AS module,
      CASE
        WHEN a.action = 'assign_access' THEN 'Team member access updated'
        WHEN a.action = 'save_permissions' THEN 'Role permissions updated'
        ELSE a.action
      END AS action,
      'access_assignment' AS entity,
      a.id::text AS record_id,
      a.actor::text AS actor_id,
      coalesce(lower(u.email), 'Administrator') AS actor_email,
      coalesce(aa.role, 'owner') AS actor_role,
      NULL::jsonb AS before_record,
      a.details AS after_record,
      '' AS reason,
      a.created_at,
      a.target AS target_label
    FROM public.access_audit a
    LEFT JOIN auth.users u ON u.id = a.actor
    LEFT JOIN public.access_assignments aa ON lower(aa.email) = lower(u.email)

    UNION ALL

    -- 4. STOCK MOVEMENTS
    SELECT
      ('stock_' || sm.id::text) AS id,
      'inventory' AS module,
      CASE
        WHEN sm.delta > 0 THEN 'Stock received (+' || sm.delta::text || ')'
        ELSE 'Stock deducted (' || sm.delta::text || ')'
      END AS action,
      'inventory' AS entity,
      sm.inventory_id::text AS record_id,
      sm.actor::text AS actor_id,
      coalesce(lower(u.email), 'Unknown staff') AS actor_email,
      coalesce(aa.role, 'staff') AS actor_role,
      jsonb_build_object('qty', sm.before_qty) AS before_record,
      jsonb_build_object('qty', sm.after_qty, 'delta', sm.delta, 'reference', sm.reference) AS after_record,
      sm.reference AS reason,
      sm.created_at,
      coalesce(inv.item_name, 'Stock item #' || substring(sm.inventory_id::text from 1 for 8)) AS target_label
    FROM public.stock_movements sm
    LEFT JOIN auth.users u ON u.id = sm.actor
    LEFT JOIN public.access_assignments aa ON lower(aa.email) = lower(u.email)
    LEFT JOIN public.inventory inv ON inv.id = sm.inventory_id
  ),
  filtered AS (
    SELECT * FROM all_events e
    WHERE (p_module IS NULL OR e.module = p_module)
      AND (p_actor_email IS NULL OR lower(e.actor_email) = lower(p_actor_email))
      AND (
        p_search IS NULL OR
        e.action ILIKE '%' || p_search || '%' OR
        e.target_label ILIKE '%' || p_search || '%' OR
        e.reason ILIKE '%' || p_search || '%' OR
        e.actor_email ILIKE '%' || p_search || '%'
      )
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM filtered),
    'events', coalesce((
      SELECT jsonb_agg(to_jsonb(f) ORDER BY f.created_at DESC)
      FROM (SELECT * FROM filtered ORDER BY created_at DESC LIMIT p_limit OFFSET p_offset) f
    ), '[]'::jsonb),
    'actors', coalesce((
      SELECT jsonb_agg(DISTINCT jsonb_build_object('email', e.actor_email, 'role', e.actor_role))
      FROM all_events e
      WHERE e.actor_email IS NOT NULL AND e.actor_email <> 'Unknown staff'
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.admin_get_audit_trail(integer,integer,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_audit_trail(integer,integer,text,text,text) TO authenticated;
