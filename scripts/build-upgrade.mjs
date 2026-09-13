import fs from 'node:fs';
const files=['supabase/migrations/20260912_003_live_operations.sql','supabase/migrations/20260912_004_verified_products.sql'];
fs.writeFileSync('supabase/UPGRADE_LIVE_OPERATIONS.sql','-- Run ONCE on the existing OM Motors project after the original setup.\n-- Adds operational tables, transactional billing and the supplied product catalogue.\n-- Does not delete existing database records or grant new staff roles.\nBEGIN;\n'+files.map(f=>fs.readFileSync(f,'utf8').replace(/^BEGIN;\r?$/gm,'').replace(/^COMMIT;\r?$/gm,'')).join('\n')+'\nNOTIFY pgrst, \'reload schema\';\nCOMMIT;\n');
// Keep package scripts independent of SQL generation.
