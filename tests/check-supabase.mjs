const base=process.env.NEXT_PUBLIC_SUPABASE_URL;
const headers={apikey:process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY};
for (const endpoint of ['/auth/v1/settings','/rest/v1/rpc/my_access','/rest/v1/customers?select=id&limit=0','/rest/v1/catalog_products?select=id&limit=0','/rest/v1/billing_documents?select=id&limit=0','/rest/v1/rpc/ws_snapshot']) {
 try { const r=await fetch(base+endpoint,{headers,signal:AbortSignal.timeout(10000)}); const d=await r.json(); console.log(endpoint,r.status,endpoint.includes('settings')?{googleEnabled:d.external?.google,error:d.msg||d.message}: {code:d.code,message:d.message}); } catch(e) {console.log(endpoint,e.message,e.cause?.code);process.exitCode=1;}
}


