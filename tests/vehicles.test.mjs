import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';

const db = new PGlite({ extensions: { pg_trgm } });
const query = async (sql, args = []) => (await db.query(sql, args)).rows;
const value = async (sql, args) => Object.values((await query(sql, args))[0])[0];
const rpc = (name, payload) =>
  value('select public.' + name + '($1::jsonb)', [JSON.stringify(payload)]);
const as = async (id) => {
  await db.exec('reset role; set role authenticated');
  await query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
};
const owner = '00000000-0000-4000-8000-000000000001';
const inventory = '00000000-0000-4000-8000-000000000002';
const mechanic = '00000000-0000-4000-8000-000000000003';
const migration = readFileSync('supabase/migrations/20261108_014_vehicle_register.sql', 'utf8');
try {
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    GRANT USAGE ON SCHEMA auth TO authenticated,anon;`);
  for (const file of readdirSync('supabase/migrations')
    .filter((f) => f < '20261108')
    .sort()) {
    await db.exec(
      readFileSync('supabase/migrations/' + file, 'utf8').replace(
        /CREATE EXTENSION IF NOT EXISTS .*;/g,
        ''
      )
    );
  }
  await query('insert into auth.users values ($1,$2,now()),($3,$4,now()),($5,$6,now())', [
    owner,
    'suryasingh4395@gmail.com',
    inventory,
    'stock@example.test',
    mechanic,
    'tech@example.test',
  ]);
  await as(owner);
  await query("select public.admin_assign_access('stock@example.test','inventory',true)");
  await query("select public.admin_assign_access('tech@example.test','mechanic',true)");
  const customer =
    await value(`insert into public.customers(name,phone,village,pan_no,aadhaar_last4,id_document_ref)
    values ('Test customer','+91 98765-43210','Test village','SECRET_PAN','9999','SECRET_REF') returning id`);
  const original = await rpc('ws_save_vehicle', {
    model_name: 'Legacy tractor',
    customer_id: customer,
    chassis_no: 'Legacy-01',
    battery_no: 'Legacy-B1',
    registration_no: 'UP-00 X1',
  });
  await db.exec("reset role; select set_config('request.jwt.claim.sub','',false)");
  // Old workshop indexes permitted these different spellings. The failed upgrade must
  // roll back completely and identify both vehicles so the owner can resolve the collision.
  await db.exec(`insert into public.vehicles(model_name,chassis_no,colour,registration_no)
    values ('Collision test','LEGACY-02','','up00x1')`);
  await assert.rejects(db.exec(migration), /Resolve duplicate Registration UP00X1.*LEGACY-0/i);
  await db.exec('rollback');
  assert.equal(await value("select to_regclass('public.vehicle_components')"), null);
  await db.exec("delete from public.vehicles where chassis_no='LEGACY-02'");
  await db.exec(migration);
  await as(owner);
  assert.equal(await value('select phone_norm from public.customers'), '9876543210');
  const detail = (id) => value('select public.vehicle_360($1)', [id]);
  const legacy = await detail(original);
  assert.equal(legacy.components[0].serial_no, 'LEGACY-B1');
  assert.equal(legacy.ownership[0].source, 'backfill');
  assert.equal(legacy.registrations[0].registration_no, 'UP-00 X1');
  assert.doesNotMatch(JSON.stringify(legacy), /aadhaar|pan_no|id_document|SECRET/);
  await db.exec('reset role');
  assert.equal(
    await value("select count(*)::int from public.workshop_audit where role='migration'"),
    3
  );
  await as(owner);
  const options = await value('select public.vehicle_intake_options()');
  const product = options.products.find((p) => p.category === 'e_rickshaw');
  const input = (i) => ({
    product_id: product.id,
    chassis_no: 'CH-' + i,
    motor_no: 'Motor-' + i,
    supplier: 'Test supplier',
    received_date: '2026-01-12',
    inspector_email: options.inspectors[0],
    components: [
      { component_type: 'battery', serial_no: 'B-' + i },
      { component_type: 'battery', serial_no: 'BX-' + i },
      { component_type: 'charger', serial_no: 'CG-' + i },
      { component_type: 'controller', serial_no: 'CT-' + i },
    ],
  });
  await as(inventory);
  assert.equal(await value("select public.has_permission('pdi.write')"), false);
  const vid = await rpc('vehicle_receive', input(1));
  const vehicle = await detail(vid);
  assert.equal(vehicle.vehicle.model_name, product.model_name);
  assert.equal(vehicle.vehicle.lifecycle, 'pdi_pending');
  assert.equal(vehicle.components.length, 4);
  assert.equal(vehicle.ownership, null);
  assert.equal(vehicle.pdi, null);
  assert.equal(await value('select sum(qty_reserved)::int from public.inventory'), 1);
  for (const [key, serial, expected] of [
    ['chassis_no', ' c h1 ', 'Chassis'],
    ['motor_no', 'M OTOR1', 'Motor'],
  ]) {
    await assert.rejects(
      rpc('vehicle_receive', { ...input(2), [key]: serial }),
      new RegExp(expected + '.*CH-1')
    );
  }
  await assert.rejects(
    rpc('vehicle_receive', {
      ...input(2),
      components: [{ component_type: 'charger', serial_no: ' b1 ' }],
    }),
    /Battery.*CH-1/
  );
  await assert.rejects(
    rpc('vehicle_receive', { ...input(2), inspector_email: 'stock@example.test' }),
    /inspector/
  );
  await assert.rejects(rpc('vehicle_receive', { ...input(2), motor_no: '' }), /motor number/);
  const search = (q, filters = {}) =>
    value('select public.vehicle_register_list($1,$2)', [q, JSON.stringify(filters)]);
  assert.equal((await search('c t-1'))[0].id, vid);
  assert.equal((await search('%')).length, 0);
  const receiptCounts = () =>
    value(`select jsonb_build_array((select count(*) from public.vehicles),
    (select count(*) from public.vehicle_components),(select sum(qty_available) from public.inventory),
    (select sum(qty_reserved) from public.inventory),(select count(*) from public.stock_movements))`);
  const counts = await receiptCounts();
  const preview = await rpc('vehicle_bulk_preview', [input(2), input(3)]);
  assert.deepEqual(preview.errors, []);
  assert.deepEqual(await receiptCounts(), counts);
  const failed = await rpc('vehicle_bulk_receive', [input(2), input(2), input(1)]);
  assert.deepEqual(
    failed.errors.map((e) => e.row),
    [2, 3]
  );
  assert.deepEqual(failed.ids, []);
  assert.deepEqual(await receiptCounts(), counts);
  const batch = await rpc('vehicle_bulk_receive', [input(2), input(3)]);
  assert.equal(batch.ids.length, 2);
  assert.equal((await search('', { pdi: true, unsold: true, unregistered: true })).length, 3);
  const battery = await value("select id from public.vehicle_components where serial_no='B-1'");
  const replacement = {
    vehicle_id: vid,
    id: battery,
    date: '2026-03-20',
    reason: 'Test replacement',
    replacement: { serial_no: 'R-01' },
  };
  await assert.rejects(
    rpc('component_replace', { ...replacement, replacement: { serial_no: 'B 2' } }),
    /Battery/
  );
  assert.equal((await detail(vid)).components.find((c) => c.serial_no === 'B-1').removed_on, null);
  await rpc('component_replace', replacement);
  const history = (await detail(vid)).components;
  assert.equal(history.find((c) => c.serial_no === 'B-1').removed_on, '2026-03-20');
  assert.equal(history.find((c) => c.serial_no === 'R-01').installed_on, '2026-03-20');
  assert.equal(await value('select battery_no from public.vehicles where id=$1', [vid]), 'BX-1');
  assert.equal((await search('r01'))[0].id, vid);
  await assert.rejects(
    query("update public.vehicle_components set spec='unauthorized'"),
    /permission denied/
  );
  await assert.rejects(
    query("select public.vehicle_save_internal('{}',true)"),
    /permission denied/
  );
  await as(owner);
  const transferVehicle = await rpc('ws_save_vehicle', {
    customer_id: customer,
    model_name: 'Transfer test',
    chassis_no: 'TRANSFER-01',
    purchase_date: '2025-01-01',
  });
  const buyer = await value(
    "insert into public.customers(name,phone,village) values ('Next owner','0123456789','Test') returning id"
  );
  const transfer = {
    vehicle_id: transferVehicle,
    customer_id: buyer,
    from_date: '2025-06-01',
    reason: 'Verified resale',
  };
  await as(inventory);
  await assert.rejects(rpc('vehicle_transfer_owner', transfer), /Manager approval/);
  const registration = {
    vehicle_id: vid,
    registration_no: ' up 12-a001 ',
    rto: 'Test office',
    registration_date: '2026-01-15',
  };
  const version = (await detail(vid)).vehicle.updated_at;
  const registrationId = await rpc('vehicle_set_registration', {
    ...registration,
    expected_updated_at: version,
  });
  assert.equal((await detail(vid)).vehicle.registration_no, 'UP12A001');
  assert.equal(await rpc('vehicle_set_registration', registration), registrationId);
  await assert.rejects(
    rpc('vehicle_set_registration', { ...registration, rto: 'Different' }),
    /reason/
  );
  await assert.rejects(
    rpc('vehicle_set_registration', {
      ...registration,
      registration_no: 'NEW01',
      reason: 'Correction',
      expected_updated_at: version,
    }),
    /changed/
  );
  await assert.rejects(
    rpc('vehicle_set_registration', { ...registration, vehicle_id: transferVehicle }),
    /already on.*CH-1/
  );
  await rpc('vehicle_set_registration', {
    ...registration,
    registration_no: 'UP 12-A002',
    reason: 'RTO correction',
  });
  const registered = await detail(vid);
  assert.equal(registered.registrations.length, 2);
  assert.equal(registered.registrations.find((r) => r.is_current).notes, 'RTO correction');
  assert.ok(registered.activity.some((a) => a.identifier === 'UP12A002'));
  assert.equal((await search('UP12A002'))[0].id, vid);
  const auxiliary = await rpc('component_save', {
    vehicle_id: vid,
    component_type: 'charger',
    serial_no: 'AUX-01',
  });
  await rpc('component_save', {
    vehicle_id: vid,
    id: auxiliary,
    brand: 'Updated brand',
    reason: 'Checked label',
  });
  await rpc('component_save', {
    vehicle_id: vid,
    id: auxiliary,
    action: 'remove',
    reason: 'Removed after inspection',
  });
  assert.ok((await detail(vid)).components.find((c) => c.id === auxiliary).removed_on);
  await as(owner);
  await assert.rejects(
    rpc('vehicle_transfer_owner', { ...transfer, from_date: '2024-01-01' }),
    /valid transfer date/
  );
  await rpc('vehicle_transfer_owner', transfer);
  const transferred = await detail(transferVehicle);
  const grouped = (q) => value('select public.db_search($1,$2,40)', [q, '{}']);
  for (const phone of ['9876543210', '+91 98765 43210', '98765-43210']) {
    const groups = await grouped(phone);
    assert.ok(groups.vehicles.some((v) => v.id === transferVehicle && v.matched_on === 'mobile'));
    assert.ok(groups.vehicles.some((v) => v.id === original));
    assert.doesNotMatch(JSON.stringify(groups), /SECRET|aadhaar|pan_no|id_document/);
  }
  for (const [q, why] of [
    ['CH-1', 'chassis'],
    ['motor1', 'motor'],
    ['R01', 'battery'],
    ['B-1', 'battery'],
    ['UP 12-A001', 'registration'],
    ['UP12A002', 'registration'],
  ]) {
    assert.ok((await grouped(q)).vehicles.some((v) => v.id === vid && v.matched_on === why));
  }
  const customerRecord = await value('select public.customer_360($1)', [customer]);
  assert.ok(customerRecord.vehicles.some((r) => r.vehicle.id === transferVehicle));
  assert.doesNotMatch(JSON.stringify(customerRecord), /SECRET|aadhaar|pan_no|id_document/);
  const exportRows = (ds, cols, f = {}, lim = 50000) =>
    value('select public.export_dataset($1,$2,$3,$4)', [ds, cols, JSON.stringify(f), lim]);
  const results = await grouped('9876543210');
  for (const [dataset, group, key] of [
    ['vehicles', 'vehicles', 'chassis'],
    ['components', 'components', 'serial'],
    ['customers', 'customers', 'owner'],
    ['sales', 'invoices', 'invoice'],
  ]) {
    const report = await exportRows(dataset, [key], { q: '9876543210', database_results: true });
    assert.deepEqual(
      report.rows.map((row) => row[key]).sort(),
      results[group].map((hit) => hit.title).sort()
    );
  }
  const exported = await exportRows('vehicles', ['mobile', 'chassis', 'pan_no'], {
    vehicle_id: original,
  });
  assert.deepEqual(exported.columns, ['mobile', 'chassis']);
  assert.deepEqual(exported.dropped, ['pan_no']);
  const sheets = Object.fromEntries(
    ['vehicles', 'components', 'ownership', 'registrations', 'customers', 'sales'].map((ds) => [
      ds,
      ds === 'sales' ? ['invoice'] : ds === 'customers' ? ['owner'] : ['chassis'],
    ])
  );
  const workbookData = await value('select public.export_workbook($1,$2,$3)', [
    'full_register',
    JSON.stringify(sheets),
    JSON.stringify({ vehicle_id: original }),
  ]);
  assert.deepEqual(Object.keys(workbookData).sort(), Object.keys(sheets).sort());
  assert.ok(workbookData.components.rows.every((row) => row.chassis === 'LEGACY-01'));
  assert.equal(exported.rows[0].chassis, 'LEGACY-01');
  await assert.rejects(exportRows('vehicles', ['chassis'], {}, 1), /exceeds/);
  for (const ds of [
    'stock',
    'customers',
    'components',
    'ownership',
    'registrations',
    'sales',
    'full_register',
  ]) {
    const result = await exportRows(ds, ['chassis', 'owner', 'amount']);
    assert.ok(Array.isArray(result.rows));
  }
  const saved = await rpc('export_template_save', {
    name: 'Custom report',
    dataset: 'vehicles',
    columns: [{ key: 'chassis', header: 'Unit' }],
    filters: { unsold: true },
    sheet_layout: 'single',
  });
  assert.deepEqual(
    await value('select columns from public.export_templates where id=$1', [saved]),
    [{ key: 'chassis', header: 'Unit' }]
  );
  await value('select public.export_template_delete($1)', [saved]);
  assert.ok((await value('select count(*)::int from public.export_log')) >= 8);
  await as(inventory);
  await assert.rejects(exportRows('vehicles', ['chassis']), /export permission/);
  await as(owner);
  await query(
    "select public.admin_save_permissions('inventory',array['vehicles.read','vehicles.export','vehicles.write'])"
  );
  await as(inventory);
  const restricted = await exportRows('vehicles', ['chassis', 'owner', 'mobile', 'invoice']);
  assert.deepEqual(restricted.columns, ['chassis']);
  assert.equal((await grouped('9876543210')).customers.length, 0);
  await as(owner);
  assert.equal(transferred.ownership.length, 2);
  assert.equal(transferred.ownership.find((o) => !o.to_date).source, 'transfer');
  assert.equal(
    transferred.ownership.find((o) => o.customer_id === customer).to_date,
    transfer.from_date
  );
  assert.equal(
    await value('select customer_id from public.vehicles where id=$1', [transferVehicle]),
    buyer
  );
  assert.ok(transferred.activity.some((a) => a.reason === transfer.reason));
  await assert.rejects(rpc('vehicle_transfer_owner', transfer), /different existing customer/);
  const workshopRow = await value('select to_jsonb(v) from public.vehicles v where id=$1', [
    original,
  ]);
  const correction = {
    ...workshopRow,
    battery_no: 'LEGACY-NEW',
    registration_no: 'UP 1 ABC',
    correction_reason: 'Corrected serials',
  };
  await rpc('ws_save_vehicle', correction);
  assert.equal((await detail(original)).registrations.length, 2);
  assert.equal((await detail(original)).components.length, 2);
  await assert.rejects(
    rpc('ws_save_vehicle', {
      model_name: 'Test tractor',
      chassis_no: 'Another chassis',
      customer_id: customer,
      registration_no: 'up-1abc',
    }),
    /Registration.*LEGACY-01/
  );
  const tractor = options.products.find((p) => p.category === 'tractor');
  const ice = { ...input(4), product_id: tractor.id, engine_no: 'ENGINE-04', motor_no: null };
  await rpc('vehicle_receive', ice);
  await assert.rejects(
    rpc('vehicle_receive', { ...ice, chassis_no: 'Tractor-05', engine_no: 'Eng ine04' }),
    /Engine.*CH-4/
  );
  const first = await detail(vid);
  assert.equal(first.pdi[0].result, 'pending');
  await db.exec('reset role');
  assert.equal(
    await value(
      "select count(*)::int from public.workshop_audit where after_record->>'serial_no'='R-01'"
    ),
    1
  );
  await as(mechanic);
  assert.equal((await detail(original)).ownership, null);
  assert.equal((await search('Legacy'))[0].owner_name, null);
  await assert.rejects(search('', { owner: 'Test' }), /Customer read/);
  await assert.rejects(rpc('vehicle_receive', input(9)), /Vehicle write/);
  await as(owner);
  await assert.rejects(
    query("select public.admin_save_permissions('mechanic',array['vehicles.export'])"),
    /requires view/
  );
  await query("select public.admin_save_permissions('mechanic',array['service.read'])");
  await db.exec("reset role; select set_config('request.jwt.claim.sub','',false)");
  await db.exec(migration);
  await as(mechanic);
  await assert.rejects(detail(vid), /Vehicle read/);
  assert.equal(await value('select count(*)::int from public.vehicle_components'), 0);
  await as(owner);
  assert.equal((await detail(original)).ownership.length, 1);
  assert.equal((await detail(original)).registrations.length, 2);
  if (process.env.REGISTER_BENCHMARK === '1') {
    await db.exec('reset role');
    await db.exec(`INSERT INTO public.customers(name,phone,village)
      SELECT 'Benchmark buyer ' || i, (8000000000::bigint + i)::text, 'Test village'
      FROM generate_series(1,1000) i;
      INSERT INTO public.vehicles(model_name,chassis_no,colour,customer_id)
      SELECT 'Benchmark tractor','BENCH-' || md5(i::text),'Blue',c.id
      FROM generate_series(1,5000) i LEFT JOIN public.customers c
        ON i <= 2500 AND c.phone=(8000000001::bigint + i % 1000)::text;
      INSERT INTO public.vehicle_components(vehicle_id,component_type,serial_no)
      SELECT id,'battery','BAT-' || chassis_no FROM public.vehicles WHERE chassis_no LIKE 'BENCH-%';
      ANALYZE public.vehicle_components;`);
    await db.exec('vacuum analyze public.vehicles');
    await db.exec('analyze public.customers; analyze public.vehicle_ownership');
    const chassis = await value("select 'BENCH-' || md5('2500')");
    const plan = await query(
      'explain (analyze, format json) select id from public.vehicles where search_text like $1',
      ['%' + chassis.slice(-10) + '%']
    );
    assert.match(JSON.stringify(plan), /vehicle_search_trgm_idx/);
    await as(owner);
    for (const term of [chassis, 'BAT-' + chassis, '+91 80000-00501']) {
      const start = performance.now();
      const result = await grouped(term);
      assert.equal(result.vehicles.length, term.startsWith('+91') ? 3 : 1);
      console.log('db_search', term, Math.round(performance.now() - start), 'ms');
    }
  }
  await db.exec('reset role; set role anon');
  await assert.rejects(detail(vid), /permission denied/);
  console.log(
    'PASS: vehicle register migration, legacy sync, intake, PDI stock, duplicates, CSV atomicity, component history, privacy and permissions.'
  );
} finally {
  await db.close();
}

// The import parser is shared with the browser. Transpile its type-only imports using the
// existing TypeScript dependency so the test works on the same Node versions as Next.
const ts = (await import('typescript')).default;
const csvModule = ts.transpileModule(readFileSync('src/lib/vehicles/csv.ts', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
});
const { parseShipment } = await import(
  'data:text/javascript;base64,' + Buffer.from(csvModule.outputText).toString('base64')
);
const sample =
  '\uFEFFproduct_code,chassis_no,motor_no,battery_serials,supplier\r\nEV,00001,00002,003|004,"Parts, ""North"""\r\n';
const products = [{ id: 'ev', code: 'EV' }];
const parsed = parseShipment(sample, products, 'test@example.test');
assert.deepEqual(parsed.errors, []);
assert.equal(parsed.rows[0].chassis_no, '00001');
assert.equal(parsed.rows[0].supplier, 'Parts, "North"');
assert.deepEqual(
  parsed.rows[0].components.map((c) => c.serial_no),
  ['003', '004']
);
assert.equal(parsed.rows[0].inspector_email, 'test@example.test');
assert.throws(
  () => parseShipment('product_code,chassis_no\n"broken', products, ''),
  /Unclosed quote/
);
assert.throws(
  () => parseShipment('product_code,chassis_no,chassis_no', products, ''),
  /template headers/
);
assert.deepEqual(
  parseShipment('product_code,chassis_no\nunknown,123\nEV,345,extra', products, '').errors.map(
    (e) => e.row
  ),
  [1, 2]
);
console.log('PASS: CSV quoting, component lists, leading zeroes and row validation.');
