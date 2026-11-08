import {PGlite} from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite({ extensions: { pg_trgm } });
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; GRANT USAGE ON SCHEMA auth TO authenticated,anon; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated,anon;`);
for(const f of ['supabase/SETUP_FRESH_PROJECT.sql','supabase/UPGRADE_LIVE_OPERATIONS.sql','supabase/UPGRADE_WORKSHOP.sql'])await db.exec(readFileSync(f,'utf8').replace(/CREATE EXTENSION IF NOT EXISTS .*;/g,''));
// Exercise the existing workshop entry points against the upgraded database.
for (const file of [
  '20260914_011_admin_audit_trail.sql',
  '20260914_012_service_pdi_fixes.sql',
  '20260914_013_receivables_management.sql',
  '20261108_014_vehicle_register.sql',
]) await db.exec(readFileSync('supabase/migrations/' + file, 'utf8'));
const owner='00000000-0000-4000-8000-000000000001',manager='00000000-0000-4000-8000-000000000002',tech='00000000-0000-4000-8000-000000000003',other='00000000-0000-4000-8000-000000000004';
await db.exec(`INSERT INTO auth.users VALUES ('${owner}','suryasingh4395@gmail.com',now()),('${manager}','manager@example.test',now()),('${tech}','tech@example.test',now()),('${other}','other@example.test',now());`);
const q=async(s,p=[])=>(await db.query(s,p)).rows;
const as=async id=>db.exec(`RESET ROLE; SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${id}',false)`);
const rpc=async(name,p)=> (await q(`SELECT public.${name}($1::jsonb) value`,[JSON.stringify(p)]))[0].value;
const snap=async()=>(await q('SELECT public.ws_snapshot() value'))[0].value;
await as(owner);
for(const [email,role] of [['manager@example.test','manager'],['tech@example.test','mechanic'],['other@example.test','mechanic']])await q('SELECT public.admin_assign_access($1,$2,true)',[email,role]);
await as(manager);
await assert.rejects(()=>q("SELECT public.admin_assign_access('intruder@example.test','owner',true)"),/Administrator/);
const cust=(await q("INSERT INTO public.customers(name,phone,village) VALUES ('Workshop test','9999999999','Test site') RETURNING id"))[0].id;
let data=await snap();const product=data.products.find(p=>p.category==='tractor');const part=data.products.find(p=>p.category==='battery');
await q('SELECT public.app_receive_stock($1,5,$2)',[part.id,'Workshop test parts']);
data=await snap();const stock=data.inventory.find(i=>i.item_id===part.id);
const car=await rpc('ws_save_vehicle',{customer_id:cust,model_name:product.model_name,product_id:product.id,chassis_no:'TEST-CUSTOMER-001',vehicle_type:'tractor',intake:false});
let jobId=await rpc('ws_save_job',{customer_id:cust,vehicle_id:car,complaint:'Brake inspection needed',technician_emails:['tech@example.test'],status:'assigned',job_type:'General Service'});
await as(tech);data=await snap();assert.equal(data.jobs.length,1);assert.equal(data.jobs[0].financials,undefined);assert.equal(data.invoices.length,0);
await assert.rejects(()=>q('SELECT * FROM public.service_jobs'),/permission denied/);
await assert.rejects(()=>rpc('ws_save_job',{customer_id:cust,vehicle_id:car,complaint:'Unauthorized create'}),/denied/);
let job=data.jobs[0];await rpc('ws_save_job',{...job,status:'work_in_progress',diagnosis:'Worn component',work_performed:'Replaced component and tested brakes',parts_used:[{inventoryId:stock.id,qty:1}],labour_hours:2});
await as(other);data=await snap();assert.equal(data.jobs.length,0);assert.equal(data.customers.length,0);await assert.rejects(()=>rpc('ws_save_job',{id:jobId,status:'completed'}),/denied/);
await as(manager);data=await snap();job=data.jobs[0];
await rpc('ws_save_job',{...job,status:'ready_for_delivery',financials:{rates:{[stock.id]:{price:1000,cost:600,gst:18,discount:0}},labour_charge:500,labour_cost:200,labour_gst:18}});
const inv=(await q('SELECT public.ws_finalize($1,$2,$3) id',[jobId,'SRV-TEST-001','cgst_sgst']))[0].id;
assert.equal((await q('SELECT qty_available FROM public.inventory WHERE id=$1',[stock.id]))[0].qty_available,4);
assert.equal((await q('SELECT public.ws_finalize($1,$2,$3) id',[jobId,'SRV-TEST-001','cgst_sgst']))[0].id,inv);
data=await snap();assert.equal(data.invoices.find(b=>b.id===inv).total,1770);
await assert.rejects(()=>rpc('app_save_document',{id:inv,kind:'invoice'}),/service job/);
await q("SELECT public.app_record_payment(gen_random_uuid(),$1,1770,'cash','TEST')",[inv]);
data=await snap();job=data.jobs.find(j=>j.id===jobId);assert.equal(job.status,'paid');await rpc('ws_save_job',{...job,status:'completed',next_service_date:'2027-01-01',recommended_work:'Check brakes'});
data=await snap();assert.equal(data.jobs[0].status,'completed');assert.ok(data.events.some(e=>e.action==='Service payment recorded'));await assert.rejects(()=>q('SELECT public.ws_cancel_invoice($1,$2)',[inv,'Test cancellation']),/Paid invoices/);
const intake=await rpc('ws_save_vehicle',{product_id:product.id,model_name:product.model_name,chassis_no:'TEST-INTAKE-001',engine_no:'TEST-ENGINE-001',vehicle_type:'tractor',intake:true,shipment_ref:'SHIP-TEST',inspector_email:'manager@example.test'});
await assert.rejects(()=>rpc('ws_save_vehicle',{product_id:product.id,model_name:product.model_name,chassis_no:'test-intake-001',vehicle_type:'tractor',intake:true,shipment_ref:'SHIP-TEST'}),/unique/);
data=await snap();let pdi=data.pdi.find(p=>p.vehicle_id===intake);assert.ok(pdi.checklist.length>20);
await assert.rejects(()=>rpc('ws_save_pdi',{...pdi,result:'passed'}),/mandatory/);
await rpc('ws_save_pdi',{...pdi,checklist:pdi.checklist.map(x=>({...x,result:'pass'})),result:'passed'});
data=await snap();assert.equal(data.vehicles.find(v=>v.id===intake).lifecycle,'available');
const warranty=await rpc('ws_save_warranty',{customer_id:cust,vehicle_id:car,product_id:part.id,item_type:'battery',product_name:part.model_name,serial_no:'TEST-BATTERY-WARRANTY',start_date:'2026-01-01',end_date:'2028-01-01',coverage_evidence:'Verified test manufacturer certificate'});
let claim=await rpc('ws_save_claim',{warranty_id:warranty,complaint_description:'Battery not charging'});
for(const status of ['inspection','submitted','approved','replacement','closed']){data=await snap();const c=data.claims.find(c=>c.id===claim);await rpc('ws_save_claim',{...c,status,review_reason:'Verified covered failure',replacement_product_id:part.id,replacement_serial:'TEST-REPLACEMENT-001',resolution:'Replaced battery under verified warranty'})}
data=await snap();assert.equal(data.claims[0].status,'closed');assert.ok(data.events.some(e=>e.entity==='claim'));
assert.equal((await q('SELECT qty_available FROM public.inventory WHERE id=$1',[stock.id]))[0].qty_available,3);
const job2=await rpc('ws_save_job',{customer_id:cust,vehicle_id:car,complaint:'Second test repair',status:'new',technician_emails:['tech@example.test']});
data=await snap();await rpc('ws_save_job',{...data.jobs.find(j=>j.id===job2),work_performed:'Replaced test part',status:'ready_for_delivery',parts_used:[{inventoryId:stock.id,qty:1}],financials:{rates:{[stock.id]:{price:100,cost:50,gst:5}},labour_charge:0,labour_cost:0,labour_gst:0}});
const inv2=(await q('SELECT public.ws_finalize($1,$2,$3) id',[job2,'SRV-TEST-002','igst']))[0].id;
await q('SELECT public.ws_cancel_invoice($1,$2)',[inv2,'Duplicate workshop charge']);await q('SELECT public.ws_cancel_invoice($1,$2)',[inv2,'Duplicate workshop charge']);
assert.equal((await q('SELECT qty_available FROM public.inventory WHERE id=$1',[stock.id]))[0].qty_available,3);
await assert.rejects(()=>q("SELECT public.app_record_payment(gen_random_uuid(),$1,10,'cash','X')",[inv2]),/cancelled/);
data=await snap();const stockVehicle=data.vehicles.find(v=>v.id===intake);
const line = {productId: product.id, inventoryId: stockVehicle.stock_id, name: product.model_name,
  qty: 1, unitPrice: 10000, discount: 0, gstRatePct: 5};
