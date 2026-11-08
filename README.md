# OM Motors workspace

Next.js with Supabase Google authentication and database-enforced email assignments and role permissions. 
## Activate this update

For the Service & PDI module, apply `supabase/UPGRADE_WORKSHOP.sql` once **after** the live operations upgrade below. It adds General Manager, Service Manager, PDI/Delivery Staff and Warranty Staff to Team & permissions; no account is automatically assigned to the new roles. It restricts technicians to assigned service work and removes their previous broad module defaults. Admins can subsequently customize role permissions.

The workshop provides job intake/cards, customer vehicle lookup, diagnosis/work/parts/labour, approval and invoice finalization, payments, completed history, reminders, technician reports, vehicle intake and configurable PDI, verified component warranties, claims/replacements and paid vehicle delivery. It reuses the existing customer, physical vehicle, inventory and billing tables. Stock movements and sensitive actions are audited. Manager-approved service invoices become immutable; an unpaid invoice may be cancelled with a reason and its stock restored, then reissued. Paid cancellation/refunds require a separate accounting procedure and are deliberately blocked.

Use Team & permissions to approve technician emails, register a customer vehicle or receive a catalogue vehicle, and create a job. Save work and verified part/labour costs, mark Ready for Delivery, then approve the invoice. Payments enable job completion. New vehicle intake creates reserved stock and a PDI; passing inspection releases the reservation. Warranty records require explicit stored coverage dates and source evidence. Private JPG/PNG/WebP/PDF attachments use the `workshop-evidence` Supabase Storage bucket created by the upgrade.

Validation covers complete isolated database workflows. Live Google-authenticated saves and Storage uploads still require the project owner to apply the migration; the public anon key cannot run SQL. The upgrade does not invent warranty durations, prices, customers, vehicles or transactions. Existing duplicate normalized vehicle/warranty identifiers must be resolved before the new uniqueness checks can be installed.

For the existing project, run `supabase/UPGRADE_LIVE_OPERATIONS.sql` once in the Supabase SQL Editor, then refresh the app. This installs the live operations tables/functions and 60 product records from the supplied verified product data pack. It preserves existing customers, staff assignments, and role permissions. Do not rerun the fresh-project setup on an existing database.

For a fresh project, first run `supabase/SETUP_FRESH_PROJECT.sql`, then the upgrade above. The public anon key cannot install database changes. Google must be enabled in Supabase; allow the app's `/auth/callback` URL in Authentication URL Configuration.

## Vehicle register rollout

After the existing upgrades through `20260914_013_receivables_management.sql`, run [the vehicle register migration](supabase/migrations/20261108_014_vehicle_register.sql) in staging, then deploy the matching app. This migration is standalone. Keep using the existing bundle scripts for their original migrations. Back up the database before production rollout. The SQL header describes recovery after live receipts.

Existing vehicles retain their IDs. The migration copies legacy battery, ownership and registration records into history tables. The workshop battery field shows the first active battery. Historical registrations and batteries retain an unknown registration or installation date. Backfilled ownership uses the purchase date when available, followed by receipt date or record creation date. Conflicting normalized identifiers abort the upgrade and identify the affected vehicles for correction.

### Manual Phase 1 check

1. Sign in on staging with vehicle write access. Under **Inventory → Receive vehicle**, choose a catalogue model and PDI inspector. Receive a chassis with two battery serials. Use **Receive and add another** for the second vehicle.
2. Search the vehicle register for each chassis and component serial. Open each detail page and check its shipment, serials and pending inspection against the receipt. Confirm two stock movements, two reservations and one inspection per chassis.
3. Download the CSV template and preview a shipment containing a duplicate serial. Check the row error and inventory counts. Correct the file, preview again and receive the shipment once.
4. Sign in with a read-only vehicle role. Open a vehicle, check the permitted sections, and visit `/vehicles/receive` to verify the route guard.

Barcode capture is optional. Set `NEXT_PUBLIC_ENABLE_CHASSIS_SCAN=true` at build time to show it on devices with native barcode detection.

### Manual Phase 2 check

1. Receive two vehicles of the same model and pass both PDIs. Create a quotation with one chassis, then convert it to an invoice. Verify one stock decrement, the customer in vehicle ownership history, and the chassis and motor or engine on the printed invoice.
2. Try the same chassis on a second invoice. Edit the first invoice to select the other chassis. Verify the old unit becomes available and the model quantity stays the same.
3. On an existing single-unit vehicle invoice, use **Link vehicle** and save. For multi-unit lines, split them into single-unit lines and check discounts and totals before saving. Cancel an unpaid sales invoice with a reason and verify the stock and ownership history.
4. Complete a separate credit delivery with a manager override reason of at least ten characters. Check the unpaid amount in Receivables.

### Manual Phase 3 check

1. Open a vehicle as inventory staff. Add a registration, then change the number with a reason. Verify both entries in registration history and search for the new number.
2. Add a battery and replace it with a new serial. Verify the installation and removal dates, reason and recent register activity.
3. Open an owned vehicle as a manager. Select another customer and confirm a dated transfer. Check that the previous ownership ends on the transfer date and the new owner appears on the vehicle card. The original invoice retains its purchaser.

The vehicle register migration includes phases 1–3. Reapply it to staging if an earlier version was already installed.

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

No simulated OCR or invented business records are included. OCR and external manufacturer claim submission remain future integrations. Claims, review decisions, replacements, private evidence, delivery records and reminders are managed within this application; they do not send messages to customers or manufacturers. Old local sample records are not migrated to production.

## Verification

`npm test` runs isolated PostgreSQL tests for access control, product import, billing calculations, custom numbering, invoice conversion, stock rollback, edit conflicts, idempotent payments and direct-write denial. `npm run build` checks the production application. Tests never insert records into the remote project.

`node tests/check-supabase.mjs` performs read-only connection/schema probes. Database tests do not replace a signed-in live save/reload test after applying the upgrade.
