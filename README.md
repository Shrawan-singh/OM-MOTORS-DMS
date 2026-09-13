# OM Motors workspace

Next.js with Supabase Google authentication and database-enforced email assignments and role permissions. Initial administrator: suryasingh4395@gmail.com.

## Activate this update

For the existing project, run `supabase/UPGRADE_LIVE_OPERATIONS.sql` once in the Supabase SQL Editor, then refresh the app. This installs the live operations tables/functions and 59 product records from the supplied verified product data pack. It preserves existing customers, staff assignments, and role permissions. Do not rerun the fresh-project setup on an existing database.

For a fresh project, first run `supabase/SETUP_FRESH_PROJECT.sql`, then the upgrade above. The public anon key cannot install database changes. Google must be enabled in Supabase; allow the app's `/auth/callback` URL in Authentication URL Configuration.

## Run

`npm install`, then `npm run dev`. Production: `npm run build`, then `npm start`.

`.env.local` holds the supplied public project URL and anon key. Never place a service-role key in the browser. Use `.env.example` for another environment.

## Live workflows

- Operational screens load Supabase records under the signed-in user's database permissions. There is no sample-data or browser-storage fallback. The obsolete sample-storage key is cleared.
- Admins approve emails before login, assign/revoke roles, and change role permissions. Business settings store the seller address, GSTIN, payment details and terms used in documents.
- The catalogue imports source-attributed product variants, specifications and uncertainty notes. Unknown selling prices, HSN codes and GST rates remain blank; authorized staff set defaults. These are source-pack records, not independently reverified current manufacturer claims.
- Customers, quotations, invoices, payments, stock receipts and adjustments persist to Supabase. Service/PDI screens read existing records and save status changes.
- Quotes and invoices support custom unique numbers, manually typed item names, discounts, HSN and editable per-item GST. Product defaults prefill new lines. Saved documents preserve customer/seller snapshots.
- The database recalculates totals, checks permissions, prevents overpayments, detects stale document edits and records billing audits. Linked inventory changes atomically with invoice saves; unlinked manual items do not change stock. Inventory linking requires inventory visibility.
- Print/PDF opens a dedicated document page with no workspace navigation. Select Print / Save as PDF there. Disable the browser's headers and footers for clean output.
- The sidebar scrolls with a visible sign-out area.

## Scope

No simulated OCR, invented transactions, prices, stock or customers are included. OCR/uploads, automated delivery/PDI/warranty creation and expanded service intake remain future features. Old local sample records are not migrated to production.

## Verification

`npm test` runs isolated PostgreSQL tests for access control, product import, billing calculations, custom numbering, invoice conversion, stock rollback, edit conflicts, idempotent payments and direct-write denial. `npm run build` checks the production application. Tests never insert records into the remote project.

`node tests/check-supabase.mjs` performs read-only connection/schema probes. Database tests do not replace a signed-in live save/reload test after applying the upgrade.