const sale = {kind:'invoice',customerId:cust,date:'2026-09-13',taxMode:'cgst_sgst'};
const stockQty = async () => (await q('select qty_available from public.inventory where id=$1',[stockVehicle.stock_id]))[0].qty_available;
const quote = await rpc('app_save_document',{...sale,kind:'quotation',validUntil:'2026-10-01',
  items:[{...line,chassisNo:' test intake001 '}]});
assert.equal(quote.items[0].vehicleId,intake);
assert.equal(await stockQty(),1);
await assert.rejects(rpc('app_save_document',{...sale,items:[{...line,qty:2,vehicleId:intake}]}),/quantity 1/);
let linked = await rpc('app_save_document',{...sale,items:quote.items,sourceQuotationId:quote.id});
assert.equal(linked.items[0].engineNo,'TEST-ENGINE-001');
assert.equal(await stockQty(),0);
await assert.rejects(rpc('app_save_document',{...sale,items:quote.items}),/unavailable/);
linked = await rpc('app_save_document',{...sale,id:linked.id,expectedUpdatedAt:linked.updated_at,
  sourceQuotationId:quote.id,items:[line]});
assert.equal(await stockQty(),0);
assert.equal((await snap()).vehicles.find(v=>v.id===intake).customer_id,null);
await rpc('vehicle_link_sale',{invoice_id:linked.id,vehicle_id:intake,source:'backfill'});
const linkedView=(await q('select public.vehicle_360($1) d',[intake]))[0].d;
assert.equal(linkedView.ownership.find(o=>!o.to_date).source,'backfill');
await rpc('ws_save_delivery',{vehicle_id:intake,invoice_id:linked.id,finish:false});
for(let retry=0;retry<2;retry++) await rpc('vehicle_cancel_invoice',{invoice_id:linked.id,reason:'Duplicate sale entry'});
assert.equal(await stockQty(),1);
assert.equal((await snap()).vehicles.find(v=>v.id===intake).lifecycle,'available');
const salesInvoice=await rpc('app_save_document',{kind:'invoice',number:'VEH-TEST-001',customerId:cust,date:'2026-09-13',taxMode:'cgst_sgst',items:[{productId:product.id,inventoryId:stockVehicle.stock_id,name:product.model_name,qty:1,unitPrice:10000,discount:0,gstRatePct:5}]});
const checks={invoice_handed:true,warranty_explained:true,manual_given:true,vehicle_demonstrated:true};
await assert.rejects(()=>rpc('ws_save_delivery',{vehicle_id:intake,invoice_id:salesInvoice.id,assigned_email:'manager@example.test',checklist:checks,finish:true}),/Settle/);
await rpc('ws_save_delivery',{vehicle_id:intake,invoice_id:salesInvoice.id,assigned_email:'manager@example.test',
  checklist:checks,finish:true,override_reason:'Approved credit delivery by manager'});
