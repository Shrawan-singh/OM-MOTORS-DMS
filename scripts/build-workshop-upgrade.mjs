import fs from 'node:fs';
import ts from 'typescript';
const mod={exports:{}};
new Function('exports',ts.transpileModule(fs.readFileSync('src/lib/workshop/checklists.ts','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText)(mod.exports);
const quote=s=>"'"+s.replaceAll("'","''")+"'";
const templates=Object.entries(mod.exports.checklistSections).map(([type,sections])=>{
 const items=Object.entries(sections).flatMap(([section,labels])=>labels.map((label,i)=>({id:`${section}-${i}`,section,label,required:true,result:'',notes:''})));
 return `INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES (${quote(type.replaceAll('_',' ')+' intake')},${quote(type)},${quote(JSON.stringify(items))}::jsonb);`;
}).join('\n');
fs.writeFileSync('supabase/migrations/20260913_011_pdi_templates.sql','BEGIN;\n-- Configurable checklist templates, not business/demo records.\n'+templates+'\nCOMMIT;\n');
const files=fs.readdirSync('supabase/migrations').filter(n=>n.startsWith('20260913_')).sort();
fs.writeFileSync('supabase/UPGRADE_WORKSHOP.sql','-- Run once AFTER UPGRADE_LIVE_OPERATIONS.sql. Preserves existing records.\n-- Adds General Manager and scoped workshop roles; no users are assigned automatically.\nBEGIN;\n'+files.map(n=>fs.readFileSync('supabase/migrations/'+n,'utf8').replace(/^BEGIN;\r?$/gm,'').replace(/^COMMIT;\r?$/gm,'')).join('\n')+'\nCOMMIT;\n');
