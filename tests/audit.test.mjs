import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const db = new PGlite();
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
GRANT USAGE ON SCHEMA auth TO authenticated,anon;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated,anon;`);

// Load schemas in the exact proper order:
for (const f of [
  'supabase/SETUP_FRESH_PROJECT.sql',
  'supabase/UPGRADE_LIVE_OPERATIONS.sql',
  'supabase/UPGRADE_WORKSHOP.sql',
  'supabase/migrations/20260914_011_admin_audit_trail.sql',
]) {
  await db.exec(readFileSync(f, 'utf8').replace(/CREATE EXTENSION IF NOT EXISTS .*;/g, ''));
}

const owner = '00000000-0000-4000-8000-000000000001';
const manager = '00000000-0000-4000-8000-000000000002';
const mechanic = '00000000-0000-4000-8000-000000000003';

await db.exec(`INSERT INTO auth.users VALUES
  ('${owner}','suryasingh4395@gmail.com',now()),
  ('${manager}','manager@ommotors.in',now()),
  ('${mechanic}','mechanic@ommotors.in',now());`);

const asUser = async (id) => db.exec(`RESET ROLE; SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${id}',false);`);
const scalar = async (sql) => (await db.query(sql)).rows[0];

// Owner setup
await asUser(owner);
await db.query("SELECT public.admin_assign_access('manager@ommotors.in','manager',true)");
await db.query("SELECT public.admin_assign_access('mechanic@ommotors.in','mechanic',true)");

// Verify role assignments
await asUser(manager);
assert.equal((await scalar('SELECT public.access_role() role')).role, 'manager');

// Manager MUST be rejected from viewing audit trail (strictly owner only)
await assert.rejects(
  db.query("SELECT public.admin_get_audit_trail()"),
  /Administrator access required/
);

// Mechanic MUST also be rejected
await asUser(mechanic);
await assert.rejects(
  db.query("SELECT public.admin_get_audit_trail()"),
  /Administrator access required/
);

// Owner can view audit trail
await asUser(owner);
const res = await scalar("SELECT public.admin_get_audit_trail() trail");
const trail = res.trail;
assert.ok(trail, 'Audit trail should return result');
assert.ok(Array.isArray(trail.events), 'Trail events should be an array');
assert.ok(trail.total >= 0, 'Total should be a non-negative number');

// We performed admin_assign_access earlier as owner, which logs to access_audit!
// Let's verify that the access_audit entry is present in trail
const accessEvent = trail.events.find((e) => e.module === 'access');
assert.ok(accessEvent, 'Should contain access_audit event from assigning roles');
assert.equal(accessEvent.actor_email, 'suryasingh4395@gmail.com');
assert.equal(accessEvent.actor_role, 'owner');

// Test filtering by module
const accessOnly = (await scalar("SELECT public.admin_get_audit_trail(100, 0, 'access') trail")).trail;
assert.ok(accessOnly.events.every((e) => e.module === 'access'));

// Test filtering by search
const searched = (await scalar("SELECT public.admin_get_audit_trail(100, 0, NULL, NULL, 'manager@ommotors.in') trail")).trail;
assert.ok(searched.events.length > 0);

console.log('PASS: admin_get_audit_trail owner-only enforcement and event aggregation verified.');