assert.equal((await q('select public.vehicle_360($1) d',[intake]))[0].d.invoice.balance,10500);
await q("SELECT public.app_record_payment(gen_random_uuid(),$1,10500,'cash','SALE')",[salesInvoice.id]);
data=await snap();assert.equal(data.vehicles.find(v=>v.id===intake).lifecycle,'delivered');assert.equal(data.vehicles.find(v=>v.id===intake).customer_id,cust);
const delivered = (await q('SELECT public.vehicle_360($1) data', [intake]))[0].data;
assert.equal(delivered.ownership.filter(row => !row.to_date).length, 1);
assert.equal(delivered.ownership[0].name, 'Workshop test');
assert.equal(delivered.invoice.id, salesInvoice.id);
assert.equal(delivered.invoice.balance, 0);
await assert.rejects(rpc('vehicle_release_sale',{vehicle_id:intake,invoice_id:salesInvoice.id}),/delivered chassis/);
await as(other);
await assert.rejects(rpc('vehicle_link_sale',{vehicle_id:intake,invoice_id:salesInvoice.id}),/permissions required/);
await as(manager);
assert.equal(delivered.payments[0].amount, 10500);
const resaleCustomer=(await q("insert into public.customers(name,phone,village) values ('Resale test','9876512345','Test village') returning id"))[0].id;
await rpc('vehicle_transfer_owner',{vehicle_id:intake,customer_id:resaleCustomer,from_date:'2026-09-14',reason:'Recorded resale'});
await rpc('app_save_document',{...sale,id:salesInvoice.id,expectedUpdatedAt:(await q(
  'select updated_at::text as updated from public.billing_documents where id=$1',[salesInvoice.id]))[0].updated,
  items:[{...line,vehicleId:intake}],notes:'Updated invoice note'});
const resaleView=(await q('select public.vehicle_360($1) data',[intake]))[0].data;
assert.equal(resaleView.ownership.find(o=>!o.to_date).customer_id,resaleCustomer);
assert.equal(resaleView.invoice.id,salesInvoice.id);
assert.equal((await q('select customer_id from public.billing_documents where id=$1',[salesInvoice.id]))[0].customer_id,cust);
writeFileSync('tests/workshop-fixture.json',JSON.stringify(data,null,2));
await as(other);await assert.rejects(()=>q('SELECT public.ws_finalize($1,$2,$3)',[job2,'FORBIDDEN','igst']),/approval/);await assert.rejects(()=>q('SELECT public.ws_base_save_document($1::jsonb)',[JSON.stringify({})]),/permission denied/);
await db.exec('RESET ROLE; SET ROLE anon');await assert.rejects(()=>snap(),/permission denied/);
console.log('PASS: manager restrictions, technician isolation, job → parts → invoice → payment → history, invoice cancellation, quotation → chassis sale → release/backfill/cancel, PDI → credit delivery → payment, duplicate identifiers, warranty claims and replacement stock.');
await db.close();
